package core

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"
)

var errHGHubNoMedia = errors.New("黄果没有返回播放地址")

var errHGHubRestricted = errors.New("黄果请求受限，请稍后重试")

func (d *Downloader) hghubRequest(ctx context.Context, method, path string) (map[string]any, error) {
	body, contentType := "", ""
	if method == http.MethodPost {
		body, contentType = base64.StdEncoding.EncodeToString([]byte("{}")), "application/json"
	}
	envelope, _ := json.Marshal(map[string]string{"method": method, "path": path, "body": body, "content_type": contentType})
	base := d.providerBaseURL(sourceHuangguoAI)
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, base+"/api/edge/request", bytes.NewReader(envelope))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Accept", "application/json")
	req.Header.Set("Referer", base+"/")
	req.Header.Set("User-Agent", userAgent)
	response, err := d.doCatalogRequestWithTimeout(req, 15*time.Second)
	if err != nil {
		return nil, err
	}
	defer response.Body.Close()
	if response.StatusCode == 401 || response.StatusCode == 403 || response.StatusCode == 429 || response.Header.Get("Retry-After") != "" {
		return nil, errHGHubRestricted
	}
	if response.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("黄果接口 HTTP %d", response.StatusCode)
	}
	var value struct {
		Status int            `json:"status"`
		Data   map[string]any `json:"data"`
	}
	if err := json.NewDecoder(io.LimitReader(response.Body, 8<<20)).Decode(&value); err != nil {
		return nil, fmt.Errorf("黄果接口数据无效: %w", err)
	}
	if value.Status != 1 || value.Data == nil {
		return nil, errors.New("黄果接口未返回可用数据")
	}
	return value.Data, nil
}

func (d *Downloader) hghubCatalog(ctx context.Context, page int, category, query string) ([]Drama, bool, error) {
	path := "/api/videos"
	values := url.Values{"page": {strconv.Itoa(max(1, page))}, "size": {"24"}}
	if query != "" {
		path = "/api/search"
		values.Set("q", query)
	} else if category != "" {
		path += "/category/" + url.PathEscape(category)
	}
	data, err := d.hghubRequest(ctx, http.MethodGet, path+"?"+values.Encode())
	if err != nil {
		return nil, false, err
	}
	var items []Drama
	for _, item := range anyList(data["items"]) {
		row, _ := item.(map[string]any)
		if drama, ok := dramaFromAIMap(row, d.providerBaseURL(sourceHuangguoAI), category); ok {
			items = append(items, drama)
		}
	}
	pagination, _ := data["pagination"].(map[string]any)
	pages, _ := strconv.Atoi(mapString(pagination, "pages"))
	return items, page < pages, nil
}

func (d *Downloader) hghubDetail(ctx context.Context, id string) (Drama, []Chapter, error) {
	data, err := d.hghubRequest(ctx, http.MethodGet, "/api/videos/"+id)
	if err != nil {
		return Drama{}, nil, err
	}
	if mapString(data, "id") != id {
		return Drama{}, nil, errors.New("黄果返回了其他剧集")
	}
	drama, ok := dramaFromAIMap(data, d.providerBaseURL(sourceHuangguoAI), "")
	if !ok {
		return Drama{}, nil, errors.New("黄果剧集信息无效")
	}
	var chapters []Chapter
	seen := map[int]bool{}
	for _, item := range anyList(data["episodes"]) {
		row, _ := item.(map[string]any)
		number, err := strconv.Atoi(mapString(row, "ep_num"))
		if err != nil || number < 1 || seen[number] {
			return Drama{}, nil, errors.New("黄果分集编号无效")
		}
		seen[number] = true
		chapters = append(chapters, Chapter{ID: providerChapterID(sourceHuangguoAI, id, strconv.Itoa(number)), Source: sourceHuangguoAI, Title: firstNonEmpty(mapString(row, "title"), fmt.Sprintf("第%d集", number)), VideoURL: "hghub://" + id + "/" + strconv.Itoa(number), CurrentEpisode: rawEpisode(number)})
	}
	sortProviderChapters(chapters)
	return drama, chapters, nil
}

func (d *Downloader) resolveHGHub(ctx context.Context, task Task) (providerMedia, error) {
	source, id, valid := splitProviderDramaID(task.DramaID)
	if !valid || source != sourceHuangguoAI || !hongguoNumericID.MatchString(id) || task.Index < 1 || task.Chapter.VideoURL != "hghub://"+id+"/"+strconv.Itoa(task.Index) {
		return providerMedia{}, errors.New("黄果播放条目无效")
	}
	normalize := func(data map[string]any) (providerMedia, error) {
		if value := mapString(data, "id"); value != "" && value != id {
			return providerMedia{}, errors.New("黄果播放剧集不一致")
		}
		if ep := mapString(data, "ep_num"); ep != "" && ep != strconv.Itoa(task.Index) {
			return providerMedia{}, errors.New("黄果播放集数不一致")
		}
		streams, _ := data["streams"].(map[string]any)
		address := firstNonEmpty(mapString(data, "video_url"), mapString(streams, "main"), mapString(data, "video_url_hevc"), mapString(streams, "hevc"))
		parsed, err := url.Parse(address)
		if err != nil || !strings.EqualFold(parsed.Scheme, "https") && !strings.EqualFold(parsed.Scheme, "http") || parsed.Host == "" {
			return providerMedia{}, errHGHubNoMedia
		}
		return providerMedia{URL: address, Referer: d.providerBaseURL(sourceHuangguoAI) + "/"}, nil
	}
	data, err := d.hghubRequest(ctx, http.MethodPost, fmt.Sprintf("/api/videos/%s/episodes/%d/playback", id, task.Index))
	if ctx.Err() != nil {
		return providerMedia{}, ctx.Err()
	}
	if errors.Is(err, errHGHubRestricted) {
		return providerMedia{}, err
	}
	if err == nil {
		if media, e := normalize(data); e == nil {
			return media, nil
		} else if !errors.Is(e, errHGHubNoMedia) {
			return providerMedia{}, e
		}
	}
	legacy, e := d.hghubRequest(ctx, http.MethodGet, fmt.Sprintf("/api/videos/%s/play?ep=%d&page_texts=0", id, task.Index))
	if e != nil {
		return providerMedia{}, e
	}
	return normalize(legacy)
}

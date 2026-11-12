package core

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"
)

const hongguoSearchAPIPath = "/api/search/result"

func (d *Downloader) fetchHongguoSearchAPI(ctx context.Context, keyword string, page int) (hongguoSearchEntry, error) {
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	query := url.Values{"aid": {"8662"}, "query": {keyword}, "page": {strconv.Itoa(page)}}
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, hongguoBaseURL+hongguoSearchAPIPath+"?"+query.Encode(), nil)
	if err != nil {
		return hongguoSearchEntry{}, err
	}
	request.Header.Set("User-Agent", userAgent)
	request.Header.Set("Referer", hongguoBaseURL+"/")
	request.Header.Set("Accept", "application/json, text/plain, */*")
	request.Header.Set("Accept-Language", "zh-CN,zh;q=0.9")
	response, err := d.doCatalogRequestWithTimeout(request, 5*time.Second)
	if err != nil {
		return hongguoSearchEntry{}, err
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		return hongguoSearchEntry{}, errors.New("红果官网搜索暂不可用")
	}
	body, err := io.ReadAll(io.LimitReader(response.Body, providerMaxBodyBytes+1))
	if err != nil {
		return hongguoSearchEntry{}, err
	}
	if len(body) > providerMaxBodyBytes {
		return hongguoSearchEntry{}, errors.New("红果官网搜索响应过大")
	}
	return parseHongguoSearchAPI(string(body), page)
}

func parseHongguoSearchAPI(body string, page int) (hongguoSearchEntry, error) {
	decoder := json.NewDecoder(strings.NewReader(body))
	decoder.UseNumber()
	var payload map[string]any
	if decoder.Decode(&payload) != nil {
		return hongguoSearchEntry{}, errors.New("红果官网搜索响应格式异常")
	}
	if code := mapString(payload, "code"); code != "" && code != "0" {
		return hongguoSearchEntry{}, errors.New("红果官网搜索返回错误")
	}
	if actual := mapString(payload, "pageNum"); actual != "" && actual != strconv.Itoa(page) {
		return hongguoSearchEntry{}, errors.New("红果官网搜索页码不一致")
	}
	rows, valid := payload["searchList"].([]any)
	if !valid {
		return hongguoSearchEntry{}, errors.New("红果官网搜索缺少结果列表")
	}
	entry := hongguoSearchEntry{Dramas: []Drama{}, WebAPI: true}
	seen := map[string]bool{}
	for _, row := range rows {
		drama := hongguoDramaFromAny(row, "短剧")
		if drama.ID == "" || drama.DisplayTitle() == drama.SourceID {
			continue
		}
		if !seen[drama.ID] {
			seen[drama.ID] = true
			entry.Dramas = append(entry.Dramas, drama)
		}
	}
	if len(rows) > 0 && len(entry.Dramas) == 0 {
		return hongguoSearchEntry{}, errors.New("红果官网搜索结果无法识别")
	}
	entry.Total, _ = strconv.Atoi(mapString(payload, "totalCount"))
	entry.Total = max(entry.Total, len(entry.Dramas))
	entry.HasMore = payload["hasMore"] == true && len(rows) > 0
	return entry, nil
}

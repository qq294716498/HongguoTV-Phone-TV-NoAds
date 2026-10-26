package core

import (
	"context"
	"encoding/json"
	"errors"
	"html"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"
)

const hongguoSearchAppPath = "/reading/bookapi/search/tab/v"

type hongguoSearchCursor struct {
	Passback  string
	SearchID  string
	Offset    string
	HasMore   bool
	ExpiresAt time.Time
}

func (d *Downloader) fetchHongguoAppSearch(ctx context.Context, keyword string, page int) (hongguoSearchEntry, error) {
	identity, err := d.ensureHongguoDeviceIdentity(ctx)
	if err != nil {
		return hongguoSearchEntry{}, err
	}
	type tabResult struct {
		entry hongguoSearchEntry
		err   error
	}
	results := make(chan tabResult, 2)
	for _, tab := range []string{"11", "19"} {
		go func(tab string) {
			batch, err := d.fetchHongguoAppSearchTab(ctx, keyword, tab, page, identity)
			results <- tabResult{batch, err}
		}(tab)
	}
	entry := hongguoSearchEntry{Dramas: []Drama{}}
	var failures []error
	for range 2 {
		result := <-results
		entry.Dramas = mergeHongguoSearchDramas(entry.Dramas, result.entry.Dramas)
		entry.Total += result.entry.Total
		entry.HasMore = entry.HasMore || result.entry.HasMore
		reportHongguoSearchProgress(ctx, entry)
		if result.err != nil {
			entry.Limited = true
			failures = append(failures, result.err)
		}
	}
	entry.Total = max(entry.Total, len(entry.Dramas))
	return entry, errors.Join(failures...)
}

func (d *Downloader) fetchHongguoAppSearchTab(ctx context.Context, keyword, tabType string, page int, identity hongguoDeviceIdentity) (hongguoSearchEntry, error) {
	client := d.hongguoClient()
	cursorKey := func(page int) string { return keyword + "\x00" + tabType + "\x00" + strconv.Itoa(page) }
	previous := hongguoSearchCursor{Offset: "0", HasMore: true}
	if page > 1 {
		client.searchCursorMu.Lock()
		previous = client.searchCursors[cursorKey(page-1)]
		client.searchCursorMu.Unlock()
		if !time.Now().Before(previous.ExpiresAt) {
			return hongguoSearchEntry{}, errors.New("搜索结果已过期，请从第 1 页重新搜索")
		}
		if !previous.HasMore {
			return hongguoSearchEntry{Dramas: []Drama{}}, nil
		}
	}
	params := url.Values{
		"query": {keyword}, "count": {"20"}, "offset": {previous.Offset}, "tab_type": {tabType}, "bookshelf_search_plan": {"4"}, "use_correct": {"true"}, "user_is_login": {"0"},
		"device_id": {identity.DeviceID}, "iid": {identity.InstallID}, "version_code": {"72232"}, "version_name": {"7.2.2.32"}, "manifest_version_code": {"72232"}, "update_version_code": {"72232"}, "pv_player": {"72232"},
	}
	if previous.Passback != "" {
		params.Set("passback", previous.Passback)
	}
	if previous.SearchID != "" {
		params.Set("search_id", previous.SearchID)
	}
	result, err := d.hongguoAppRequest(ctx, http.MethodGet, hongguoSearchAppPath, params, nil)
	if err != nil {
		return hongguoSearchEntry{}, err
	}
	var tab map[string]any
	for _, value := range anyList(result["search_tabs"]) {
		candidate, _ := value.(map[string]any)
		if mapString(candidate, "tab_type") == tabType {
			tab = candidate
			break
		}
	}
	if tab == nil {
		return hongguoSearchEntry{}, errors.New("红果 App 搜索未返回所请求的分类")
	}
	rows, valid := tab["data"].([]any)
	if !valid && tab["data"] != nil {
		return hongguoSearchEntry{}, errors.New("红果 App 搜索未返回有效列表")
	}
	more := mapString(tab, "has_more")
	if more != "true" && more != "false" && more != "0" && more != "1" {
		return hongguoSearchEntry{}, errors.New("红果 App 搜索缺少分页状态")
	}
	entry := hongguoSearchEntry{Dramas: []Drama{}, HasMore: more == "true" || more == "1"}
	for _, row := range rows {
		entry.Dramas = mergeHongguoSearchDramas(entry.Dramas, hongguoAppSearchDramas(row, 0))
	}
	entry.Total, _ = strconv.Atoi(mapString(tab, "total_count", "total"))
	entry.Total = max(entry.Total, len(entry.Dramas))
	cursor := hongguoSearchCursor{Passback: mapString(tab, "passback"), SearchID: mapString(tab, "search_id"), Offset: mapString(tab, "next_offset"), HasMore: entry.HasMore, ExpiresAt: time.Now().Add(5 * time.Minute)}
	if entry.HasMore {
		next, offsetErr := strconv.Atoi(cursor.Offset)
		current, _ := strconv.Atoi(previous.Offset)
		if cursor.SearchID == "" || cursor.Passback == "" || offsetErr != nil || next <= current || cursor.Passback == previous.Passback {
			entry.HasMore = false
			return entry, errors.New("红果 App 搜索分页游标未推进")
		}
	}
	client.searchCursorMu.Lock()
	if client.searchCursors == nil {
		client.searchCursors = map[string]hongguoSearchCursor{}
	}
	for key, saved := range client.searchCursors {
		if !time.Now().Before(saved.ExpiresAt) {
			delete(client.searchCursors, key)
		}
	}
	if len(client.searchCursors) >= 256 {
		oldestKey := ""
		oldest := time.Now().Add(6 * time.Minute)
		for key, saved := range client.searchCursors {
			if saved.ExpiresAt.Before(oldest) {
				oldestKey, oldest = key, saved.ExpiresAt
			}
		}
		delete(client.searchCursors, oldestKey)
	}
	client.searchCursors[cursorKey(page)] = cursor
	client.searchCursorMu.Unlock()
	return entry, nil
}

func hongguoAppSearchDramas(value any, depth int) []Drama {
	if depth > 8 {
		return nil
	}
	row, ok := value.(map[string]any)
	if !ok {
		return nil
	}
	var dramas []Drama
	videos, _ := row["video_data"].([]any)
	if video := nestedMap(row, "video_data"); video != nil {
		videos = append(videos, video)
	}
	if mapString(row, "series_id", "series_id_str") != "" {
		videos = append(videos, row)
	}
	for _, video := range videos {
		data, _ := video.(map[string]any)
		normalized := make(map[string]any, len(data)+4)
		for key, value := range data {
			normalized[key] = value
		}
		normalized["series_id"] = firstNonEmpty(mapString(data, "series_id_str", "series_id"), mapString(row, "book_id", "search_result_id"))
		title := firstNonEmpty(mapString(data, "series_title", "series_name", "title"), mapString(nestedMap(row, "search_high_light", "title"), "text"), mapString(row, "cell_name"))
		title = html.UnescapeString(strings.NewReplacer("<em>", "", "</em>", "").Replace(title))
		normalized["series_title"] = title
		normalized["cover"] = firstNonEmpty(mapString(data, "series_cover", "cover", "cover_url"))
		normalized["episode_cnt"] = firstNonEmpty(mapString(data, "episode_cnt"), mapString(nestedMap(data, "series_episode_info"), "episode_cnt"))
		normalized["episode_right_text"] = firstNonEmpty(mapString(data, "episode_right_text", "rec_text", "sub_title"))
		if title != "" {
			if drama := hongguoDramaFromAny(normalized, "短剧"); drama.ID != "" {
				dramas = mergeHongguoSearchDramas(dramas, []Drama{drama})
			}
		}
	}
	if raw := mapString(row, "lynx_data"); raw != "" {
		var decoded map[string]any
		decoder := json.NewDecoder(strings.NewReader(raw))
		decoder.UseNumber()
		if decoder.Decode(&decoded) == nil {
			dramas = mergeHongguoSearchDramas(dramas, hongguoAppSearchDramas(decoded, depth+1))
		}
	}
	for _, key := range []string{"cell_data", "data", "items"} {
		switch nested := row[key].(type) {
		case map[string]any:
			dramas = mergeHongguoSearchDramas(dramas, hongguoAppSearchDramas(nested, depth+1))
		case []any:
			for _, item := range nested {
				dramas = mergeHongguoSearchDramas(dramas, hongguoAppSearchDramas(item, depth+1))
			}
		}
	}
	return dramas
}

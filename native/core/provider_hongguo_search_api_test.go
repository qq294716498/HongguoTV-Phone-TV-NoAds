package core

import (
	"context"
	"fmt"
	"net/http"
	"strings"
	"testing"
	"time"
)

func TestHongguoWebsiteSearchNoRegistrationAndPages(t *testing.T) {
	calls := 0
	d := sourceFixtureDownloader(t, func(r *http.Request) (*http.Response, error) {
		calls++
		if r.URL.Path != hongguoSearchAPIPath {
			t.Fatalf("unexpected path %s", r.URL.Path)
		}
		if r.URL.Query().Get("aid") != "8662" || r.URL.Query().Get("query") != "合成故事" || r.Header.Get("X-Gorgon") != "" {
			t.Fatal("wrong website request")
		}
		page := r.URL.Query().Get("page")
		return sourceFixtureResponse(r, 200, fmt.Sprintf(`{"searchList":[{"video_data":{"series_id":764819044682853890%s,"series_title":"合成故事第%s季","series_cover":"https://example.test/poster.jpg","episode_cnt":20}}],"totalCount":"2","pageNum":%s,"hasMore":%t}`, page, page, page, page == "1")), nil
	}, false)
	first, err := d.searchHongguoDramasPage(context.Background(), "合成故事", 1)
	if err != nil || len(first.Dramas) != 1 || !first.HasMore || !first.WebAPI || first.Dramas[0].SourceID != "7648190446828538901" || first.Dramas[0].Cover == "" {
		t.Fatalf("first: %+v %v", first, err)
	}
	second, err := d.searchHongguoDramasPage(context.Background(), "合成故事", 2)
	if err != nil || len(second.Dramas) != 1 || second.HasMore || second.Dramas[0].SourceID != "7648190446828538902" {
		t.Fatalf("second: %+v %v", second, err)
	}
	_, err = d.searchHongguoDramasPage(context.Background(), "合成故事", 1)
	if err != nil || calls != 2 {
		t.Fatalf("cache: %d %v", calls, err)
	}
	client := d.hongguoClient()
	client.mu.Lock()
	expired := client.searches["合成故事\x001"]
	expired.ExpiresAt = time.Now().Add(-time.Second)
	client.searches["合成故事\x001"] = expired
	client.mu.Unlock()
	_, err = d.searchHongguoDramasPage(context.Background(), "合成故事", 1)
	if err != nil {
		t.Fatal(err)
	}
	client.mu.Lock()
	_, stale := client.searches["合成故事\x002"]
	client.mu.Unlock()
	if stale {
		t.Fatal("new first page retained stale second page")
	}
}
func TestHongguoWebsiteSearchParser(t *testing.T) {
	for _, body := range []string{`{}`, `{"code":"FAIL","searchList":[]}`, `{"searchList":[{"broken":true}]}`, `{"searchList":[],"pageNum":2}`, `<html>blocked</html>`} {
		if _, err := parseHongguoSearchAPI(body, 1); err == nil {
			t.Fatalf("accepted %s", body)
		}
	}
	entry, err := parseHongguoSearchAPI(`{"searchList":[],"pageNum":1,"totalCount":0,"hasMore":false}`, 1)
	if err != nil || len(entry.Dramas) != 0 || entry.HasMore {
		t.Fatal("valid empty response rejected")
	}
	entry, err = parseHongguoSearchAPI(`{"searchList":[{"keyword":"7648190446828538904","name":"合成故事第二季","video_data":{}}],"hasMore":false}`, 1)
	if err != nil || len(entry.Dramas) != 1 || entry.Dramas[0].DisplayTitle() != "合成故事第二季" {
		t.Fatal("name-only result lost")
	}
}
func TestHongguoWebsiteContinuationFailureDoesNotMixAppPages(t *testing.T) {
	d := sourceFixtureDownloader(t, func(r *http.Request) (*http.Response, error) {
		if r.URL.Path != hongguoSearchAPIPath {
			t.Fatalf("mixed continuation route %s", r.URL.Path)
		}
		if r.URL.Query().Get("page") == "2" {
			return sourceFixtureResponse(r, 503, ""), nil
		}
		return sourceFixtureResponse(r, 200, `{"searchList":[{"keyword":"1234567","name":"合成故事"}],"pageNum":1,"hasMore":true}`), nil
	}, false)
	if _, err := d.searchHongguoDramasPage(context.Background(), "合成故事", 1); err != nil {
		t.Fatal(err)
	}
	if _, err := d.searchHongguoDramasPage(context.Background(), "合成故事", 2); err == nil {
		t.Fatal("failed continuation looked complete")
	}
}
func TestHongguoWebsiteSearchCancelledDoesNotFallback(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	d := sourceFixtureDownloader(t, func(r *http.Request) (*http.Response, error) {
		if !strings.HasSuffix(r.URL.Path, hongguoSearchAPIPath) {
			t.Fatal("cancelled search fell back")
		}
		cancel()
		return nil, ctx.Err()
	}, false)
	if _, err := d.searchHongguoDramasPage(ctx, "合成故事", 1); err == nil {
		t.Fatal("cancel lost")
	}
}

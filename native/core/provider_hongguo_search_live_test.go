package core

import (
	"context"
	"net/http"
	"os"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

func TestLiveHongguoSignedSearchPagination(t *testing.T) {
	if os.Getenv("HG_SEARCH_LIVE") != "1" {
		t.Skip("HG_SEARCH_LIVE=1")
	}
	keyword := os.Getenv("HG_SEARCH_QUERY")
	if keyword == "" {
		keyword = "万妖图录传"
	}
	var pages atomic.Int32
	d := sourceFixtureDownloader(t, func(request *http.Request) (*http.Response, error) {
		if request.URL.Path == hongguoSearchAppPath {
			pages.Add(1)
		}
		return http.DefaultTransport.RoundTrip(request)
	}, false)
	ctx, cancel := context.WithTimeout(context.Background(), 35*time.Second)
	defer cancel()
	first, err := d.searchHongguoDramasPage(ctx, keyword, 1)
	if err != nil {
		t.Fatalf("搜索请求失败（%T）：%v", err, publicError(err))
	}
	if !first.HasMore {
		t.Fatalf("未获得 App 后续页：请求数=%d，结果数=%d，提示=%s", pages.Load(), len(first.Dramas), first.Warning)
	}
	entry, err := d.searchHongguoDramasPage(ctx, keyword, 2)
	entry.Dramas = mergeHongguoSearchDramas(first.Dramas, entry.Dramas)
	t.Logf("App search pages=%d dramas=%d limited=%t errorType=%T", pages.Load(), len(entry.Dramas), entry.Limited, err)
	if err != nil {
		t.Fatalf("搜索请求失败（%T）：%v", err, publicError(err))
	}
	if len(entry.Dramas) == 0 {
		t.Fatal("App 搜索没有剧集")
	}
	if pages.Load() < 3 {
		t.Fatal("未验证第二页游标")
	}
	for _, drama := range entry.Dramas {
		if strings.HasPrefix(drama.DisplayTitle(), keyword) {
			t.Logf("title=%s", drama.DisplayTitle())
		}
	}
}

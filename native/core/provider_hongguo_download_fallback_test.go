package core

import (
	"context"
	"errors"
	"net/http"
	"testing"
)

// v5 空正文 + 下载上下文：必须和前台播放一样补一次 video_tab，否则播放能取流而
// 下载直接失败。下载管理器给 ctx 打了 backgroundCatalogKey，这里同时带上
// hongguoDownloadKey，回到真实的调度形态。
func TestHongguoDownloadEmptyResponseUsesVideoTabFallback(t *testing.T) {
	mobileCalls, tabCalls := 0, 0
	d := sourceFixtureDownloader(t, func(r *http.Request) (*http.Response, error) {
		switch r.URL.Path {
		case "/novel/player/multi_video_model/player/v1":
			mobileCalls++
			return sourceFixtureResponse(r, 200, ""), nil
		case hongguoVideoTabPath:
			tabCalls++
			return sourceFixtureResponse(r, 200, videoTabFixtureModel("9001")), nil
		}
		t.Fatalf("unexpected path %s", r.URL.Path)
		return nil, nil
	})
	searchFixtureIdentity(d)
	ctx := context.WithValue(context.Background(), backgroundCatalogKey{}, true)
	ctx = context.WithValue(ctx, hongguoDownloadKey{}, true)
	media, err := d.resolveHongguoMobileMedia(ctx, "9001")
	if err != nil {
		t.Fatalf("下载任务应回退 video_tab: %v", err)
	}
	if media.URL != "https://media.example.test/test.mp4" {
		t.Fatalf("unexpected media url %q", media.URL)
	}
	if mobileCalls != len(hongguoPlayModelHosts) || tabCalls != 1 {
		t.Fatalf("unexpected calls mobile=%d tab=%d", mobileCalls, tabCalls)
	}
}

// 空闲预取保持原样：不补 video_tab、不重试，避免后台任务抢播放通道。
func TestHongguoBackgroundPrefetchSkipsVideoTab(t *testing.T) {
	mobileCalls, tabCalls := 0, 0
	d := sourceFixtureDownloader(t, func(r *http.Request) (*http.Response, error) {
		switch r.URL.Path {
		case "/novel/player/multi_video_model/player/v1":
			mobileCalls++
			return sourceFixtureResponse(r, 200, ""), nil
		case hongguoVideoTabPath:
			tabCalls++
			return sourceFixtureResponse(r, 200, videoTabFixtureModel("9001")), nil
		}
		t.Fatalf("unexpected path %s", r.URL.Path)
		return nil, nil
	})
	searchFixtureIdentity(d)
	ctx := context.WithValue(context.Background(), backgroundCatalogKey{}, true)
	_, err := d.resolveHongguoMobileMedia(ctx, "9001")
	if !errors.Is(err, errHongguoEmptyResponse) {
		t.Fatalf("后台预取不应回退，err = %v", err)
	}
	if mobileCalls != 1 || tabCalls != 0 {
		t.Fatalf("unexpected calls mobile=%d tab=%d", mobileCalls, tabCalls)
	}
}

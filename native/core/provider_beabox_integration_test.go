package core

import (
	"context"
	"encoding/json"
	"net/http"
	"os"
	"testing"
	"time"
)

func TestBeaboxCatalogDetailAndPlaybackIntegration(t *testing.T) {
	row := map[string]any{"vodId": "sample01", "vodName": "合成样本", "vodPlaySource": map[string]any{"beabox-app": []any{map[string]any{"from": "beabox-app", "flag": "第1集", "url": "https://media.example.test/a.mp4", "playUrl": "https://media.example.test/a.mp4"}}}}
	d := sourceFixtureDownloader(t, func(r *http.Request) (*http.Response, error) {
		var value any
		switch r.URL.Path {
		case "/api/vod/search", "/api/vod/latest":
			value = map[string]any{"data": []any{row}, "totalPages": 2}
		case "/api/vod/detail/sample01":
			value = row
		case "/api/configs":
			value = map[string]any{"home_tags": "分类甲,分类乙"}
		default:
			t.Fatalf("unexpected request %s", r.URL.Path)
		}
		body, _ := json.Marshal(map[string]any{"code": 200, "data": beaboxFixtureCiphertext(t, value)})
		return sourceFixtureResponse(r, 200, string(body)), nil
	})
	ctx := context.Background()
	categories, err := d.fetchBeaboxCategories(ctx)
	if err != nil || len(categories) != 2 {
		t.Fatal(categories, err)
	}
	for _, query := range []string{"", "合成"} {
		rows, more, err := d.fetchBeaboxCatalogPage(ctx, 1, "", query)
		if err != nil || len(rows) != 1 || !more {
			t.Fatal(rows, more, err)
		}
	}
	drama, chapters, err := d.fetchBeaboxDetail(ctx, "sample01")
	if err != nil || len(chapters) != 1 {
		t.Fatal(err)
	}
	media, err := d.resolveBeaboxMedia(ctx, Task{DramaID: drama.ID, Chapter: chapters[0]})
	if err != nil || media.URL != "https://media.example.test/a.mp4" {
		t.Fatal(media, err)
	}
}

func TestBeaboxRestrictionDoesNotDiscoverOrRotate(t *testing.T) {
	for _, status := range []int{403, 429} {
		calls := 0
		d := sourceFixtureDownloader(t, func(r *http.Request) (*http.Response, error) {
			calls++
			return sourceFixtureResponse(r, status, ""), nil
		})
		_, _, err := d.fetchBeaboxCatalogPage(context.Background(), 1, "", "")
		if err == nil || calls != 1 {
			t.Fatalf("restriction did not stop: %d %v", calls, err)
		}
	}
}

func TestLiveBeaboxCatalogMetadata(t *testing.T) {
	if os.Getenv("BEABOX_LIVE") != "1" {
		t.Skip("explicit metadata-only source verification")
	}
	engine, err := newNativeEngine(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(engine.downloads.close)
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	categories, err := engine.downloader.fetchBeaboxCategories(ctx)
	if err != nil {
		t.Fatal(err)
	}
	rows, _, err := engine.downloader.fetchBeaboxCatalogPage(ctx, 1, "", "")
	if err != nil {
		t.Fatal(err)
	}
	if len(categories) == 0 || len(rows) == 0 {
		t.Fatal("empty source metadata")
	}
	t.Logf("metadata verified: categories=%d rows=%d; no images or media fetched", len(categories), len(rows))
}

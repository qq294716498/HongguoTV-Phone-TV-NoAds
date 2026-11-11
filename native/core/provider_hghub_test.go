package core

import (
	"context"
	"encoding/json"
	"net/http"
	"os"
	"strings"
	"testing"
	"time"
)

func TestHGHubGuestProtocolAndPlayback(t *testing.T) {
	for _, fallback := range []bool{false, true} {
		calls := 0
		d := sourceFixtureDownloader(t, func(r *http.Request) (*http.Response, error) {
			calls++
			if r.Method != "POST" || r.URL.Path != "/api/edge/request" || r.Header.Get("Authorization") != "" {
				t.Fatal(r.Method, r.URL)
			}
			var envelope map[string]string
			if err := json.NewDecoder(r.Body).Decode(&envelope); err != nil {
				t.Fatal(err)
			}
			var data any
			switch {
			case strings.HasPrefix(envelope["path"], "/api/videos?page="):
				data = map[string]any{"items": []any{map[string]any{"id": 123, "title": "合成剧", "episode_count": 1}}, "pagination": map[string]any{"pages": 2}}
			case envelope["path"] == "/api/videos/123":
				data = map[string]any{"id": 123, "title": "合成剧", "episodes": []any{map[string]any{"ep_num": 1}}}
			case envelope["path"] == "/api/videos/123/episodes/1/playback":
				if envelope["body"] != "e30=" || envelope["method"] != "POST" {
					t.Fatal(envelope)
				}
				data = map[string]any{"id": 123, "ep_num": 1, "streams": map[string]any{"main": "https://media.example.test/a.mp4"}}
				if fallback {
					data = map[string]any{}
				}
			case envelope["path"] == "/api/videos/123/play?ep=1&page_texts=0":
				if !fallback || envelope["method"] != "GET" || envelope["body"] != "" {
					t.Fatal(envelope)
				}
				data = map[string]any{"video_url": "https://media.example.test/a.mp4"}
			default:
				t.Fatal(envelope)
			}
			raw, _ := json.Marshal(map[string]any{"status": 1, "data": data})
			return sourceFixtureResponse(r, 200, string(raw)), nil
		})
		rows, more, err := d.hghubCatalog(context.Background(), 1, "", "")
		if err != nil || len(rows) != 1 || !more {
			t.Fatal(rows, more, err)
		}
		drama, chapters, err := d.fetchHuangguoAIDetail(context.Background(), "123")
		if err != nil || len(chapters) != 1 {
			t.Fatal(err)
		}
		media, err := d.resolveProviderMedia(context.Background(), Task{DramaID: drama.ID, Chapter: chapters[0], Index: 1})
		if err != nil || media.URL != "https://media.example.test/a.mp4" {
			t.Fatal(media, err)
		}
		want := 3
		if fallback {
			want = 4
		}
		if calls != want {
			t.Fatal(calls)
		}
	}
}
func TestHGHubDenialStopsPlaybackFallback(t *testing.T) {
	for _, status := range []int{401, 403, 429} {
		calls := 0
		d := sourceFixtureDownloader(t, func(r *http.Request) (*http.Response, error) {
			calls++
			return sourceFixtureResponse(r, status, ""), nil
		})
		_, err := d.resolveHGHub(context.Background(), Task{DramaID: providerDramaID(sourceHuangguoAI, "123"), Chapter: Chapter{VideoURL: "hghub://123/1"}, Index: 1})
		if err == nil || calls != 1 {
			t.Fatal(calls, err)
		}
	}
}

func hghubFixtureRequest(t *testing.T, request *http.Request) *http.Request {
	t.Helper()
	if request.Method != "POST" || request.URL.Path != "/api/edge/request" {
		t.Fatalf("unexpected HGhub transport %s %s", request.Method, request.URL)
	}
	var envelope map[string]string
	if err := json.NewDecoder(request.Body).Decode(&envelope); err != nil {
		t.Fatal(err)
	}
	if envelope["method"] != "GET" || envelope["body"] != "" {
		t.Fatal(envelope)
	}
	copy := request.Clone(request.Context())
	address, err := request.URL.Parse(envelope["path"])
	if err != nil {
		t.Fatal(err)
	}
	copy.URL = address
	return copy
}

func hghubFixtureRows(rows any, pages int) map[string]any {
	return map[string]any{"status": 1, "data": map[string]any{"items": rows, "pagination": map[string]any{"pages": pages}}}
}

func TestLiveHGHubGuestMetadata(t *testing.T) {
	if os.Getenv("HGHUB_LIVE") != "1" {
		t.Skip("explicit guest metadata check")
	}
	d := sourceFixtureDownloader(t, nil, false)
	d.client = &http.Client{Timeout: 15 * time.Second}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	rows, _, err := d.hghubCatalog(ctx, 1, "", "")
	if err != nil || len(rows) == 0 {
		t.Fatal("catalog", err)
	}
	_, id, valid := splitProviderDramaID(rows[0].ID)
	if !valid {
		t.Fatal("identity")
	}
	_, chapters, err := d.hghubDetail(ctx, id)
	if err != nil || len(chapters) == 0 {
		t.Fatal("detail", err)
	}
	t.Logf("guest catalog=%d detail episodes=%d; no images or media downloaded", len(rows), len(chapters))
}

func TestHGHubWrongEpisodeDoesNotFallback(t *testing.T) {
	calls := 0
	d := sourceFixtureDownloader(t, func(r *http.Request) (*http.Response, error) {
		calls++
		return sourceFixtureResponse(r, 200, `{"status":1,"data":{"id":123,"ep_num":2,"video_url":"https://media.example.test/other.mp4"}}`), nil
	})
	_, err := d.resolveHGHub(context.Background(), Task{DramaID: providerDramaID(sourceHuangguoAI, "123"), Chapter: Chapter{VideoURL: "hghub://123/1"}, Index: 1})
	if err == nil || calls != 1 {
		t.Fatal("wrong episode was accepted or retried", calls, err)
	}
}

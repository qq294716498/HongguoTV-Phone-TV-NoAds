package core

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"net/http"
	"testing"
)

func TestHongguoWebFallbackPreservesTypeThroughPlaybackRoutes(t *testing.T) {
	for _, contentType := range []int{1, 1002, 1004, 1007, 0, -1} {
		t.Run(fmt.Sprint(contentType), func(t *testing.T) {
			appCalls, backupCalls := 0, 0
			expectedType := contentType
			if contentType < 0 {
				expectedType = 0
			}
			expectedApp, expectedBackup := expectedType, expectedType
			if expectedType == 0 {
				expectedApp, expectedBackup = 1, 1004
			}
			d := sourceFixtureDownloader(t, func(request *http.Request) (*http.Response, error) {
				switch request.URL.Path {
				case "/detail":
					body := fmt.Sprintf(`<script>_ROUTER_DATA = {"loaderData":{"detail_page":{"seriesDetail":{"series_id":"12345","series_name":"合成 AI 剧","content_type":%d,"vid_list":["9001","9002"]}}}};</script>`, contentType)
					return sourceFixtureResponse(request, http.StatusOK, body), nil
				case "/novel/player/video_model/v1/":
					appCalls++
					var payload map[string]any
					if err := json.NewDecoder(request.Body).Decode(&payload); err != nil {
						t.Fatal(err)
					}
					if payload["video_id"] != "9001" || payload["content_type"] != float64(expectedApp) {
						t.Fatalf("App route changed the persisted episode identity or type: %v", payload)
					}
					return sourceFixtureResponse(request, http.StatusOK, ""), nil
				case "/player/12345/9001":
					return sourceFixtureResponse(request, http.StatusOK, `<script>_ROUTER_DATA = {"loaderData":{"player_page":{"series_id":"12345","vid":"9001","protectedPlayback":true}}};</script>`), nil
				case "/api/hongguo/play":
					backupCalls++
					encoded, err := base64.StdEncoding.DecodeString(request.URL.Query().Get("id"))
					if err != nil {
						t.Fatal(err)
					}
					var reference hongguoPlaybackReference
					if err := json.Unmarshal(encoded, &reference); err != nil {
						t.Fatal(err)
					}
					if reference.SeriesID != "12345" || reference.VideoID != "9001" || reference.ContentType != expectedBackup {
						t.Fatalf("backup route changed the persisted episode identity or type: %+v", reference)
					}
					return sourceFixtureResponse(request, http.StatusOK, "{}"), nil
				default:
					t.Fatalf("unexpected request: %s", request.URL.Path)
					return nil, nil
				}
			})
			d.cfg.Retries = 1
			_, chapters, err := d.fetchHongguoWebChapters(context.Background(), "12345")
			if err != nil || len(chapters) != 2 {
				t.Fatalf("web detail failed: %v", err)
			}
			for _, chapter := range chapters {
				if chapter.ContentType != expectedType {
					t.Fatalf("web detail lost the content type: got %d want %d", chapter.ContentType, expectedType)
				}
			}
			encoded, err := json.Marshal(chapters[0])
			if err != nil {
				t.Fatal(err)
			}
			var restored Chapter
			if err := json.Unmarshal(encoded, &restored); err != nil {
				t.Fatal(err)
			}
			_, err = d.resolveHongguoMedia(context.Background(), Task{DramaID: providerDramaID(sourceHongguo, "12345"), Chapter: restored})
			if err == nil || appCalls != 1 || backupCalls != 1 {
				t.Fatalf("fallback did not exercise both routes: app=%d backup=%d error=%v", appCalls, backupCalls, err)
			}
		})
	}
}

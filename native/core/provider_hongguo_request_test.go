package core

import (
	"context"
	"encoding/json"
	"net/http"
	"strings"
	"testing"
)

func TestHongguoEpisodeContentTypeSurvivesDetailAndSerialization(t *testing.T) {
	response := map[string]any{"data": map[string]any{"video_data": map[string]any{
		"series_id": "12345", "series_title": "合成漫剧", "content_type": 1004, "episode_cnt": 2,
		"video_list": []any{
			map[string]any{"vid": "9001", "vid_index": 1},
			map[string]any{"vid": "9002", "vid_index": 2, "content_type": 1007},
		},
	}}}
	entry, err := parseHongguoAppDetail(response, "12345")
	if err != nil {
		t.Fatal(err)
	}
	for index, expected := range []int{1004, 1007} {
		if entry.Chapters[index].ContentType != expected {
			t.Fatalf("episode %d lost content type: got %d want %d", index+1, entry.Chapters[index].ContentType, expected)
		}
		encoded, err := json.Marshal(entry.Chapters[index])
		if err != nil {
			t.Fatal(err)
		}
		var restored Chapter
		if err := json.Unmarshal(encoded, &restored); err != nil || restored.ContentType != expected {
			t.Fatalf("episode content type did not survive persistence: %v", err)
		}
	}
}

func TestHongguoPlaybackUsesRequestedEpisodeContentType(t *testing.T) {
	for _, scenario := range []struct {
		name        string
		contentType int
		expected    int
	}{
		{"short-drama", 1, 1},
		{"motion-comic", 1004, 1004},
		{"ai-comic", 1007, 1007},
		{"legacy", 0, 1},
		{"invalid", -1, 1},
	} {
		t.Run(scenario.name, func(t *testing.T) {
			d := sourceFixtureDownloader(t, func(request *http.Request) (*http.Response, error) {
				if request.URL.Path != "/novel/player/video_model/v1/" {
					t.Fatalf("unexpected route: %s", request.URL.Path)
				}
				for _, header := range []string{"X-Gorgon", "X-Khronos", "X-SS-STUB", "X-SS-Req-Ticket"} {
					if request.Header.Get(header) != "" {
						t.Fatalf("playback model request retained incompatible header %s", header)
					}
				}
				var payload struct {
					VideoID     string `json:"video_id"`
					ContentType int    `json:"content_type"`
				}
				if err := json.NewDecoder(request.Body).Decode(&payload); err != nil {
					t.Fatal(err)
				}
				if payload.VideoID != "9001" || payload.ContentType != scenario.expected {
					t.Fatalf("wrong episode identity or content type: %+v", payload)
				}
				return sourceFixtureResponse(request, http.StatusOK, `{"code":0,"data":{"video_model":{"video_list":[{"main_url":"https://media.example.test/episode.mp4","video_meta":{"codec_type":"h264","definition":"720p"}}]}}}`), nil
			})
			media, err := d.resolveHongguoMedia(context.Background(), Task{
				DramaID: providerDramaID(sourceHongguo, "12345"),
				Chapter: Chapter{VideoURL: "hongguo-cenc://9001", ContentType: scenario.contentType},
			})
			if err != nil || media.URL != "https://media.example.test/episode.mp4" {
				t.Fatalf("matching episode media was not selected: %v", err)
			}
		})
	}
}

func TestHongguoEmptyResponseReportsObservedStatus(t *testing.T) {
	d := sourceFixtureDownloader(t, func(request *http.Request) (*http.Response, error) {
		return sourceFixtureResponse(request, http.StatusOK, ""), nil
	})
	_, err := d.resolveHongguoAppMedia(context.Background(), "9001", 1004)
	if err == nil || !strings.Contains(err.Error(), "HTTP 200") || !strings.Contains(err.Error(), "0 字节") || strings.Contains(err.Error(), "可能需要登录") {
		t.Fatalf("empty response was misclassified: %v", err)
	}
}

func TestHongguoProtectedWebResponseIsNotReportedAsLoginRequired(t *testing.T) {
	d := sourceFixtureDownloader(t, func(request *http.Request) (*http.Response, error) {
		return sourceFixtureResponse(request, http.StatusOK, `<script>_ROUTER_DATA = {"loaderData":{"player_page":{"series_id":"12345","vid":"9001","protectedPlayback":true}}};</script>`), nil
	})
	_, err := d.resolveHongguoWebMedia(context.Background(), "12345", "9001")
	if err == nil || !strings.Contains(err.Error(), "受保护播放协议") || strings.Contains(err.Error(), "可能需要登录") {
		t.Fatalf("protected playback was misclassified: %v", err)
	}
}

func TestHongguoDetailRequestPreservesExistingSignature(t *testing.T) {
	d := sourceFixtureDownloader(t, func(request *http.Request) (*http.Response, error) {
		for _, header := range []string{"X-Gorgon", "X-Khronos", "X-SS-STUB", "X-SS-Req-Ticket"} {
			if request.Header.Get(header) == "" {
				t.Fatalf("non-playback request lost header %s", header)
			}
		}
		return sourceFixtureResponse(request, http.StatusOK, `{"code":0,"data":{}}`), nil
	})
	_, err := d.hongguoAppRequest(context.Background(), http.MethodPost, "/novel/player/video_detail/v1/", nil, map[string]any{"series_id": "12345"})
	if err != nil {
		t.Fatal(err)
	}
}

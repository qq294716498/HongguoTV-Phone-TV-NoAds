package core

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"strings"
	"testing"
	"time"
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

func TestHongguoPlaybackRoutesEpisodeIntoMixedVideoIDMap(t *testing.T) {
	// 播放模型接口已迁到 multi_video_model/v1：分集 ID 通过 mixed_video_id_map 的
	// 1004 槽位传递，biz_param.video_platform 固定 1024，且必须带齐六个签名头。
	for _, contentType := range []int{1, 1004, 1007, 0, -1} {
		t.Run(fmt.Sprintf("content-type-%d", contentType), func(t *testing.T) {
			d := sourceFixtureDownloader(t, func(request *http.Request) (*http.Response, error) {
				if request.URL.Path != hongguoVideoModelPath {
					t.Fatalf("unexpected route: %s", request.URL.Path)
				}
				for _, header := range []string{"X-Gorgon", "X-Khronos", "X-Ladon", "X-Argus", "X-Helios", "X-Medusa", "X-SS-STUB", "X-SS-Req-Ticket"} {
					if request.Header.Get(header) == "" {
						t.Fatalf("playback model request lost required header %s", header)
					}
				}
				var payload struct {
					BizParam struct {
						VideoPlatform int `json:"video_platform"`
					} `json:"biz_param"`
					MixedVideoIDMap map[string][]string `json:"mixed_video_id_map"`
				}
				if err := json.NewDecoder(request.Body).Decode(&payload); err != nil {
					t.Fatal(err)
				}
				if payload.BizParam.VideoPlatform != 1024 {
					t.Fatalf("wrong video platform: %d", payload.BizParam.VideoPlatform)
				}
				if len(payload.MixedVideoIDMap["1004"]) != 1 || payload.MixedVideoIDMap["1004"][0] != "9001" {
					t.Fatalf("episode was not routed into the 1004 slot: %+v", payload.MixedVideoIDMap)
				}
				return sourceFixtureResponse(request, http.StatusOK, `{"code":0,"data":{"9001":{"video_model":{"video_list":[{"main_url":"https://media.example.test/episode.mp4","video_meta":{"codec_type":"h264","definition":"720p"}}]}}}}`), nil
			})
			media, err := d.resolveHongguoMedia(context.Background(), Task{
				DramaID: providerDramaID(sourceHongguo, "12345"),
				Chapter: Chapter{VideoURL: "hongguo-cenc://9001", ContentType: contentType},
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

func TestHongguoPlaybackHTTPBackoffSurvivesFallback(t *testing.T) {
	for _, status := range []int{http.StatusForbidden, http.StatusTooManyRequests} {
		t.Run(http.StatusText(status), func(t *testing.T) {
			calls := 0
			d := sourceFixtureDownloader(t, func(request *http.Request) (*http.Response, error) {
				calls++
				if request.URL.Path != hongguoVideoModelPath {
					if status == http.StatusTooManyRequests {
						t.Fatalf("429 issued another route: %s", request.URL)
					}
					return sourceFixtureResponse(request, http.StatusOK, "{}"), nil
				}
				response := sourceFixtureResponse(request, status, "{}")
				response.Header.Set("Retry-After", "120")
				return response, nil
			})
			_, err := d.resolveHongguoMedia(context.Background(), Task{
				DramaID: providerDramaID(sourceHongguo, "12345"),
				Chapter: Chapter{VideoURL: "hongguo-cenc://9001", ContentType: 1004},
			})
			var blocked *requestBackoff
			if !errors.As(err, &blocked) || blocked.status != status || time.Until(blocked.until) < 119*time.Second {
				t.Fatalf("HTTP backoff identity or deadline was lost: %v", err)
			}
			if status == http.StatusTooManyRequests && calls != 1 || status == http.StatusForbidden && calls != 3 {
				t.Fatalf("unexpected fallback count after HTTP %d: %d", status, calls)
			}
		})
	}
}

func TestHongguoSlowHTTPRoutesReachBackupWithinCallerBudget(t *testing.T) {
	appCalls, webCalls, apiCalls := 0, 0, 0
	d := sourceFixtureDownloader(t, func(request *http.Request) (*http.Response, error) {
		switch request.URL.Path {
		case hongguoVideoModelPath:
			appCalls++
			<-request.Context().Done()
			return nil, request.Context().Err()
		case "/player/12345/9001":
			webCalls++
			<-request.Context().Done()
			return nil, request.Context().Err()
		case "/api/hongguo/play":
			apiCalls++
			return sourceFixtureResponse(request, http.StatusOK, "{}"), nil
		default:
			t.Fatalf("unexpected playback route: %s", request.URL)
			return nil, errors.New("unexpected route")
		}
	})
	d.cfg.Retries = 2
	ctx, cancel := context.WithTimeout(context.Background(), 300*time.Millisecond)
	defer cancel()
	_, err := d.resolveHongguoMedia(ctx, Task{
		DramaID: providerDramaID(sourceHongguo, "12345"),
		Chapter: Chapter{VideoURL: "hongguo-cenc://9001", ContentType: 1004},
	})
	if err == nil || appCalls != 1 || webCalls != 1 || apiCalls != 1 || ctx.Err() != nil {
		t.Fatalf("slow routes consumed the caller budget: app=%d web=%d api=%d ctx=%v error=%v", appCalls, webCalls, apiCalls, ctx.Err(), err)
	}
}

func TestHongguoHTTPForbiddenAllowsIndependentWebPlayback(t *testing.T) {
	calls := 0
	d := sourceFixtureDownloader(t, func(request *http.Request) (*http.Response, error) {
		calls++
		switch request.URL.Path {
		case hongguoVideoModelPath:
			return sourceFixtureResponse(request, http.StatusForbidden, "{}"), nil
		case "/player/12345/9001":
			return sourceFixtureResponse(request, http.StatusOK, `<script>_ROUTER_DATA = {"loaderData":{"player_page":{"series_id":"12345","vid":"9001","video_player_info":{"main_url":"https://media.example.test/fallback.mp4"}}}}};</script>`), nil
		default:
			t.Fatalf("unexpected fallback request: %s", request.URL)
			return nil, errors.New("unexpected fallback request")
		}
	})
	media, err := d.resolveHongguoMedia(context.Background(), Task{
		DramaID: providerDramaID(sourceHongguo, "12345"),
		Chapter: Chapter{VideoURL: "hongguo-cenc://9001", ContentType: 1004},
	})
	if err != nil || calls != 2 || media.URL != "https://media.example.test/fallback.mp4" {
		t.Fatalf("independent HTTP fallback failed: calls=%d media=%+v error=%v", calls, media, err)
	}
}

func TestHongguoCanceledPlaybackDoesNotIssueHTTP(t *testing.T) {
	d := sourceFixtureDownloader(t, func(request *http.Request) (*http.Response, error) {
		t.Fatalf("canceled playback issued request: %s", request.URL)
		return nil, errors.New("unexpected request")
	})
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	_, err := d.resolveHongguoMedia(ctx, Task{
		DramaID: providerDramaID(sourceHongguo, "12345"),
		Chapter: Chapter{VideoURL: "hongguo-cenc://9001", ContentType: 1004},
	})
	if !errors.Is(err, context.Canceled) {
		t.Fatalf("cancellation identity was lost: %v", err)
	}
}

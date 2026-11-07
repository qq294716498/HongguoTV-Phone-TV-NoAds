package core

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"strings"
	"sync/atomic"
	"testing"
)

func TestHongguoRegisteredMediaAcceptsTopLevelVariantDictionary(t *testing.T) {
	for _, wrap := range []string{"top-level", "object", "json", "base64"} {
		t.Run(wrap, func(t *testing.T) {
			model := map[string]any{"video_duration": 12, "video_list": map[string]any{
				"high": map[string]any{"main_url": "https://media.example.test/episode.mp4", "video_meta": map[string]any{"codec_type": "hevc", "definition": "1080p"}},
			}}
			data := model
			if wrap != "top-level" {
				var value any = model
				if wrap == "json" || wrap == "base64" {
					encoded, _ := json.Marshal(model)
					value = string(encoded)
					if wrap == "base64" {
						value = base64.StdEncoding.EncodeToString(encoded)
					}
				}
				data = map[string]any{"video_model": value}
			}
			body, _ := json.Marshal(map[string]any{"data": data})
			d := sourceFixtureDownloader(t, func(request *http.Request) (*http.Response, error) {
				if request.URL.Path != hongguoSingleVideoModelPath {
					t.Fatal("unexpected request")
				}
				return sourceFixtureResponse(request, http.StatusOK, string(body)), nil
			})
			media, err := d.resolveHongguoRegisteredMedia(context.Background(), "9001")
			if err != nil || media.URL != "https://media.example.test/episode.mp4" || media.Quality != 1080 || media.Duration.Seconds() != 12 {
				t.Fatalf("valid dictionary was lost: quality=%d duration=%v err=%v", media.Quality, media.Duration, err)
			}
		})
	}
}

func TestHongguoMediaSelectionClassifiesWithoutLeakingInputs(t *testing.T) {
	unsupported := map[string]any{"main_url": "https://media.example.test/private?token=secret", "video_meta": map[string]any{"codec_type": "bytevc2"}}
	unavailable := map[string]any{"main_url": "secret-invalid-address", "video_meta": map[string]any{"codec_type": "hevc"}}
	for _, scenario := range []struct {
		name        string
		rows        []any
		unsupported int
		unavailable int
		invalid     int
	}{
		{"unsupported", []any{unsupported}, 1, 0, 0},
		{"missing-address", []any{unavailable}, 0, 1, 0},
		{"bad-shape", []any{"secret-malformed-row", nil, map[string]any{}}, 0, 0, 3},
		{"mixed", []any{unsupported, unavailable, nil}, 1, 1, 1},
	} {
		t.Run(scenario.name, func(t *testing.T) {
			_, err := selectHongguoAppMedia(map[string]any{"video_list": scenario.rows})
			var failure *hongguoMediaSelectionError
			if !errors.As(err, &failure) || failure.variants != len(scenario.rows) || failure.unsupportedCodec != scenario.unsupported || failure.unavailableURL != scenario.unavailable || failure.invalidVariant != scenario.invalid {
				t.Fatalf("incorrect failure classification: %v", err)
			}
			message := publicError(err).Error()
			if strings.Contains(message, "secret") || strings.Contains(message, "https://") || strings.Contains(message, "token=") {
				t.Fatal("selection failure disclosed input")
			}
			if scenario.unsupported == 0 && strings.Contains(message, "编码不支持") {
				t.Fatal("address failure was mislabeled as unsupported codec")
			}
		})
	}
}

func TestHongguoSelectionKeepsPlayableHEVCAndProtectedFailures(t *testing.T) {
	good := map[string]any{"main_url": "https://media.example.test/hevc.mp4", "video_meta": map[string]any{"codec_type": "hevc", "definition": "1080p"}}
	protected := map[string]any{"main_url": "https://media.example.test/protected.mp4", "encrypt_info": map[string]any{"encrypt": true, "spade_a": "invalid"}}
	media, err := selectHongguoAppMedia(map[string]any{"video_list": []any{nil, protected, good}})
	if err != nil || media.URL != "https://media.example.test/hevc.mp4" || len(media.Variants) != 1 {
		t.Fatalf("valid HEVC alternative was lost: %v", err)
	}
	if _, err := selectHongguoAppMedia(map[string]any{"video_list": []any{protected}}); err == nil || !strings.Contains(err.Error(), "媒体密钥不可用") {
		t.Fatal("protected-media failure was weakened")
	}
}

func TestHongguoProductionSearchDetailAndResolverKeepEpisodeIdentity(t *testing.T) {
	var searches, details, models atomic.Int32
	engine := sourceFixtureEngine(t, func(request *http.Request) (*http.Response, error) {
		switch request.URL.Path {
		case hongguoSearchAppPath:
			searches.Add(1)
			if request.URL.Query().Get("tab_type") == "19" {
				return searchFixtureTab(request, false, 0, "", `[{"video_data":[{"series_id":"12345","series_title":"合成故事第三季","episode_cnt":4}]}]`), nil
			}
			return sourceFixtureResponse(request, 200, `{"search_tabs":[{"tab_type":7,"data":[{"video_data":{"series_id":"54321","series_title":"其他标签剧集"}}]}]}`), nil
		case "/novel/player/video_detail/v1/":
			details.Add(1)
			return sourceFixtureResponse(request, 200, `{"data":{"video_data":{"series_id":"12345","series_title":"合成故事第三季","episode_cnt":4,"video_list":[{"vid":"9004","vid_index":4},{"vid":"9001","vid_index":1},{"vid":"9003","vid_index":3},{"vid":"9002","vid_index":2}]}}}`), nil
		case hongguoSingleVideoModelPath:
			models.Add(1)
			var payload map[string]any
			if err := json.NewDecoder(request.Body).Decode(&payload); err != nil {
				return nil, err
			}
			videoID := mapString(payload, "video_id")
			if videoID != "9001" && videoID != "9004" {
				t.Errorf("wrong episode selected: %s", videoID)
			}
			if mapString(payload, "content_type") != "1" || mapString(nestedMap(payload, "biz_param"), "video_platform") != "3" || nestedMap(payload, "biz_param")["need_all_video_definition"] != true {
				t.Error("production model request changed")
			}
			return sourceFixtureResponse(request, 200, fmt.Sprintf(`{"data":{"video_list":{"high":{"main_url":"https://media.example.test/%s.mp4","video_meta":{"codec_type":"bytevc1","definition":"1080p"}},"unsupported":{"main_url":"https://media.example.test/unsupported.mp4","video_meta":{"codec_type":"bytevc2"}}}}}`, videoID)), nil
		default:
			return sourceFixtureResponse(request, http.StatusServiceUnavailable, "synthetic web unavailable"), nil
		}
	})
	d := engine.downloader
	entry, err := d.fetchHongguoSearch(context.Background(), "合成故事", 1)
	if err != nil || len(entry.Dramas) != 1 || entry.Dramas[0].SourceID != "12345" || !entry.Limited {
		t.Fatalf("production search lost partial results or included unrelated tabs: count=%d err=%v", len(entry.Dramas), err)
	}
	_, chapters, err := d.fetchHongguoChapters(context.Background(), entry.Dramas[0].SourceID)
	if err != nil || len(chapters) != 4 {
		t.Fatalf("production detail failed: count=%d err=%v", len(chapters), err)
	}
	for _, index := range []int{0, 3} {
		media, err := d.resolveProviderMedia(context.Background(), Task{DramaID: entry.Dramas[0].ID, Chapter: chapters[index], Index: index + 1})
		expected := fmt.Sprintf("https://media.example.test/900%d.mp4", index+1)
		if err != nil || media.URL != expected || media.Quality != 1080 || len(media.Variants) != 1 {
			t.Fatalf("episode %d failed production resolver: quality=%d variants=%d err=%v", index+1, media.Quality, len(media.Variants), err)
		}
	}
	if _, _, err := d.fetchHongguoChapters(context.Background(), entry.Dramas[0].SourceID); err != nil {
		t.Fatal(err)
	}
	if searches.Load() != 2 || details.Load() != 1 || models.Load() != 2 {
		t.Fatalf("unexpected request counts: search=%d detail=%d model=%d", searches.Load(), details.Load(), models.Load())
	}
}

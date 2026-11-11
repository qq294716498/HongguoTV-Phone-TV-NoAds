package core

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"strings"
	"testing"
)

func codecFixtureModel(codec string) map[string]any {
	return map[string]any{"video_id": "9001", "video_duration": 60, "video_list": []any{
		map[string]any{"main_url": "https://media.example.test/video.mp4", "codec_type": codec, "gear_des_key": "1080_bytevc2", "video_meta": map[string]any{"codec_type": codec}},
	}}
}

func TestHongguoCodecLabelsIgnoreGearDescription(t *testing.T) {
	for _, codec := range []string{"hevc", "h264", "h265_hvc1", "bytevc2", "bvc2"} {
		model := codecFixtureModel(codec)
		_, err := selectHongguoAppMedia(model)
		if hongguoOnlyByteVC2(err) != (codec == "bytevc2" || codec == "bvc2") {
			t.Fatalf("codec %s: %v", codec, err)
		}
		if codec == "hevc" && err != nil {
			t.Fatal(err)
		}
	}
	model := codecFixtureModel("bvc2")
	row := model["video_list"].([]any)[0].(map[string]any)
	delete(row, "video_meta")
	if _, err := selectHongguoAppMedia(model); !hongguoOnlyByteVC2(err) {
		t.Fatal("top-level codec bypassed filter")
	}
}

func TestHongguoCompatibleFallbackPreservesSignedBytes(t *testing.T) {
	address, err := hongguoCompatibleFallback("https://api.fqnovel.com/f?token=A%2bB%2FC&codec_type=4&x=a+b&force_codec=old&codec_type=4", "codec_type=1")
	if err != nil || address != "https://api.fqnovel.com/f?token=A%2bB%2FC&x=a+b&codec_type=1" {
		t.Fatalf("query changed: %s %v", address, err)
	}
}

func TestHongguoCodecFallbackRecoveryAndStops(t *testing.T) {
	for _, scenario := range []string{"first", "second", "unsupported", "mismatch", "duration", "missing", "forbidden", "limited", "retry-after", "cancel", "plain", "no-address", "bad-address"} {
		t.Run(scenario, func(t *testing.T) {
			calls := 0
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			d := sourceFixtureDownloader(t, func(r *http.Request) (*http.Response, error) {
				calls++
				if r.Header.Get("X-Medusa") != "" {
					t.Fatal("signature forwarded")
				}
				model := codecFixtureModel("bytevc2")
				if calls > 1 {
					switch scenario {
					case "forbidden":
						return sourceFixtureResponse(r, 403, ""), nil
					case "limited":
						return sourceFixtureResponse(r, 429, ""), nil
					case "retry-after":
						response := sourceFixtureResponse(r, 200, "{}")
						response.Header.Set("Retry-After", "120")
						return response, nil
					case "mismatch":
						model["video_id"] = "9002"
					case "duration":
						model["video_duration"] = 10
					case "missing":
						delete(model, "video_id")
					}
				}
				if (scenario == "first" && calls == 2) || (scenario == "second" && calls == 3) {
					model = codecFixtureModel("hevc")
				}
				if calls == 2 && r.URL.Query().Get("codec_type") != "1" {
					t.Fatal("first codec query missing")
				}
				if calls == 3 && (r.URL.Query().Get("codec_type") != "0" || r.URL.Query().Get("force_codec") != "h264") {
					t.Fatal("second codec query missing")
				}
				body, _ := json.Marshal(map[string]any{"video_info": map[string]any{"data": model}})
				if scenario == "cancel" {
					cancel()
				}
				return sourceFixtureResponse(r, 200, string(body)), nil
			})
			d.cfg.Retries = 1
			model := codecFixtureModel("bytevc2")
			model["fallback_api"] = "https://api.fqnovel.com/f?codec_type=4&token=A%2BB"
			if scenario == "plain" {
				model = codecFixtureModel("hevc")
			}
			if scenario == "bad-address" {
				model["video_list"].([]any)[0].(map[string]any)["codec_type"] = "hevc"
				model["video_list"].([]any)[0].(map[string]any)["main_url"] = ""
			}
			if scenario == "no-address" {
				delete(model, "fallback_api")
			}
			media, err := d.resolveHongguoModelMedia(ctx, model)
			want := 2
			if scenario == "second" || scenario == "unsupported" {
				want = 3
			}
			if scenario == "cancel" {
				want = 1
			}
			if scenario == "plain" || scenario == "no-address" || scenario == "bad-address" {
				want = 0
			}
			if calls != want {
				t.Fatalf("requests=%d want=%d err=%v", calls, want, err)
			}
			success := scenario == "first" || scenario == "second" || scenario == "plain"
			if success != (err == nil) || (success && media.URL == "") {
				t.Fatalf("unexpected result: %v", err)
			}
			if err != nil && strings.Contains(err.Error(), "token=") {
				t.Fatal("token leaked")
			}
		})
	}
}

func TestHongguoRegisteredCodecFallbackIsUsed(t *testing.T) {
	calls := 0
	d := sourceFixtureDownloader(t, func(r *http.Request) (*http.Response, error) {
		calls++
		model := codecFixtureModel("bytevc2")
		if calls == 1 {
			model["fallback_api"] = "https://api.fqnovel.com/f?codec_type=4"
			body, _ := json.Marshal(map[string]any{"data": map[string]any{"video_model": model}})
			return sourceFixtureResponse(r, 200, string(body)), nil
		}
		if calls == 3 {
			model = codecFixtureModel("hevc")
		}
		body, _ := json.Marshal(map[string]any{"video_info": map[string]any{"data": model}})
		return sourceFixtureResponse(r, 200, string(body)), nil
	})
	media, err := d.resolveHongguoRegisteredMedia(context.Background(), "9001")
	if err != nil || media.URL == "" || calls != 3 {
		t.Fatal(fmt.Sprint(calls, err))
	}
}

func TestHongguoFallbackTopLevelKeyIsNotIgnored(t *testing.T) {
	model := codecFixtureModel("hevc")
	model["video_list"].([]any)[0].(map[string]any)["spade_a"] = "invalid"
	if _, err := selectHongguoAppMedia(model); err == nil || !strings.Contains(err.Error(), "媒体密钥不可用") {
		t.Fatalf("encrypted fallback was treated as clear: %v", err)
	}
}

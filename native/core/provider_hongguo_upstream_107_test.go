package core

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

func TestHongguoPlayerResponseFormatsAndRegistrationReuse(t *testing.T) {
	model := map[string]any{"duration": 90, "video_list": []any{map[string]any{
		"main_url":   "https://media.example.test/episode.mp4",
		"backup_url": base64.StdEncoding.EncodeToString([]byte("https://backup.example.test/episode.mp4")),
		"video_meta": map[string]any{"codec_type": "h264", "definition": "720p"},
	}}}
	encoded, _ := json.Marshal(model)
	for _, format := range []string{"object", "json", "base64", "raw-base64", "direct", "direct-map", "empty"} {
		t.Run(format, func(t *testing.T) {
			var registrations atomic.Int32
			d := sourceFixtureDownloader(t, func(r *http.Request) (*http.Response, error) {
				if r.URL.Host == "log.snssdk.com" {
					registrations.Add(1)
					return sourceFixtureResponse(r, 200, `{"device_id_str":"123456","install_id_str":"789012"}`), nil
				}
				if r.URL.Path != "/novel/player/video_model/v1/" || r.Method != http.MethodPost {
					return nil, fmt.Errorf("unexpected request")
				}
				for _, header := range []string{"X-Argus", "X-Ladon", "X-Gorgon", "X-Khronos", "X-SS-STUB"} {
					if r.Header.Get(header) == "" {
						t.Errorf("missing %s", header)
					}
				}
				if r.URL.Query().Get("device_id") != "123456" {
					t.Error("unregistered device")
				}
				var payload map[string]any
				json.NewDecoder(r.Body).Decode(&payload)
				if payload["video_id"] != "800001" {
					t.Error("wrong episode")
				}
				data := map[string]any{"video_model": model}
				switch format {
				case "json":
					data["video_model"] = string(encoded)
				case "base64":
					data["video_model"] = base64.StdEncoding.EncodeToString(encoded)
				case "raw-base64":
					data["video_model"] = base64.RawStdEncoding.EncodeToString(encoded)
				case "direct":
					data = model
				case "direct-map":
					data = map[string]any{"duration": 90, "video_list": map[string]any{"video_1": model["video_list"].([]any)[0]}}
				case "empty":
					data = map[string]any{"video_model": "", "video_list": model["video_list"], "duration": 90}
				}
				body, _ := json.Marshal(map[string]any{"code": 0, "data": data})
				return sourceFixtureResponse(r, 200, string(body)), nil
			}, false)
			for i := 0; i < 2; i++ {
				media, err := d.resolveHongguoRegisteredMedia(context.Background(), "800001")
				if err != nil || media.Quality != 720 || media.Duration != 90*time.Second || len(media.Variants) != 2 {
					t.Fatalf("bad media: quality=%d variants=%d error=%v", media.Quality, len(media.Variants), err)
				}
			}
			restarted := sourceFixtureDownloader(t, func(r *http.Request) (*http.Response, error) {
				t.Error("registered again after restart")
				return nil, fmt.Errorf("unexpected")
			}, false)
			restarted.cfg.dataDir = d.cfg.dataDir
			if _, err := restarted.ensureHongguoDeviceIdentity(context.Background()); err != nil {
				t.Fatal(err)
			}
			if registrations.Load() != 1 {
				t.Fatal("duplicate registration")
			}
		})
	}
}

func TestHongguoPlayerRejectsInvalidResponses(t *testing.T) {
	for _, body := range []string{`{"video_model":"%%%"}`, `{"video_model":"e30="}`, `{"video_model":{"video_list":[{"main_url":"file:///tmp/media"}]}}`, `{"video_model":{"video_list":[{"main_url":"https://media.example.test/a","video_meta":{"codec_type":"bytevc2"}}]}}`} {
		t.Run(body, func(t *testing.T) {
			d := sourceFixtureDownloader(t, func(r *http.Request) (*http.Response, error) {
				return sourceFixtureResponse(r, 200, `{"code":0,"data":`+body+`}`), nil
			})
			searchFixtureIdentity(d)
			if _, err := d.resolveHongguoRegisteredMedia(context.Background(), "800001"); err == nil {
				t.Fatal("invalid response accepted")
			}
		})
	}
}

func TestHongguoResolutionUsesOnlyOfficialRoutes(t *testing.T) {
	var paths []string
	d := sourceFixtureDownloader(t, func(r *http.Request) (*http.Response, error) {
		paths = append(paths, r.URL.Host+r.URL.Path)
		if r.URL.Path == hongguoSingleVideoModelPath {
			return sourceFixtureResponse(r, 200, `{"code":100001}`), nil
		}
		if r.URL.Host != "hongguoduanju.com" {
			t.Fatal("unexpected third-party request")
		}
		return sourceFixtureResponse(r, 200, `window._ROUTER_DATA={"loaderData":{"player_page":{"vid":"9002","series_id":"100","video_player_info":{"main_url":"https://media.example.test/wrong.mp4"}}}}`), nil
	})
	searchFixtureIdentity(d)
	_, err := d.resolveHongguoMedia(context.Background(), Task{DramaID: "hongguo:100", Chapter: Chapter{VideoURL: "hongguo-cenc://9001"}})
	if err == nil || len(paths) != 2 {
		t.Fatalf("wrong-episode or route validation failed: paths=%v error=%v", paths, err)
	}
}

func TestHongguoPlayerLiveRequestedEpisode(t *testing.T) {
	if os.Getenv("HONGGUO_LIVE_EPISODE") != "1" {
		t.Skip("explicit network opt-in required")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 90*time.Second)
	defer cancel()
	directory := os.Getenv("HONGGUO_LIVE_STATE")
	if directory == "" {
		directory = t.TempDir()
	}
	engine, err := newNativeEngine(directory)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(engine.downloads.close)
	d := engine.downloader
	transport := d.client.Transport
	if transport == nil {
		transport = http.DefaultTransport
	}
	d.client.Transport = sourceFixtureTransport(func(r *http.Request) (*http.Response, error) {
		if os.Getenv("HONGGUO_LIVE_OLD_SIGN") == "1" {
			r.Header.Del("X-Argus")
			r.Header.Del("X-Ladon")
		}
		response, err := transport.RoundTrip(r)
		if err == nil && r.URL.Path == "/novel/player/video_model/v1/" {
			body, readErr := io.ReadAll(io.LimitReader(response.Body, providerMaxBodyBytes+1))
			response.Body.Close()
			if readErr != nil {
				return nil, readErr
			}
			response.Body = io.NopCloser(strings.NewReader(string(body)))
			var result map[string]any
			json.Unmarshal(body, &result)
			t.Logf("player HTTP=%d bytes=%d video_model_type=%T", response.StatusCode, len(body), nestedMap(result, "data")["video_model"])
		}
		return response, err
	})
	if _, err := d.ensureHongguoDeviceIdentity(ctx); err != nil {
		t.Fatalf("device registration: %v", err)
	}
	dramas, err := d.fetchHongguoSearchNames(ctx, "文盲修仙第六季")
	if err != nil {
		t.Fatal(err)
	}
	for _, drama := range dramas {
		if !strings.Contains(drama.Title, "第六季") && !strings.Contains(drama.Title, "第6季") {
			continue
		}
		title, chapters, err := d.fetchHongguoChapters(ctx, drama.SourceID)
		if err != nil || len(chapters) == 0 {
			t.Fatalf("detail: %v", err)
		}
		media, err := d.resolveHongguoMedia(ctx, Task{DramaID: drama.ID, Chapter: chapters[0]})
		if err != nil {
			t.Fatalf("playback resolution: %v", err)
		}
		t.Logf("title=%s episode=1 variants=%d quality=%d duration=%s", title, len(media.Variants), media.Quality, media.Duration)
		if os.Getenv("HONGGUO_LIVE_DECODE") == "1" {
			stream, streamErr := newNativeStreamServer(d)
			if streamErr != nil {
				t.Fatal("local stream setup failed")
			}
			defer func() {
				stream.server.Close()
				stream.mu.Lock()
				defer stream.mu.Unlock()
				for _, session := range stream.sessions {
					session.cancel()
				}
			}()
			address, _ := stream.nativeOpen(media)
			decodeCtx, stop := context.WithTimeout(ctx, 60*time.Second)
			defer stop()
			output, decodeErr := exec.CommandContext(decodeCtx, "ffmpeg", "-v", "error", "-xerror", "-threads", "2", "-i", address+"?cenc=clear", "-t", "8", "-map", "0:v:0", "-map", "0:a:0?", "-f", "null", "-").CombinedOutput()
			if decodeErr != nil {
				t.Fatalf("Android clear stream 8-second decode failed: errorType=%T diagnosticBytes=%d", decodeErr, len(output))
			}
			t.Log("Android clear stream: eight seconds audio/video software decode passed; not a physical Android MediaCodec test")
		}
		return
	}
	t.Fatal("requested season not identified in search response")
}

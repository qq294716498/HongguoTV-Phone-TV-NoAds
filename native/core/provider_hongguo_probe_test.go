package core

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"sort"
	"strings"
	"testing"
	"time"
)

type hongguoProbeTransport struct {
	base http.RoundTripper
	test *testing.T
}

func (transport hongguoProbeTransport) RoundTrip(request *http.Request) (*http.Response, error) {
	if strings.HasSuffix(strings.ToLower(request.URL.Path), ".png") || strings.HasSuffix(strings.ToLower(request.URL.Path), ".jpg") {
		return nil, fmt.Errorf("image requests are disabled")
	}
	response, err := transport.base.RoundTrip(request)
	if err != nil {
		return response, err
	}
	body, readErr := io.ReadAll(io.LimitReader(response.Body, providerMaxBodyBytes+1))
	response.Body.Close()
	response.Body = io.NopCloser(bytes.NewReader(body))
	var result map[string]any
	keys := []string{}
	if json.Unmarshal(body, &result) == nil {
		for key := range result {
			keys = append(keys, key)
		}
		sort.Strings(keys)
	}
	transport.test.Logf("response host=%s path=%s status=%d type=%q bytes=%d fields=%v", request.URL.Hostname(), request.URL.Path, response.StatusCode, response.Header.Get("Content-Type"), len(body), keys)
	if readErr != nil {
		return nil, readErr
	}
	return response, nil
}

func TestLiveHongguoPlaybackResolution(t *testing.T) {
	if os.Getenv("CHECK_LIVE_HONGGUO") != "true" {
		t.Skip("set CHECK_LIVE_HONGGUO=true to request provider text APIs")
	}
	engine, err := newNativeEngine(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(engine.downloads.close)
	d := engine.downloader
	d.cfg.Retries = 1
	base := d.client.Transport
	if base == nil {
		base = http.DefaultTransport
	}
	d.client.Transport = hongguoProbeTransport{base: base, test: t}
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()
	seriesID := "7695704804978330649"
	_, chapters, err := d.fetchHongguoChapters(ctx, seriesID)
	if err != nil || len(chapters) == 0 {
		t.Fatalf("detail lookup failed: %v", err)
	}
	videoID := strings.TrimPrefix(chapters[0].VideoURL, "hongguo-cenc://")
	t.Logf("detail episodes=%d firstVideoID=%s", len(chapters), videoID)
	resolvers := []struct {
		name    string
		resolve func() (providerMedia, error)
	}{
		{"app", func() (providerMedia, error) { return d.resolveHongguoAppMedia(ctx, videoID) }},
		{"official-single-request", func() (providerMedia, error) {
			payload := map[string]any{"video_id": videoID, "video_platform": 3, "need_all_video_definition": true}
			result, err := d.hongguoAppRequest(ctx, http.MethodPost, "/novel/player/video_model/v1/", nil, payload)
			if err != nil {
				return providerMedia{}, err
			}
			data := nestedMap(result, "data")
			keys := []string{}
			for key := range data {
				keys = append(keys, key)
			}
			sort.Strings(keys)
			t.Logf("official single data fields=%v", keys)
			model, _ := data["video_model"].(map[string]any)
			if encoded, ok := data["video_model"].(string); ok {
				if err := json.Unmarshal([]byte(encoded), &model); err != nil {
					return providerMedia{}, err
				}
			}
			return selectHongguoAppMedia(model)
		}},
		{"web", func() (providerMedia, error) { return d.resolveHongguoWebMedia(ctx, seriesID, videoID) }},
		{"backup", func() (providerMedia, error) { return d.resolveHongguoPlaybackAPI(ctx, seriesID, videoID) }},
	}
	playable := false
	for _, resolver := range resolvers {
		media, err := resolver.resolve()
		t.Logf("route=%s resolved=%t variants=%d error=%v", resolver.name, media.URL != "", len(media.Variants), publicError(err))
		playable = playable || err == nil && media.URL != ""
	}
	if !playable {
		t.Fatal("all Hongguo playback address routes failed; no restoration verified")
	}
}

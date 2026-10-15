package core

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"sort"
	"strings"
	"testing"
	"time"
)

type hongguoComicProbeKey struct{}

type hongguoProbeTransport struct {
	base http.RoundTripper
	test *testing.T
}

func (transport hongguoProbeTransport) RoundTrip(request *http.Request) (*http.Response, error) {
	if strings.HasSuffix(strings.ToLower(request.URL.Path), ".png") || strings.HasSuffix(strings.ToLower(request.URL.Path), ".jpg") {
		return nil, fmt.Errorf("image requests are disabled")
	}
	if comic, _ := request.Context().Value(hongguoComicProbeKey{}).(bool); comic {
		request.Header.Set("User-Agent", strings.ReplaceAll(strings.ReplaceAll(hongguoAppUserAgent, "com.phoenix.read", "com.kylin.read"), "/73532 ", "/74032 "))
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
	if request.URL.Path == "/novel/player/video_detail/v1/" {
		detail := nestedMap(result, "data", "video_data")
		transport.test.Logf("detail contentType=%v videoContentType=%v genreType=%v platform=%v", detail["content_type"], detail["video_content_type"], detail["genre_type"], detail["video_platform"])
		if rows := anyList(detail["video_list"]); len(rows) > 0 {
			first, _ := rows[0].(map[string]any)
			transport.test.Logf("first contentType=%v platform=%v hasModel=%t", first["content_type"], first["video_platform"], first["video_model"] != nil)
		}
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
		{"candidate-episode-content-type", func() (providerMedia, error) { return d.resolveHongguoAppMedia(ctx, videoID, chapters[0].ContentType) }},
		{"official-manga-content-type", func() (providerMedia, error) {
			return probeHongguoOfficialModel(ctx, d, videoID, nil)
		}},
		{"official-manga-client", func() (providerMedia, error) {
			comicContext := context.WithValue(ctx, hongguoComicProbeKey{}, true)
			profile := url.Values{"aid": {"8704"}, "app_name": {"kylin_read"}, "version_code": {"74032"}, "version_name": {"7.4.0.32"}, "manifest_version_code": {"74032"}, "update_version_code": {"74032"}}
			return probeHongguoOfficialModel(comicContext, d, videoID, profile)
		}},
		{"official-manga-batch", func() (providerMedia, error) {
			comicContext := context.WithValue(ctx, hongguoComicProbeKey{}, true)
			profile := url.Values{"aid": {"8704"}, "app_name": {"kylin_read"}, "version_code": {"74032"}, "version_name": {"7.4.0.32"}, "manifest_version_code": {"74032"}, "update_version_code": {"74032"}}
			payload := map[string]any{"mixed_video_id_map": map[string]any{"1004": []string{videoID}}, "biz_param": map[string]any{"video_platform": 3, "need_all_video_definition": true}}
			result, err := d.hongguoAppRequest(comicContext, http.MethodPost, "/novel/player/multi_video_model/v1/", profile, payload)
			if err != nil {
				return providerMedia{}, err
			}
			entry := nestedMap(result, "data", videoID)
			keys := []string{}
			for key := range entry {
				keys = append(keys, key)
			}
			sort.Strings(keys)
			t.Logf("official batch entry fields=%v", keys)
			model, _ := entry["video_model"].(map[string]any)
			if encoded, ok := entry["video_model"].(string); ok {
				if err := json.Unmarshal([]byte(encoded), &model); err != nil {
					return providerMedia{}, err
				}
			}
			return selectHongguoAppMedia(model)
		}},
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

func probeHongguoOfficialModel(ctx context.Context, d *Downloader, videoID string, profile url.Values) (providerMedia, error) {
	payload := map[string]any{"video_id": videoID, "content_type": 1004, "biz_param": map[string]any{"video_platform": 3, "need_all_video_definition": true}}
	result, err := d.hongguoAppRequest(ctx, http.MethodPost, "/novel/player/video_model/v1/", profile, payload)
	if err != nil {
		return providerMedia{}, err
	}
	data := nestedMap(result, "data")
	model, _ := data["video_model"].(map[string]any)
	if encoded, ok := data["video_model"].(string); ok {
		if err := json.Unmarshal([]byte(encoded), &model); err != nil {
			return providerMedia{}, err
		}
	}
	return selectHongguoAppMedia(model)
}

package core

import (
	"context"
	"crypto/tls"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/cookiejar"
	"net/url"
	"os"
	"sort"
	"strconv"
	"strings"
	"testing"
	"time"
)

type hongguoProtocolProbeKey struct{}

type hongguoProtocolProbeTransport struct {
	base    http.RoundTripper
	test    *testing.T
	limited *bool
}

func (transport hongguoProtocolProbeTransport) RoundTrip(request *http.Request) (*http.Response, error) {
	if request.URL.Hostname() != "api5-normal.fqnovel.com" && request.URL.Hostname() != "api5-normal-sinfonlineb.fqnovel.com" {
		return nil, errors.New("protocol probe only permits APK-derived API hosts")
	}
	if !strings.HasPrefix(request.URL.Path, "/novel/player/") && !strings.HasPrefix(request.URL.Path, "/reading/bookapi/video_tab/") {
		return nil, errors.New("protocol probe only permits text playback APIs")
	}
	if unsigned, _ := request.Context().Value(hongguoProtocolProbeKey{}).(bool); unsigned {
		request = request.Clone(request.Context())
		for _, header := range []string{"X-Gorgon", "X-Khronos", "X-SS-STUB", "X-SS-Req-Ticket"} {
			request.Header.Del(header)
		}
	}
	response, err := transport.base.RoundTrip(request)
	if err != nil {
		return response, err
	}
	headers := make([]string, 0, len(response.Header))
	for name := range response.Header {
		headers = append(headers, name)
	}
	sort.Strings(headers)
	suppressed := -1
	if value, err := strconv.Atoi(response.Header.Get("X-Tt-Suppress-Body-Code")); err == nil {
		suppressed = value
	}
	*transport.limited = response.StatusCode == http.StatusTooManyRequests
	transport.test.Logf("protocol host=%s path=%s http=%s status=%d suppressed=%d responseHeaders=%v", request.URL.Hostname(), request.URL.Path, response.Proto, response.StatusCode, suppressed, headers)
	return response, nil
}

func TestLiveHongguoProtocolComparison(t *testing.T) {
	if os.Getenv("CHECK_LIVE_HONGGUO_PROTOCOL") != "true" {
		t.Skip("set CHECK_LIVE_HONGGUO_PROTOCOL=true to run the limited APK protocol comparison")
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
	jar, err := cookiejar.New(nil)
	if err != nil {
		t.Fatal(err)
	}
	d.client.Jar = jar
	d.client.CheckRedirect = func(request *http.Request, via []*http.Request) error {
		return http.ErrUseLastResponse
	}
	ctx, cancel := context.WithTimeout(context.Background(), 4*time.Minute)
	defer cancel()
	ctx = context.WithValue(ctx, hongguoComicProbeKey{}, true)
	deviceID, installID, err := probeHongguoGuestIDs(ctx, base, jar, t)
	if err != nil {
		t.Fatalf("registration precondition failed: %v", err)
	}
	client := d.hongguoClient()
	client.mu.Lock()
	client.state.DeviceID = deviceID
	client.state.InstallID = installID
	client.mu.Unlock()
	profile := url.Values{
		"aid": {"8704"}, "app_name": {"kylin_read"}, "version_code": {"74032"},
		"version_name": {"7.4.0.32"}, "manifest_version_code": {"74032"}, "update_version_code": {"74032"},
	}
	videoID := "7695722622981508121"
	biz := map[string]any{
		"video_platform": 3, "need_all_video_definition": true, "need_mp4_align": false,
		"use_os_player": false, "video_id_type": 0, "source": 5, "from_video_id": "", "device_level": 3,
	}
	basic := map[string]any{"video_id": videoID, "content_type": 1004, "biz_param": map[string]any{"video_platform": 3, "need_all_video_definition": true}}
	complete := map[string]any{"video_id": videoID, "content_type": 1004, "biz_param": biz}
	batch := map[string]any{"mixed_video_id_map": map[string]any{"1004": []string{videoID}}, "biz_param": biz, "dr_scene": "default"}
	limited := false
	wrap := func(roundTripper http.RoundTripper) http.RoundTripper {
		return hongguoProtocolProbeTransport{base: hongguoProbeTransport{base: roundTripper, test: t}, test: t, limited: &limited}
	}
	d.client.Transport = wrap(base)
	type route struct {
		name    string
		host    string
		method  string
		path    string
		query   url.Values
		payload any
		http1   bool
		noSign  bool
	}
	routes := []route{
		{name: "configured-host", host: hongguoAppBaseURL, method: http.MethodPost, path: "/novel/player/video_model/v1/", payload: basic},
		{name: "apk-default-host", host: "https://api5-normal.fqnovel.com", method: http.MethodPost, path: "/novel/player/video_model/v1/", payload: basic},
		{name: "apk-builder-fields", host: "https://api5-normal.fqnovel.com", method: http.MethodPost, path: "/novel/player/video_model/v1/", payload: complete},
		{name: "legacy-get-operation", host: "https://api5-normal.fqnovel.com", method: http.MethodGet, path: "/reading/bookapi/video_tab/video_model/v1/", query: url.Values{"video_id": {videoID}, "video_platform": {"3"}, "need_all_video_definition": {"true"}, "use_os_player": {"false"}, "video_id_type": {"0"}, "source": {"5"}, "device_level": {"3"}, "need_mp4_align": {"false"}}},
		{name: "batch-default-scene", host: "https://api5-normal.fqnovel.com", method: http.MethodPost, path: "/novel/player/multi_video_model/default/v1/", payload: batch},
		{name: "http1-control", host: "https://api5-normal.fqnovel.com", method: http.MethodPost, path: "/novel/player/video_model/v1/", payload: basic, http1: true},
		{name: "without-current-signature-control", host: "https://api5-normal.fqnovel.com", method: http.MethodPost, path: "/novel/player/video_model/v1/", payload: basic, noSign: true},
	}
	playable := false
	for _, variant := range routes {
		client.mu.Lock()
		client.baseURL = variant.host
		client.mu.Unlock()
		d.client.Transport = wrap(base)
		if variant.http1 {
			http1 := &http.Transport{Proxy: http.ProxyFromEnvironment, TLSNextProto: map[string]func(string, *tls.Conn) http.RoundTripper{}}
			defer http1.CloseIdleConnections()
			d.client.Transport = wrap(http1)
		}
		query := url.Values{}
		for key, values := range profile {
			query[key] = append([]string(nil), values...)
		}
		for key, values := range variant.query {
			query[key] = append([]string(nil), values...)
		}
		requestContext := context.WithValue(ctx, hongguoProtocolProbeKey{}, variant.noSign)
		result, requestErr := d.hongguoAppRequest(requestContext, variant.method, variant.path, query, variant.payload)
		media, mediaErr := probeHongguoProtocolMedia(result, videoID)
		resolved := requestErr == nil && mediaErr == nil && media.URL != ""
		t.Logf("hypothesis=%s resolved=%t requestErrorType=%T mediaErrorType=%T", variant.name, resolved, requestErr, mediaErr)
		playable = playable || resolved
		if limited {
			t.Fatal("provider rate limit received; stopped the comparison")
		}
	}
	client.mu.Lock()
	client.baseURL = "https://api5-normal.fqnovel.com"
	client.mu.Unlock()
	d.client.Transport = wrap(base)
	detail, detailErr := d.hongguoAppRequest(ctx, http.MethodPost, "/novel/player/video_detail/v1/", profile, map[string]any{"series_id": "7695704804978330649"})
	t.Logf("initialization detailSucceeded=%t episodeRows=%d", detailErr == nil, len(anyList(nestedMap(detail, "data", "video_data")["video_list"])))
	if limited {
		t.Fatal("provider rate limit received; stopped the comparison")
	}
	result, requestErr := d.hongguoAppRequest(ctx, http.MethodPost, "/novel/player/video_model/v1/", profile, basic)
	media, mediaErr := probeHongguoProtocolMedia(result, videoID)
	resolved := requestErr == nil && mediaErr == nil && media.URL != ""
	t.Logf("hypothesis=after-detail-initialization resolved=%t requestErrorType=%T mediaErrorType=%T", resolved, requestErr, mediaErr)
	playable = playable || resolved
	if !playable {
		t.Fatal("APK-derived routing, request fields, legacy operation, batch scene, HTTP version, signature control and detail initialization did not restore playback")
	}
}

func probeHongguoProtocolMedia(result map[string]any, videoID string) (providerMedia, error) {
	data := nestedMap(result, "data")
	candidates := []map[string]any{data, nestedMap(data, videoID)}
	for _, key := range []string{"video_model", "video_model_data", "video_data", "video_model_map", "video_models"} {
		entry := nestedMap(data, key)
		candidates = append(candidates, entry, nestedMap(entry, videoID))
		if rows, ok := data[key].([]any); ok {
			for _, row := range rows {
				if entry, ok := row.(map[string]any); ok {
					candidates = append(candidates, entry)
				}
			}
		}
	}
	for _, entry := range candidates {
		model := entry
		if nested, ok := entry["video_model"].(map[string]any); ok {
			model = nested
		} else if encoded, ok := entry["video_model"].(string); ok {
			if json.Unmarshal([]byte(encoded), &model) != nil {
				continue
			}
		}
		media, err := selectHongguoAppMedia(model)
		if err == nil && media.URL != "" {
			return media, nil
		}
	}
	return providerMedia{}, errors.New("no supported playback model in text response")
}

func TestLiveHongguoSignatureControl(t *testing.T) {
	if os.Getenv("CHECK_LIVE_HONGGUO_PROTOCOL") != "true" {
		t.Skip("set CHECK_LIVE_HONGGUO_PROTOCOL=true to compare the existing client signature")
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
	limited := false
	d.client.Transport = hongguoProtocolProbeTransport{base: hongguoProbeTransport{base: base, test: t}, test: t, limited: &limited}
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()
	client := d.hongguoClient()
	success := false
	for _, host := range []string{hongguoAppBaseURL, "https://api5-normal.fqnovel.com"} {
		client.mu.Lock()
		client.baseURL = host
		client.mu.Unlock()
		for _, unsigned := range []bool{false, true} {
			requestContext := context.WithValue(ctx, hongguoProtocolProbeKey{}, unsigned)
			media, resolveErr := d.resolveHongguoAppMedia(requestContext, "7695722622981508121", 1004)
			resolved := resolveErr == nil && media.URL != ""
			t.Logf("existing-profile host=%s generatedIds=true unsigned=%t resolved=%t variants=%d keyBytes=%d errorType=%T", host, unsigned, resolved, len(media.Variants), len(media.CENCKey), resolveErr)
			if limited {
				t.Fatal("provider rate limit received; stopped the comparison")
			}
			success = success || unsigned && resolved
		}
	}
	if !success {
		t.Fatal("removing the current signature did not resolve playback with the existing client profile")
	}
}

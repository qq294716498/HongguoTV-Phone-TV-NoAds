package core

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/url"
	"os"
	"sort"
	"strconv"
	"strings"
	"testing"
	"time"
)

type hongguo74132RoundTrip func(*http.Request) (*http.Response, error)

func (run hongguo74132RoundTrip) RoundTrip(request *http.Request) (*http.Response, error) {
	return run(request)
}

func TestLiveHongguoAPK74132KnownEpisode(t *testing.T) {
	if os.Getenv("CHECK_LIVE_HONGGUO_APK74132") != "true" {
		t.Skip("set CHECK_LIVE_HONGGUO_APK74132=true to verify the user-confirmed episode")
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
	ctx, cancel := context.WithTimeout(context.Background(), 90*time.Second)
	defer cancel()
	const seriesID = "7686430794469887001"
	const videoID = "7686465196335844376"
	stopped := false
	resolved := false
	run := func(name string, apkProfile, legacySignature bool) {
		if stopped || ctx.Err() != nil {
			return
		}
		guard := hongguo74132RoundTrip(func(request *http.Request) (*http.Response, error) {
			if stopped {
				return nil, errors.New("provider requested the comparison to stop")
			}
			host := strings.ToLower(request.URL.Hostname())
			if host != "api5-normal-sinfonlineb.fqnovel.com" && host != "hongguoduanju.com" && host != "djapi.999888456.xyz" {
				return nil, errors.New("known-episode comparison only permits existing text API hosts")
			}
			request = request.Clone(request.Context())
			if apkProfile {
				request.Header.Set("User-Agent", strings.ReplaceAll(strings.ReplaceAll(hongguoAppUserAgent, "com.phoenix.read", "com.kylin.read"), "/73532 ", "/74132 "))
			}
			if legacySignature && request.URL.Path == "/novel/player/video_model/v1/" {
				var body []byte
				if request.Body != nil {
					var err error
					body, err = io.ReadAll(io.LimitReader(request.Body, 4096))
					request.Body.Close()
					if err != nil {
						return nil, err
					}
					request.Body = io.NopCloser(bytes.NewReader(body))
				}
				signHongguoRequest(request, body, time.Now())
			}
			response, err := base.RoundTrip(request)
			if response != nil && host == "api5-normal-sinfonlineb.fqnovel.com" {
				suppressionCode := int64(-1)
				if value, parseErr := strconv.ParseInt(response.Header.Get("X-Tt-Suppress-Body-Code"), 10, 32); parseErr == nil {
					suppressionCode = value
				}
				t.Logf("comparison=%s apiStatus=%d protocol=%s declaredBytes=%d bodySuppressionCode=%d", name, response.StatusCode, response.Proto, response.ContentLength, suppressionCode)
			}
			if response != nil && (response.StatusCode == http.StatusForbidden || response.StatusCode == http.StatusTooManyRequests || response.Header.Get("Retry-After") != "") {
				stopped = true
			}
			if err == nil && response != nil && host == "djapi.999888456.xyz" && response.StatusCode == http.StatusOK {
				body, readErr := io.ReadAll(io.LimitReader(response.Body, providerMaxBodyBytes+1))
				response.Body.Close()
				response.Body = io.NopCloser(bytes.NewReader(body))
				if readErr != nil {
					return nil, readErr
				}
				decoded, decodeErr := decodeHongguoPlaybackResponse(string(body))
				var envelope map[string]any
				jsonErr := json.Unmarshal(decoded, &envelope)
				fields := make([]string, 0, len(envelope))
				for field := range envelope {
					fields = append(fields, field)
				}
				sort.Strings(fields)
				code := int64(-1)
				if value, parseErr := strconv.ParseInt(mapString(envelope, "code", "status_code"), 10, 32); parseErr == nil {
					code = value
				}
				t.Logf("backup decoded=%t json=%t fields=%v code=%d mediaEntries=%d", decodeErr == nil, jsonErr == nil, fields, code, len(anyList(envelope["key_urls"])))
			}
			return response, err
		})
		d.client.Transport = hongguoProbeTransport{base: guard, test: t}
		var media providerMedia
		var resolveErr error
		if !apkProfile {
			_, chapters, detailErr := d.fetchHongguoWebChapters(ctx, seriesID)
			if detailErr != nil || len(chapters) == 0 || chapters[0].VideoURL != "hongguo-cenc://"+videoID {
				t.Logf("comparison=%s detailErrorType=%T matchedEpisode=false", name, detailErr)
				return
			}
			t.Logf("known episode=%s/%s webContentType=%d", seriesID, videoID, chapters[0].ContentType)
			media, resolveErr = d.resolveHongguoMedia(ctx, Task{DramaID: providerDramaID(sourceHongguo, seriesID), Chapter: chapters[0]})
		} else {
			profile := url.Values{
				"aid": {"8704"}, "app_name": {"kylin_read"}, "version_code": {"74132"},
				"version_name": {"7.4.1.32"}, "manifest_version_code": {"74132"}, "update_version_code": {"74132"},
			}
			payload := map[string]any{"video_id": videoID, "content_type": 1002, "biz_param": map[string]any{"video_platform": 3, "need_all_video_definition": true}}
			result, requestErr := d.hongguoAppRequest(ctx, http.MethodPost, "/novel/player/video_model/v1/", profile, payload)
			resolveErr = requestErr
			if requestErr == nil {
				media, resolveErr = probeHongguoProtocolMedia(result, videoID)
			}
		}
		ok := resolveErr == nil && media.URL != ""
		t.Logf("comparison=%s resolved=%t variants=%d keyBytes=%d errorType=%T", name, ok, len(media.Variants), len(media.CENCKey), resolveErr)
		if !ok || stopped {
			return
		}
		status, size, valid, headerErr := probeHongguoMP4Header(ctx, base, media)
		t.Logf("comparison=%s mediaStatus=%d bytes=%d validMP4=%t errorType=%T", name, status, size, valid, headerErr)
		if status == http.StatusForbidden || status == http.StatusTooManyRequests {
			stopped = true
		}
		resolved = headerErr == nil && valid
	}
	run("production-resolver", false, false)
	if !resolved {
		run("apk74132-unsigned", true, false)
	}
	if !resolved {
		run("apk74132-legacy-signature-control", true, true)
	}
	if !resolved {
		t.Fatal("the user-confirmed episode did not return verified media; playback restoration is not established")
	}
}

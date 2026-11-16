// SPDX-License-Identifier: GPL-3.0-only
package core

import (
	"bytes"
	"compress/gzip"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/cookiejar"
	"net/url"
	"os"
	"strconv"
	"strings"
	"testing"
	"time"
)

func TestHongguoV5IndependentVectors(t *testing.T) {
	var hashes []struct {
		TS                  uint32
		Query, Body, Digest string
	}
	data, err := os.ReadFile("testdata/hongguo-signing-v5-f13.json")
	if err != nil {
		t.Fatal(err)
	}
	if err = json.Unmarshal(data, &hashes); err != nil {
		t.Fatal(err)
	}
	if len(hashes) != 32 {
		t.Fatal("missing timestamp vectors")
	}
	for _, row := range hashes {
		result := hgV5Hash(hgUnhex(row.Query), hgUnhex(row.Body), row.TS)
		if hgHex(result[:16]) != row.Digest || result[16]&0x24 != 0x24 {
			t.Fatalf("digest ts=%d got=%x", row.TS, result)
		}
	}
	var carriers []struct {
		TS                         uint32
		Key, Source, IV, Encrypted string
	}
	data, err = os.ReadFile("testdata/hongguo-signing-v5-carrier.json")
	if err != nil {
		t.Fatal(err)
	}
	if err = json.Unmarshal(data, &carriers); err != nil {
		t.Fatal(err)
	}
	if len(carriers) != 4 {
		t.Fatal("missing carrier variants")
	}
	for _, row := range carriers {
		result := hgV5Carrier(hgUnhex(row.Key), hgUnhex(row.Source), hgUnhex(row.IV), row.TS)
		if hgHex(result) != row.Encrypted {
			t.Fatalf("carrier ts=%d mismatch", row.TS)
		}
	}
}

func mobileFixtureModel(id string, typed, encoded bool) string {
	var model any = map[string]any{"video_list": []any{map[string]any{"main_url": "https://media.example.test/test.mp4", "video_meta": map[string]any{"definition": "720p", "codec_type": "h264"}}}}
	if encoded {
		b, _ := json.Marshal(model)
		model = string(b)
	}
	var data any = map[string]any{id: map[string]any{"video_model": model}}
	if typed {
		data = map[string]any{"1004": data}
	}
	b, _ := json.Marshal(map[string]any{"code": 0, "data": data})
	return string(b)
}

func TestHongguoV5ProductionRouteAndCompressedSignature(t *testing.T) {
	for _, typed := range []bool{false, true} {
		for _, encoded := range []bool{false, true} {
			calls := 0
			var cdid string
			d := sourceFixtureDownloader(t, func(r *http.Request) (*http.Response, error) {
				calls++
				if r.URL.Scheme+"://"+r.URL.Host+r.URL.Path != hongguoMobileModelURL {
					t.Fatalf("wrong production path %s", r.URL.Path)
				}
				q := r.URL.Query()
				if q.Get("device_id") != "1234567890123456" || q.Get("iid") == "" || q.Get("cdid") == "" || q.Get("version_code") != "74332" {
					t.Fatal("incorrect v5 profile")
				}
				if cdid != "" && cdid != q.Get("cdid") {
					t.Fatal("identity changed across requests")
				}
				cdid = q.Get("cdid")
				body, err := io.ReadAll(r.Body)
				if err != nil {
					t.Fatal(err)
				}
				if r.Header.Get("Content-Encoding") != "gzip" || r.Header.Get("X-Ss-Stub") != strings.ToUpper(hgHex(hgMD5(body))) {
					t.Fatal("compressed request digest mismatch")
				}
				if r.Header.Get("Cookie") != "" || r.Header.Get("X-Argus") != "" || r.Header.Get("X-Gorgon") != "" {
					t.Fatal("legacy headers leaked")
				}
				ts, _ := strconv.ParseUint(r.Header.Get("X-Khronos"), 10, 32)
				iv := hgGetIv(hgGetIv(hgGetIv(0x20230928, hgSM3([]byte(r.URL.RawQuery))), hgMD5(body)), hgLe32(uint32(ts)))
				if iv&15 != 12 || r.Header.Get("X-Medusa") == "" || r.Header.Get("X-Helios") == "" {
					t.Fatal("v5 signature missing or wrong branch")
				}
				reader, err := gzip.NewReader(bytes.NewReader(body))
				if err != nil {
					t.Fatal(err)
				}
				raw, err := io.ReadAll(reader)
				reader.Close()
				if err != nil {
					t.Fatal(err)
				}
				var payload map[string]any
				if err = json.Unmarshal(raw, &payload); err != nil {
					t.Fatal(err)
				}
				if nestedMap(payload, "biz_param")["device_level"] != float64(1) || payload["dr_scene"] != "player" {
					t.Fatal("wrong player payload")
				}
				if !strings.Contains(string(raw), `"1004":["9001"]`) {
					t.Fatal("wrong episode")
				}
				return sourceFixtureResponse(r, 200, mobileFixtureModel("9001", typed, encoded)), nil
			})
			searchFixtureIdentity(d)
			for range 2 {
				media, err := d.resolveHongguoMedia(context.Background(), Task{DramaID: providerDramaID(sourceHongguo, "123"), Chapter: Chapter{VideoURL: "hongguo-cenc://9001"}})
				if err != nil || media.URL != "https://media.example.test/test.mp4" {
					t.Fatalf("production route: %v", err)
				}
			}
			if calls != 2 {
				t.Fatal("unexpected retries")
			}
		}
	}
}

func TestHongguoV5FailureDoesNotRotateOrUseLegacy(t *testing.T) {
	for _, tc := range []struct {
		name   string
		status int
		body   string
		retry  bool
	}{
		{"empty", 200, "", false}, {"rejected", 403, "denied", false}, {"limited", 429, "limited", false},
		{"retryAfter", 200, "", true}, {"business", 200, `{"code":110001}`, false},
		{"wrongEpisode", 200, mobileFixtureModel("9002", true, false), false}, {"oversize", 200, strings.Repeat(" ", (2<<20)+1), false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			calls := 0
			d := sourceFixtureDownloader(t, func(r *http.Request) (*http.Response, error) {
				calls++
				if r.URL.Path != "/novel/player/multi_video_model/player/v1" {
					t.Fatal("legacy or registration fallback")
				}
				response := sourceFixtureResponse(r, tc.status, tc.body)
				if tc.retry {
					response.Header.Set("Retry-After", "60")
				}
				return response, nil
			})
			searchFixtureIdentity(d)
			if _, err := d.resolveHongguoMobileMedia(context.Background(), "9001"); err == nil {
				t.Fatal("accepted failure")
			}
			if calls != 1 {
				t.Fatal("unexpected recovery", calls)
			}
		})
	}
}

func TestHongguoV5BackgroundNeverRegisters(t *testing.T) {
	d := sourceFixtureDownloader(t, func(r *http.Request) (*http.Response, error) {
		t.Fatal("background registration or request")
		return nil, fmt.Errorf("unexpected")
	}, false)
	ctx := context.WithValue(context.Background(), backgroundCatalogKey{}, true)
	if _, err := d.resolveHongguoMobileMedia(ctx, "9001"); err == nil {
		t.Fatal("unregistered background request")
	}
}

func TestLiveHongguoV5Metadata(t *testing.T) {
	if os.Getenv("HG_MOBILE_V5_LIVE") != "1" {
		t.Skip("explicit v5 metadata acceptance")
	}
	engine, err := newNativeEngine(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(engine.downloads.close)
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	start := time.Now()
	media, err := engine.downloader.resolveHongguoMobileMedia(ctx, "7693917197759958040")
	if err != nil {
		t.Fatal(err)
	}
	t.Logf("v5 metadata ready elapsedMs=%d quality=%d variants=%d", time.Since(start).Milliseconds(), media.Quality, len(media.Variants))
}

func TestHongguoV5MatchesReferenceEnvelope(t *testing.T) {
	data, err := os.ReadFile("testdata/hongguo-signing-v5-envelope.json")
	if err != nil {
		t.Fatal(err)
	}
	var rows []struct {
		TS                        uint32
		URL, Body, Medusa, Helios string
	}
	if err = json.Unmarshal(data, &rows); err != nil {
		t.Fatal(err)
	}
	for _, row := range rows {
		ctx := hgMedusaContext{MessageRand: 0x80000000, Nonce: "synthetic", Started: 1800000000000}
		actual := hgV5Medusa(row.URL, hgUnhex(row.Body), row.TS, "1234567890123456", ctx, 0x80000000, 0x80000000)
		if actual != row.Medusa {
			t.Fatalf("reference Medusa mismatch ts=%d", row.TS)
		}
		if hgHeliosLicense(row.TS, 0x80000000, "646637794") != row.Helios {
			t.Fatalf("reference Helios mismatch ts=%d", row.TS)
		}
	}
}

func TestHongguoV5DoesNotSendJarCookiesOrFollowRedirects(t *testing.T) {
	calls := 0
	d := sourceFixtureDownloader(t, func(r *http.Request) (*http.Response, error) {
		calls++
		if r.Header.Get("Cookie") != "" {
			t.Fatal("account cookie reached anonymous playback")
		}
		response := sourceFixtureResponse(r, 302, "")
		response.Header.Set("Location", "https://other.example.test/model")
		return response, nil
	})
	jar, _ := cookiejar.New(nil)
	target, _ := url.Parse(hongguoMobileModelURL)
	jar.SetCookies(target, []*http.Cookie{{Name: "sessionid", Value: "synthetic-account"}})
	d.client.Jar = jar
	if _, err := d.resolveHongguoMobileMedia(context.Background(), "9001"); err == nil || calls != 1 {
		t.Fatalf("unexpected redirect: calls=%d err=%v", calls, err)
	}
	if len(d.client.Jar.Cookies(target)) != 1 {
		t.Fatal("shared cookie state modified")
	}
}

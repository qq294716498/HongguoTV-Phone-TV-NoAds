package core

import (
	"bytes"
	"compress/gzip"
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/http/cookiejar"
	"net/url"
	"os"
	"sort"
	"strings"
	"testing"
	"time"
)

func TestLiveHongguoGuestRegistration(t *testing.T) {
	if os.Getenv("CHECK_LIVE_HONGGUO_REGISTRATION") != "true" {
		t.Skip("set CHECK_LIVE_HONGGUO_REGISTRATION=true to run the limited guest registration probe")
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
	d.client.Transport = hongguoProbeTransport{base: base, test: t}
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()
	ctx = context.WithValue(ctx, hongguoComicProbeKey{}, true)
	profile := url.Values{
		"aid": {"8704"}, "app_name": {"kylin_read"}, "version_code": {"74032"},
		"version_name": {"7.4.0.32"}, "manifest_version_code": {"74032"}, "update_version_code": {"74032"},
	}
	videoID := "7695722622981508121"
	before, beforeErr := probeHongguoOfficialModel(ctx, d, videoID, profile)
	t.Logf("control=random-generated-ids resolved=%t errorType=%T", beforeErr == nil && before.URL != "", beforeErr)

	deviceID, installID, err := probeHongguoGuestIDs(ctx, base, jar, t)
	if err != nil {
		t.Fatalf("guest registration did not produce usable server IDs; playback comparison not completed: %v", err)
	}
	client := d.hongguoClient()
	client.mu.Lock()
	client.state.DeviceID = deviceID
	client.state.InstallID = installID
	client.mu.Unlock()
	after, afterErr := probeHongguoOfficialModel(ctx, d, videoID, profile)
	resolved := afterErr == nil && after.URL != ""
	t.Logf("control=server-registered-ids resolved=%t variants=%d errorType=%T", resolved, len(after.Variants), afterErr)
	if !resolved {
		t.Fatal("registered guest IDs alone did not restore address resolution; native security reporting was not reproduced")
	}
}

func probeHongguoGuestIDs(ctx context.Context, transport http.RoundTripper, jar http.CookieJar, t *testing.T) (string, string, error) {
	var random [32]byte
	if _, err := rand.Read(random[:]); err != nil {
		return "", "", errors.New("could not create a synthetic guest installation")
	}
	clientID := hex.EncodeToString(random[:16])
	openID := hex.EncodeToString(random[16:24])
	header := map[string]any{
		"aid": 8704, "app_name": "kylin_read", "package": "com.kylin.read",
		"app_version": "7.4.0.32", "version_code": 74032, "manifest_version_code": 74032,
		"update_version_code": 74032, "channel": "update_64", "device_platform": "android",
		"os": "Android", "os_api": 36, "os_version": "16", "device_model": "25053RT47C",
		"device_brand": "Redmi", "device_manufacturer": "Xiaomi", "cpu_abi": "arm64-v8a",
		"resolution": "2772x1280", "density_dpi": 520, "language": "zh", "access": "wifi",
		"clientudid": clientID, "openudid": openID, "req_id": hex.EncodeToString(random[24:]),
		"sdk_version": "3.7.0-rc.34-fanqie-xiaoshuo", "sdk_flavor": "china",
	}
	body, err := json.Marshal(map[string]any{"magic_tag": "ss_app_log", "header": header, "_gen_time": time.Now().UnixMilli()})
	if err != nil {
		return "", "", errors.New("could not encode guest registration")
	}
	var compressed bytes.Buffer
	writer := gzip.NewWriter(&compressed)
	if _, err := writer.Write(body); err != nil {
		return "", "", errors.New("could not compress guest registration")
	}
	if err := writer.Close(); err != nil {
		return "", "", errors.New("could not finish guest registration compression")
	}
	body = compressed.Bytes()
	client := &http.Client{
		Transport: transport, Jar: jar, Timeout: 25 * time.Second,
		CheckRedirect: func(request *http.Request, via []*http.Request) error {
			return http.ErrUseLastResponse
		},
	}
	endpoints := []string{
		"https://ib.snssdk.com/service/2/device_register/",
		"https://log5-applog.fqnovel.com/service/2/device_register/",
	}
	for _, endpoint := range endpoints {
		address, err := url.Parse(endpoint)
		if err != nil {
			return "", "", errors.New("invalid APK registration address")
		}
		query := url.Values{
			"aid": {"8704"}, "app_name": {"kylin_read"}, "version_code": {"74032"},
			"version_name": {"7.4.0.32"}, "device_platform": {"android"}, "os": {"android"},
			"_rticket": {fmt.Sprint(time.Now().UnixMilli())},
		}
		address.RawQuery = query.Encode()
		request, err := http.NewRequestWithContext(ctx, http.MethodPost, address.String(), bytes.NewReader(body))
		if err != nil {
			return "", "", errors.New("could not prepare guest registration")
		}
		request.Header.Set("Content-Type", "application/json; charset=utf-8")
		request.Header.Set("Content-Encoding", "gzip")
		request.Header.Set("Accept", "application/json")
		request.Header.Set("User-Agent", strings.ReplaceAll(strings.ReplaceAll(hongguoAppUserAgent, "com.phoenix.read", "com.kylin.read"), "/73532 ", "/74032 "))
		response, err := client.Do(request)
		if err != nil {
			t.Logf("registration host=%s transportErrorType=%T", address.Hostname(), err)
			continue
		}
		content, readErr := io.ReadAll(io.LimitReader(response.Body, 1024*1024+1))
		response.Body.Close()
		if readErr != nil || len(content) > 1024*1024 {
			t.Logf("registration host=%s status=%d unreadable=true", address.Hostname(), response.StatusCode)
			continue
		}
		deviceID, installID, fields := parseHongguoRegistrationIDs(content)
		t.Logf("registration host=%s encoding=gzip-json-fallback status=%d bytes=%d fields=%v validDeviceID=%t validInstallID=%t cookies=%d", address.Hostname(), response.StatusCode, len(content), fields, deviceID != "", installID != "", len(jar.Cookies(address)))
		if response.StatusCode == http.StatusOK && deviceID != "" && installID != "" {
			return deviceID, installID, nil
		}
	}
	return "", "", errors.New("APK-derived registration endpoints returned no valid ID pair via gzip JSON fallback; encrypted registration and native risk reporting remain untested")
}

func parseHongguoRegistrationIDs(content []byte) (string, string, []string) {
	decoder := json.NewDecoder(bytes.NewReader(content))
	decoder.UseNumber()
	var result map[string]any
	if decoder.Decode(&result) != nil {
		return "", "", nil
	}
	fields := make([]string, 0, len(result))
	for field := range result {
		fields = append(fields, field)
	}
	sort.Strings(fields)
	validID := func(value any) string {
		var text string
		switch value := value.(type) {
		case string:
			text = value
		case json.Number:
			text = string(value)
		}
		if len(text) == 0 || len(text) > 32 {
			return ""
		}
		nonzero := false
		for _, digit := range text {
			if digit < '0' || digit > '9' {
				return ""
			}
			nonzero = nonzero || digit != '0'
		}
		if !nonzero {
			return ""
		}
		return text
	}
	return validID(result["device_id"]), validID(result["install_id"]), fields
}

func TestHongguoRegistrationIDsRejectMissingAndInvalidValues(t *testing.T) {
	for _, test := range []struct {
		content string
		valid   bool
	}{
		{`{"device_id":"123","install_id":456}`, true},
		{`{"device_id":0,"install_id":"456"}`, false},
		{`{"device_id":"123","install_id":"-1"}`, false},
		{`{"device_id":"123"}`, false},
		{`{"device_id":"1e9","install_id":"456"}`, false},
		{`<html>unavailable</html>`, false},
	} {
		deviceID, installID, _ := parseHongguoRegistrationIDs([]byte(test.content))
		if (deviceID != "" && installID != "") != test.valid {
			t.Fatalf("registration ID validation mismatch for synthetic response")
		}
	}
}

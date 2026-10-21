package core

import (
	"context"
	"encoding/json"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"strconv"
	"strings"
	"testing"
	"time"
)

// 联网校验：用本包自己的签名打官方接口，确认能拿到数据而非 200 空正文。
// 默认跳过，只在显式设置 HG_LIVE=1 时执行，避免 CI 依赖外网与风控状态。
//
//	HG_LIVE=1 HG_VID=<分集ID> go test ./core -run TestLiveHongguoSignedRequest -v
func TestLiveHongguoSignedRequest(t *testing.T) {
	if os.Getenv("HG_LIVE") != "1" {
		t.Skip("设置 HG_LIVE=1 开启联网校验")
	}
	videoID := os.Getenv("HG_VID")
	if videoID == "" {
		videoID = "7693917197759958040"
	}
	if !hongguoNumericID.MatchString(videoID) {
		t.Fatalf("HG_VID 无效: %s", videoID)
	}

	// 本机可能配置了 HTTP_PROXY（会拦下红果域名），校验时显式直连。
	client := &http.Client{
		Timeout: 20 * time.Second,
		Transport: &http.Transport{
			Proxy:             nil,
			DialContext:       (&net.Dialer{Timeout: 10 * time.Second}).DialContext,
			DisableKeepAlives: false,
			ForceAttemptHTTP2: true,
		},
	}

	payload := map[string]any{
		"biz_param": map[string]any{
			"detail_page_version": 0, "device_level": 3, "disable_digg_stat": false,
			"need_all_video_definition": true, "need_mp4_align": false,
			"use_os_player": false, "use_server_dns": false, "video_platform": 1024,
		},
		"mixed_video_id_map": map[string]any{"1004": []any{videoID}},
	}
	body, err := json.Marshal(payload)
	if err != nil {
		t.Fatalf("构造请求体失败: %v", err)
	}

	now := time.Now()
	// 设备身份取 1e15 + 48bit 随机，与 App 侧生成规则一致；
	// 用固定假值会被风控判为异常流量并返回 Code 110001。
	deviceID := strconv.FormatUint(
		1_000_000_000_000_000+(uint64(hgRandUint32())<<16|uint64(hgRandUint32()&0xffff))%1_000_000_000_000_000, 10)
	query := url.Values{
		"aid": {"8662"}, "app_name": {"novelread"}, "version_code": {"73532"}, "version_name": {"7.3.5.32"},
		"manifest_version_code": {"73532"}, "update_version_code": {"73532"}, "channel": {"update_64"},
		"device_platform": {"android"}, "os": {"android"}, "ssmix": {"a"}, "device_type": {"25053RT47C"},
		"device_brand": {"Redmi"}, "language": {"zh"}, "os_api": {"36"}, "os_version": {"16"},
		"resolution": {"1280*2772"}, "dpi": {"520"}, "ac": {"wifi"},
		"device_id": {deviceID}, "iid": {deviceID},
		"ts": {strconv.FormatInt(now.Unix(), 10)}, "_rticket": {strconv.FormatInt(now.UnixMilli(), 10)},
	}
	rawURL := "https://api5-normal-sinfonlineb.fqnovel.com" + hongguoVideoModelPath + "?" + query.Encode()

	request, err := http.NewRequestWithContext(context.Background(), http.MethodPost, rawURL, strings.NewReader(string(body)))
	if err != nil {
		t.Fatalf("构造请求失败: %v", err)
	}
	request.Header.Set("User-Agent", hongguoAppUserAgent)
	request.Header.Set("Accept", "application/json; charset=utf-8,application/x-protobuf")
	request.Header.Set("Content-Type", "application/json; charset=UTF-8")
	request.Header.Set("X-XS-From-Web", "0")
	request.Header.Set("Sdk-Version", "2")
	signHongguoRequest(request, body, now)

	response, err := client.Do(request)
	if err != nil {
		t.Fatalf("请求失败: %v", err)
	}
	defer response.Body.Close()
	content, err := io.ReadAll(io.LimitReader(response.Body, 1<<20))
	if err != nil {
		t.Fatalf("读取响应失败: %v", err)
	}
	if response.StatusCode != http.StatusOK {
		t.Fatalf("HTTP %d", response.StatusCode)
	}
	if len(content) == 0 {
		t.Fatalf("签名未通过：HTTP 200 但正文为空（六个头或 branch 抖动仍有问题）")
	}
	t.Logf("响应正文 %d 字节", len(content))

	decoded := map[string]any{}
	decoder := json.NewDecoder(strings.NewReader(string(content)))
	decoder.UseNumber()
	if err := decoder.Decode(&decoded); err != nil {
		t.Fatalf("响应不是 JSON: %v", err)
	}
	data := nestedMap(decoded, "data")
	entry := nestedMap(data, videoID)
	if len(entry) == 0 {
		t.Fatalf("响应缺少分集条目: %s", string(content[:minInt(len(content), 300)]))
	}
	model, err := hongguoVideoModel(entry["video_model"])
	if err != nil {
		t.Fatalf("video_model 解析失败: %v", err)
	}
	hasList := len(anyList(model["video_list"])) > 0
	fallback := mapString(model, "fallback_api")
	if !hasList && fallback == "" {
		t.Fatalf("video_model 既无 video_list 也无 fallback_api，键=%v", mapKeys(model))
	}
	if hasList {
		t.Logf("video_model 直接返回 video_list，档位数=%d", len(anyList(model["video_list"])))
		media, err := selectHongguoAppMedia(model)
		if err != nil {
			t.Fatalf("从真实响应选流失败: %v", err)
		}
		if !isProviderHTTPMediaURL(media.URL) {
			t.Fatalf("选中的不是有效媒体地址: %s", media.URL)
		}
		t.Logf("选中清晰度=%d 候选=%d CENC加密=%v 地址=%s",
			media.Quality, len(media.Variants), media.CENCKey != nil, media.URL[:minInt(len(media.URL), 100)])
	}
	if fallback != "" {
		t.Logf("fallback_api = %s", fallback[:minInt(len(fallback), 120)])
	}
}

func minInt(a, b int) int {
	if a < b {
		return a
	}
	return b
}

func mapKeys(m map[string]any) []string {
	keys := make([]string, 0, len(m))
	for key := range m {
		keys = append(keys, key)
	}
	return keys
}

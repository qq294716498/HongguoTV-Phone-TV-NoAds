// SPDX-License-Identifier: GPL-3.0-only
package core

import (
	"bytes"
	"compress/gzip"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"
)

type hongguoMobileModelKey struct{}

// v5 播放模型端点。
//
// 2026-11-23 起服务端不再单纯按签名放行，而是按「设备可信度」过滤：设备画像不完整的
// 请求一律回 HTTP 200 + 0 字节正文，与签名是否正确无关。端点与 profile 本身没有变，
// 仍然是 api5-normal-sinfonlinea 的 player/v1 + 7.4.3.32 —— 之前一度误判为端点迁移，
// 改走 preload/v1 + 7.4.5.32 同样拿不到片源。参考 OOIUa/hongguo-android c0821c6f。
const hongguoMobileModelURL = "https://api5-normal-sinfonlinea.fqnovel.com/novel/player/multi_video_model/player/v1"

// hongguoMobileUserAgent 与 query 里的机型 / 系统保持一致：
// medusa 明文同样从 query 取这些字段，UA 单独漂移会让三者对不上。
const hongguoMobileUserAgent = "com.phoenix.read/73932 (Linux; U; Android 12; zh_CN_#Hans; PGT-AN10; Build/V417IR;tt-ok/3.12.13.20)"

// resolveHongguoMobileMedia 取某集片源：v5 播放模型优先。
//
// v5 会间歇性返回 HTTP 200 + 0 字节正文（上游按时间窗与身份波动）。此时按官方
// App 的 GET /reading/bookapi/video_tab/... 路径对当前集补一次；两条路径都用同一
// 注册身份，不轮换设备、不带账户 Cookie。参考 N3urda/hongguoTV 0.16.10。
func (d *Downloader) resolveHongguoMobileMedia(ctx context.Context, videoID string) (providerMedia, error) {
	if !hongguoNumericID.MatchString(videoID) {
		return providerMedia{}, errors.New("红果视频 ID 无效")
	}
	// 下载任务同样带 backgroundCatalogKey（避免批量下载挤占播放通道），但它是用户
	// 主动发起的：不能像空闲预取那样压到 2 秒预算并跳过 video_tab 回退，否则 v5
	// 返回空正文时播放能靠回退取流、下载却直接失败。
	background, _ := ctx.Value(backgroundCatalogKey{}).(bool)
	download, _ := ctx.Value(hongguoDownloadKey{}).(bool)
	passive := background && !download
	budget := 8 * time.Second
	if passive {
		budget = 2 * time.Second
	}
	ctx, cancel := context.WithTimeout(ctx, budget)
	defer cancel()
	media, err := d.fetchHongguoMobileModel(ctx, videoID)
	if err == nil {
		return media, nil
	}
	if !errors.Is(err, errHongguoEmptyResponse) || ctx.Err() != nil || passive {
		return providerMedia{}, err
	}
	model, tabErr := d.fetchHongguoVideoTabModel(ctx, videoID)
	if tabErr != nil {
		d.recordDiagnostic(diagnosticEvent{
			Event: "hongguo.video_tab_fallback_failed", Level: "warning", Source: sourceHongguo,
			Host: "api5-normal-sinfonlineb.fqnovel.com", Attempt: 1,
			Message: "v5 播放模型空响应，video_tab 回退仍失败：" + fmt.Sprint(publicError(tabErr)),
		})
		return providerMedia{}, errors.Join(err, tabErr)
	}
	fallback, fallbackErr := d.resolveHongguoModelMedia(ctx, model)
	if fallbackErr != nil {
		return providerMedia{}, fallbackErr
	}
	d.recordDiagnostic(diagnosticEvent{
		Event: "hongguo.video_tab_fallback", Level: "warning", Source: sourceHongguo,
		Host: "api5-normal-sinfonlineb.fqnovel.com", Attempt: 1,
		Message: "v5 播放模型空响应，已用 video_tab 取回同一集片源",
	})
	return fallback, nil
}

// fetchHongguoMobileModel 走 v5 播放协议（74532 查询 + v04.10.03 签名 + gzip 正文）。
func (d *Downloader) fetchHongguoMobileModel(ctx context.Context, videoID string) (providerMedia, error) {
	budget := hongguoVideoTabTimeout(ctx)
	requestCtx, cancel := context.WithTimeout(context.WithValue(ctx, hongguoMobileModelKey{}, true), budget)
	defer cancel()
	identity, err := d.ensureHongguoDeviceIdentity(requestCtx)
	if err != nil {
		return providerMedia{}, err
	}
	// dr_scene 与 device_level 保持官方 player 形态：preload/v1 那套参数并不能
	// 绕开设备可信度过滤，反而多了一层不匹配。
	payload := []byte(`{"biz_param":{"detail_page_version":0,"device_level":1,"disable_digg_stat":false,"disable_video_relate_book":false,"need_all_video_definition":true,"need_mp4_align":false,"use_os_player":false,"use_server_dns":false,"video_platform":1024},"mixed_video_id_map":{"1004":["` + videoID + `"]},"dr_scene":"player"}`)
	var compressed bytes.Buffer
	writer := gzip.NewWriter(&compressed)
	if _, err = writer.Write(payload); err != nil {
		return providerMedia{}, err
	}
	if err = writer.Close(); err != nil {
		return providerMedia{}, err
	}
	body := compressed.Bytes()
	// 官方播放 query 的完整设备上下文（28 项）。缺 resolution / dpi / os_api /
	// rom_version / host_abi / dragon_device_type / player_so_load 这些画像分量时，
	// 签名照样合法，但上游按「设备画像不完整」回 200 + 0 字节。
	query := url.Values{
		"aid": {"8662"}, "app_name": {"novelread"},
		"version_code": {"74332"}, "manifest_version_code": {"74332"}, "update_version_code": {"74332"},
		"version_name": {"7.4.3.32"},
		"channel":      {"vivo_8662_64"}, "device_platform": {"android"}, "os": {"android"},
		"ssmix": {"a"}, "device_type": {"PGT-AN10"}, "device_brand": {"HONOR"},
		"language": {"zh"}, "os_api": {"31"}, "os_version": {"12"},
		"resolution": {"1920*1080"}, "dpi": {"280"}, "ac": {"wifi"},
		"host_abi": {"arm64-v8a"}, "dragon_device_type": {"phone"},
		"pv_player": {"74332"}, "compliance_status": {"0"}, "need_personal_recommend": {"1"},
		"player_so_load": {"1"}, "is_android_pad_screen": {"0"},
		"rom_version": {"V417IR+release-keys"},
		"iid":         {identity.InstallID}, "cdid": {identity.CDID}, "device_id": {identity.DeviceID},
	}
	if identity.EGDI != "" {
		query.Set("klink_egdi", identity.EGDI)
	}
	request, err := http.NewRequestWithContext(requestCtx, http.MethodPost, hongguoMobileModelURL, bytes.NewReader(body))
	if err != nil {
		return providerMedia{}, err
	}
	request.Header.Set("User-Agent", hongguoMobileUserAgent)
	request.Header.Set("Accept", "application/json")
	request.Header.Set("Content-Type", "application/json; charset=utf-8")
	request.Header.Set("Content-Encoding", "gzip")
	request.Header.Set("X-Ss-Stub", strings.ToUpper(hgHex(hgMD5(body))))
	var signingErr error
	transport := *d.client
	transport.Jar = nil
	transport.CheckRedirect = func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }
	response, err := d.doPreparedCatalogRequestWithClient(request, budget, func(prepared *http.Request) {
		now := time.Now()
		query.Set("_rticket", strconv.FormatInt(now.UnixMilli(), 10))
		prepared.URL.RawQuery = query.Encode()
		signingErr = signHongguoMobileRequest(prepared, body, now)
		if signingErr != nil {
			cancel()
		}
	}, &transport)
	if signingErr != nil {
		return providerMedia{}, signingErr
	}
	if err != nil {
		return providerMedia{}, err
	}
	content, readErr := io.ReadAll(io.LimitReader(response.Body, (2<<20)+1))
	response.Body.Close()
	if readErr != nil {
		return providerMedia{}, readErr
	}
	if err = requestCtx.Err(); err != nil {
		return providerMedia{}, err
	}
	if response.StatusCode != http.StatusOK || catalogResponseBlockReason(response, content) != "" {
		return providerMedia{}, d.catalogResponseError(request, response, content)
	}
	if response.Header.Get("Retry-After") != "" {
		return providerMedia{}, errors.New("红果 v5 播放接口要求稍后重试")
	}
	if len(content) > 2<<20 {
		return providerMedia{}, errors.New("红果 v5 播放信息超过大小限制")
	}
	if len(bytes.TrimSpace(content)) == 0 {
		return providerMedia{}, fmt.Errorf("%w（v5 player，HTTP 200，正文 0 字节；设备身份已保留）", errHongguoEmptyResponse)
	}
	var result map[string]any
	decoder := json.NewDecoder(bytes.NewReader(content))
	decoder.UseNumber()
	if err = decoder.Decode(&result); err != nil || result == nil {
		return providerMedia{}, errors.New("红果 v5 播放信息格式异常")
	}
	code := firstNonEmpty(mapString(result, "code", "Code", "status_code"), mapString(nestedMap(result, "BaseResp"), "StatusCode"))
	if code != "" && code != "0" {
		return providerMedia{}, fmt.Errorf("红果 v5 播放接口返回错误（%s）", truncate(code, 20))
	}
	data := nestedMap(result, "data")
	if typed := nestedMap(data, "1004"); len(typed) > 0 {
		data = typed
	}
	row := nestedMap(data, videoID)
	model, err := hongguoVideoModel(row["video_model"])
	if err != nil {
		return providerMedia{}, err
	}
	if !hongguoModelHasVideoList(model) && hongguoFallbackAddress(model["fallback_api"]) == "" {
		return providerMedia{}, errors.New("红果 v5 未返回所选集的可播放媒体")
	}
	return d.resolveHongguoModelMedia(requestCtx, model)
}

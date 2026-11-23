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

const hongguoMobileModelURL = "https://api5-normal-sinfonlinea.fqnovel.com" + hongguoPlayModelPath

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

// fetchHongguoMobileModel 走 v5 播放协议（74332 查询 + v04.10.03 签名 + gzip 正文）。
//
// 换机策略见 provider_hongguo_play_hosts.go：官方客户端把播放请求分散在多台
// api5/api3-normal 主机上并按健康度排序，本仓库此前只写死 sinfonlinea 一台。这里
// 按同一顺序逐台尝试，单台的空正文与网络失败会换下一台，整体预算仍是原来的
// hongguoVideoTabTimeout。
func (d *Downloader) fetchHongguoMobileModel(ctx context.Context, videoID string) (providerMedia, error) {
	budget := hongguoVideoTabTimeout(ctx)
	// hongguoMobileModelKey 必须在取身份之前打上：设备注册层用它在后台预取时跳过
	// 注册、等前台先行，这里少带这个标记会让后台任务直接去注册设备。
	modelCtx, cancel := context.WithTimeout(context.WithValue(ctx, hongguoMobileModelKey{}, true), budget)
	defer cancel()
	identity, err := d.ensureHongguoDeviceIdentity(modelCtx)
	if err != nil {
		return providerMedia{}, err
	}
	var lastErr error
	state := d.hongguoPlayHostState()
	hosts := state.order()
	// 空闲预取（后台、非下载）保持单次请求：换机会把后台任务的行数放大数倍，
	// 挤占播放通道，而预取失败本来就可以直接放弃。
	if background, _ := modelCtx.Value(backgroundCatalogKey{}).(bool); background {
		if download, _ := modelCtx.Value(hongguoDownloadKey{}).(bool); !download && len(hosts) > 1 {
			hosts = hosts[:1]
		}
	}
	for index, host := range hosts {
		if index > 0 && modelCtx.Err() != nil {
			break
		}
		media, hostErr := d.fetchHongguoMobileModelFrom(modelCtx, videoID, identity, host)
		state.mark(host, hostErr)
		if hostErr == nil {
			if index > 0 {
				d.recordDiagnostic(diagnosticEvent{
					Event: "hongguo.play_host_switch", Level: "info", Source: sourceHongguo,
					Host: hongguoPlayHostName(host), Attempt: index + 1,
					Message: "v5 播放模型已换到可用主机取回",
				})
			}
			return media, nil
		}
		lastErr = hostErr
		if !hongguoPlayHostRetryable(hostErr) {
			break
		}
		d.recordDiagnostic(diagnosticEvent{
			Event: "hongguo.play_host_fail", Level: "warning", Source: sourceHongguo,
			Host: hongguoPlayHostName(host), Attempt: index + 1,
			Message: "v5 播放模型失败，准备换机：" + fmt.Sprint(publicError(hostErr)),
		})
	}
	if lastErr == nil {
		lastErr = modelCtx.Err()
	}
	if lastErr == nil {
		lastErr = errHongguoEmptyResponse
	}
	return providerMedia{}, lastErr
}

// fetchHongguoMobileModelFrom 向指定主机发一次 v5 播放模型请求。
func (d *Downloader) fetchHongguoMobileModelFrom(ctx context.Context, videoID string, identity hongguoDeviceIdentity, base string) (providerMedia, error) {
	budget := hongguoVideoTabTimeout(ctx)
	requestCtx, cancel := context.WithTimeout(context.WithValue(ctx, hongguoMobileModelKey{}, true), budget)
	defer cancel()
	var err error
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
	query := url.Values{
		"aid": {"8662"}, "app_name": {"novelread"}, "version_code": {"74332"}, "version_name": {"7.4.3.32"},
		"channel": {"vivo_8662_64"}, "device_platform": {"android"}, "device_type": {"PGT-AN10"}, "os_version": {"12"}, "update_version_code": {"74332"},
		"iid": {identity.InstallID}, "cdid": {identity.CDID}, "device_id": {identity.DeviceID},
	}
	request, err := http.NewRequestWithContext(requestCtx, http.MethodPost, base+hongguoPlayModelPath, bytes.NewReader(body))
	if err != nil {
		return providerMedia{}, err
	}
	request.Header.Set("User-Agent", "com.phoenix.read/73932 (Linux; U; Android 12; zh_CN_#Hans; PGT-AN10; Build/V417IR;tt-ok/3.12.13.20)")
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

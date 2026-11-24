// SPDX-License-Identifier: GPL-3.0-only
package core

import (
	"bytes"
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

// 红果播放模型的 GET 回退路径。
//
// v5（POST /novel/player/multi_video_model/preload/v1）会间歇性返回
// HTTP 200 + 0 字节正文。官方 App 仍保留 GET
// /reading/bookapi/video_tab/multi_video_model/v1/，同一注册身份可以取到
// 同一集的 video_model。参考实现（N3urda/hongguoTV 0.16.10）在 v5 空响应后
// 对当前集补一次该 GET，本文件实现同一条回退。
const hongguoVideoTabPath = "/reading/bookapi/video_tab/multi_video_model/v1/"

// 播放模型请求使用的厂商 UA；旧 /novel/player 与 video_tab 接口一致。
const hongguoPlayerUserAgent = "com.phoenix.read/71532 (Linux; U; Android 9; SM-N9860; Build/PQ3A.190705.10241111;tt-ok/3.12.13.20)"

// video_tab 的 v5 形态沿用目录请求的 UA（Cronet 版本）。参考实现的签名层只保留三个
// 验签头，UA 由通用请求构造提供，因此这里必须显式带上这一版 UA。
const hongguoVideoTabUserAgent = "com.phoenix.read/71332 (Linux; U; Android 16; zh_CN; 25053RT47C; Build/BP2A.250605.031.A3; Cronet/TTNetVersion:04657795 2026-01-23 QuicVersion:c67e9834 2025-09-08)"

// hongguoVideoTabQuery 组装 video_tab 的查询参数：注册身份 + 播放模型参数。
func hongguoVideoTabQuery(identity hongguoDeviceIdentity, videoID string, ticket int64) url.Values {
	values := url.Values{
		"ac": {"wifi"}, "channel": {"update_64"}, "aid": {"8662"}, "app_name": {"novelread"},
		"version_code": {"73932"}, "version_name": {"7.3.9.32"}, "device_platform": {"android"},
		"os": {"android"}, "ssmix": {"a"}, "device_type": {"25053RT47C"}, "device_brand": {"Redmi"},
		"language": {"zh"}, "os_api": {"36"}, "os_version": {"16"}, "manifest_version_code": {"73932"},
		"resolution": {"1280*2772"}, "dpi": {"520"}, "update_version_code": {"73932"},
		"host_abi": {"arm64-v8a"}, "dragon_device_type": {"phone"}, "pv_player": {"73932"},
		"compliance_status": {"0"}, "need_personal_recommend": {"1"}, "player_so_load": {"1"},
		"is_android_pad_screen": {"0"},
		"device_id":             {identity.DeviceID}, "iid": {identity.InstallID},
		"video_id": {videoID}, "video_id_type": {"0"}, "device_level": {"1"},
		"need_all_video_definition": {"1"}, "need_mp4_align": {"0"}, "use_os_player": {"0"},
		"video_platform": {"1024"}, "source": {"0"}, "from_video_id": {""},
		"_rticket": {strconv.FormatInt(ticket, 10)},
	}
	if identity.CDID != "" {
		values.Set("cdid", identity.CDID)
	}
	return values
}

// hongguoPlaybackCookie 只保留播放协议需要的匿名身份 Cookie。
func hongguoPlaybackCookie(raw string) string {
	allowed := map[string]bool{"install_id": true, "ttreq": true, "store-region": true, "store-region-src": true}
	var kept []string
	for _, pair := range strings.Split(raw, ";") {
		pair = strings.TrimSpace(pair)
		if index := strings.IndexByte(pair, '='); index > 0 && allowed[pair[:index]] {
			kept = append(kept, pair)
		}
	}
	return strings.Join(kept, "; ")
}

// fetchHongguoVideoTabModel 用注册身份取一次 video_tab 播放模型。
//
// 官方现行 GET 走 v5 验签（v04.10.03）：只保留 x-khronos / x-helios / x-medusa，
// 连 UA、Cookie、sdk-version 都不带。服务端对播放模型的放行策略按「签名套系 ×
// 时间窗」收紧，验签不符会在验签阶段短路成 HTTP 200 + 0 字节。因此这里先按 v5
// 形态取一次，仍空时才退回旧六头形态（部分时间窗只对旧形态放行）。
func (downloader *Downloader) fetchHongguoVideoTabModel(ctx context.Context, videoID string) (map[string]any, error) {
	if !hongguoNumericID.MatchString(videoID) {
		return nil, errors.New("红果视频 ID 无效")
	}
	identity, err := downloader.ensureHongguoDeviceIdentity(ctx)
	if err != nil {
		return nil, err
	}
	model, err := downloader.fetchHongguoVideoTabProfile(ctx, identity, videoID, true)
	if err == nil {
		return model, nil
	}
	if !errors.Is(err, errHongguoEmptyResponse) || ctx.Err() != nil {
		return nil, err
	}
	legacy, legacyErr := downloader.fetchHongguoVideoTabProfile(ctx, identity, videoID, false)
	if legacyErr != nil {
		return nil, errors.Join(err, legacyErr)
	}
	return legacy, nil
}

// fetchHongguoVideoTabProfile 按指定验签形态发一次 video_tab GET。
// v5 为真时只带 v5 三头（官方现行形态）；为假时保持旧六头 + 匿名播放 Cookie。
func (downloader *Downloader) fetchHongguoVideoTabProfile(ctx context.Context, identity hongguoDeviceIdentity, videoID string, v5 bool) (map[string]any, error) {
	query := hongguoVideoTabQuery(identity, videoID, time.Now().UnixMilli())
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, hongguoAppBaseURL+hongguoVideoTabPath+"?"+query.Encode(), nil)
	if err != nil {
		return nil, err
	}
	if v5 {
		// 官方现行形态：目录 UA + Accept-Language + 匿名 Cookie，配 v5 三头验签。
		request.Header.Set("User-Agent", hongguoVideoTabUserAgent)
		request.Header.Set("Accept-Language", "zh-CN,zh;q=0.9")
	} else {
		request.Header.Set("User-Agent", hongguoPlayerUserAgent)
		request.Header.Set("Accept", "application/json; charset=utf-8,application/x-protobuf")
		request.Header.Set("Sdk-Version", "2")
		request.Header.Set("X-XS-From-Web", "0")
	}
	// 匿名播放 Cookie（install_id/ttreq/store-region）两种形态都带：这一头是显式头，
	// 与 CookieJar 无关；参考实现只在缺它时才被验签短路。
	if cookie := hongguoPlaybackCookie(identity.Cookie); cookie != "" {
		request.Header.Set("Cookie", cookie)
	}
	// 播放请求不带账户 Cookie 罐，也不跟随重定向。
	transport := *downloader.client
	transport.Jar = nil
	transport.CheckRedirect = func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }
	var signingErr error
	response, err := downloader.doPreparedCatalogRequestWithClient(request, hongguoVideoTabTimeout(ctx), func(prepared *http.Request) {
		now := time.Now()
		if v5 {
			// v5 验签自身会把 _rticket 抖动到目标分支，并只写三个验签头。
			signingErr = signHongguoMobileRequest(prepared, nil, now)
			return
		}
		khronos := uint32(now.Unix())
		ticket := now.UnixMilli()
		for offset := 0; offset < 1024; offset++ {
			prepared.URL.RawQuery = hongguoVideoTabQuery(identity, videoID, ticket+int64(offset)).Encode()
			if hgBranchOf(prepared.URL.String(), nil, khronos) == 0 {
				break
			}
		}
		for name, value := range hgSignHeaders(prepared.URL.String(), nil, khronos, identity.DeviceID, "7.3.9.32") {
			prepared.Header.Set(name, value)
		}
		prepared.Header.Set("X-SS-Req-Ticket", prepared.URL.Query().Get("_rticket"))
	}, &transport)
	if signingErr != nil {
		return nil, signingErr
	}
	if err != nil {
		return nil, err
	}
	content, readErr := io.ReadAll(io.LimitReader(response.Body, (2<<20)+1))
	response.Body.Close()
	if readErr != nil {
		return nil, readErr
	}
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	if response.StatusCode != http.StatusOK || catalogResponseBlockReason(response, content) != "" {
		return nil, downloader.catalogResponseError(request, response, content)
	}
	if response.Header.Get("Retry-After") != "" {
		return nil, errors.New("红果视频列表接口要求稍后重试")
	}
	if len(content) > 2<<20 {
		return nil, errors.New("红果视频列表响应超过大小限制")
	}
	if len(bytes.TrimSpace(content)) == 0 {
		return nil, fmt.Errorf("%w（video_tab，HTTP 200，正文 0 字节）", errHongguoEmptyResponse)
	}
	var result map[string]any
	decoder := json.NewDecoder(bytes.NewReader(content))
	decoder.UseNumber()
	if err := decoder.Decode(&result); err != nil || result == nil {
		return nil, errors.New("红果视频列表返回格式异常")
	}
	code := firstNonEmpty(mapString(result, "code", "Code", "status_code"), mapString(nestedMap(result, "BaseResp"), "StatusCode"))
	if code != "" && code != "0" {
		return nil, fmt.Errorf("红果视频列表接口返回错误（%s）", truncate(code, 20))
	}
	data := nestedMap(result, "data")
	if rows := nestedMap(data, "video_model_data"); len(rows) > 0 {
		data = rows
	}
	row := nestedMap(data, videoID)
	if len(row) == 0 {
		return nil, errors.New("红果视频列表未返回该集播放信息")
	}
	model, err := hongguoVideoModel(row["video_model"])
	if err != nil {
		return nil, err
	}
	if !hongguoModelHasVideoList(model) && hongguoFallbackAddress(model["fallback_api"]) == "" {
		return nil, errors.New("红果视频列表未返回该集的可播放媒体")
	}
	return model, nil
}

// hongguoVideoTabTimeout 取流回退与 v5 共用同一预算，后台预取不再等待。
func hongguoVideoTabTimeout(ctx context.Context) time.Duration {
	if deadline, ok := ctx.Deadline(); ok {
		if remaining := time.Until(deadline); remaining > 0 {
			return remaining
		}
		return time.Second
	}
	if background, _ := ctx.Value(backgroundCatalogKey{}).(bool); background {
		return 2 * time.Second
	}
	return 8 * time.Second
}

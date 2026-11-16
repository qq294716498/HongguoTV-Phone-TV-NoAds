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

const hongguoMobileModelURL = "https://api5-normal-sinfonlinea.fqnovel.com/novel/player/multi_video_model/player/v1"

func (d *Downloader) resolveHongguoMobileMedia(ctx context.Context, videoID string) (providerMedia, error) {
	if !hongguoNumericID.MatchString(videoID) {
		return providerMedia{}, errors.New("红果视频 ID 无效")
	}
	budget := 8 * time.Second
	background, _ := ctx.Value(backgroundCatalogKey{}).(bool)
	if background {
		budget = 2 * time.Second
	}
	ctx, cancel := context.WithTimeout(ctx, budget)
	defer cancel()
	ctx = context.WithValue(ctx, hongguoMobileModelKey{}, true)
	identity, err := d.ensureHongguoDeviceIdentity(ctx)
	if err != nil {
		return providerMedia{}, err
	}
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
	request, err := http.NewRequestWithContext(ctx, http.MethodPost, hongguoMobileModelURL, bytes.NewReader(body))
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
	if err = ctx.Err(); err != nil {
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
	return d.resolveHongguoModelMedia(ctx, model)
}

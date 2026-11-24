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
	"time"
)

const hongguoDeviceRegisterURL = "https://log.snssdk.com/service/2/device_register/"

// 注册后官方客户端必做一次的匿名设备激活。未激活的设备在播放接口上被当作
// 「低质量设备」，一律回 HTTP 200 + 0 字节正文 —— 与签名是否正确无关。
const hongguoAlertCheckURL = "https://log5-applog-lf.fqnovel.com/service/2/app_alert_check/"

// 激活是尽力而为的旁路请求：超时短于注册，失败也不阻断取流。
const hongguoAlertCheckTimeout = 3 * time.Second

type hongguoRegisterRejection struct{ error }

func hongguoAppQuery(deviceID, installID string) url.Values {
	return url.Values{
		"aid": {"8662"}, "app_name": {"novelread"}, "version_code": {"73532"}, "version_name": {"7.3.5.32"},
		"manifest_version_code": {"73532"}, "update_version_code": {"73532"}, "channel": {"update_64"},
		"device_platform": {"android"}, "os": {"android"}, "ssmix": {"a"}, "device_type": {"25053RT47C"},
		"device_brand": {"Redmi"}, "language": {"zh"}, "os_api": {"36"}, "os_version": {"16"},
		"resolution": {"1280*2772"}, "dpi": {"520"}, "ac": {"wifi"}, "device_id": {deviceID}, "iid": {installID},
	}
}

func (downloader *Downloader) registerHongguoDevice(ctx context.Context) (hongguoDeviceIdentity, error) {
	header := map[string]any{
		"display_name": "红果免费短剧", "aid": 8662, "app_version": "7.3.5.32", "version_code": 73532,
		"manifest_version_code": 73532, "update_version_code": 73532, "channel": "update_64", "package": "com.phoenix.read",
		"app_language": "zh", "os": "Android", "os_version": "16", "os_api": 36, "device_model": "25053RT47C",
		"device_brand": "Redmi", "device_manufacturer": "Xiaomi", "cpu_abi": "arm64-v8a", "density_dpi": 520,
		"display_density": "xxhdpi", "resolution": "2772x1280", "language": "zh", "timezone": 8, "access": "wifi",
		"openudid": randomHex(8), "clientudid": uuidLike(), "cdid": uuidLike(),
		"region": "CN", "tz_name": "Asia/Shanghai", "tz_offset": 28800, "sim_region": "cn", "device_platform": "android",
		"not_request_sender": 0, "is_system_app": 0, "sdk_flavor": "china", "rom": "OS2.0", "rom_version": "BP2A.250605.031.A3",
	}
	body, err := json.Marshal(map[string]any{"magic_tag": "ss_app_log", "header": header, "_gen_time": time.Now().UnixMilli()})
	if err != nil {
		return hongguoDeviceIdentity{}, err
	}
	query := hongguoAppQuery("", "")
	query.Del("device_id")
	query.Del("iid")
	query.Set("req_id", uuidLike())
	request, err := http.NewRequestWithContext(ctx, http.MethodPost, hongguoDeviceRegisterURL, bytes.NewReader(body))
	if err != nil {
		return hongguoDeviceIdentity{}, err
	}
	request.Header.Set("User-Agent", hongguoAppUserAgent)
	request.Header.Set("Accept", "application/json")
	request.Header.Set("Content-Type", "application/json; charset=utf-8")
	response, err := downloader.doPreparedCatalogRequest(request, 20*time.Second, func(prepared *http.Request) {
		query.Set("_rticket", strconv.FormatInt(time.Now().UnixMilli(), 10))
		prepared.URL.RawQuery = query.Encode()
	})
	if err != nil {
		return hongguoDeviceIdentity{}, err
	}
	content, err := io.ReadAll(io.LimitReader(response.Body, 64<<10))
	response.Body.Close()
	if err != nil {
		return hongguoDeviceIdentity{}, err
	}
	if response.StatusCode != http.StatusOK {
		return hongguoDeviceIdentity{}, hongguoRegisterRejection{fmt.Errorf("红果设备注册 HTTP %d", response.StatusCode)}
	}
	var result map[string]any
	decoder := json.NewDecoder(bytes.NewReader(content))
	decoder.UseNumber()
	if err := decoder.Decode(&result); err != nil {
		return hongguoDeviceIdentity{}, hongguoRegisterRejection{errors.New("红果设备注册返回格式异常")}
	}
	identity := hongguoDeviceIdentity{
		DeviceID:  mapString(result, "device_id_str", "device_id"),
		InstallID: mapString(result, "install_id_str", "install_id"),
		EGDI:      hongguoResponseEgdi(result),
	}
	if !identity.valid() {
		return hongguoDeviceIdentity{}, hongguoRegisterRejection{errors.New("红果设备注册未返回设备号")}
	}
	cookieRequest := &http.Request{Header: http.Header{}}
	for _, cookie := range response.Cookies() {
		cookieRequest.AddCookie(cookie)
	}
	identity.Cookie = cookieRequest.Header.Get("Cookie")
	// 激活放在注册之后、返回之前：激活结果不影响本集取流，但下一集起设备已可信。
	// 只有拿到 klink_egdi 的正常注册才激活 —— 没有它设备本来就是不可信的。
	if identity.EGDI != "" {
		downloader.activateHongguoDevice(ctx, identity)
	}
	return identity, nil
}

// hongguoResponseEgdi 解析注册响应里的 klink_egdi（不透明设备标识，可能直接给，
// 也可能包一层 data）。播放 query 会带上它，缺失时按「设备画像不完整」处理。
func hongguoResponseEgdi(result map[string]any) string {
	if value := mapString(result, "klink_egdi"); value != "" {
		return value
	}
	return mapString(nestedMap(result, "data"), "klink_egdi")
}

// activateHongguoDevice 调一次 app_alert_check（官方注册后必走）。
//
// 失败静默：老设备升级上来时注册信息已存在、不会重新注册，此时靠播放请求自身
// 的完整设备画像兜底，不能因为激活失败就让整集取流失败。
func (downloader *Downloader) activateHongguoDevice(ctx context.Context, identity hongguoDeviceIdentity) {
	if !identity.valid() {
		return
	}
	query := url.Values{
		"aid": {"8662"}, "app_name": {"novelread"}, "channel": {"update_64"},
		"device_id": {identity.DeviceID}, "iid": {identity.InstallID},
		"device_platform": {"android"}, "os": {"android"},
		"version_code": {"73932"}, "version_name": {"7.3.9.32"},
		"_rticket": {strconv.FormatInt(time.Now().UnixMilli(), 10)},
	}
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, hongguoAlertCheckURL+"?"+query.Encode(), nil)
	if err != nil {
		return
	}
	request.Header.Set("User-Agent", hongguoAppUserAgent)
	request.Header.Set("Accept", "application/json")
	response, err := downloader.doPreparedCatalogRequest(request, hongguoAlertCheckTimeout, func(*http.Request) {})
	if err != nil {
		return
	}
	io.Copy(io.Discard, io.LimitReader(response.Body, 8<<10))
	response.Body.Close()
}

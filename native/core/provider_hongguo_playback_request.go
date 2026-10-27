package core

import (
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"
)

func hongguoPlaybackQuery(identity hongguoDeviceIdentity, timestamp, ticket int64) string {
	fields := [][2]string{
		{"ac", "wifi"}, {"channel", "update_64"}, {"aid", "8662"}, {"app_name", "novelread"},
		{"version_code", "71332"}, {"version_name", "7.1.3.32"}, {"device_platform", "android"},
		{"os", "android"}, {"ssmix", "a"}, {"device_type", "25053RT47C"}, {"device_brand", "Redmi"},
		{"language", "zh"}, {"os_api", "36"}, {"os_version", "16"}, {"manifest_version_code", "71332"},
		{"resolution", "1280*2772"}, {"dpi", "520"}, {"update_version_code", "71332"},
		{"host_abi", "arm64-v8a"}, {"dragon_device_type", "phone"}, {"pv_player", "71332"},
		{"compliance_status", "0"}, {"need_personal_recommend", "1"}, {"player_so_load", "1"},
		{"is_android_pad_screen", "0"}, {"iid", identity.InstallID}, {"device_id", identity.DeviceID},
		{"ts", strconv.FormatInt(timestamp, 10)}, {"_rticket", strconv.FormatInt(ticket, 10)},
	}
	encoded := make([]string, 0, len(fields))
	for _, field := range fields {
		encoded = append(encoded, url.QueryEscape(field[0])+"="+strings.ReplaceAll(url.QueryEscape(field[1]), "+", "%20"))
	}
	return strings.Join(encoded, "&")
}

func (client *hongguoAppClient) preparePlaybackSignature(request *http.Request, body []byte, now time.Time, identities [32]hongguoDeviceIdentity) {
	var identity hongguoDeviceIdentity
	for offset, candidate := range identities {
		identity = candidate
		request.URL.RawQuery = hongguoPlaybackQuery(identity, now.Unix(), now.UnixMilli()+int64(offset))
		if hgBranchOf(request.URL.String(), body, uint32(now.Unix())) != 1 {
			break
		}
	}
	for name, value := range hgSignHeaders(request.URL.String(), body, uint32(now.Unix()), identity.DeviceID, "7.1.3.32") {
		request.Header.Set(name, value)
	}
	request.Header.Set("X-SS-STUB", strings.ToUpper(hgHex(hgMD5(body))))
	request.Header.Set("X-SS-Req-Ticket", request.URL.Query().Get("_rticket"))
	client.signatureMu.Lock()
	client.signatureStatus.Generated++
	client.signatureStatus.GeneratedAt = now
	client.signatureStatus.UsedAt = now
	client.signatureMu.Unlock()
}

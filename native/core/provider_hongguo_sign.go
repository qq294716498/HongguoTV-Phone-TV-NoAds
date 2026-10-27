package core

import (
	"crypto/rand"
	"encoding/binary"
	"net/http"
	"strconv"
	"strings"
	"time"
)

func newHongguoPlaybackIdentity() (hongguoDeviceIdentity, error) {
	var random [16]byte
	if _, err := rand.Read(random[:]); err != nil {
		return hongguoDeviceIdentity{}, err
	}
	id := func(part []byte) string {
		return strconv.FormatUint(1_000_000_000_000_000+(binary.BigEndian.Uint64(part)&((1<<48)-1)), 10)
	}
	return hongguoDeviceIdentity{DeviceID: id(random[:8]), InstallID: id(random[8:])}, nil
}

func newHongguoDeviceID() string {
	var random [8]byte
	if _, err := rand.Read(random[:]); err != nil {
		return strconv.FormatInt(time.Now().UnixNano(), 10)
	}
	return strconv.FormatUint(1_000_000_000_000_000_000+binary.BigEndian.Uint64(random[:])%8_000_000_000_000_000_000, 10)
}

// signHongguoRequest 为红果 App 接口附加完整签名头。
//
// 必须六个头齐全：官方播放接口（multi_video_model/v1）对缺头的请求返回
// HTTP 200 且正文为零字节，不会给出任何错误码，因此缺头时表现为「接口没数据」。
//
// 另需处理 branch==1：签名内部按 iv 低 4 位选分支，落到 1 时服务端不接受，
// 表现为同样的空正文。此处通过自增 _rticket 重算出不同 iv 来避开。
func signHongguoRequest(request *http.Request, body []byte, now time.Time) {
	timestamp := uint32(now.Unix())
	for attempt := 0; attempt < 32; attempt++ {
		if hgBranchOf(request.URL.String(), body, timestamp) != 1 {
			break
		}
		bumped, ok := hgBumpTicket(request.URL.RawQuery)
		if !ok {
			break
		}
		request.URL.RawQuery = bumped
	}

	query := request.URL.RawQuery
	headers := hgSignHeaders(
		request.URL.String(),
		body,
		timestamp,
		hgParamOf(query, "device_id", "0"),
		hgParamOf(query, "version_name", "7.1.3.32"),
	)
	for name, value := range headers {
		request.Header.Set(name, value)
	}
	if len(body) > 0 {
		request.Header.Set("X-SS-STUB", strings.ToUpper(hgHex(hgMD5(body))))
	}
	ticket := hgParamOf(query, "_rticket", "")
	if ticket == "" {
		ticket = strconv.FormatInt(now.UnixMilli(), 10)
	}
	request.Header.Set("X-SS-Req-Ticket", ticket)
}

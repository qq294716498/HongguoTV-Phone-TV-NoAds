package core

import (
	"bytes"
	"compress/gzip"
	"context"
	"crypto/aes"
	"crypto/cipher"
	"crypto/rand"
	"crypto/sha512"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

func hongguoEncryptRegistration(body []byte) ([]byte, error) {
	var compressed bytes.Buffer
	writer := gzip.NewWriter(&compressed)
	if _, err := writer.Write(body); err != nil {
		return nil, err
	}
	if err := writer.Close(); err != nil {
		return nil, err
	}
	seed := make([]byte, 32)
	if _, err := rand.Read(seed); err != nil {
		return nil, err
	}
	digest := sha512.Sum512(seed)
	keyMaterial := sha512.Sum512(append(digest[:], hongguoSpadeURLConstants...))
	digest = sha512.Sum512(compressed.Bytes())
	plain := append(digest[:], compressed.Bytes()...)
	padding := aes.BlockSize - len(plain)%aes.BlockSize
	plain = append(plain, bytes.Repeat([]byte{byte(padding)}, padding)...)
	block, err := aes.NewCipher(keyMaterial[:16])
	if err != nil {
		return nil, err
	}
	encrypted := make([]byte, len(plain))
	cipher.NewCBCEncrypter(block, keyMaterial[16:32]).CryptBlocks(encrypted, plain)
	return append(append([]byte{0x74, 0x63, 0x05, 0x10, 0, 0}, seed...), encrypted...), nil
}

func (d *Downloader) registerHongguoDevice(ctx context.Context) (string, string, string, error) {
	random := make([]byte, 64)
	if _, err := rand.Read(random); err != nil {
		return "", "", "", err
	}
	id := func(start int) string { return hex.EncodeToString(random[start : start+16]) }
	now := time.Now()
	header := map[string]any{
		"display_name": "红果免费短剧", "aid": 8662, "channel": "69310258a", "package": "com.phoenix.read",
		"version_code": 73932, "app_version": "7.3.9.32", "sdk_version": "3.7.0-rc.34-fanqie-xiaoshuo", "sdk_target_version": 29,
		"git_hash": "3a88f4e", "release_build": "b5e187f", "os": "Android", "os_version": "16", "os_api": 36,
		"device_model": "25053RT47C", "device_brand": "Redmi", "device_manufacturer": "Xiaomi", "cpu_abi": "arm64-v8a",
		"density_dpi": 520, "display_density": "mdpi", "resolution": "1280x2772", "language": "zh", "timezone": 8, "access": "wifi",
		"carrier": "CHINA MOBILE", "mcc_mnc": "46000", "rom": "BP2A.250605.031.A3", "rom_version": "release-keys",
		"cdid": id(0), "sig_hash": "56a962410c494bbaf0b58dba20cae56f", "openudid": hex.EncodeToString(random[16:24]), "clientudid": id(16),
		"region": "CN", "tz_name": "Asia/Shanghai", "tz_offset": 28800, "sim_region": "cn", "sim_serial_number": []string{},
		"oaid_may_support": false, "req_id": id(32), "device_platform": "android", "custom": map[string]any{"account_region_src": "fallback", "host_bit": 64, "account_region": "cn", "dragon_device_type": "phone"},
		"pre_installed_channel": "", "apk_first_install_time": now.UnixMilli(), "is_system_app": 0, "sdk_flavor": "china", "guest_mode": 0,
	}
	body, err := json.Marshal(map[string]any{"magic_tag": "ss_app_log", "header": header, "_gen_time": now.UnixMilli()})
	if err != nil {
		return "", "", "", err
	}
	body, err = hongguoEncryptRegistration(body)
	if err != nil {
		return "", "", "", err
	}
	request, err := http.NewRequestWithContext(ctx, http.MethodPost, "https://log5-applog-lf.fqnovel.com/service/2/device_register/?tt_data=a&cronet_version=8d40f833_2026-03-03&ttnet_version=4.2.243.31-douyin&use_store_region_cookie=1", bytes.NewReader(body))
	if err != nil {
		return "", "", "", err
	}
	for key, value := range map[string]string{
		"Content-Type": "application/octet-stream;tt-data=a", "Log-Encode-Type": "gzip", "X-SS-DP": "8662", "X-SS-Req-Ticket": strconv.FormatInt(now.UnixMilli(), 10),
		"X-Vc-Bdturing-Sdk-Version": "4.0.3.cn", "Lc": "101", "Sdk-Version": "2", "Passport-Sdk-Version": "5051452", "X-Neptune": "-8|50:51:59:30:40:47:49:39",
		"X-SS-STUB": fmt.Sprintf("%X", hgMD5(body)), "User-Agent": "com.phoenix.read/73932 (Linux; U; Android 16; zh_CN; 25053RT47C; Build/BP2A.250605.031.A3)",
	} {
		request.Header.Set(key, value)
	}
	response, err := d.doCatalogRequestWithTimeout(request, 8*time.Second)
	if err != nil {
		return "", "", "", err
	}
	defer response.Body.Close()
	content, err := io.ReadAll(io.LimitReader(response.Body, (1<<20)+1))
	if err != nil {
		return "", "", "", err
	}
	if response.StatusCode != http.StatusOK || catalogResponseBlockReason(response, content) != "" {
		return "", "", "", d.catalogResponseError(request, response, content)
	}
	if len(content) > 1<<20 {
		return "", "", "", errors.New("红果设备注册响应过大")
	}
	decoder := json.NewDecoder(bytes.NewReader(content))
	decoder.UseNumber()
	var result map[string]any
	if decoder.Decode(&result) != nil {
		return "", "", "", errors.New("红果设备注册响应无效")
	}
	deviceID := mapString(result, "device_id_str", "device_id")
	installID := mapString(result, "install_id_str", "install_id")
	if !(hongguoDeviceIdentity{DeviceID: deviceID, InstallID: installID}).valid() {
		return "", "", "", errors.New("红果设备注册未下发有效身份")
	}
	cookieRequest := &http.Request{Header: http.Header{}}
	for _, cookie := range response.Cookies() {
		cookieRequest.AddCookie(cookie)
	}
	return deviceID, installID, cookieRequest.Header.Get("Cookie"), nil
}

type hongguoDeviceIdentity struct {
	DeviceID  string `json:"deviceId"`
	InstallID string `json:"installId"`
	Cookie    string `json:"cookie"`
}

func (identity hongguoDeviceIdentity) valid() bool {
	return hongguoNumericID.MatchString(identity.DeviceID) && strings.Trim(identity.DeviceID, "0") != "" && hongguoNumericID.MatchString(identity.InstallID) && strings.Trim(identity.InstallID, "0") != ""
}

func (d *Downloader) ensureHongguoDeviceIdentity(ctx context.Context) (hongguoDeviceIdentity, error) {
	client := d.hongguoClient()
	select {
	case client.deviceRegistration <- struct{}{}:
	case <-ctx.Done():
		return hongguoDeviceIdentity{}, ctx.Err()
	}
	defer func() { <-client.deviceRegistration }()
	path := filepath.Join(d.cfg.dataDir, "hongguo-device.json")
	if !client.deviceIdentityLoaded {
		if d.cfg.dataDir != "" {
			body, err := os.ReadFile(path)
			restoredCurrent := err == nil
			if os.IsNotExist(err) {
				body, err = os.ReadFile(filepath.Join(d.cfg.dataDir, "hongguo-search-device.json"))
			}
			if err == nil {
				var saved hongguoDeviceIdentity
				if json.Unmarshal(body, &saved) == nil {
					client.deviceIdentity = saved
					client.deviceIdentityPersisted = saved.valid() && restoredCurrent
				}
			}
		}
		client.deviceIdentityLoaded = true
	}
	if !client.deviceIdentity.valid() {
		deviceID, installID, cookie, err := d.registerHongguoDevice(ctx)
		if err != nil {
			return hongguoDeviceIdentity{}, err
		}
		client.deviceIdentity = hongguoDeviceIdentity{DeviceID: deviceID, InstallID: installID, Cookie: cookie}
	}
	if d.cfg.dataDir != "" && !client.deviceIdentityPersisted {
		body, _ := json.Marshal(client.deviceIdentity)
		if err := writeNativeCacheFile(path, body); err != nil {
			return hongguoDeviceIdentity{}, errors.New("设备注册信息无法保存，请检查存储空间或目录权限后重试")
		}
		client.deviceIdentityPersisted = true
	}
	client.mu.Lock()
	client.state.DeviceID = client.deviceIdentity.DeviceID
	client.state.InstallID = client.deviceIdentity.InstallID
	client.mu.Unlock()
	return client.deviceIdentity, nil
}

package core

import (
	"bytes"
	"compress/gzip"
	"context"
	"crypto/aes"
	"crypto/cipher"
	"crypto/rand"
	"crypto/sha512"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
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

type hongguoDeviceIdentity struct {
	DeviceID  string `json:"deviceId"`
	InstallID string `json:"installId"`
	Cookie    string `json:"cookie"`
	CDID      string `json:"cdid,omitempty"`
	// EGDI 是注册下发的不透明设备标识（klink_egdi）。官方播放 query 会带它，
	// 缺了就落到「设备画像不完整」那一类，播放接口回 200 + 0 字节。
	EGDI string `json:"egdi,omitempty"`
}

func (identity hongguoDeviceIdentity) valid() bool {
	return hongguoNumericID.MatchString(identity.DeviceID) && strings.Trim(identity.DeviceID, "0") != "" && hongguoNumericID.MatchString(identity.InstallID) && strings.Trim(identity.InstallID, "0") != ""
}

func (d *Downloader) ensureHongguoDeviceIdentity(ctx context.Context, rejected ...string) (hongguoDeviceIdentity, error) {
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
					// 0.1.60 之前不解析 klink_egdi，磁盘上的旧身份多半没有它 ——
					// 包括从 hongguo-search-device.json 迁移过来的那一份。
					client.deviceIdentityNeedsEGDI = saved.valid() && saved.EGDI == ""
				}
			}
		}
		client.deviceIdentityLoaded = true
	}
	background, _ := ctx.Value(backgroundCatalogKey{}).(bool)
	mobile, _ := ctx.Value(hongguoMobileModelKey{}).(bool)
	if mobile && background && !client.deviceIdentity.valid() {
		return hongguoDeviceIdentity{}, errors.New("红果后台预取等待前台设备注册")
	}
	rotate := len(rejected) > 0 && rejected[0] == client.deviceIdentity.DeviceID
	// 老版本存下来的身份没有 EGDI，而播放接口现在按「设备画像是否完整」过滤：
	// 缺 EGDI 时重新注册一次把设备可信标识补上，只试一次。
	missingEGDI := client.deviceIdentityNeedsEGDI
	if !client.deviceIdentity.valid() || rotate || missingEGDI {
		client.deviceIdentityNeedsEGDI = false
		if time.Now().Before(client.deviceRotationPausedUntil) {
			if missingEGDI {
				// 注册暂不可用时不至于让整集取流失败：用旧身份继续尝试。
				return client.deviceIdentity, nil
			}
			return hongguoDeviceIdentity{}, errors.New("红果设备注册暂不可用，请稍后重试")
		}
		registered, err := d.registerHongguoDevice(ctx)
		if err != nil {
			var rejection hongguoRegisterRejection
			if errors.As(err, &rejection) && ctx.Err() == nil {
				client.deviceRotationPausedUntil = time.Now().Add(10 * time.Minute)
			}
			// 只为补 EGDI 的重注册失败时，不该让原本能用的旧身份失效。
			if missingEGDI {
				return client.deviceIdentity, nil
			}
			return hongguoDeviceIdentity{}, err
		}
		client.deviceIdentityPersisted = false
		client.deviceIdentity = registered
	}
	if client.deviceIdentity.CDID == "" {
		client.deviceIdentity.CDID = uuidLike()
		client.deviceIdentityPersisted = false
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
	client.signatureMu.Lock()
	client.signatureStatus.Registered = true
	client.signatureMu.Unlock()
	return client.deviceIdentity, nil
}

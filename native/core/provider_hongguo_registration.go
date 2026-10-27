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
				}
			}
		}
		client.deviceIdentityLoaded = true
	}
	rotate := len(rejected) > 0 && rejected[0] == client.deviceIdentity.DeviceID
	if !client.deviceIdentity.valid() || rotate {
		if rotate && time.Now().Before(client.deviceRotationPausedUntil) {
			return hongguoDeviceIdentity{}, errors.New("红果设备注册暂不可用，请稍后重试")
		}
		deviceID, installID, cookie, err := d.registerHongguoDevice(ctx)
		if err != nil {
			if rotate && ctx.Err() == nil {
				client.deviceRotationPausedUntil = time.Now().Add(10 * time.Minute)
			}
			return hongguoDeviceIdentity{}, err
		}
		client.deviceIdentityPersisted = false
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
	client.signatureMu.Lock()
	client.signatureStatus.Registered = true
	client.signatureMu.Unlock()
	return client.deviceIdentity, nil
}

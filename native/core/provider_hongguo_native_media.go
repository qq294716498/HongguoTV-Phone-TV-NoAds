package core

import (
	"context"
	"crypto/aes"
	"crypto/cipher"
	"crypto/sha512"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"sort"
	"strconv"
	"strings"
	"time"
)

// 红果播放取源。
//
// 老路径 /novel/player/video_model/v1/ 实测长期只返回 200 空正文（补齐全套签名也不返回数据），
// 当前有效路径是 multi_video_model/v1。新路径与老接口的差异：
//   - 请求体用 mixed_video_id_map + biz_param，不再有顶层 video_id / content_type；
//   - mixed_video_id_map 的键固定 1004、video_platform 固定 1024，实测用其它取值返回 100001；
//   - video_model 有时直接带 video_list，有时只给 fallback_api，需二次 GET 拿 video_info.data。
const hongguoVideoModelPath = "/novel/player/multi_video_model/v1/"

// 允许跟随 fallback_api 的域名后缀，避免把请求带往第三方。
var hongguoFallbackDomains = []string{"fqnovel.com", "snssdk.com"}

// 媒体 URL 解密的固定常量段（64 字节）。
var hongguoSpadeURLConstants = hgUnhex(
	"4dd4c2e6b83162090e52b3c7a6733ba41cb2462b829ab58a196b39db57177524" +
		"f49baf7f08e8d68d26a72e37c1a95a2f1f05a51892aef2949732b62a38aadd58")

// resolveHongguoAppMedia 取某集的 App 播放信息。
// contentTypes 由调用方按剧集元数据传入；新接口不再接受 content_type，
// 保留形参只为不打断既有调用链。
func (downloader *Downloader) resolveHongguoAppMedia(ctx context.Context, videoID string, contentTypes ...int) (providerMedia, error) {
	if !hongguoNumericID.MatchString(videoID) {
		return providerMedia{}, errors.New("红果视频 ID 无效")
	}
	payload := map[string]any{
		"biz_param": map[string]any{
			"detail_page_version":       0,
			"device_level":              3,
			"disable_digg_stat":         false,
			"need_all_video_definition": true,
			"need_mp4_align":            false,
			"use_os_player":             false,
			"use_server_dns":            false,
			"video_platform":            1024,
		},
		"mixed_video_id_map": map[string]any{"1004": []any{videoID}},
	}
	result, err := downloader.hongguoAppRequest(ctx, http.MethodPost, hongguoVideoModelPath, nil, payload)
	if err != nil {
		return providerMedia{}, err
	}
	data := nestedMap(result, "data")
	var model map[string]any
	// 三种返回形态：data[vid].video_model（新）、data.video_model（旧）、其它单键条目。
	if entry := nestedMap(data, videoID); len(entry) > 0 {
		model, err = hongguoVideoModel(entry["video_model"])
		if err != nil {
			return providerMedia{}, err
		}
	} else if direct, exists := data["video_model"]; exists {
		model, err = hongguoVideoModel(direct)
		if err != nil {
			return providerMedia{}, err
		}
	} else {
		for _, candidate := range data {
			object, ok := candidate.(map[string]any)
			if !ok {
				continue
			}
			if parsed, parseErr := hongguoVideoModel(object["video_model"]); parseErr == nil && len(parsed) > 0 {
				model = parsed
				break
			}
		}
		if len(model) == 0 {
			return providerMedia{}, errors.New("红果 App 接口未返回该集播放信息")
		}
	}
	// 两种返回形态都要支持：直接给 video_list，或只给 fallback_api。
	if hongguoModelHasVideoList(model) {
		return selectHongguoAppMedia(model)
	}
	fallback := strings.TrimSpace(mapString(model, "fallback_api"))
	if fallback == "" {
		return providerMedia{}, errors.New("红果 App 接口未返回本集片源地址")
	}
	outer, err := downloader.hongguoFallbackJSON(ctx, fallback)
	if err != nil {
		return providerMedia{}, err
	}
	info := nestedMap(outer, "video_info")
	inner := nestedMap(info, "data")
	if len(inner) == 0 {
		inner = nestedMap(outer, "data")
	}
	if len(inner) == 0 {
		return providerMedia{}, errors.New("红果 App 接口未返回本集片源模型")
	}
	var seed []byte
	if encoded := strings.TrimSpace(mapString(inner, "key_seed")); encoded != "" {
		decoded, decodeErr := decodeHongguoBase64(encoded)
		if decodeErr != nil {
			return providerMedia{}, errors.New("红果 App 媒体地址密钥无效")
		}
		seed = decoded
	}
	merged := make(map[string]any, len(inner)+len(model))
	for key, value := range model {
		merged[key] = value
	}
	for key, value := range inner {
		merged[key] = value
	}
	return selectHongguoAppMedia(merged, seed)
}

func hongguoModelHasVideoList(model map[string]any) bool {
	if len(anyList(model["video_list"])) > 0 {
		return true
	}
	if rows, ok := model["video_list"].(map[string]any); ok && len(rows) > 0 {
		return true
	}
	return false
}

// hongguoVideoModel 规整 video_model：可能是 JSON 字符串，也可能是对象。
func hongguoVideoModel(value any) (map[string]any, error) {
	switch typed := value.(type) {
	case map[string]any:
		return typed, nil
	case string:
		trimmed := strings.TrimSpace(typed)
		if trimmed == "" {
			return nil, errors.New("红果 App 播放信息为空")
		}
		decoded := map[string]any{}
		decoder := json.NewDecoder(strings.NewReader(trimmed))
		decoder.UseNumber()
		if err := decoder.Decode(&decoded); err != nil {
			return nil, errors.New("红果 App 播放信息格式异常")
		}
		return decoded, nil
	default:
		return nil, errors.New("红果 App 未返回播放信息")
	}
}

// hongguoFallbackJSON 跟随 fallback_api：普通 GET，不带签名头，只带 UA。
func (downloader *Downloader) hongguoFallbackJSON(ctx context.Context, rawURL string) (map[string]any, error) {
	if err := hongguoCheckFallbackDomain(rawURL); err != nil {
		return nil, err
	}
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, rawURL, nil)
	if err != nil {
		return nil, err
	}
	request.Header.Set("User-Agent", hongguoAppUserAgent)
	request.Header.Set("Accept", "application/json")
	response, err := downloader.doPreparedCatalogRequest(request, 20*time.Second, nil)
	if err != nil {
		return nil, err
	}
	defer response.Body.Close()
	content, err := io.ReadAll(io.LimitReader(response.Body, providerMaxBodyBytes+1))
	if err != nil {
		return nil, err
	}
	if response.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("红果片源接口 HTTP %d", response.StatusCode)
	}
	if len(content) == 0 {
		return nil, errors.New("红果片源接口返回空正文")
	}
	decoded := map[string]any{}
	decoder := json.NewDecoder(strings.NewReader(string(content)))
	decoder.UseNumber()
	if err := decoder.Decode(&decoded); err != nil {
		return nil, errors.New("红果片源接口返回了无效数据")
	}
	return decoded, nil
}

func hongguoCheckFallbackDomain(rawURL string) error {
	parsed, err := url.Parse(strings.TrimSpace(rawURL))
	if err != nil {
		return errors.New("红果片源地址无效")
	}
	if parsed.Scheme != "https" {
		return errors.New("红果片源地址不是 HTTPS")
	}
	host := strings.ToLower(parsed.Hostname())
	for _, allowed := range hongguoFallbackDomains {
		if host == allowed || strings.HasSuffix(host, "."+allowed) {
			return nil
		}
	}
	return errors.New("红果片源地址不在允许的域名内")
}

// selectHongguoAppMedia 从 video_list 选流；seed 非空时用于解密受 key_seed 保护的地址。
func selectHongguoAppMedia(model map[string]any, seeds ...[]byte) (providerMedia, error) {
	var seed []byte
	if len(seeds) > 0 {
		seed = seeds[0]
	}
	variants := anyList(model["video_list"])
	if rows, ok := model["video_list"].(map[string]any); ok && len(variants) == 0 {
		keys := make([]string, 0, len(rows))
		for key := range rows {
			keys = append(keys, key)
		}
		sort.Strings(keys)
		for _, key := range keys {
			variants = append(variants, rows[key])
		}
	}
	if len(variants) == 0 {
		return providerMedia{}, errors.New("红果 App 未返回可用的视频档位")
	}
	duration, _ := strconv.ParseFloat(mapString(model, "video_duration", "duration"), 64)
	var keyErr error
	type scoredMedia struct {
		media providerMedia
		score int
	}
	var choices []scoredMedia
	for _, row := range variants {
		variant, _ := row.(map[string]any)
		meta := nestedMap(variant, "video_meta")
		codec := strings.ToLower(mapString(meta, "codec_type"))
		if codec == "bytevc2" || strings.Contains(strings.ToLower(mapString(variant, "gear_des_key")), "bytevc2") {
			continue
		}
		addresses := hongguoMediaAddresses(variant, seed)
		if len(addresses) == 0 {
			continue
		}
		media := providerMedia{Referer: "https://novel.snssdk.com/", Duration: time.Duration(duration * float64(time.Second))}
		encryption := nestedMap(variant, "encrypt_info")
		spade := mapString(encryption, "spade_a")
		if spade != "" || encryption["encrypt"] == true || mapString(encryption, "encryption_method") == "cenc-aes-ctr" {
			var err error
			media.CENCKey, err = hongguoContentKey(spade)
			if err != nil {
				keyErr = err
				continue
			}
		}
		height, _ := strconv.Atoi(mapString(meta, "vheight"))
		if definition, err := strconv.Atoi(hongguoQualityNumber.FindString(mapString(meta, "definition"))); err == nil && definition > 0 {
			height = definition
		} else if width, _ := strconv.Atoi(mapString(meta, "vwidth")); width > 0 && (height == 0 || width < height) {
			height = width
		}
		media.Quality = height
		quality := height * 10
		if codec == "h264" || codec == "avc1" {
			quality++
		}
		for _, address := range addresses {
			media.URL = address
			choices = append(choices, scoredMedia{media: media, score: quality})
		}
	}
	if len(choices) > 0 {
		sort.SliceStable(choices, func(i, j int) bool { return choices[i].score > choices[j].score })
		selected := choices[0].media
		for _, choice := range choices {
			selected.Variants = append(selected.Variants, choice.media)
		}
		return selected, nil
	}
	if keyErr != nil {
		return providerMedia{}, fmt.Errorf("红果 App 媒体密钥不可用: %w", keyErr)
	}
	return providerMedia{}, errors.New("红果 App 未返回兼容的媒体，已跳过不支持的编码")
}

// hongguoMediaAddresses 收集候选媒体地址；seed 非空时先按 spade URL 解密。
func hongguoMediaAddresses(info map[string]any, seeds ...[]byte) []string {
	var seed []byte
	if len(seeds) > 0 {
		seed = seeds[0]
	}
	var addresses []string
	seen := map[string]bool{}
	var add func(any)
	add = func(value any) {
		switch typed := value.(type) {
		case string:
			address := strings.TrimSpace(typed)
			if len(address) > 8192 {
				return
			}
			if !isProviderHTTPMediaURL(address) {
				if seed != nil {
					if decrypted, err := hongguoDecryptSpadeURL(address, seed); err == nil {
						address = decrypted
					}
				}
				if !isProviderHTTPMediaURL(address) {
					decoded, err := decodeHongguoBase64(address)
					if err != nil {
						return
					}
					address = strings.TrimSpace(string(decoded))
				}
			}
			if isProviderHTTPMediaURL(address) && !seen[address] {
				seen[address] = true
				addresses = append(addresses, address)
			}
		case []any:
			for _, item := range typed {
				add(item)
			}
		}
	}
	for _, key := range []string{"main_url", "backup_url", "backup_url_1", "backup_url_2", "backup_urls", "url_list"} {
		add(info[key])
	}
	return addresses
}

// hongguoDecryptSpadeURL 解密被 key_seed 保护的媒体地址。
// 布局：[0]=0xa8、[1] 保留、[2]=0x01、[3]=0x00、[4:] 为 AES-128-CBC 密文。
func hongguoDecryptSpadeURL(value string, seed []byte) (string, error) {
	raw, err := decodeHongguoBase64(value)
	if err != nil || len(raw) < 5 {
		return "", errors.New("红果媒体地址密文过短")
	}
	if raw[0] != 0xa8 || raw[2] != 0x01 || raw[3] != 0x00 {
		return "", errors.New("红果媒体地址密文头格式错误")
	}
	cipherLength := (len(raw) - 4) / aes.BlockSize * aes.BlockSize
	if cipherLength == 0 {
		return "", errors.New("红果媒体地址密文无完整分组")
	}
	first := sha512.Sum512(seed)
	second := sha512.Sum512(append(first[:], hongguoSpadeURLConstants...))
	block, err := aes.NewCipher(second[:16])
	if err != nil {
		return "", err
	}
	plain := make([]byte, cipherLength)
	cipher.NewCBCDecrypter(block, second[16:32]).CryptBlocks(plain, raw[4:4+cipherLength])
	end := len(plain)
	if end > 0 {
		if padding := int(plain[end-1]); padding >= 1 && padding <= aes.BlockSize && padding <= end {
			end -= padding
		}
	}
	for end > 0 && plain[end-1] == 0 {
		end--
	}
	return string(plain[:end]), nil
}

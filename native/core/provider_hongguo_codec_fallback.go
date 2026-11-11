package core

import (
	"context"
	"errors"
	"math"
	"net/url"
	"strconv"
	"strings"
)

func hongguoOnlyByteVC2(err error) bool {
	var failure *hongguoMediaSelectionError
	return errors.As(err, &failure) && failure.variants > 0 && failure.unsupportedCodec == failure.variants
}

func selectHongguoSeededMedia(model map[string]any) (providerMedia, error) {
	var seed []byte
	if encoded := strings.TrimSpace(mapString(model, "key_seed")); encoded != "" {
		var err error
		seed, err = decodeHongguoBase64(encoded)
		if err != nil {
			return providerMedia{}, errors.New("红果 App 媒体地址密钥无效")
		}
	}
	return selectHongguoAppMedia(model, seed)
}

func (downloader *Downloader) resolveHongguoModelMedia(ctx context.Context, model map[string]any) (providerMedia, error) {
	var initialError error
	if hongguoModelHasVideoList(model) {
		media, err := selectHongguoSeededMedia(model)
		if !hongguoOnlyByteVC2(err) {
			return media, err
		}
		initialError = err
	}
	fallback := hongguoFallbackAddress(model["fallback_api"])
	if fallback == "" {
		if initialError != nil {
			return providerMedia{}, initialError
		}
		return providerMedia{}, errors.New("红果 App 接口未返回本集片源地址")
	}
	current, err := downloader.hongguoFallbackModel(ctx, fallback)
	if err != nil {
		return providerMedia{}, err
	}
	if err := hongguoConfirmMediaIdentity(model, current, false); err != nil {
		return providerMedia{}, err
	}
	merged := make(map[string]any, len(model)+len(current))
	for key, value := range model {
		merged[key] = value
	}
	for key, value := range current {
		merged[key] = value
	}
	media, err := selectHongguoSeededMedia(merged)
	if !hongguoOnlyByteVC2(err) {
		return media, err
	}
	for _, query := range []string{"codec_type=1", "codec_type=0&force_codec=h264"} {
		if err := ctx.Err(); err != nil {
			return providerMedia{}, err
		}
		address, addressErr := hongguoCompatibleFallback(fallback, query)
		if addressErr != nil {
			return providerMedia{}, addressErr
		}
		other, fetchErr := downloader.hongguoFallbackModel(ctx, address)
		if fetchErr != nil {
			return providerMedia{}, fetchErr
		}
		if identityErr := hongguoConfirmMediaIdentity(current, other, true); identityErr != nil {
			return providerMedia{}, identityErr
		}
		candidate, selectionErr := selectHongguoSeededMedia(other)
		if selectionErr == nil {
			return candidate, nil
		}
		if !hongguoOnlyByteVC2(selectionErr) {
			return providerMedia{}, selectionErr
		}
		err = selectionErr
	}
	return providerMedia{}, err
}

func (downloader *Downloader) hongguoFallbackModel(ctx context.Context, address string) (map[string]any, error) {
	outer, err := downloader.hongguoFallbackJSON(ctx, address)
	if err != nil {
		return nil, err
	}
	info := nestedMap(outer, "video_info")
	for _, object := range []map[string]any{outer, info} {
		for _, name := range []string{"code", "Code"} {
			if value := mapString(object, name); value != "" && value != "0" {
				return nil, errors.New("红果片源接口拒绝本次请求")
			}
		}
	}
	inner := nestedMap(info, "data")
	if len(inner) == 0 {
		inner = nestedMap(outer, "data")
	}
	if len(inner) == 0 {
		return nil, errors.New("红果 App 接口未返回本集片源模型")
	}
	return inner, nil
}

func hongguoCompatibleFallback(address, codecQuery string) (string, error) {
	if err := hongguoCheckFallbackDomain(address); err != nil {
		return "", err
	}
	parsed, err := url.Parse(address)
	if err != nil {
		return "", err
	}
	var kept []string
	for _, item := range strings.Split(parsed.RawQuery, "&") {
		key, _, _ := strings.Cut(item, "=")
		name, err := url.QueryUnescape(key)
		if err != nil {
			return "", errors.New("红果片源查询参数无效")
		}
		if item != "" && name != "codec_type" && name != "force_codec" {
			kept = append(kept, item)
		}
	}
	parsed.RawQuery = strings.Join(append(kept, codecQuery), "&")
	return parsed.String(), nil
}

func hongguoConfirmMediaIdentity(reference, other map[string]any, required bool) error {
	id, otherID := mapString(reference, "video_id", "vid"), mapString(other, "video_id", "vid")
	duration, _ := strconv.ParseFloat(mapString(reference, "video_duration", "duration"), 64)
	otherDuration, _ := strconv.ParseFloat(mapString(other, "video_duration", "duration"), 64)
	validDuration := func(value float64) bool { return value > 0 && !math.IsNaN(value) && !math.IsInf(value, 0) }
	if (id != "" && otherID != "" && id != otherID) ||
		(validDuration(duration) && validDuration(otherDuration) && math.Abs(duration-otherDuration) > 0.5) ||
		(required && (id == "" || otherID == "" || !validDuration(duration) || !validDuration(otherDuration))) {
		return errors.New("备用片源编号或完整时长无法确认，已停止取址")
	}
	return nil
}

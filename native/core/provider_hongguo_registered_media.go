package core

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/url"
	"strings"
)

type hongguoRegisteredBatchKey struct{}

const hongguoSingleVideoModelPath = "/novel/player/video_model/v1/"

func (downloader *Downloader) resolveHongguoRegisteredMedia(ctx context.Context, videoID string) (providerMedia, error) {
	model, err := downloader.fetchHongguoRegisteredVideoModel(ctx, videoID)
	if errors.Is(err, errHongguoEmptyResponse) && !errors.Is(err, errHongguoIdentityRenewal) && ctx.Err() == nil {
		model, err = downloader.fetchHongguoRegisteredBatchVideoModel(ctx, videoID)
	}
	if err != nil {
		return providerMedia{}, err
	}
	return downloader.resolveHongguoModelMedia(ctx, model)
}

func (downloader *Downloader) fetchHongguoRegisteredVideoModel(ctx context.Context, videoID string) (map[string]any, error) {
	if !hongguoNumericID.MatchString(videoID) {
		return nil, errors.New("红果视频 ID 无效")
	}
	payload := map[string]any{
		"video_id": videoID, "content_type": 1,
		"biz_param": map[string]any{"need_all_video_definition": true, "video_platform": 3},
	}
	result, err := downloader.hongguoAppRequest(ctx, http.MethodPost, hongguoSingleVideoModelPath, nil, payload)
	if err != nil {
		return nil, err
	}
	data := nestedMap(result, "data")
	model, _ := data["video_model"].(map[string]any)
	if encoded, ok := data["video_model"].(string); ok && encoded != "" {
		if decoded, err := decodeHongguoBase64(encoded); err == nil && len(decoded) > 0 {
			encoded = string(decoded)
		}
		decoder := json.NewDecoder(strings.NewReader(encoded))
		decoder.UseNumber()
		if err := decoder.Decode(&model); err != nil {
			return nil, errors.New("红果 App 播放信息格式异常")
		}
	}
	if len(model) == 0 {
		if hongguoModelHasVideoList(data) || hongguoFallbackAddress(data["fallback_api"]) != "" {
			model = data
		}
	}
	return model, nil
}

func (downloader *Downloader) fetchHongguoRegisteredBatchVideoModel(ctx context.Context, videoID string) (map[string]any, error) {
	if !hongguoNumericID.MatchString(videoID) {
		return nil, errors.New("红果视频 ID 无效")
	}
	extra := url.Values{"version_code": {"73932"}, "manifest_version_code": {"73932"}, "update_version_code": {"73932"}, "pv_player": {"73932"}, "version_name": {"7.3.9.32"}}
	payload := map[string]any{"biz_param": map[string]any{"detail_page_version": 0, "device_level": 1, "disable_digg_stat": false, "need_all_video_definition": true, "need_mp4_align": false, "use_os_player": false, "use_server_dns": false, "video_platform": 1024}, "mixed_video_id_map": map[string]any{"1004": []any{videoID}}}
	extra.Set("host_abi", "arm64-v8a")
	extra.Set("dragon_device_type", "phone")
	extra.Set("compliance_status", "0")
	extra.Set("need_personal_recommend", "1")
	extra.Set("player_so_load", "1")
	extra.Set("is_android_pad_screen", "0")
	ctx = context.WithValue(ctx, hongguoRegisteredBatchKey{}, true)
	result, err := downloader.hongguoAppRequest(ctx, http.MethodPost, hongguoVideoModelPath, extra, payload)
	if err != nil {
		return nil, err
	}
	data := nestedMap(result, "data")
	row := nestedMap(data, videoID)
	if len(row) == 0 {
		return nil, errors.New("红果 App 接口未返回该集播放信息")
	}
	model, err := hongguoVideoModel(row["video_model"])
	if err != nil {
		return nil, err
	}
	if !hongguoModelHasVideoList(model) && hongguoFallbackAddress(model["fallback_api"]) == "" {
		return nil, errors.New("红果 App 播放信息格式异常")
	}
	return model, nil
}

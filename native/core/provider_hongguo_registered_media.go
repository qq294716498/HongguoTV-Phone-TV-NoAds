package core

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"strings"
)

const hongguoSingleVideoModelPath = "/novel/player/video_model/v1/"

func (downloader *Downloader) resolveHongguoRegisteredMedia(ctx context.Context, videoID string) (providerMedia, error) {
	model, err := downloader.fetchHongguoRegisteredVideoModel(ctx, videoID)
	if err != nil {
		return providerMedia{}, err
	}
	return selectHongguoAppMedia(model)
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
		if hongguoModelHasVideoList(data) {
			model = map[string]any{
				"video_list":     data["video_list"],
				"video_duration": data["video_duration"],
				"duration":       data["duration"],
			}
		}
	}
	return model, nil
}

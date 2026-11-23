package core

import (
	"context"
	"errors"
	"net"
	"strings"
	"time"
)

const hongguoDownloadRetryDelay = 2 * time.Second

// hongguoSignedDownload 判断该任务是否要走红果的签名取流接口；只有这类任务需要
// 下载专用的取流预算与标记，其他源保持原有取流路径。
func hongguoSignedDownload(job nativeDownloadJob) bool {
	return sourceFromDramaID(job.Drama.ID) == sourceHongguo && strings.HasPrefix(job.Chapter.VideoURL, "hongguo-cenc://")
}

func (manager *nativeDownloads) resolveDownloadMedia(ctx context.Context, job nativeDownloadJob) (providerMedia, error) {
	if !hongguoSignedDownload(job) {
		return manager.resolve(ctx, job)
	}
	ctx = context.WithValue(ctx, backgroundCatalogKey{}, true)
	ctx, cancel := context.WithTimeout(context.WithValue(ctx, hongguoDownloadKey{}, true), 2*hongguoDownloadBudget)
	defer cancel()
	var lastErr error
	for attempt := 0; attempt < 2; attempt++ {
		if err := ctx.Err(); err != nil {
			return providerMedia{}, err
		}
		if attempt > 0 {
			timer := time.NewTimer(hongguoDownloadRetryDelay)
			select {
			case <-timer.C:
			case <-ctx.Done():
				timer.Stop()
				return providerMedia{}, ctx.Err()
			}
		}
		media, err := manager.resolve(ctx, job)
		if err == nil {
			return media, ctx.Err()
		}
		lastErr = err
		var blocked *requestBackoff
		var network net.Error
		if ctx.Err() != nil || errors.Is(err, context.Canceled) || errors.As(err, &blocked) {
			return providerMedia{}, err
		}
		if !errors.Is(err, errHongguoEmptyResponse) && !errors.Is(err, context.DeadlineExceeded) && !(errors.As(err, &network) && network.Timeout()) {
			return providerMedia{}, err
		}
	}
	return providerMedia{}, lastErr
}

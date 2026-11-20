package core

import (
	"context"
	"errors"
	"net"
	"strings"
	"time"
)

const (
	hongguoDownloadRetryDelay = 2 * time.Second
	// 红果对高频取流会返回 HTTP 200 + 0 字节正文（软风控），一旦触发会影响同一台
	// 设备上的全部取流，连播放都拿不到片源。批量下载必须限速：串行 slot 之外再
	// 加一层最小间隔，连续空响应则整体冷却，等上游放开再继续。
	hongguoDownloadSpacing    = 1500 * time.Millisecond
	hongguoDownloadCooldown   = 45 * time.Second
	hongguoDownloadEmptyLimit = 4
)

func (manager *nativeDownloads) resolveDownloadMedia(ctx context.Context, job nativeDownloadJob) (providerMedia, error) {
	if sourceFromDramaID(job.Drama.ID) != sourceHongguo || !strings.HasPrefix(job.Chapter.VideoURL, "hongguo-cenc://") {
		return manager.resolve(ctx, job)
	}
	manager.hongguoResolveOnce.Do(func() { manager.hongguoResolveSlot = make(chan struct{}, 1) })
	select {
	case manager.hongguoResolveSlot <- struct{}{}:
	case <-ctx.Done():
		return providerMedia{}, ctx.Err()
	}
	defer func() { <-manager.hongguoResolveSlot }()
	manager.mu.Lock()
	spacing, cooldown := manager.hongguoSpacing, manager.hongguoCooldown
	if spacing <= 0 {
		spacing = hongguoDownloadSpacing
	}
	if cooldown <= 0 {
		cooldown = hongguoDownloadCooldown
	}
	wait := time.Until(manager.hongguoLastResolve.Add(spacing))
	cooling := manager.hongguoEmptyStreak >= hongguoDownloadEmptyLimit
	manager.mu.Unlock()
	if cooling {
		wait = cooldown
	}
	if wait > 0 {
		timer := time.NewTimer(wait)
		select {
		case <-timer.C:
		case <-ctx.Done():
			timer.Stop()
			return providerMedia{}, ctx.Err()
		}
	}
	// 后注册先执行：先记下本次结束时刻，再释放 slot，下一次任务据此计算间隔。
	defer func() {
		manager.mu.Lock()
		manager.hongguoLastResolve = time.Now()
		manager.mu.Unlock()
	}()
	ctx = context.WithValue(ctx, backgroundCatalogKey{}, true)
	ctx, cancel := context.WithTimeout(context.WithValue(ctx, hongguoDownloadKey{}, true), 2*hongguoDownloadBudget+cooldown)
	defer cancel()
	var lastErr error
	for attempt := 0; attempt < 2; attempt++ {
		if err := ctx.Err(); err != nil {
			return providerMedia{}, err
		}
		if attempt > 0 {
			delay := hongguoDownloadRetryDelay
			manager.mu.Lock()
			if manager.hongguoEmptyStreak >= hongguoDownloadEmptyLimit {
				delay = cooldown
			}
			manager.mu.Unlock()
			timer := time.NewTimer(delay)
			select {
			case <-timer.C:
			case <-ctx.Done():
				timer.Stop()
				return providerMedia{}, ctx.Err()
			}
		}
		media, err := manager.resolve(ctx, job)
		if err == nil {
			manager.mu.Lock()
			manager.hongguoEmptyStreak = 0
			manager.mu.Unlock()
			return media, ctx.Err()
		}
		if errors.Is(err, errHongguoEmptyResponse) {
			manager.mu.Lock()
			manager.hongguoEmptyStreak++
			manager.mu.Unlock()
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

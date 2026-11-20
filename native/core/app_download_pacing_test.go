package core

import (
	"context"
	"testing"
	"time"
)

func pacingTestManager(t *testing.T) *nativeDownloads {
	t.Helper()
	manager := &nativeDownloads{}
	manager.resolve = func(context.Context, nativeDownloadJob) (providerMedia, error) {
		return providerMedia{URL: "https://media.example.test/ep.mp4", Quality: 720}, nil
	}
	return manager
}

func pacingTestJob() nativeDownloadJob {
	return nativeDownloadJob{
		Drama:   nativeDrama{ID: "hongguo:100", Source: "hongguo"},
		Chapter: Chapter{VideoURL: "hongguo-cenc://9001"},
		Index:   1,
		Quality: 720,
	}
}

// 批量下载连续取流必须留出间隔，否则红果会把 601 集当成刷接口并返回空正文。
func TestHongguoDownloadsKeepMinimumSpacing(t *testing.T) {
	manager := pacingTestManager(t)
	manager.hongguoSpacing = 120 * time.Millisecond
	manager.hongguoCooldown = time.Nanosecond
	job := pacingTestJob()
	if _, err := manager.resolveDownloadMedia(context.Background(), job); err != nil {
		t.Fatal(err)
	}
	start := time.Now()
	if _, err := manager.resolveDownloadMedia(context.Background(), job); err != nil {
		t.Fatal(err)
	}
	if elapsed := time.Since(start); elapsed < manager.hongguoSpacing {
		t.Fatalf("两次取流间隔 %v，小于设定的 %v", elapsed, manager.hongguoSpacing)
	}
}

// 连续空响应累计到阈值后，下一次取流要先整体冷却，且成功后计数清零。
func TestHongguoDownloadCoolsDownAfterRepeatedEmptyResponses(t *testing.T) {
	manager := pacingTestManager(t)
	manager.hongguoSpacing = time.Nanosecond
	manager.hongguoCooldown = 150 * time.Millisecond
	manager.mu.Lock()
	manager.hongguoEmptyStreak = hongguoDownloadEmptyLimit
	manager.mu.Unlock()
	start := time.Now()
	if _, err := manager.resolveDownloadMedia(context.Background(), pacingTestJob()); err != nil {
		t.Fatal(err)
	}
	if elapsed := time.Since(start); elapsed < manager.hongguoCooldown {
		t.Fatalf("连续空响应后应冷却 %v，实际只等了 %v", manager.hongguoCooldown, elapsed)
	}
	manager.mu.Lock()
	streak := manager.hongguoEmptyStreak
	manager.mu.Unlock()
	if streak != 0 {
		t.Fatalf("取流成功后空响应计数应清零，实际 %d", streak)
	}
}

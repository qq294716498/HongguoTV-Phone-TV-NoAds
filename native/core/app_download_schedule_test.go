package core

import (
	"context"
	"strconv"
	"testing"
	"time"
)

// 红果任务可以全部排进队列，但同一时刻只允许一个在执行：取流接口被高频打满后
// 会对整台设备返回 HTTP 200 + 0 字节，连播放都取不到片源。
func TestHongguoScheduleRunsSingleTaskAtATime(t *testing.T) {
	manager := downloadTestManager(t)
	manager.concurrency = 2
	manager.hongguoSpacing = time.Nanosecond
	manager.hongguoCooldown = time.Nanosecond
	blocked := make(chan struct{})
	manager.resolve = func(ctx context.Context, job nativeDownloadJob) (providerMedia, error) {
		select {
		case <-blocked:
		case <-ctx.Done():
		}
		return providerMedia{}, ctx.Err()
	}
	manager.mu.Lock()
	manager.jobs = map[string]*nativeDownloadRecord{}
	for index := 1; index <= 3; index++ {
		id := nativeDownloadID("hongguo:100", index)
		manager.jobs[id] = &nativeDownloadRecord{nativeDownloadJob: nativeDownloadJob{
			ID:      id,
			Drama:   nativeDrama{ID: "hongguo:100", Source: "hongguo", Title: "合成下载测试"},
			Chapter: Chapter{ID: strconv.Itoa(index), VideoURL: "hongguo-cenc://" + strconv.Itoa(index)},
			Index:   index,
			State:   "queued",
			Created: int64(index),
		}}
	}
	manager.scheduleLocked()
	active := len(manager.active)
	manager.mu.Unlock()
	close(blocked)
	if active != 1 {
		t.Fatalf("红果任务应串行执行，实际同时启动了 %d 个", active)
	}
}

// 非红果源不受红果串行限制，另一个源的任务仍可与红果任务并行。
func TestHongguoScheduleLeavesOtherSourcesParallel(t *testing.T) {
	previous := buildAllSources
	buildAllSources = "true"
	defer func() { buildAllSources = previous }()
	manager := downloadTestManager(t)
	manager.concurrency = 2
	manager.hongguoSpacing = time.Nanosecond
	manager.hongguoCooldown = time.Nanosecond
	blocked := make(chan struct{})
	manager.resolve = func(ctx context.Context, job nativeDownloadJob) (providerMedia, error) {
		select {
		case <-blocked:
		case <-ctx.Done():
		}
		return providerMedia{}, ctx.Err()
	}
	manager.mu.Lock()
	manager.jobs = map[string]*nativeDownloadRecord{}
	manager.jobs["a"] = &nativeDownloadRecord{nativeDownloadJob: nativeDownloadJob{
		ID:      "a",
		Drama:   nativeDrama{ID: "hongguo:100", Source: "hongguo", Title: "红果"},
		Chapter: Chapter{ID: "1", VideoURL: "hongguo-cenc://1"},
		Index:   1, State: "queued", Created: 1,
	}}
	manager.jobs["b"] = &nativeDownloadRecord{nativeDownloadJob: nativeDownloadJob{
		ID:      "b",
		Drama:   nativeDrama{ID: "huangguo-video:200", Source: "huangguo-video", Title: "其他源"},
		Chapter: Chapter{ID: "1"},
		Index:   1, State: "queued", Created: 2,
	}}
	manager.scheduleLocked()
	active := len(manager.active)
	manager.mu.Unlock()
	close(blocked)
	if active != 2 {
		t.Fatalf("非红果任务应可与红果任务并行，实际只启动了 %d 个", active)
	}
}

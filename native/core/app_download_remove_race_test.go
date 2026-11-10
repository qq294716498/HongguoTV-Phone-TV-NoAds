package core

import (
	"context"
	"errors"
	"sync"
	"testing"
	"time"
)

func TestDownloadRemoveWaitsBeforeImmediateReenqueue(t *testing.T) {
	manager := downloadTestManager(t)
	started := make(chan struct{})
	canceled := make(chan struct{})
	release := make(chan struct{})
	var once sync.Once
	unblock := func() { once.Do(func() { close(release) }) }
	t.Cleanup(unblock)
	manager.resolve = func(ctx context.Context, job nativeDownloadJob) (providerMedia, error) {
		close(started)
		<-ctx.Done()
		close(canceled)
		<-release
		return providerMedia{}, ctx.Err()
	}
	input := downloadTestInput(1)
	if n, err := manager.enqueue(input); n != 1 || err != nil {
		t.Fatalf("initial enqueue: %d, %v", n, err)
	}
	<-started
	id := nativeDownloadID(input.Drama.ID, 1)
	removed := make(chan error, 1)
	go func() { removed <- manager.control(id, "remove") }()
	<-canceled
	select {
	case err := <-removed:
		t.Fatalf("remove returned before cleanup: %v", err)
	case <-time.After(30 * time.Millisecond):
	}
	if count, err := manager.enqueue(input); count != 0 || err == nil {
		t.Fatalf("in-progress deletion was silently treated as a duplicate: %d, %v", count, err)
	}
	unblock()
	if err := <-removed; err != nil {
		t.Fatal(err)
	}
	jobs, err := manager.snapshot()
	if err != nil || len(jobs) != 0 {
		t.Fatalf("removed job still counted: %+v, %v", jobs, err)
	}
	manager.resolve = func(context.Context, nativeDownloadJob) (providerMedia, error) {
		return providerMedia{}, errors.New("synthetic retry")
	}
	if count, err := manager.enqueue(input); count != 1 || err != nil {
		t.Fatalf("immediate re-download was lost: %d, %v", count, err)
	}
	waitDownloads(t, manager, func(jobs []nativeDownloadJob) bool {
		return len(jobs) == 1 && jobs[0].State == "failed"
	})
	manager.close()
	reopened := newNativeDownloads(manager.engine)
	t.Cleanup(reopened.close)
	jobs, err = reopened.snapshot()
	if err != nil || len(jobs) != 1 || jobs[0].Index != 1 {
		t.Fatalf("redownload count changed after restart: %+v, %v", jobs, err)
	}
}

func TestDownloadRemoveAndReenqueueMixedQueueCounts(t *testing.T) {
	manager := downloadTestManager(t)
	started := make(chan struct{}, 3)
	manager.resolve = func(ctx context.Context, _ nativeDownloadJob) (providerMedia, error) {
		started <- struct{}{}
		<-ctx.Done()
		return providerMedia{}, ctx.Err()
	}
	input := downloadTestInput(3)
	if count, err := manager.enqueue(input); count != 3 || err != nil {
		t.Fatalf("enqueue mixed queue: %d, %v", count, err)
	}
	<-started
	ids := []string{}
	for index := 1; index <= 3; index++ {
		ids = append(ids, nativeDownloadID(input.Drama.ID, index))
	}
	result, err := manager.controlBatch(ids, "remove")
	if err != nil || len(result.Completed) != 3 || len(result.Failures) != 0 {
		t.Fatalf("mixed queue deletion: %+v, %v", result, err)
	}
	jobs, err := manager.snapshot()
	if err != nil || len(jobs) != 0 {
		t.Fatalf("deleted queue counted old jobs: %+v, %v", jobs, err)
	}
	manager.resolve = func(context.Context, nativeDownloadJob) (providerMedia, error) {
		return providerMedia{}, errors.New("synthetic retry")
	}
	if count, err := manager.enqueue(input); count != 3 || err != nil {
		t.Fatalf("mixed queue redownload: %d, %v", count, err)
	}
	waitDownloads(t, manager, func(jobs []nativeDownloadJob) bool {
		return len(jobs) == 3 && jobs[0].State == "failed" && jobs[1].State == "failed" && jobs[2].State == "failed"
	})
}

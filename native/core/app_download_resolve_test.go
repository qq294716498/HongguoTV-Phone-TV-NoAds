package core

import (
	"bytes"
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

func TestHongguoBatchDownloadsRecoverAfterTwoSuccessfulEpisodes(t *testing.T) {
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.ServeContent(w, r, "episode.mp4", time.Time{}, bytes.NewReader([]byte("synthetic media bytes")))
	}))
	defer upstream.Close()
	manager := downloadTestManager(t)
	var mu sync.Mutex
	calls := map[int]int{}
	var active atomic.Int32
	manager.resolve = func(ctx context.Context, job nativeDownloadJob) (providerMedia, error) {
		if active.Add(1) != 1 {
			t.Error("Hongguo download metadata requests overlapped")
		}
		defer active.Add(-1)
		if download, _ := ctx.Value(hongguoDownloadKey{}).(bool); !download {
			t.Error("download did not select its own route budget")
		}
		mu.Lock()
		calls[job.Index]++
		attempt := calls[job.Index]
		mu.Unlock()
		if job.Index > 2 && attempt == 1 {
			return providerMedia{}, errors.Join(errHongguoEmptyResponse, errors.New("fallback unavailable"))
		}
		return providerMedia{URL: upstream.URL + "/episode.mp4", Quality: 720}, nil
	}
	input := downloadTestInput(4)
	for i := range input.Entries {
		input.Entries[i].Chapter.VideoURL = "hongguo-cenc://9001"
	}
	if _, err := manager.enqueue(input); err != nil {
		t.Fatal(err)
	}
	waitDownloads(t, manager, func(jobs []nativeDownloadJob) bool {
		if len(jobs) != 4 {
			return false
		}
		for _, job := range jobs {
			if job.State != "completed" {
				return false
			}
		}
		return true
	})
	mu.Lock()
	defer mu.Unlock()
	if calls[1] != 1 || calls[2] != 1 || calls[3] != 2 || calls[4] != 2 {
		t.Fatalf("unexpected recovery counts: %v", calls)
	}
}

func TestHongguoDownloadResolveStopsAtBoundAndOnRejection(t *testing.T) {
	for _, scenario := range []struct {
		name string
		err  error
		want int
	}{
		{"empty", errHongguoEmptyResponse, 2},
		{"timeout", context.DeadlineExceeded, 2},
		{"unavailable", errors.New("episode unavailable"), 1},
		{"limited", &requestBackoff{status: 429}, 1},
		{"forbidden", &requestBackoff{status: 403}, 1},
	} {
		t.Run(scenario.name, func(t *testing.T) {
			calls := 0
			manager := &nativeDownloads{resolve: func(context.Context, nativeDownloadJob) (providerMedia, error) {
				calls++
				return providerMedia{}, scenario.err
			}}
			_, err := manager.resolveDownloadMedia(context.Background(), nativeDownloadJob{Drama: nativeDrama{ID: "hongguo:100"}, Chapter: Chapter{VideoURL: "hongguo-cenc://9001"}})
			if !errors.Is(err, scenario.err) || calls != scenario.want {
				t.Fatalf("calls=%d err=%v", calls, err)
			}
		})
	}
}

func TestHongguoDownloadResolveCancellationReleasesWaitingJobs(t *testing.T) {
	entered := make(chan struct{})
	manager := &nativeDownloads{resolve: func(ctx context.Context, _ nativeDownloadJob) (providerMedia, error) {
		close(entered)
		<-ctx.Done()
		return providerMedia{}, ctx.Err()
	}}
	job := nativeDownloadJob{Drama: nativeDrama{ID: "hongguo:100"}, Chapter: Chapter{VideoURL: "hongguo-cenc://9001"}}
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { _, err := manager.resolveDownloadMedia(ctx, job); done <- err }()
	<-entered
	waiting, stop := context.WithCancel(context.Background())
	stop()
	if _, err := manager.resolveDownloadMedia(waiting, job); !errors.Is(err, context.Canceled) {
		t.Fatal(err)
	}
	cancel()
	if err := <-done; !errors.Is(err, context.Canceled) {
		t.Fatal(err)
	}
	if len(manager.hongguoResolveSlot) != 0 {
		t.Fatal("resolution slot leaked")
	}
}

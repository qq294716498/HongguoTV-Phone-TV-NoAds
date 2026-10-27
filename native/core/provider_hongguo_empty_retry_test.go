package core

import (
	"context"
	"crypto/sha256"
	"errors"
	"io"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

const hongguoRetryModelFixture = `{"code":0,"data":{"video_model":{"video_list":[{"main_url":"https://media.example.test/retry.mp4","video_meta":{"codec_type":"h264","definition":"720p"}}]}}}`

type hongguoRetryObservedBody struct {
	io.ReadCloser
	once    sync.Once
	onClose func()
}

func (body *hongguoRetryObservedBody) Close() error {
	err := body.ReadCloser.Close()
	body.once.Do(body.onClose)
	return err
}

func TestHongguoEmptyModelRetriesWithFreshIdentityAndSignature(t *testing.T) {
	type identity struct {
		device, install, ticket string
		body                    [32]byte
		at                      time.Time
	}
	var requests []identity
	d := sourceFixtureDownloader(t, func(request *http.Request) (*http.Response, error) {
		body, err := io.ReadAll(request.Body)
		if err != nil {
			return nil, err
		}
		requests = append(requests, identity{
			device: request.URL.Query().Get("device_id"), install: request.URL.Query().Get("iid"),
			ticket: request.URL.Query().Get("_rticket"), body: sha256.Sum256(body), at: time.Now(),
		})
		for _, header := range []string{"X-Gorgon", "X-Khronos", "X-Ladon", "X-Argus", "X-Helios", "X-Medusa"} {
			if request.Header.Get(header) == "" {
				t.Errorf("model request lost signature header %s", header)
			}
		}
		if len(requests) == 1 {
			return sourceFixtureResponse(request, http.StatusOK, ""), nil
		}
		return sourceFixtureResponse(request, http.StatusOK, hongguoRetryModelFixture), nil
	})
	d.cfg.Retries = 2
	media, err := d.resolveHongguoAppMedia(context.Background(), "9001", 1004)
	if err != nil || media.URL != "https://media.example.test/retry.mp4" || len(requests) != 2 {
		t.Fatalf("empty response did not recover once: requests=%d error=%v", len(requests), err)
	}
	first, second := requests[0], requests[1]
	if first.device == "" || first.install == "" || first.device == second.device || first.install == second.install || first.body != second.body {
		t.Fatal("empty response retry must rotate temporary identity without changing the episode")
	}
	if first.ticket == second.ticket || second.at.Sub(first.at) < hongguoEmptyResponseRetryDelay {
		t.Fatal("each playback retry must refresh its signature while retaining backoff")
	}
}

func TestHongguoContinuousEmptyModelRespectsAttemptCap(t *testing.T) {
	for _, scenario := range []struct {
		retries, expected int
	}{{1, 4}, {2, 4}, {3, 4}, {99, 4}} {
		t.Run("retries-"+strconv.Itoa(scenario.retries), func(t *testing.T) {
			calls := 0
			d := sourceFixtureDownloader(t, func(request *http.Request) (*http.Response, error) {
				calls++
				return sourceFixtureResponse(request, http.StatusOK, ""), nil
			})
			d.cfg.Retries = scenario.retries
			_, err := d.resolveHongguoAppMedia(context.Background(), "9001", 1004)
			if err == nil || calls != scenario.expected || !strings.Contains(err.Error(), "0 字节") {
				t.Fatalf("empty model exceeded configured/capped attempts: calls=%d expected=%d error=%v", calls, scenario.expected, err)
			}
		})
	}
}

func TestHongguoOnlyEmptyModelUsesSoftRetry(t *testing.T) {
	for _, scenario := range []struct {
		name, path, body, retryAfter, mitigation string
		status                                   int
	}{
		{name: "whitespace", body: " \n\t", status: 200},
		{name: "html", body: "<html>temporarily unavailable</html>", status: 200},
		{name: "business-error", body: `{"code":1001}`, status: 200},
		{name: "forbidden", status: 403},
		{name: "rate-limit", status: 429, retryAfter: "120"},
		{name: "empty-with-retry-after", status: 200, retryAfter: "120"},
		{name: "challenge", status: 200, mitigation: "challenge"},
	} {
		t.Run(scenario.name, func(t *testing.T) {
			calls := 0
			d := sourceFixtureDownloader(t, func(request *http.Request) (*http.Response, error) {
				calls++
				response := sourceFixtureResponse(request, scenario.status, scenario.body)
				if scenario.retryAfter != "" {
					response.Header.Set("Retry-After", scenario.retryAfter)
				}
				if scenario.mitigation != "" {
					response.Header.Set("Cf-Mitigated", scenario.mitigation)
				}
				return response, nil
			})
			d.cfg.Retries = 3
			path := scenario.path
			if path == "" {
				path = "/novel/player/video_model/v1/"
			}
			_, err := d.hongguoAppRequest(context.Background(), http.MethodPost, path, nil, map[string]any{"video_id": "9001"})
			if err == nil || calls != 1 {
				t.Fatalf("non-empty/transient-blocked response was soft-retried: calls=%d error=%v", calls, err)
			}
			if scenario.status == 429 || scenario.mitigation != "" {
				var blocked *requestBackoff
				if !errors.As(err, &blocked) {
					t.Fatalf("server restriction lost its classification: %v", err)
				}
			}
		})
	}
}

func TestHongguoCancelDuringEmptyRetryDelayStopsNextHTTP(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	calls := 0
	d := sourceFixtureDownloader(t, func(request *http.Request) (*http.Response, error) {
		calls++
		if calls == 1 {
			time.AfterFunc(20*time.Millisecond, cancel)
		}
		return sourceFixtureResponse(request, http.StatusOK, ""), nil
	})
	d.cfg.Retries = 2
	_, err := d.resolveHongguoAppMedia(ctx, "9001", 1004)
	if !errors.Is(err, context.Canceled) || calls != 1 {
		t.Fatalf("canceled empty retry issued another HTTP: calls=%d error=%v", calls, err)
	}
}

func TestHongguoEmptyRetryHonorsForegroundAndPreloadDeadlines(t *testing.T) {
	for _, background := range []bool{false, true} {
		t.Run(map[bool]string{false: "foreground", true: "preload"}[background], func(t *testing.T) {
			ctx, cancel := context.WithTimeout(context.WithValue(context.Background(), backgroundCatalogKey{}, background), 40*time.Millisecond)
			defer cancel()
			calls := 0
			d := sourceFixtureDownloader(t, func(request *http.Request) (*http.Response, error) {
				calls++
				return sourceFixtureResponse(request, http.StatusOK, ""), nil
			})
			d.cfg.Retries = 2
			_, err := d.resolveHongguoAppMedia(ctx, "9001", 1004)
			if !errors.Is(err, context.DeadlineExceeded) || calls != 1 {
				t.Fatalf("empty retry outlived its caller budget: calls=%d error=%v", calls, err)
			}
		})
	}
}

func TestHongguoEmptyThen429KeepsHostCooldown(t *testing.T) {
	calls := 0
	d := sourceFixtureDownloader(t, func(request *http.Request) (*http.Response, error) {
		calls++
		if calls == 1 {
			return sourceFixtureResponse(request, http.StatusOK, ""), nil
		}
		response := sourceFixtureResponse(request, http.StatusTooManyRequests, "")
		response.Header.Set("Retry-After", "120")
		return response, nil
	})
	d.cfg.Retries = 3
	_, err := d.resolveHongguoAppMedia(context.Background(), "9001", 1004)
	var blocked *requestBackoff
	if !errors.As(err, &blocked) || blocked.status != 429 || time.Until(blocked.until) < 119*time.Second || calls != 2 {
		t.Fatalf("empty retry bypassed or lost rate limiting: calls=%d error=%v", calls, err)
	}
	_, err = d.resolveHongguoAppMedia(context.Background(), "9001", 1004)
	if !errors.As(err, &blocked) || calls != 2 {
		t.Fatalf("manual retry bypassed the retained host cooldown: calls=%d error=%v", calls, err)
	}
}

func TestHongguoForegroundCanUseGateDuringPreloadEmptyBackoff(t *testing.T) {
	background, stopBackground := context.WithTimeout(context.WithValue(context.Background(), backgroundCatalogKey{}, true), 2*time.Second)
	defer stopBackground()
	foreground, stopForeground := context.WithTimeout(context.Background(), 2*time.Second)
	defer stopForeground()
	entered, release := make(chan struct{}), make(chan struct{})
	var releaseOnce sync.Once
	unblock := func() { releaseOnce.Do(func() { close(release) }) }
	defer unblock()
	var calls, live, peak atomic.Int32
	var mu sync.Mutex
	var order []string
	d := sourceFixtureDownloader(t, func(request *http.Request) (*http.Response, error) {
		number := calls.Add(1)
		active := live.Add(1)
		for previous := peak.Load(); active > previous; previous = peak.Load() {
			if peak.CompareAndSwap(previous, active) {
				break
			}
		}
		isBackground, _ := request.Context().Value(backgroundCatalogKey{}).(bool)
		name := "foreground"
		if isBackground {
			name = "preload"
		}
		mu.Lock()
		order = append(order, name)
		mu.Unlock()
		body := hongguoRetryModelFixture
		if number == 1 {
			close(entered)
			select {
			case <-release:
			case <-request.Context().Done():
			}
			body = ""
		}
		response := sourceFixtureResponse(request, http.StatusOK, body)
		response.Body = &hongguoRetryObservedBody{ReadCloser: response.Body, onClose: func() { live.Add(-1) }}
		return response, nil
	})
	d.cfg.Retries = 2
	backgroundResult := make(chan error, 1)
	go func() {
		_, err := d.resolveHongguoAppMedia(background, "9001", 1004)
		backgroundResult <- err
	}()
	select {
	case <-entered:
	case err := <-backgroundResult:
		t.Fatalf("preload ended before acquiring its request gate: %v", err)
	case <-background.Done():
		t.Fatal("preload did not enter the fixture before its deadline")
	}
	foregroundResult := make(chan error, 1)
	go func() {
		_, err := d.resolveHongguoAppMedia(foreground, "9001", 1004)
		foregroundResult <- err
	}()
	waitUntil := time.Now().Add(time.Second)
	for {
		d.limiter.mu.Lock()
		waiting := d.limiter.foregroundWaiting
		d.limiter.mu.Unlock()
		if waiting > 0 {
			break
		}
		if time.Now().After(waitUntil) {
			t.Fatal("foreground request did not queue behind the preload")
		}
		time.Sleep(time.Millisecond)
	}
	unblock()
	select {
	case err := <-foregroundResult:
		if err != nil {
			t.Fatalf("foreground could not acquire the released preload gate: %v", err)
		}
	case <-foreground.Done():
		t.Fatal("foreground result did not settle before its deadline")
	}
	select {
	case err := <-backgroundResult:
		if err != nil {
			t.Fatalf("preload could not complete its bounded retry: %v", err)
		}
	case <-background.Done():
		t.Fatal("preload result did not settle before its deadline")
	}
	mu.Lock()
	got := strings.Join(order, ",")
	mu.Unlock()
	if got != "preload,foreground,preload" || peak.Load() != 1 || live.Load() != 0 || calls.Load() != 3 {
		t.Fatalf("shared gate was held during retry or allowed overlapping HTTP: order=%s peak=%d live=%d calls=%d", got, peak.Load(), live.Load(), calls.Load())
	}
}

func TestHongguoLateModelResponseAfterCancellationCannotSucceed(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	entered, release := make(chan struct{}), make(chan struct{})
	var releaseOnce sync.Once
	unblock := func() { releaseOnce.Do(func() { close(release) }) }
	defer unblock()
	calls := 0
	d := sourceFixtureDownloader(t, func(request *http.Request) (*http.Response, error) {
		calls++
		close(entered)
		<-release
		return sourceFixtureResponse(request, http.StatusOK, hongguoRetryModelFixture), nil
	})
	d.cfg.Retries = 2
	result := make(chan error, 1)
	go func() {
		_, err := d.resolveHongguoAppMedia(ctx, "9001", 1004)
		result <- err
	}()
	select {
	case <-entered:
	case err := <-result:
		t.Fatalf("model ended before the late-response fixture: %v", err)
	case <-ctx.Done():
		t.Fatal("model did not enter the late-response fixture before its deadline")
	}
	cancel()
	unblock()
	select {
	case err := <-result:
		if !errors.Is(err, context.Canceled) || calls != 1 {
			t.Fatalf("late model response resurrected canceled work: calls=%d error=%v", calls, err)
		}
	case <-time.After(time.Second):
		t.Fatal("late-response result did not settle after cancellation")
	}
}

func TestHongguoPlaybackRecoversAfterThreeEmptyResponses(t *testing.T) {
	calls := 0
	var tickets []string
	var deviceID, installID string
	d := sourceFixtureDownloader(t, func(request *http.Request) (*http.Response, error) {
		calls++
		ticket := request.URL.Query().Get("_rticket")
		if ticket == "" || request.Header.Get("X-Medusa") == "" {
			t.Error("retry lost its signature")
		}
		tickets = append(tickets, ticket)
		device, install := request.URL.Query().Get("device_id"), request.URL.Query().Get("iid")
		if device == "" || install == "" || device == deviceID || install == installID {
			t.Error("playback retry reused a temporary identity")
		}
		deviceID, installID = device, install
		if calls < 4 {
			return sourceFixtureResponse(request, 200, " \n"), nil
		}
		return sourceFixtureResponse(request, 200, hongguoRetryModelFixture), nil
	})
	media, err := d.resolveHongguoAppMedia(context.Background(), "9001")
	if err != nil || media.URL == "" || calls != 4 {
		t.Fatalf("fourth signed attempt failed: calls=%d error=%v", calls, err)
	}
	if tickets[0] == tickets[1] || tickets[1] == tickets[2] || tickets[2] == tickets[3] {
		t.Fatal("each playback request must have a fresh signature")
	}
}

func TestHongguoReadOnlyEndpointsRecoverEmptyResponse(t *testing.T) {
	for _, path := range []string{hongguoSearchAppPath, "/novel/player/video_detail/v1/", "/reading/distribution/category/landpage/v/"} {
		t.Run(path, func(t *testing.T) {
			calls := 0
			d := sourceFixtureDownloader(t, func(r *http.Request) (*http.Response, error) {
				calls++
				if calls == 1 {
					return sourceFixtureResponse(r, 200, ""), nil
				}
				return sourceFixtureResponse(r, 200, `{"code":0}`), nil
			})
			_, err := d.hongguoAppRequest(context.Background(), http.MethodPost, path, nil, map[string]any{})
			if err != nil || calls != 2 {
				t.Fatalf("read-only empty response did not recover: calls=%d error=%v", calls, err)
			}
		})
	}
}

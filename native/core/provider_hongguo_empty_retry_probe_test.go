package core

import (
	"bytes"
	"context"
	"errors"
	"io"
	"net/http"
	"net/url"
	"os"
	"strings"
	"sync"
	"testing"
	"time"
)

type hongguoBoundedProbeTransport struct {
	mu       sync.Mutex
	base     http.RoundTripper
	test     *testing.T
	host     string
	calls    int
	stopped  bool
	lastCall time.Time
}

func (probe *hongguoBoundedProbeTransport) RoundTrip(request *http.Request) (*http.Response, error) {
	probe.mu.Lock()
	defer probe.mu.Unlock()
	if probe.stopped || probe.calls >= 3 {
		return nil, errors.New("bounded model diagnostic request limit reached")
	}
	if request.Method != http.MethodPost || request.URL.Scheme != "https" || !strings.EqualFold(request.URL.Host, probe.host) || request.URL.Path != "/novel/player/video_model/v1/" {
		probe.stopped = true
		return nil, errors.New("bounded model diagnostic rejected an out-of-scope request")
	}
	if delay := time.Until(probe.lastCall.Add(hongguoEmptyResponseRetryDelay)); delay > 0 {
		select {
		case <-time.After(delay):
		case <-request.Context().Done():
			return nil, request.Context().Err()
		}
	}
	if err := request.Context().Err(); err != nil {
		return nil, err
	}
	probe.calls++
	probe.lastCall = time.Now()
	response, err := probe.base.RoundTrip(request)
	if err != nil {
		probe.test.Logf("model diagnostic request=%d path=%s transportFailed=true elapsedMs=%d", probe.calls, request.URL.Path, time.Since(probe.lastCall).Milliseconds())
		return nil, errors.New("bounded model diagnostic transport failed")
	}
	body, readErr := io.ReadAll(io.LimitReader(response.Body, providerMaxBodyBytes+1))
	response.Body.Close()
	probe.test.Logf("model diagnostic request=%d path=%s status=%d bodyBytes=%d elapsedMs=%d", probe.calls, request.URL.Path, response.StatusCode, len(body), time.Since(probe.lastCall).Milliseconds())
	if response.StatusCode == http.StatusForbidden || response.StatusCode == http.StatusTooManyRequests || response.Header.Get("Retry-After") != "" || strings.EqualFold(response.Header.Get("Cf-Mitigated"), "challenge") {
		probe.stopped = true
	}
	if readErr != nil || len(body) > providerMaxBodyBytes {
		return nil, errors.New("bounded model diagnostic response could not be read")
	}
	response.Body = io.NopCloser(bytes.NewReader(body))
	return response, nil
}

func TestLiveHongguoEmptyResponseBoundedRetry(t *testing.T) {
	if os.Getenv("HONGGUO_EMPTY_MODEL_PROBE") != "1" {
		t.Skip("set HONGGUO_EMPTY_MODEL_PROBE=1 for one bounded model-only diagnostic")
	}
	endpoint, err := url.Parse(hongguoAppBaseURL)
	if err != nil {
		t.Fatal("invalid configured model diagnostic origin")
	}
	transport := http.DefaultTransport.(*http.Transport).Clone()
	defer transport.CloseIdleConnections()
	probe := &hongguoBoundedProbeTransport{base: transport, test: t, host: endpoint.Host}
	d := &Downloader{
		cfg: Config{Retries: 1}, client: &http.Client{Transport: probe, Timeout: 15 * time.Second,
			CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }},
		limiter: newRequestLimiter(1, hongguoEmptyResponseRetryDelay), providerHosts: map[string]string{},
	}
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	for _, retries := range []int{1, 2} {
		probe.mu.Lock()
		stop := probe.stopped || probe.calls >= 3
		probe.mu.Unlock()
		if stop || ctx.Err() != nil {
			break
		}
		d.cfg.Retries = retries
		media, err := d.resolveHongguoAppMedia(ctx, "7695722622981508121", 1004)
		t.Logf("model diagnostic retries=%d modelSuccess=%t failed=%t", retries, err == nil && media.URL != "", err != nil)
		var blocked *requestBackoff
		if errors.As(err, &blocked) {
			break
		}
	}
	probe.mu.Lock()
	calls := probe.calls
	probe.mu.Unlock()
	if calls > 3 {
		t.Fatalf("model diagnostic exceeded its request bound: %d", calls)
	}
	t.Logf("model-only diagnostic finished requests=%d; this test does not establish real-episode playback acceptance", calls)
}

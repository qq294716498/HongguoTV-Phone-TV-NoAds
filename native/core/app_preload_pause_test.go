package core

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

func setTestPreloadPaused(t *testing.T, engine *nativeEngine, plan nativePlan, paused bool) nativePlan {
	t.Helper()
	input := downloadTestInput(1)
	input.Action, input.PlaybackSession, input.Paused = "setPreloadPaused", plan.Session, &paused
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	result, err := engine.nativeSetPreloadPaused(ctx, input)
	if err != nil {
		t.Fatal(err)
	}
	return result
}

func TestPreloadPausePreservesPartialAndResumesSameSession(t *testing.T) {
	data := append([]byte("\x00\x00\x00\x18ftypisom\x00\x00\x02\x00isomiso2"), bytes.Repeat([]byte("pause-resume-media"), 150000)...)
	var requests atomic.Int32
	var resumed atomic.Int64
	var active atomic.Int32
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/next.mp4" {
			http.ServeContent(w, r, "current.mp4", time.Time{}, bytes.NewReader([]byte("current-unaffected")))
			return
		}
		active.Add(1)
		defer active.Add(-1)
		if r.Header.Get("Referer") != "https://example.test/episode" {
			t.Error("preload lost its request headers")
		}
		w.Header().Set("Content-Type", "video/mp4")
		w.Header().Set("ETag", `"pause-stable"`)
		if requests.Add(1) == 1 {
			w.Header().Set("Content-Length", fmt.Sprint(len(data)))
			_, _ = w.Write(data[:512<<10])
			w.(http.Flusher).Flush()
			<-r.Context().Done()
			return
		}
		var offset int64
		if _, err := fmt.Sscanf(r.Header.Get("Range"), "bytes=%d-", &offset); err == nil && r.Header.Get("If-Range") == `"pause-stable"` {
			resumed.Store(offset)
		}
		http.ServeContent(w, r, "next.mp4", time.Time{}, bytes.NewReader(data))
	}))
	defer upstream.Close()
	engine, plan, directory := startTestEpisodeCache(t, providerMedia{URL: upstream.URL + "/next.mp4", Referer: "https://example.test/episode"})
	defer engine.nativeReleasePlayback(plan.Session)
	waitTestEpisodeCache(t, engine, plan, func(p nativePlan) bool { return p.PrefetchedBytes >= 512<<10 })
	paused := setTestPreloadPaused(t, engine, plan, true)
	partial := filepath.Join(directory, "media.mp4.part")
	prefix, err := os.ReadFile(partial)
	if err != nil || len(prefix) == 0 || len(prefix) >= len(data) || paused.PreloadState != "paused" || paused.PreloadError != "" {
		t.Fatalf("pause discarded data or reported a failure: %+v, bytes=%d, error=%v", paused, len(prefix), err)
	}
	deadline := time.Now().Add(time.Second)
	for active.Load() != 0 && time.Now().Before(deadline) {
		time.Sleep(time.Millisecond)
	}
	if active.Load() != 0 {
		t.Fatal("pause did not cancel the upstream request")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 80*time.Millisecond)
	request, _ := http.NewRequestWithContext(ctx, http.MethodGet, plan.URL, nil)
	response, err := http.DefaultClient.Do(request)
	if response != nil {
		response.Body.Close()
	}
	cancel()
	if err == nil || requests.Load() != 1 {
		t.Fatal("paused local preparation reached the media origin")
	}
	current, err := engine.nativeOpenPlayback(context.Background(), nativePlaybackChoices(providerMedia{URL: upstream.URL + "/current.mp4"}, 0))
	if err != nil {
		t.Fatal(err)
	}
	defer engine.nativeReleasePlayback(current.Session)
	response, err = http.Get(current.URL)
	if err != nil {
		t.Fatal(err)
	}
	currentBytes, err := io.ReadAll(response.Body)
	response.Body.Close()
	if err != nil || string(currentBytes) != "current-unaffected" {
		t.Fatal("next pause blocked the unrelated current playback")
	}
	still, err := os.ReadFile(partial)
	if err != nil || !bytes.Equal(still, prefix) {
		t.Fatal("paused cache changed or disappeared")
	}
	setTestPreloadPaused(t, engine, plan, false)
	complete := waitTestEpisodeCache(t, engine, plan, func(p nativePlan) bool { return p.PreloadComplete })
	if resumed.Load() != int64(len(prefix)) || complete.Session != plan.Session || complete.PrefetchedBytes != int64(len(data)) || requests.Load() != 2 {
		t.Fatalf("resume restarted instead of Range continuing: offset=%d prefix=%d requests=%d plan=%+v", resumed.Load(), len(prefix), requests.Load(), complete)
	}
	upstream.Close()
	response, err = http.Get(plan.URL)
	if err != nil {
		t.Fatal(err)
	}
	body, err := io.ReadAll(response.Body)
	response.Body.Close()
	if err != nil || !bytes.Equal(body, data) {
		t.Fatal("resumed verified bytes differ")
	}
}

func TestPreloadPauseHLSKeepsCompletedResourcesAndSegmentValidator(t *testing.T) {
	segment := bytes.Repeat([]byte("hls-segment"), 50000)
	var mu sync.Mutex
	requests := map[string]int{}
	var rangeOffset atomic.Int64
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		requests[r.URL.Path]++
		count := requests[r.URL.Path]
		mu.Unlock()
		switch r.URL.Path {
		case "/index.m3u8":
			_, _ = io.WriteString(w, "#EXTM3U\n#EXT-X-TARGETDURATION:10\n#EXT-X-KEY:METHOD=AES-128,URI=\"key\"\n#EXTINF:10,\none.ts\n#EXTINF:10,\ntwo.ts\n#EXT-X-ENDLIST\n")
		case "/key":
			_, _ = io.WriteString(w, "0123456789abcdef")
		case "/one.ts":
			_, _ = io.WriteString(w, "complete-first-segment")
		case "/two.ts":
			w.Header().Set("ETag", `"hls-stable"`)
			if count == 1 {
				w.Header().Set("Content-Length", fmt.Sprint(len(segment)))
				_, _ = w.Write(segment[:65536])
				w.(http.Flusher).Flush()
				<-r.Context().Done()
				return
			}
			var offset int64
			if _, err := fmt.Sscanf(r.Header.Get("Range"), "bytes=%d-", &offset); err == nil && r.Header.Get("If-Range") == `"hls-stable"` {
				rangeOffset.Store(offset)
			}
			http.ServeContent(w, r, "two.ts", time.Time{}, bytes.NewReader(segment))
		}
	}))
	defer upstream.Close()
	engine, plan, directory := startTestEpisodeCache(t, providerMedia{URL: upstream.URL + "/index.m3u8"})
	defer engine.nativeReleasePlayback(plan.Session)
	waitTestEpisodeCache(t, engine, plan, func(p nativePlan) bool { return p.PrefetchedBytes >= 65536+16+int64(len("complete-first-segment")) })
	setTestPreloadPaused(t, engine, plan, true)
	completed := filepath.Join(directory, nativeDownloadAssetName(upstream.URL+"/one.ts", ".ts"))
	before, err := os.ReadFile(completed)
	if err != nil || string(before) != "complete-first-segment" {
		t.Fatal("HLS pause discarded a completed segment")
	}
	setTestPreloadPaused(t, engine, plan, false)
	waitTestEpisodeCache(t, engine, plan, func(p nativePlan) bool { return p.PreloadComplete })
	mu.Lock()
	keyRequests, firstRequests := requests["/key"], requests["/one.ts"]
	mu.Unlock()
	if keyRequests != 1 || firstRequests != 1 || rangeOffset.Load() != 65536 {
		t.Fatalf("HLS resume fetched completed resources or lost Range validator: key=%d first=%d offset=%d", keyRequests, firstRequests, rangeOffset.Load())
	}
	last := filepath.Join(directory, nativeDownloadAssetName(upstream.URL+"/two.ts", ".ts"))
	data, err := os.ReadFile(last)
	if err != nil || !bytes.Equal(data, segment) {
		t.Fatal("HLS resumed segment changed")
	}
}

func TestPreloadPauseReleaseWakesLocalReadersAndDeletesCache(t *testing.T) {
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("ETag", `"release-paused"`)
		w.Header().Set("Content-Length", "1048576")
		_, _ = w.Write(bytes.Repeat([]byte("x"), 65536))
		w.(http.Flusher).Flush()
		<-r.Context().Done()
	}))
	defer upstream.Close()
	engine, plan, directory := startTestEpisodeCache(t, providerMedia{URL: upstream.URL + "/next.mp4"})
	defer engine.nativeReleasePlayback(plan.Session)
	waitTestEpisodeCache(t, engine, plan, func(p nativePlan) bool { return p.PrefetchedBytes >= 65536 })
	setTestPreloadPaused(t, engine, plan, true)
	result := make(chan error, 1)
	go func() {
		ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
		defer cancel()
		request, _ := http.NewRequestWithContext(ctx, http.MethodGet, plan.URL, nil)
		response, err := http.DefaultClient.Do(request)
		if response != nil {
			response.Body.Close()
			if response.StatusCode != http.StatusGone {
				err = fmt.Errorf("released reader status=%d", response.StatusCode)
			}
		}
		result <- err
	}()
	engine.nativeReleasePlayback(plan.Session)
	select {
	case err := <-result:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("released paused reader did not wake")
	}
	deadline := time.Now().Add(time.Second)
	for time.Now().Before(deadline) {
		if _, err := os.Stat(directory); os.IsNotExist(err) {
			return
		}
		time.Sleep(time.Millisecond)
	}
	t.Fatal("released paused directory was retained")
}

func TestPreloadPauseGateBeforeWorkAndRetryWait(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	cache := &nativeEpisodeCache{session: &nativeStreamSession{ctx: ctx}, paused: true}
	started := make(chan error, 1)
	go func() {
		work, finish, err := cache.beginWork(ctx, true)
		if err == nil {
			if work.Err() != nil {
				err = work.Err()
			}
			finish()
		}
		started <- err
	}()
	select {
	case <-started:
		t.Fatal("work crossed the initial pause gate")
	case <-time.After(40 * time.Millisecond):
	}
	if err := cache.setPaused(ctx, false); err != nil {
		t.Fatal(err)
	}
	if err := <-started; err != nil {
		t.Fatal(err)
	}
	if err := cache.setPaused(ctx, true); err != nil {
		t.Fatal(err)
	}
	finished := make(chan bool, 1)
	go func() { finished <- cache.waitRetry(ctx, 80*time.Millisecond) }()
	select {
	case <-finished:
		t.Fatal("retry backoff expired while paused")
	case <-time.After(100 * time.Millisecond):
	}
	if err := cache.setPaused(ctx, false); err != nil {
		t.Fatal(err)
	}
	select {
	case <-finished:
		t.Fatal("paused wall time consumed retry backoff")
	case <-time.After(20 * time.Millisecond):
	}
	select {
	case ok := <-finished:
		if !ok {
			t.Fatal("resumed retry backoff did not complete")
		}
	case <-time.After(time.Second):
		t.Fatal("retry backoff did not resume")
	}
}

func TestPreloadPauseRejectsForeignExpiredAndCanceledControls(t *testing.T) {
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = io.WriteString(w, "complete-media")
	}))
	defer upstream.Close()
	engine, plan, _ := startTestEpisodeCache(t, providerMedia{URL: upstream.URL + "/next.mp4"})
	defer engine.nativeReleasePlayback(plan.Session)
	waitTestEpisodeCache(t, engine, plan, func(p nativePlan) bool { return p.PreloadComplete })
	paused := true
	valid := downloadTestInput(1)
	valid.Action, valid.PlaybackSession, valid.Paused = "setPreloadPaused", plan.Session, &paused
	for _, change := range []func(*nativeInput){
		func(input *nativeInput) { input.Paused = nil },
		func(input *nativeInput) { input.PlaybackSession = "" },
		func(input *nativeInput) { input.PlaybackSession = "missing" },
		func(input *nativeInput) { input.Drama.ID = "hongguo:foreign" },
		func(input *nativeInput) { input.Drama.Source = "huangdou" },
	} {
		input := valid
		change(&input)
		if _, err := engine.nativeSetPreloadPaused(context.Background(), input); err == nil {
			t.Fatal("foreign or incomplete control was accepted")
		}
	}
	valid.Drama.Source = ""
	if _, err := engine.nativeSetPreloadPaused(context.Background(), valid); err != nil {
		t.Fatal("same authorized ID with omitted source was rejected", err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	resume := false
	valid.Paused = &resume
	if _, err := engine.nativeSetPreloadPaused(ctx, valid); !errors.Is(err, context.Canceled) {
		t.Fatal("canceled control mutated the session")
	}
	cache := engine.stream.sessions[engine.playbacks[plan.Session].streamSession].preload
	cache.mu.Lock()
	stillPaused := cache.paused
	cache.mu.Unlock()
	if !stillPaused {
		t.Fatal("canceled control resumed the producer")
	}
	engine.nativeReleasePlayback(plan.Session)
	if _, err := engine.nativeSetPreloadPaused(context.Background(), valid); err == nil {
		t.Fatal("released control was accepted")
	}
	for _, source := range []string{"hongguo", "huangdou", "unknown"} {
		input := nativeInput{Action: "setPreloadPaused", Drama: nativeDrama{ID: source + ":1", Source: source}, Paused: &paused}
		if allowed := nativeSourceAvailable(source); (nativeAuthorizeInput(input) == nil) != allowed {
			t.Fatalf("preload controls bypassed source authorization for %s", source)
		}
	}
}

func TestPreloadPauseConcurrentControlsKeepOneProducer(t *testing.T) {
	data := bytes.Repeat([]byte("concurrent-pause"), 40000)
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("ETag", `"concurrent"`)
		start := int64(0)
		if value := r.Header.Get("Range"); value != "" {
			_, _ = fmt.Sscanf(value, "bytes=%d-", &start)
			w.Header().Set("Content-Range", fmt.Sprintf("bytes %d-%d/%d", start, len(data)-1, len(data)))
			w.Header().Set("Content-Length", fmt.Sprint(int64(len(data))-start))
			w.WriteHeader(http.StatusPartialContent)
		} else {
			w.Header().Set("Content-Length", fmt.Sprint(len(data)))
		}
		for offset := start; offset < int64(len(data)); offset += 4096 {
			end := min(offset+4096, int64(len(data)))
			if _, err := w.Write(data[offset:end]); err != nil {
				return
			}
			w.(http.Flusher).Flush()
			select {
			case <-r.Context().Done():
				return
			case <-time.After(time.Millisecond):
			}
		}
	}))
	defer upstream.Close()
	engine, plan, directory := startTestEpisodeCache(t, providerMedia{URL: upstream.URL + "/next.mp4"})
	defer engine.nativeReleasePlayback(plan.Session)
	waitTestEpisodeCache(t, engine, plan, func(p nativePlan) bool { return p.PrefetchedBytes > 0 })
	var wg sync.WaitGroup
	errorsOut := make(chan error, 16)
	for index := 0; index < 16; index++ {
		wg.Add(1)
		go func(paused bool) {
			defer wg.Done()
			input := downloadTestInput(1)
			input.PlaybackSession, input.Paused = plan.Session, &paused
			ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
			defer cancel()
			_, err := engine.nativeSetPreloadPaused(ctx, input)
			errorsOut <- err
		}(index%2 == 0)
	}
	wg.Wait()
	close(errorsOut)
	for err := range errorsOut {
		if err != nil {
			t.Fatal(err)
		}
	}
	setTestPreloadPaused(t, engine, plan, true)
	cache := engine.stream.sessions[engine.playbacks[plan.Session].streamSession].preload
	cache.mu.Lock()
	active := 0
	for _, work := range cache.works {
		if work.wait {
			active++
		}
	}
	cache.mu.Unlock()
	if active != 0 {
		t.Fatal("paused producer still active")
	}
	setTestPreloadPaused(t, engine, plan, false)
	waitTestEpisodeCache(t, engine, plan, func(p nativePlan) bool { return p.PreloadComplete })
	final, err := os.ReadFile(filepath.Join(directory, "media.mp4"))
	if err != nil || !bytes.Equal(final, data) {
		t.Fatal("concurrent pause/resume corrupted the file")
	}
}

func TestPreloadPauseCancelsActiveProxyRemainder(t *testing.T) {
	data := append([]byte("\x00\x00\x00\x18ftypisom\x00\x00\x02\x00isomiso2"), bytes.Repeat([]byte("m"), 2<<20)...)
	var requests atomic.Int32
	var active atomic.Int32
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		requests.Add(1)
		active.Add(1)
		defer active.Add(-1)
		w.Header().Set("ETag", `"proxy-stable"`)
		w.Header().Set("Content-Type", "video/mp4")
		start := int64(0)
		if r.Header.Get("Range") != "" {
			_, _ = fmt.Sscanf(r.Header.Get("Range"), "bytes=%d-", &start)
			w.Header().Set("Content-Range", fmt.Sprintf("bytes %d-%d/%d", start, len(data)-1, len(data)))
			w.Header().Set("Content-Length", fmt.Sprint(int64(len(data))-start))
			w.WriteHeader(http.StatusPartialContent)
		} else {
			w.Header().Set("Content-Length", fmt.Sprint(len(data)))
		}
		if start == 0 {
			_, _ = w.Write(data[:512<<10])
		}
		w.(http.Flusher).Flush()
		<-r.Context().Done()
	}))
	defer upstream.Close()
	engine, plan, _ := startTestEpisodeCache(t, providerMedia{URL: upstream.URL + "/next.mp4"})
	defer engine.nativeReleasePlayback(plan.Session)
	waitTestEpisodeCache(t, engine, plan, func(p nativePlan) bool { return p.PrefetchedBytes >= 512<<10 })
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	request, _ := http.NewRequestWithContext(ctx, http.MethodGet, plan.URL, nil)
	response, err := http.DefaultClient.Do(request)
	if err != nil {
		t.Fatal(err)
	}
	defer response.Body.Close()
	prefix := make([]byte, 65536)
	if _, err := io.ReadFull(response.Body, prefix); err != nil {
		t.Fatal("proxy prefix did not arrive", err)
	}
	deadline := time.Now().Add(time.Second)
	for requests.Load() < 2 && time.Now().Before(deadline) {
		time.Sleep(time.Millisecond)
	}
	if requests.Load() != 2 {
		t.Fatal("proxy remainder fixture did not start")
	}
	setTestPreloadPaused(t, engine, plan, true)
	deadline = time.Now().Add(time.Second)
	for active.Load() != 0 && time.Now().Before(deadline) {
		time.Sleep(time.Millisecond)
	}
	if active.Load() != 0 {
		t.Fatal("pause left a proxy media request active")
	}
	_, _ = io.Copy(io.Discard, response.Body)
	if status, err := engine.nativePreloadStatus(plan.Session); err != nil || status.PreloadState != "paused" || status.PreloadComplete {
		t.Fatalf("proxy pause ended the cache session: %+v %v", status, err)
	}
}

func TestPreloadPauseReleaseWakesBeforeStartedWork(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	cache := &nativeEpisodeCache{session: &nativeStreamSession{ctx: ctx}, paused: true}
	finished := make(chan error, 1)
	go func() {
		_, finish, err := cache.beginWork(context.Background(), true)
		if finish != nil {
			finish()
		}
		finished <- err
	}()
	cancel()
	select {
	case err := <-finished:
		if !errors.Is(err, context.Canceled) {
			t.Fatal("released wait returned wrong error", err)
		}
	case <-time.After(time.Second):
		t.Fatal("session release left a paused startup worker blocked")
	}
}

func TestPreloadPauseCancelsAndResumesCENCStartupWorker(t *testing.T) {
	var active atomic.Int32
	var ranges atomic.Int32
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		active.Add(1)
		defer active.Add(-1)
		if r.Header.Get("Range") != "" {
			ranges.Add(1)
		}
		<-r.Context().Done()
	}))
	defer upstream.Close()
	engine, plan, directory := startTestEpisodeCache(t, providerMedia{URL: upstream.URL + "/encrypted.mp4", CENCKey: []byte("0123456789abcdef")})
	defer engine.nativeReleasePlayback(plan.Session)
	cache := engine.stream.sessions[engine.playbacks[plan.Session].streamSession].preload
	cache.publishStartup(nativeStreamAsset{
		address: upstream.URL + "/encrypted.mp4", data: []byte("\x00\x00\x00\x18ftypisom\x00\x00\x02\x00isomiso2"),
		total: 1 << 20, contentType: "video/mp4", etag: `"cenc-paused"`,
	}, false, false)
	waitRange := func(count int32) {
		t.Helper()
		deadline := time.Now().Add(time.Second)
		for ranges.Load() < count && time.Now().Before(deadline) {
			time.Sleep(time.Millisecond)
		}
		if ranges.Load() < count {
			t.Fatalf("CENC startup worker did not issue metadata Range %d", count)
		}
	}
	waitRange(1)
	setTestPreloadPaused(t, engine, plan, true)
	deadline := time.Now().Add(time.Second)
	for active.Load() != 0 && time.Now().Before(deadline) {
		time.Sleep(time.Millisecond)
	}
	if active.Load() != 0 {
		t.Fatal("paused CENC worker kept its origin request alive")
	}
	setTestPreloadPaused(t, engine, plan, false)
	waitRange(2)
	engine.nativeReleasePlayback(plan.Session)
	deadline = time.Now().Add(time.Second)
	for time.Now().Before(deadline) {
		if _, err := os.Stat(directory); os.IsNotExist(err) {
			return
		}
		time.Sleep(time.Millisecond)
	}
	t.Fatal("CENC startup waiter blocked session release")
}

func TestPreloadPauseCompleteCacheRemainsReadableOffline(t *testing.T) {
	for _, hls := range []bool{false, true} {
		t.Run(fmt.Sprintf("hls=%v", hls), func(t *testing.T) {
			var requests atomic.Int32
			upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				requests.Add(1)
				switch r.URL.Path {
				case "/index.m3u8":
					_, _ = io.WriteString(w, "#EXTM3U\n#EXT-X-TARGETDURATION:10\n#EXT-X-KEY:METHOD=AES-128,URI=\"key\"\n#EXTINF:10,\nsegment.ts\n#EXT-X-ENDLIST\n")
				case "/key":
					_, _ = io.WriteString(w, "0123456789abcdef")
				default:
					_, _ = io.WriteString(w, "verified-offline-media")
				}
			}))
			defer upstream.Close()
			entry := "/media.mp4"
			if hls {
				entry = "/index.m3u8"
			}
			engine, plan, _ := startTestEpisodeCache(t, providerMedia{URL: upstream.URL + entry})
			defer engine.nativeReleasePlayback(plan.Session)
			waitTestEpisodeCache(t, engine, plan, func(p nativePlan) bool { return p.PreloadComplete })
			before := requests.Load()
			paused := setTestPreloadPaused(t, engine, plan, true)
			if !paused.PreloadComplete || paused.PreloadState != "complete" {
				t.Fatal("complete cache regressed to an incomplete pause")
			}
			upstream.Close()
			read := func(address string) string {
				t.Helper()
				ctx, cancel := context.WithTimeout(context.Background(), time.Second)
				defer cancel()
				request, _ := http.NewRequestWithContext(ctx, http.MethodGet, address, nil)
				response, err := http.DefaultClient.Do(request)
				if err != nil {
					t.Fatal("verified local read was blocked by late pause", err)
				}
				body, err := io.ReadAll(response.Body)
				response.Body.Close()
				if err != nil || response.StatusCode != http.StatusOK || len(body) == 0 {
					t.Fatalf("complete local cache read failed: status=%d error=%v", response.StatusCode, err)
				}
				return string(body)
			}
			body := read(plan.URL)
			if hls {
				for _, match := range nativePlaylistURI.FindAllStringSubmatch(body, -1) {
					read(match[1])
				}
				for _, line := range strings.Split(body, "\n") {
					if strings.HasPrefix(line, "http:") {
						read(line)
					}
				}
			} else if body != "verified-offline-media" {
				t.Fatal("verified current media changed after late pause")
			}
			if requests.Load() != before {
				t.Fatal("paused complete reads reached the origin")
			}
		})
	}
}

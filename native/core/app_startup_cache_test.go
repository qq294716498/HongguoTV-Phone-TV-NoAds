package core

import (
	"bytes"
	"context"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

func TestEpisodeStartupSharesPrefixBeforeCompletionAndPromotesSameResource(t *testing.T) {
	data := append([]byte("\x00\x00\x00\x18ftypisom\x00\x00\x02\x00isomiso2"), bytes.Repeat([]byte("synthetic-media"), 600000)...)
	release := make(chan struct{})
	var once sync.Once
	defer once.Do(func() { close(release) })
	var requests atomic.Int32
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		requests.Add(1)
		w.Header().Set("Content-Type", "video/mp4")
		w.Header().Set("ETag", `"startup-v1"`)
		if r.Header.Get("Range") == "" {
			w.Header().Set("Content-Length", fmt.Sprint(len(data)))
			w.Write(data[:5<<20])
			w.(http.Flusher).Flush()
			select {
			case <-release:
				w.Write(data[5<<20:])
			case <-r.Context().Done():
			}
			return
		}
		http.ServeContent(w, r, "video.mp4", time.Time{}, bytes.NewReader(data))
	}))
	defer func() {
		once.Do(func() { close(release) })
		upstream.Close()
	}()
	engine, plan, _ := startTestEpisodeCache(t, providerMedia{URL: upstream.URL + "/opaque"})
	if plan.MediaType != "" {
		t.Fatal("unverified media type bypasses player sniffing")
	}
	ready := waitTestEpisodeCache(t, engine, plan, func(p nativePlan) bool { return p.StartupReady })
	if ready.PreloadComplete || ready.MediaType != "mp4" {
		t.Fatalf("startup waited for full download or missed media type: %+v", ready)
	}
	waitTestEpisodeCache(t, engine, plan, func(p nativePlan) bool { return p.PrefetchedBytes >= 5<<20 })
	session := engine.stream.sessions[engine.playbacks[plan.Session].streamSession]
	session.mu.Lock()
	startupBytes := session.startupBytes
	session.mu.Unlock()
	if startupBytes != nativePreloadLimit {
		t.Fatalf("startup memory cap was not enforced: bytes=%d", startupBytes)
	}
	request, _ := http.NewRequest(http.MethodGet, plan.URL, nil)
	request.Header.Set("Range", "bytes=0-65535")
	response, err := http.DefaultClient.Do(request)
	if err != nil {
		t.Fatal(err)
	}
	body, err := io.ReadAll(response.Body)
	response.Body.Close()
	if err != nil || response.StatusCode != 206 || !bytes.Equal(body, data[:65536]) || requests.Load() != 1 {
		t.Fatalf("startup prefix was downloaded twice: requests=%d status=%d error=%v", requests.Load(), response.StatusCode, err)
	}
	once.Do(func() { close(release) })
	waitTestEpisodeCache(t, engine, plan, func(p nativePlan) bool { return p.PreloadComplete })
	upstream.Close()
	response, err = http.Get(plan.URL)
	if err != nil {
		t.Fatal(err)
	}
	body, err = io.ReadAll(response.Body)
	response.Body.Close()
	if err != nil || response.StatusCode != 200 || !bytes.Equal(body, data) || requests.Load() != 1 {
		t.Fatalf("prepared playback could not use completed file offline: status=%d error=%v requests=%d", response.StatusCode, err, requests.Load())
	}
}

func TestEpisodeStartupPrioritizesHLSAudioVideoDependencies(t *testing.T) {
	release := make(chan struct{})
	beginBackground := make(chan struct{})
	backgroundStarted := make(chan struct{}, 1)
	var once sync.Once
	defer once.Do(func() { close(release) })
	startupPaths := []string{
		"/master.m3u8", "/audio.m3u8", "/video.m3u8", "/key",
		"/audio-init.mp4", "/video-init.mp4", "/audio-first.m4s", "/video-first.m4s",
	}
	allPaths := append(append([]string{}, startupPaths...), "/audio-second.m4s", "/video-second.m4s")
	knownPaths := make(map[string]bool, len(allPaths))
	for _, path := range allPaths {
		knownPaths[path] = true
	}
	var requestsMu sync.Mutex
	requests := make(map[string]int)
	assertRequests := func(required []string) {
		t.Helper()
		requestsMu.Lock()
		defer requestsMu.Unlock()
		for path, count := range requests {
			if !knownPaths[path] || count != 1 {
				t.Fatalf("unexpected or repeated HLS request: path=%s count=%d requests=%v", path, count, requests)
			}
		}
		for _, path := range required {
			if requests[path] != 1 {
				t.Fatalf("HLS dependency was not downloaded exactly once: path=%s count=%d requests=%v", path, requests[path], requests)
			}
		}
	}
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		second := r.URL.Path == "/audio-second.m4s" || r.URL.Path == "/video-second.m4s"
		if second {
			select {
			case <-beginBackground:
			case <-release:
			case <-r.Context().Done():
				return
			}
		}
		requestsMu.Lock()
		requests[r.URL.Path]++
		requestsMu.Unlock()
		if !knownPaths[r.URL.Path] {
			t.Errorf("unknown HLS request: %s", r.URL.Path)
			http.NotFound(w, r)
			return
		}
		if second {
			select {
			case backgroundStarted <- struct{}{}:
			default:
			}
		}
		switch r.URL.Path {
		case "/master.m3u8":
			io.WriteString(w, "#EXTM3U\n#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"audio\",DEFAULT=YES,URI=\"audio.m3u8\"\n#EXT-X-STREAM-INF:BANDWIDTH=200000,RESOLUTION=1280x720,AUDIO=\"audio\"\nvideo.m3u8\n")
		case "/audio.m3u8", "/video.m3u8":
			kind := strings.TrimSuffix(strings.TrimPrefix(r.URL.Path, "/"), ".m3u8")
			fmt.Fprintf(w, "#EXTM3U\n#EXT-X-TARGETDURATION:4\n#EXT-X-KEY:METHOD=AES-128,URI=\"key\"\n#EXT-X-MAP:URI=\"%s-init.mp4\"\n#EXTINF:4,\n%s-first.m4s\n#EXTINF:4,\n%s-second.m4s\n#EXT-X-ENDLIST\n", kind, kind, kind)
		case "/key":
			io.WriteString(w, "0123456789abcdef")
		default:
			if second {
				select {
				case <-release:
				case <-r.Context().Done():
					return
				}
			}
			io.WriteString(w, "synthetic "+r.URL.Path)
		}
	}))
	defer func() {
		once.Do(func() { close(release) })
		upstream.Close()
	}()
	engine, plan, _ := startTestEpisodeCache(t, providerMedia{URL: upstream.URL + "/master.m3u8"})
	ready := waitTestEpisodeCache(t, engine, plan, func(p nativePlan) bool { return p.StartupReady })
	if ready.PreloadComplete || ready.MediaType != "hls" {
		t.Fatalf("HLS startup did not precede completion: %+v", ready)
	}
	assertRequests(startupPaths)
	read := func(address string) string {
		t.Helper()
		response, err := http.Get(address)
		if err != nil {
			t.Fatal(err)
		}
		body, err := io.ReadAll(response.Body)
		response.Body.Close()
		if err != nil || response.StatusCode != 200 {
			t.Fatalf("shared HLS read failed: status=%d error=%v", response.StatusCode, err)
		}
		return string(body)
	}
	root := read(plan.URL)
	close(beginBackground)
	select {
	case <-backgroundStarted:
	case <-time.After(8 * time.Second):
		t.Fatal("background HLS download did not start during cached playback")
	}
	var children, segments []string
	for _, match := range nativePlaylistURI.FindAllStringSubmatch(root, -1) {
		children = append(children, match[1])
	}
	for _, line := range strings.Split(root, "\n") {
		if strings.HasPrefix(line, "http:") {
			children = append(children, line)
		}
	}
	if len(children) != 2 {
		t.Fatalf("missing selected audio/video playlists: %s", root)
	}
	for _, child := range children {
		body := read(child)
		for _, match := range nativePlaylistURI.FindAllStringSubmatch(body, -1) {
			read(match[1])
		}
		first := true
		for _, line := range strings.Split(body, "\n") {
			if strings.HasPrefix(line, "http:") {
				segments = append(segments, line)
				if first {
					read(line)
					first = false
				}
			}
		}
	}
	assertRequests(startupPaths)
	once.Do(func() { close(release) })
	waitTestEpisodeCache(t, engine, plan, func(p nativePlan) bool { return p.PreloadComplete })
	assertRequests(allPaths)
	upstream.Close()
	for _, segment := range segments {
		if !strings.HasPrefix(read(segment), "synthetic /") {
			t.Fatal("original HLS resource URL did not become available offline")
		}
	}
	assertRequests(allPaths)
}

func TestSharedPrefixIsImmediateAndRejectsChangedRemainder(t *testing.T) {
	data := bytes.Repeat([]byte("0123456789abcdef"), 64)
	var changed atomic.Bool
	release := make(chan struct{})
	var once sync.Once
	defer once.Do(func() { close(release) })
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Range") != "bytes=64-1023" || r.Header.Get("If-Range") != `"v1"` {
			t.Error("remainder did not preserve range and resource identity")
		}
		select {
		case <-release:
		case <-r.Context().Done():
			return
		}
		etag := `"v1"`
		if changed.Load() {
			etag = `"v2"`
		}
		w.Header().Set("ETag", etag)
		http.ServeContent(w, r, "video.mp4", time.Time{}, bytes.NewReader(data))
	}))
	defer func() {
		once.Do(func() { close(release) })
		upstream.Close()
	}()
	engine, err := newNativeEngine(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	stream, err := newNativeStreamServer(engine.downloader)
	if err != nil {
		t.Fatal(err)
	}
	defer stream.server.Close()
	address, token := stream.nativeOpen(providerMedia{URL: upstream.URL})
	defer stream.nativeRelease(token)
	session := stream.sessions[token]
	session.mu.Lock()
	for id, asset := range session.assets {
		asset.data, asset.total, asset.etag = data[:64], int64(len(data)), `"v1"`
		session.assets[id] = asset
	}
	session.mu.Unlock()
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	request, _ := http.NewRequestWithContext(ctx, http.MethodGet, address, nil)
	response, err := http.DefaultClient.Do(request)
	if err != nil {
		t.Fatal("cached prefix waited for the blocked origin:", err)
	}
	prefix := make([]byte, 64)
	if _, err := io.ReadFull(response.Body, prefix); err != nil || !bytes.Equal(prefix, data[:64]) {
		t.Fatalf("prefix unavailable before origin response: %v", err)
	}
	changed.Store(true)
	once.Do(func() { close(release) })
	rest, err := io.ReadAll(response.Body)
	response.Body.Close()
	if err == nil || len(rest) != 0 {
		t.Fatal("changed media was mixed with the prepared prefix")
	}
	response, err = http.Get(address)
	if err != nil {
		t.Fatal(err)
	}
	response.Body.Close()
	if response.StatusCode != http.StatusConflict {
		t.Fatal("invalidated resource silently changed during active playback")
	}
}

func TestEpisodeStartupPreparesCENCIndexBeforeWholeFile(t *testing.T) {
	ffmpeg, err := exec.LookPath("ffmpeg")
	if err != nil {
		t.Skip("FFmpeg is required for synthetic CENC media")
	}
	filename := filepath.Join(t.TempDir(), "encrypted.mp4")
	key := []byte("0123456789abcdef")
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	output, err := exec.CommandContext(ctx, ffmpeg, "-hide_banner", "-loglevel", "error", "-nostdin", "-f", "lavfi", "-i", "testsrc2=size=160x96:rate=10", "-t", "1", "-c:v", "libx264", "-movflags", "+faststart", "-encryption_scheme", "cenc-aes-ctr", "-encryption_key", fmt.Sprintf("%x", key), "-encryption_kid", "0123456789abcdef0123456789abcdef", filename).CombinedOutput()
	if err != nil {
		t.Fatalf("synthetic CENC generation failed: %v %s", err, output)
	}
	data, err := os.ReadFile(filename)
	if err != nil {
		t.Fatal(err)
	}
	data = append(data, []byte{0, 0, 0, 0, 'f', 'r', 'e', 'e'}...)
	data = append(data, make([]byte, 5<<20)...)
	release := make(chan struct{})
	var once sync.Once
	defer once.Do(func() { close(release) })
	var requests atomic.Int32
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		requests.Add(1)
		w.Header().Set("ETag", `"cenc-v1"`)
		w.Header().Set("Content-Type", "video/mp4")
		if r.Header.Get("Range") == "" {
			w.Header().Set("Content-Length", fmt.Sprint(len(data)))
			w.Write(data[:256<<10])
			w.(http.Flusher).Flush()
			select {
			case <-release:
				w.Write(data[256<<10:])
			case <-r.Context().Done():
			}
			return
		}
		http.ServeContent(w, r, "encrypted.mp4", time.Time{}, bytes.NewReader(data))
	}))
	defer func() {
		once.Do(func() { close(release) })
		upstream.Close()
	}()
	engine, plan, _ := startTestEpisodeCache(t, providerMedia{URL: upstream.URL + "/opaque", CENCKey: key})
	ready := waitTestEpisodeCache(t, engine, plan, func(p nativePlan) bool { return p.StartupReady })
	if ready.PreloadComplete || ready.MediaType != "mp4" || requests.Load() != 1 {
		t.Fatalf("CENC metadata did not reuse growing prefix: %+v requests=%d", ready, requests.Load())
	}
	request, _ := http.NewRequest(http.MethodGet, plan.URL+"?cenc=clear", nil)
	request.Header.Set("Range", "bytes=0-4095")
	response, err := http.DefaultClient.Do(request)
	if err != nil {
		t.Fatal(err)
	}
	body, err := io.ReadAll(response.Body)
	response.Body.Close()
	if err != nil || response.StatusCode != 206 || len(body) != 4096 || requests.Load() != 1 {
		t.Fatalf("prepared CENC prefix was not playable: error=%v status=%d requests=%d", err, response.StatusCode, requests.Load())
	}
	once.Do(func() { close(release) })
	waitTestEpisodeCache(t, engine, plan, func(p nativePlan) bool { return p.PreloadComplete })
	upstream.Close()
	response, err = http.DefaultClient.Do(request)
	if err != nil {
		t.Fatal(err)
	}
	body, err = io.ReadAll(response.Body)
	response.Body.Close()
	if err != nil || response.StatusCode != 206 || len(body) != 4096 {
		t.Fatal("prepared CENC session did not promote to verified offline bytes")
	}
}

func TestEpisodeStartupReleaseCancelsProducerAndRemovesCache(t *testing.T) {
	started, canceled := make(chan struct{}), make(chan struct{})
	data := append([]byte("\x00\x00\x00\x18ftypisom\x00\x00\x02\x00isomiso2"), make([]byte, 1<<20)...)
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("ETag", `"cancel-v1"`)
		w.Header().Set("Content-Length", fmt.Sprint(len(data)+1))
		w.Write(data)
		w.(http.Flusher).Flush()
		close(started)
		<-r.Context().Done()
		close(canceled)
	}))
	engine, plan, directory := startTestEpisodeCache(t, providerMedia{URL: upstream.URL + "/media"})
	defer upstream.Close()
	defer engine.nativeReleasePlayback(plan.Session)
	select {
	case <-started:
	case <-time.After(2 * time.Second):
		t.Fatal("startup producer did not start")
	}
	waitTestEpisodeCache(t, engine, plan, func(p nativePlan) bool { return p.StartupReady })
	engine.nativeReleasePlayback(plan.Session)
	select {
	case <-canceled:
	case <-time.After(2 * time.Second):
		t.Fatal("session release did not cancel the download")
	}
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		if _, err := os.Stat(directory); os.IsNotExist(err) {
			return
		}
		time.Sleep(time.Millisecond)
	}
	t.Fatal("released session retained its cache directory")
}

func TestSharedPrefixValidatesLastModifiedBeyondCachedRange(t *testing.T) {
	data := bytes.Repeat([]byte("same-size-media"), 64)
	original := "Mon, 02 Jan 2006 15:04:05 GMT"
	for _, changed := range []bool{false, true} {
		t.Run(fmt.Sprint(changed), func(t *testing.T) {
			upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if r.Header.Get("If-Unmodified-Since") != original {
					t.Error("Last-Modified identity was not sent for the seek")
				}
				modified := original
				if changed {
					modified = "Tue, 03 Jan 2006 15:04:05 GMT"
				}
				w.Header().Set("ETag", `W/"weak"`)
				w.Header().Set("Last-Modified", modified)
				http.ServeContent(w, r, "video.mp4", time.Time{}, bytes.NewReader(data))
			}))
			defer upstream.Close()
			engine, err := newNativeEngine(t.TempDir())
			if err != nil {
				t.Fatal(err)
			}
			stream, err := newNativeStreamServer(engine.downloader)
			if err != nil {
				t.Fatal(err)
			}
			defer stream.server.Close()
			address, token := stream.nativeOpen(providerMedia{URL: upstream.URL})
			defer stream.nativeRelease(token)
			session := stream.sessions[token]
			session.mu.Lock()
			for id, asset := range session.assets {
				asset.data, asset.total = data[:64], int64(len(data))
				asset.etag, asset.modified = `W/"weak"`, original
				session.assets[id] = asset
			}
			session.mu.Unlock()
			request, _ := http.NewRequest(http.MethodGet, address, nil)
			request.Header.Set("Range", "bytes=128-255")
			response, err := http.DefaultClient.Do(request)
			if err != nil {
				t.Fatal(err)
			}
			body, err := io.ReadAll(response.Body)
			response.Body.Close()
			if changed {
				if response.StatusCode != http.StatusConflict || bytes.Equal(body, data[128:256]) {
					t.Fatal("changed Last-Modified with unchanged size and weak ETag bypassed identity validation")
				}
			} else if err != nil || response.StatusCode != http.StatusPartialContent || !bytes.Equal(body, data[128:256]) {
				t.Fatalf("unchanged Last-Modified seek failed: status=%d error=%v", response.StatusCode, err)
			}
		})
	}
}

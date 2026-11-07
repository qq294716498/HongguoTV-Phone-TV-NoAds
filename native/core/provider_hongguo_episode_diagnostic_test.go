package core

import (
	"context"
	"crypto/sha256"
	"errors"
	"io"
	"net/http"
	"os"
	"strings"
	"sync"
	"testing"
	"time"
)

func TestLiveHongguoEpisodeModelDiagnostic(t *testing.T) {
	if os.Getenv("HG_EPISODE_MODEL_DIAGNOSTIC") != "1" {
		t.Skip("explicit metadata-only episode comparison")
	}
	var mu sync.Mutex
	requests, registrations := 0, 0
	seen := map[[32]byte]bool{}
	stopped := false
	engine, err := newNativeEngine(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(engine.downloads.close)
	d := engine.downloader
	transport := d.client.Transport
	t.Cleanup(func() {
		if closer, ok := transport.(interface{ CloseIdleConnections() }); ok {
			closer.CloseIdleConnections()
		}
	})
	d.client.Transport = sourceFixtureTransport(func(request *http.Request) (*http.Response, error) {
		mu.Lock()
		defer mu.Unlock()
		if stopped || request.URL.Scheme != "https" || requests >= 6 {
			return nil, errors.New("metadata diagnostic request limit")
		}
		host, path := request.URL.Hostname(), request.URL.Path
		allowed := host == "api5-normal-sinfonlineb.fqnovel.com" &&
			(path == hongguoSearchAppPath || path == "/novel/player/video_detail/v1/" || path == hongguoSingleVideoModelPath)
		if host == "log.snssdk.com" && path == "/service/2/device_register/" && registrations == 0 {
			allowed = true
			registrations++
		}
		if !allowed {
			return nil, errors.New("metadata diagnostic rejected an unrelated request")
		}
		identity := []byte(request.Method + " " + host + path + " " + request.URL.Query().Get("tab_type"))
		if request.GetBody != nil {
			body, err := request.GetBody()
			if err != nil {
				return nil, err
			}
			content, err := io.ReadAll(io.LimitReader(body, 16*1024))
			body.Close()
			if err != nil {
				return nil, err
			}
			identity = append(identity, content...)
		}
		key := sha256.Sum256(identity)
		if seen[key] {
			return nil, errors.New("metadata diagnostic does not repeat a request")
		}
		seen[key] = true
		requests++
		response, err := transport.RoundTrip(request)
		if err != nil || response.StatusCode == http.StatusForbidden || response.StatusCode == http.StatusTooManyRequests {
			stopped = true
		}
		return response, err
	})
	ctx, cancel := context.WithTimeout(context.Background(), 90*time.Second)
	defer cancel()
	search, err := d.fetchHongguoAppSearch(ctx, "我家仙妻不太正经", 1)
	if err != nil {
		t.Logf("search returned partial results=%d: %v", len(search.Dramas), publicError(err))
	}
	seriesID := ""
	for _, drama := range search.Dramas {
		if drama.DisplayTitle() == "我家仙妻不太正经第三季" {
			seriesID = drama.SourceID
		}
	}
	if seriesID == "" {
		t.Fatalf("exact season not returned: results=%d", len(search.Dramas))
	}
	detail, err := d.hongguoAppDetail(ctx, seriesID)
	if err != nil {
		t.Fatal(publicError(err))
	}
	if detail.Drama.DisplayTitle() != "我家仙妻不太正经第三季" || len(detail.Chapters) != 151 {
		t.Fatal("season identity or episode count did not match")
	}
	t.Logf("matched requested season: episodes=%d", len(detail.Chapters))
	for _, index := range []int{0, 3} {
		videoID := strings.TrimPrefix(detail.Chapters[index].VideoURL, "hongguo-cenc://")
		model, err := d.fetchHongguoRegisteredVideoModel(ctx, videoID)
		if err != nil {
			t.Errorf("episode=%d model failed: %v", index+1, publicError(err))
			continue
		}
		rows := anyList(model["video_list"])
		if items, ok := model["video_list"].(map[string]any); ok && len(rows) == 0 {
			for _, item := range items {
				rows = append(rows, item)
			}
		}
		t.Logf("episode=%d variants=%d", index+1, len(rows))
		for _, row := range rows {
			variant, _ := row.(map[string]any)
			meta := nestedMap(variant, "video_meta")
			codec := strings.ToLower(mapString(meta, "codec_type"))
			switch codec {
			case "h264", "avc1", "hevc", "h265", "bytevc1", "bytevc2":
			default:
				codec = "other"
			}
			encryption := nestedMap(variant, "encrypt_info")
			t.Logf("episode=%d codec=%s bytevc2Gear=%t parsedAddresses=%d encryptionMetadata=%t", index+1, codec,
				strings.Contains(strings.ToLower(mapString(variant, "gear_des_key")), "bytevc2"),
				len(hongguoMediaAddresses(variant)), len(encryption) > 0)
		}
	}
}

package core

import (
	"bytes"
	"compress/gzip"
	"context"
	"crypto/aes"
	"crypto/cipher"
	"crypto/sha512"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

func searchFixtureIdentity(d *Downloader) {
	client := d.hongguoClient()
	client.deviceIdentityLoaded = true
	client.deviceIdentity = hongguoDeviceIdentity{DeviceID: "1234567890123456", InstallID: "2345678901234567", Cookie: "install_id=2345678901234567; store-region=cn"}
}

func searchFixtureTab(request *http.Request, more bool, offset int, passback, data string) *http.Response {
	return sourceFixtureResponse(request, 200, fmt.Sprintf(`{"code":0,"search_tabs":[{"tab_type":%s,"has_more":%t,"next_offset":%d,"search_id":"fixture-session","passback":%q,"data":%s}]}`, request.URL.Query().Get("tab_type"), more, offset, passback, data))
}

func TestHongguoSignedSearchPagesReachNextSeason(t *testing.T) {
	var calls atomic.Int32
	d := sourceFixtureDownloader(t, func(r *http.Request) (*http.Response, error) {
		calls.Add(1)
		if r.URL.Path != hongguoSearchAppPath {
			t.Errorf("unexpected fallback: %s", r.URL.Path)
			return nil, errors.New("unexpected fallback")
		}
		for _, header := range []string{"X-Gorgon", "X-Khronos", "X-Ladon", "X-Argus", "X-Helios", "X-Medusa"} {
			if r.Header.Get(header) == "" {
				t.Errorf("missing signature %s", header)
			}
		}
		if !strings.Contains(r.Header.Get("Cookie"), "install_id=2345678901234567") {
			t.Error("missing registered cookie")
		}
		query := r.URL.Query()
		if query.Get("device_id") != "1234567890123456" || query.Get("iid") != "2345678901234567" {
			t.Error("wrong device pair")
		}
		if query.Get("tab_type") == "11" {
			return searchFixtureTab(r, false, 0, "", `[]`), nil
		}
		if query.Get("offset") == "0" {
			if query.Get("search_id") != "" || query.Get("passback") != "" {
				t.Error("first page reused cursor")
			}
			return searchFixtureTab(r, true, 6, "opaque-cursor", `[{"video_data":[{"series_id":7621200213801176126,"title":"合成故事第一季"}]}]`), nil
		}
		if query.Get("offset") != "6" || query.Get("search_id") != "fixture-session" || query.Get("passback") != "opaque-cursor" {
			t.Error("did not forward server cursor")
		}
		return searchFixtureTab(r, false, 7, "", `[{"video_data":[{"series_id":"7621200213801176127","title":"合成故事第二季","video_desc":"合成简介","episode_cnt":12}]}]`), nil
	})
	searchFixtureIdentity(d)
	first, err := d.searchHongguoDramasPage(context.Background(), "合成故事", 1)
	if err != nil || !first.HasMore || len(first.Dramas) != 1 {
		t.Fatalf("first page: %+v %v", first, err)
	}
	second, err := d.searchHongguoDramasPage(context.Background(), "合成故事", 2)
	if err != nil || second.HasMore || len(second.Dramas) != 1 || second.Dramas[0].DisplayTitle() != "合成故事第二季" {
		t.Fatalf("second page: %+v %v", second, err)
	}
	if second.Dramas[0].SourceID != "7621200213801176127" {
		t.Fatal("numeric ID lost precision")
	}
	_, err = d.searchHongguoDramasPage(context.Background(), "合成故事", 2)
	if err != nil || calls.Load() != 3 {
		t.Fatalf("page cache or exhausted tab re-requested: %d %v", calls.Load(), err)
	}
}

func TestHongguoSearchFallsBackOnlyWhenAppFailsOrEmpty(t *testing.T) {
	for _, mode := range []string{"empty", "failed", "success"} {
		t.Run(mode, func(t *testing.T) {
			var web atomic.Int32
			d := sourceFixtureDownloader(t, func(r *http.Request) (*http.Response, error) {
				switch {
				case r.URL.Path == hongguoSearchAppPath:
					if mode == "failed" {
						return sourceFixtureResponse(r, 200, ""), nil
					}
					data := `[]`
					if mode == "success" {
						data = `[{"video_data":[{"series_id":"12345","title":"合成剧"}]}]`
					}
					return searchFixtureTab(r, false, 0, "", data), nil
				case r.URL.Path == "/incent_resource/suggestion":
					return sourceFixtureResponse(r, 200, `{"suggest_list":[]}`), nil
				case strings.HasPrefix(r.URL.Path, "/search/"):
					web.Add(1)
					if r.Header.Get("X-Gorgon") != "" {
						t.Error("website fallback should be unsigned")
					}
					return sourceFixtureResponse(r, 200, `<script>window._ROUTER_DATA={"loaderData":{"search_(keyword)/page":{"isSuccess":true,"query":"合成剧","searchList":[{"video_data":{"series_id":"12345","series_title":"合成剧"}}],"totalCount":1}}};</script>`), nil
				}
				return nil, errors.New("unexpected URL")
			})
			searchFixtureIdentity(d)
			entry, err := d.searchHongguoDramas(context.Background(), "合成剧")
			if err != nil || len(entry.Dramas) != 1 {
				t.Fatalf("search failed: %+v %v", entry, err)
			}
			expected := int32(1)
			if mode == "success" {
				expected = 0
			}
			if web.Load() != expected {
				t.Fatalf("wrong fallback count: %d", web.Load())
			}
		})
	}
}

func TestHongguoSearchRejectsExpiredAndStalledCursors(t *testing.T) {
	var calls atomic.Int32
	d := sourceFixtureDownloader(t, func(r *http.Request) (*http.Response, error) {
		calls.Add(1)
		return searchFixtureTab(r, true, 0, "same", `[{"video_data":[{"series_id":"12345","title":"合成剧"}]}]`), nil
	})
	searchFixtureIdentity(d)
	_, err := d.fetchHongguoAppSearch(context.Background(), "合成剧", 2)
	if err == nil || calls.Load() != 0 {
		t.Fatal("missing cursor restarted search at page one")
	}
	_, err = d.fetchHongguoAppSearch(context.Background(), "合成剧", 1)
	if err == nil || !strings.Contains(err.Error(), "游标") || calls.Load() != 2 {
		t.Fatalf("stalled cursor accepted: %v", err)
	}
}

func TestHongguoSearchParsesLynxCellsAndDeduplicates(t *testing.T) {
	var row map[string]any
	decoder := json.NewDecoder(strings.NewReader(`{"lynx_data":"{\"cell_data\":[{\"book_id\":\"7621200213801176126\",\"search_high_light\":{\"title\":{\"text\":\"合成<em>故事</em>\"}},\"video_data\":[{\"video_desc\":\"简介\",\"episode_cnt\":81}]}]}"}`))
	decoder.UseNumber()
	if err := decoder.Decode(&row); err != nil {
		t.Fatal(err)
	}
	dramas := hongguoAppSearchDramas(row, 0)
	if len(dramas) != 1 || dramas[0].SourceID != "7621200213801176126" || dramas[0].DisplayTitle() != "合成故事" || dramas[0].Desc != "简介" {
		t.Fatalf("lynx parsing failed: %+v", dramas)
	}
	if len(hongguoAppSearchDramas(map[string]any{"book_id": "12345", "cell_name": "广告"}, 0)) != 0 {
		t.Fatal("non-video cell became a drama")
	}
}

func TestHongguoSearchRegistrationEncryptsAndPersistsIdentity(t *testing.T) {
	var registrations atomic.Int32
	d := sourceFixtureDownloader(t, func(r *http.Request) (*http.Response, error) {
		registrations.Add(1)
		if r.URL.Path != "/service/2/device_register/" || r.Header.Get("X-Gorgon") != "" {
			t.Error("registration route or headers wrong")
		}
		body, err := io.ReadAll(r.Body)
		if err != nil {
			return nil, err
		}
		if len(body) < 54 || !bytes.Equal(body[:6], []byte{0x74, 0x63, 5, 0x10, 0, 0}) {
			t.Fatal("registration body is not raw ttEncrypt bytes")
		}
		seedHash := sha512.Sum512(body[6:38])
		material := sha512.Sum512(append(seedHash[:], hongguoSpadeURLConstants...))
		block, _ := aes.NewCipher(material[:16])
		plain := make([]byte, len(body)-38)
		cipher.NewCBCDecrypter(block, material[16:32]).CryptBlocks(plain, body[38:])
		plain = plain[:len(plain)-int(plain[len(plain)-1])]
		digest := sha512.Sum512(plain[64:])
		if !bytes.Equal(digest[:], plain[:64]) {
			t.Fatal("registration digest mismatch")
		}
		reader, err := gzip.NewReader(bytes.NewReader(plain[64:]))
		if err != nil {
			t.Fatal(err)
		}
		var payload map[string]any
		if err = json.NewDecoder(reader).Decode(&payload); err != nil {
			t.Fatal(err)
		}
		reader.Close()
		header := nestedMap(payload, "header")
		if header["os_version"] != "16" || header["device_id"] != nil || payload["magic_tag"] != "ss_app_log" {
			t.Fatal("invalid registration profile")
		}
		response := sourceFixtureResponse(r, 200, `{"device_id_str":"3456789012345678","install_id":4567890123456789}`)
		response.Header.Add("Set-Cookie", "install_id=4567890123456789; Path=/")
		return response, nil
	}, false)
	var group sync.WaitGroup
	for range 4 {
		group.Add(1)
		go func() {
			defer group.Done()
			identity, err := d.ensureHongguoDeviceIdentity(context.Background())
			if err != nil || !identity.valid() {
				t.Errorf("registration failed: %v", err)
			}
		}()
	}
	group.Wait()
	if registrations.Load() != 1 {
		t.Fatalf("registration was not coalesced: %d", registrations.Load())
	}
	path := filepath.Join(d.cfg.dataDir, "hongguo-device.json")
	info, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	if info.Mode().Perm() != 0600 {
		t.Fatalf("identity file permissions: %v", info.Mode())
	}
	restored := sourceFixtureDownloader(t, func(r *http.Request) (*http.Response, error) {
		t.Error("persisted identity was not reused")
		return nil, errors.New("unexpected registration")
	}, false)
	restored.cfg.dataDir = d.cfg.dataDir
	identity, err := restored.ensureHongguoDeviceIdentity(context.Background())
	if err != nil || identity.InstallID != "4567890123456789" || identity.Cookie == "" {
		t.Fatalf("restore failed: %+v %v", identity, err)
	}
}

func TestHongguoSearchCancellationDoesNotFallback(t *testing.T) {
	var requests atomic.Int32
	d := sourceFixtureDownloader(t, func(r *http.Request) (*http.Response, error) {
		requests.Add(1)
		return nil, errors.New("unexpected request")
	})
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	_, err := d.searchHongguoDramasPage(ctx, "合成", 1)
	if !errors.Is(err, context.Canceled) || requests.Load() != 0 {
		t.Fatalf("cancellation ignored: %v", err)
	}
}

func TestHongguoSearchRegistrationWaitRespectsCancellation(t *testing.T) {
	d := sourceFixtureDownloader(t, nil)
	d.hongguoClient().deviceRegistration <- struct{}{}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Millisecond)
	defer cancel()
	_, err := d.ensureHongguoDeviceIdentity(ctx)
	if !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("waiting registration ignored deadline: %v", err)
	}
}

func TestNativeHongguoSearchExposesServerPagination(t *testing.T) {
	var requests atomic.Int32
	engine := sourceFixtureEngine(t, func(r *http.Request) (*http.Response, error) {
		requests.Add(1)
		return searchFixtureTab(r, true, 20, "cursor-20", `[{"video_data":[{"series_id":"12345","title":"合成剧"}]}]`), nil
	})
	searchFixtureIdentity(engine.downloader)
	input := nativeInput{Source: sourceHongguo, Query: "合成剧", Page: 1}
	first, err := engine.nativeCatalog(context.Background(), input)
	if err != nil || !first.HasMore || first.Page != 1 || len(first.Items) != 1 {
		t.Fatalf("native pagination missing: %+v %v", first, err)
	}
	_, err = engine.nativeCatalog(context.Background(), input)
	if err != nil || requests.Load() != 2 {
		t.Fatal("native search did not cache")
	}
	input.Force = true
	_, err = engine.nativeCatalog(context.Background(), input)
	if err != nil || requests.Load() != 4 {
		t.Fatal("forced first page did not refresh")
	}
}

func TestHongguoSearchRetriesBusyCodeWithoutChangingDevice(t *testing.T) {
	calls := map[string]int{}
	var mu sync.Mutex
	d := sourceFixtureDownloader(t, func(r *http.Request) (*http.Response, error) {
		mu.Lock()
		defer mu.Unlock()
		key := r.URL.Query().Get("tab_type")
		calls[key]++
		if r.URL.Query().Get("device_id") != "1234567890123456" {
			t.Error("retry changed registered identity")
		}
		if calls[key] == 1 {
			return sourceFixtureResponse(r, 200, `{"code":100103}`), nil
		}
		return searchFixtureTab(r, false, 0, "", `[{"video_data":[{"series_id":"12345","title":"合成剧"}]}]`), nil
	})
	searchFixtureIdentity(d)
	entry, err := d.searchHongguoDramas(context.Background(), "合成剧")
	if err != nil || len(entry.Dramas) != 1 || calls["11"] != 2 || calls["19"] != 2 {
		t.Fatalf("busy retry failed: %v", err)
	}
}

package core

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestHongguoRegisteredIdentitySharedAcrossAppRoutes(t *testing.T) {
	registrations, requests := 0, 0
	d := sourceFixtureDownloader(t, func(r *http.Request) (*http.Response, error) {
		if r.URL.Path == "/service/2/device_register/" {
			registrations++
			response := sourceFixtureResponse(r, 200, `{"device_id":"3456789012345678","install_id":"4567890123456789"}`)
			response.Header.Add("Set-Cookie", "install_id=4567890123456789; Path=/")
			return response, nil
		}
		requests++
		if r.URL.Path == hongguoVideoModelPath {
			if r.URL.Query().Get("device_id") == "3456789012345678" || r.URL.Query().Get("iid") == "4567890123456789" || r.Header.Get("Cookie") != "" {
				t.Error("playback leaked registered identity into temporary profile")
			}
			return sourceFixtureResponse(r, 200, `{"code":0}`), nil
		}
		if r.URL.Query().Get("device_id") != "3456789012345678" || r.URL.Query().Get("iid") != "4567890123456789" || r.Header.Get("Cookie") != "install_id=4567890123456789" {
			t.Error("App request lost shared registered identity")
		}
		return sourceFixtureResponse(r, 200, `{"code":0}`), nil
	}, false)
	for _, path := range []string{hongguoSearchAppPath, hongguoVideoModelPath, "/reading/bookapi/video_tab/", "/novel/commentapi/comment/list/12345/v1/"} {
		_, err := d.hongguoAppRequest(context.Background(), http.MethodPost, path, url.Values{"device_id": {"unregistered"}, "iid": {"unregistered"}}, map[string]any{"fixture": true})
		if err != nil {
			t.Fatal(err)
		}
	}
	if registrations != 1 || requests != 4 {
		t.Fatalf("shared device registration was not reused: %d %d", registrations, requests)
	}
	snapshot := d.hongguoCatalogSnapshot()
	if snapshot.DeviceID != "3456789012345678" || snapshot.InstallID != "4567890123456789" {
		t.Fatal("catalog snapshot kept random identity")
	}
}

func TestHongguoFailedRegistrationPausesThenCanRetry(t *testing.T) {
	registrations, requests := 0, 0
	d := sourceFixtureDownloader(t, func(r *http.Request) (*http.Response, error) {
		if r.URL.Path == "/service/2/device_register/" {
			registrations++
			if registrations == 1 {
				return sourceFixtureResponse(r, 200, `{"device_id":0,"install_id":0}`), nil
			}
			return sourceFixtureResponse(r, 200, `{"device_id":"12345","install_id":"23456"}`), nil
		}
		requests++
		return sourceFixtureResponse(r, 200, `{"code":0}`), nil
	}, false)
	_, err := d.hongguoAppRequest(context.Background(), http.MethodPost, hongguoSearchAppPath, nil, nil)
	if err == nil || requests != 0 {
		t.Fatal("unregistered request escaped startup gate")
	}
	_, err = d.hongguoAppRequest(context.Background(), http.MethodPost, hongguoSearchAppPath, nil, nil)
	if err == nil || requests != 0 || registrations != 1 {
		t.Fatal("registration rejection did not pause subsequent attempts")
	}
	d.hongguoClient().deviceRotationPausedUntil = time.Now().Add(-time.Second)
	_, err = d.hongguoAppRequest(context.Background(), http.MethodPost, hongguoSearchAppPath, nil, nil)
	if err != nil || requests != 1 || registrations != 2 {
		t.Fatalf("registration retry did not recover: %v", err)
	}
}

func TestHongguoTransientRegistrationFailureCanRetry(t *testing.T) {
	registrations := 0
	d := sourceFixtureDownloader(t, func(r *http.Request) (*http.Response, error) {
		registrations++
		if registrations == 1 {
			return nil, errors.New("fixture connection reset")
		}
		return sourceFixtureResponse(r, 200, `{"device_id":"12345","install_id":"23456"}`), nil
	}, false)
	if _, err := d.ensureHongguoDeviceIdentity(context.Background()); err == nil {
		t.Fatal("transport error was lost")
	}
	if _, err := d.ensureHongguoDeviceIdentity(context.Background()); err != nil || registrations != 2 {
		t.Fatalf("transient failure unexpectedly paused registration: %v", err)
	}
}

func TestHongguoMigratesPreviouslyRegisteredSearchIdentity(t *testing.T) {
	d := sourceFixtureDownloader(t, func(r *http.Request) (*http.Response, error) {
		t.Error("migration should reuse registered identity")
		return nil, errors.New("unexpected registration")
	}, false)
	saved := hongguoDeviceIdentity{DeviceID: "123456", InstallID: "234567", Cookie: "install_id=234567"}
	body, _ := json.Marshal(saved)
	if err := os.WriteFile(filepath.Join(d.cfg.dataDir, "hongguo-search-device.json"), body, 0600); err != nil {
		t.Fatal(err)
	}
	identity, err := d.ensureHongguoDeviceIdentity(context.Background())
	if err != nil || identity != saved {
		t.Fatalf("migration lost identity: %v", err)
	}
	migrated, err := os.ReadFile(filepath.Join(d.cfg.dataDir, "hongguo-device.json"))
	if err != nil || string(migrated) != string(body) {
		t.Fatalf("shared identity was not saved: %v", err)
	}
}

func TestHongguoRegistrationSaveFailureBlocksAndRetriesWithoutReregistering(t *testing.T) {
	registrations := 0
	d := sourceFixtureDownloader(t, func(r *http.Request) (*http.Response, error) {
		registrations++
		return sourceFixtureResponse(r, 200, `{"device_id":"12345","install_id":"23456"}`), nil
	}, false)
	path := filepath.Join(d.cfg.dataDir, "blocked-directory")
	if err := os.WriteFile(path, []byte("fixture"), 0600); err != nil {
		t.Fatal(err)
	}
	d.cfg.dataDir = path
	if _, err := d.ensureHongguoDeviceIdentity(context.Background()); err == nil {
		t.Fatal("unsaved registration reported success")
	}
	if err := os.Remove(path); err != nil {
		t.Fatal(err)
	}
	if _, err := d.ensureHongguoDeviceIdentity(context.Background()); err != nil {
		t.Fatal(err)
	}
	if registrations != 1 {
		t.Fatal("storage retry registered a second device")
	}
}

func TestHongguoPersistedIdentitySurvivesPlaybackFailureAndRestart(t *testing.T) {
	requests, registrations := 0, 0
	transport := func(r *http.Request) (*http.Response, error) {
		if r.URL.Path == "/service/2/device_register/" {
			registrations++
			t.Fatal("a valid saved identity was unexpectedly replaced")
		}
		requests++
		if r.URL.Query().Get("device_id") != "123456" || r.URL.Query().Get("iid") != "234567" {
			t.Fatal("saved identity was not used")
		}
		return sourceFixtureResponse(r, 200, `{"data":{"video_model":{"video_list":[{"main_url":"https://media.example.test/a.mp4","video_meta":{"codec_type":"bytevc2"}}]}}}`), nil
	}
	d := sourceFixtureDownloader(t, transport, false)
	saved := hongguoDeviceIdentity{DeviceID: "123456", InstallID: "234567"}
	body, _ := json.Marshal(saved)
	path := filepath.Join(d.cfg.dataDir, "hongguo-device.json")
	if err := os.WriteFile(path, body, 0600); err != nil {
		t.Fatal(err)
	}
	for iteration := 0; iteration < 2; iteration++ {
		identity, err := d.ensureHongguoDeviceIdentity(context.Background())
		if err != nil || identity != saved {
			t.Fatalf("startup identity changed: %v", err)
		}
		_, err = d.resolveHongguoRegisteredMedia(context.Background(), "9001")
		var selection *hongguoMediaSelectionError
		if !errors.As(err, &selection) || selection.unsupportedCodec != 1 {
			t.Fatalf("expected fresh unsupported model: %v", err)
		}
		if requests != iteration+1 || registrations != 0 {
			t.Fatal("retry cached the failure or replaced the identity")
		}
		restarted := sourceFixtureDownloader(t, transport, false)
		restarted.cfg.dataDir = d.cfg.dataDir
		d = restarted
	}
	unchanged, err := os.ReadFile(path)
	if err != nil || string(unchanged) != string(body) {
		t.Fatalf("unsupported codec changed persistent registration: %v", err)
	}
}

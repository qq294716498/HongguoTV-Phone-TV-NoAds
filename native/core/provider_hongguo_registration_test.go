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

func TestHongguoFailedRegistrationBlocksAppRequestAndCanRetry(t *testing.T) {
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
	_, err := d.hongguoAppRequest(context.Background(), http.MethodPost, hongguoVideoModelPath, nil, nil)
	if err == nil || requests != 0 {
		t.Fatal("unregistered request escaped startup gate")
	}
	_, err = d.hongguoAppRequest(context.Background(), http.MethodPost, hongguoVideoModelPath, nil, nil)
	if err != nil || requests != 1 || registrations != 2 {
		t.Fatalf("registration retry did not recover: %v", err)
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

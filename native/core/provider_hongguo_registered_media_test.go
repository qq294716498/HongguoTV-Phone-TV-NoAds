package core

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

func TestHongguoSingleEpisodeRecoversAndKeepsRegisteredIdentity(t *testing.T) {
	var registrations, requests int
	d := sourceFixtureDownloader(t, func(r *http.Request) (*http.Response, error) {
		if r.URL.Path == "/service/2/device_register/" {
			registrations++
			return sourceFixtureResponse(r, 200, `{"device_id":"3456789012345678","install_id":"4567890123456789"}`), nil
		}
		requests++
		if requests == 1 {
			return sourceFixtureResponse(r, 200, ""), nil
		}
		if r.URL.Query().Get("device_id") != "3456789012345678" {
			t.Error("renewed device was not reused")
		}
		return sourceFixtureResponse(r, 200, `{"data":{"video_model":{"video_list":[{"main_url":"https://media.example.test/test.mp4","video_meta":{"definition":"1080p","codec_type":"h264"}}]}}}`), nil
	})
	searchFixtureIdentity(d)
	for range 2 {
		if _, err := d.resolveHongguoRegisteredMedia(context.Background(), "9001"); err != nil {
			t.Fatal(err)
		}
	}
	if registrations != 1 || requests != 3 {
		t.Fatalf("unexpected recovery counts %d/%d", registrations, requests)
	}
}

func TestHongguoConcurrentRejectedIdentityOnlyRegistersOnce(t *testing.T) {
	var registrations atomic.Int32
	d := sourceFixtureDownloader(t, func(r *http.Request) (*http.Response, error) {
		registrations.Add(1)
		return sourceFixtureResponse(r, 200, `{"device_id":"3456789012345678","install_id":"4567890123456789"}`), nil
	})
	searchFixtureIdentity(d)
	var group sync.WaitGroup
	for range 6 {
		group.Add(1)
		go func() {
			defer group.Done()
			identity, err := d.ensureHongguoDeviceIdentity(context.Background(), "1234567890123456")
			if err != nil || identity.DeviceID != "3456789012345678" {
				t.Errorf("shared renewal failed: %v", err)
			}
		}()
	}
	group.Wait()
	if registrations.Load() != 1 {
		t.Fatal("duplicate concurrent registrations", registrations.Load())
	}
}

func TestHongguoSingleEpisodeRotationBoundedAndRestrictionsStop(t *testing.T) {
	for _, status := range []int{200, 403, 429} {
		t.Run(fmt.Sprint(status), func(t *testing.T) {
			registrations, requests := 0, 0
			d := sourceFixtureDownloader(t, func(r *http.Request) (*http.Response, error) {
				if r.URL.Path == "/service/2/device_register/" {
					registrations++
					return sourceFixtureResponse(r, 200, fmt.Sprintf(`{"device_id":"%d","install_id":"%d"}`, 3456789012345678+registrations, 4567890123456789+registrations)), nil
				}
				requests++
				return sourceFixtureResponse(r, status, ""), nil
			})
			searchFixtureIdentity(d)
			d.cfg.Retries = 1
			_, err := d.resolveHongguoRegisteredMedia(context.Background(), "9001")
			if err == nil {
				t.Fatal("unexpected success")
			}
			if status == 200 {
				if registrations != 3 || requests != 5 || !errors.Is(err, errHongguoEmptyResponse) {
					t.Fatalf("unbounded empty recovery: %d/%d %v", registrations, requests, err)
				}
			} else if registrations != 0 || requests != 1 {
				t.Fatal("restriction retried", registrations, requests)
			}
		})
	}
}

func TestHongguoRotationBackoffPreservesEmptyResponseOnDeadline(t *testing.T) {
	requests := 0
	d := sourceFixtureDownloader(t, func(r *http.Request) (*http.Response, error) {
		if r.URL.Path == "/service/2/device_register/" {
			return sourceFixtureResponse(r, 200, `{"device_id":"3456789012345678","install_id":"4567890123456789"}`), nil
		}
		requests++
		return sourceFixtureResponse(r, 200, ""), nil
	})
	searchFixtureIdentity(d)
	ctx, cancel := context.WithTimeout(context.Background(), 150*time.Millisecond)
	defer cancel()
	_, err := d.resolveHongguoRegisteredMedia(ctx, "9001")
	if !errors.Is(err, errHongguoEmptyResponse) || !errors.Is(err, context.DeadlineExceeded) || requests != 1 {
		t.Fatalf("empty response or rotation backoff lost: requests=%d err=%v", requests, err)
	}
}

func TestHongguoRetryAfterEmptyIsNotEligibleForPlayerRecovery(t *testing.T) {
	d := sourceFixtureDownloader(t, func(r *http.Request) (*http.Response, error) {
		response := sourceFixtureResponse(r, 200, "")
		response.Header.Set("Retry-After", "120")
		return response, nil
	})
	searchFixtureIdentity(d)
	_, err := d.resolveHongguoRegisteredMedia(context.Background(), "9001")
	if err == nil || errors.Is(err, errHongguoEmptyResponse) {
		t.Fatalf("upstream retry instruction marked auto-retryable: %v", err)
	}
}

func TestHongguoCatalogAndDetailUseReferenceSignatureProfile(t *testing.T) {
	for _, path := range []string{"/reading/distribution/category/landpage/v/", "/novel/player/video_detail/v1/"} {
		t.Run(path, func(t *testing.T) {
			d := sourceFixtureDownloader(t, func(r *http.Request) (*http.Response, error) {
				if r.Header.Get("Cookie") != "" || r.Header.Get("X-Medusa") != "" || r.Header.Get("X-Helios") != "" {
					t.Fatal("mixed legacy and reference request profiles")
				}
				for _, name := range []string{"X-Gorgon", "X-Argus", "X-Ladon", "X-Khronos", "X-SS-STUB"} {
					if r.Header.Get(name) == "" {
						t.Fatal("missing reference signature", name)
					}
				}
				if r.URL.Query().Get("device_id") != "1234567890123456" {
					t.Fatal("registered device changed")
				}
				return sourceFixtureResponse(r, 200, `{"code":0}`), nil
			})
			searchFixtureIdentity(d)
			if _, err := d.hongguoAppRequest(context.Background(), http.MethodPost, path, nil, map[string]any{}); err != nil {
				t.Fatal(err)
			}
		})
	}
}

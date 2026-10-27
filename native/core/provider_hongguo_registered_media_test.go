package core

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"sync"
	"sync/atomic"
	"testing"
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

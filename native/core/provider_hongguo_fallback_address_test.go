package core

import (
	"context"
	"encoding/json"
	"net/http"
	"testing"
)

func TestHongguoFallbackAddressShapesReachValidatedSecondRequest(t *testing.T) {
	address := "https://api5-normal-sinfonlineb.fqnovel.com/video/fallback"
	for _, shape := range []any{address, []any{address}, map[string]any{"fallback_api": address}, `{"fallback_api":"` + address + `"}`} {
		calls := 0
		d := sourceFixtureDownloader(t, func(request *http.Request) (*http.Response, error) {
			calls++
			if request.URL.Path == hongguoVideoModelPath {
				body, _ := json.Marshal(map[string]any{"code": 0, "data": map[string]any{"9001": map[string]any{"video_model": map[string]any{"fallback_api": shape}}}})
				return sourceFixtureResponse(request, http.StatusOK, string(body)), nil
			}
			if request.URL.String() != address || request.Header.Get("X-Medusa") != "" {
				t.Fatal("fallback changed address or forwarded signature")
			}
			return sourceFixtureResponse(request, http.StatusOK, `{"video_info":{"data":{"video_list":[{"main_url":"https://media.example.test/episode.mp4","video_meta":{"codec_type":"h264","definition":"720p"}}]}}}`), nil
		})
		media, err := d.resolveHongguoAppMedia(context.Background(), "9001")
		if err != nil || media.URL == "" || calls != 2 {
			t.Fatalf("fallback shape %T failed: calls=%d err=%v", shape, calls, err)
		}
	}
}

func TestHongguoFallbackRejectsUntrustedAddress(t *testing.T) {
	calls := 0
	d := sourceFixtureDownloader(t, func(request *http.Request) (*http.Response, error) {
		calls++
		return sourceFixtureResponse(request, http.StatusOK, `{"data":{"9001":{"video_model":{"fallback_api":["https://untrusted.example.test/video"]}}}}`), nil
	})
	if _, err := d.resolveHongguoAppMedia(context.Background(), "9001"); err == nil || calls != 1 {
		t.Fatal("untrusted fallback escaped validation")
	}
}

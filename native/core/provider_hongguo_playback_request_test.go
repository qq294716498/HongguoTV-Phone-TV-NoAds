package core

import (
	"context"
	"io"
	"net/http"
	"strings"
	"testing"
	"time"
)

func TestHongguoPlaybackQueryMatchesReferenceOrderAndEncoding(t *testing.T) {
	identity := hongguoDeviceIdentity{DeviceID: "1000000000000001", InstallID: "1000000000000002"}
	want := "ac=wifi&channel=update_64&aid=8662&app_name=novelread&version_code=71332&version_name=7.1.3.32&device_platform=android&os=android&ssmix=a&device_type=25053RT47C&device_brand=Redmi&language=zh&os_api=36&os_version=16&manifest_version_code=71332&resolution=1280%2A2772&dpi=520&update_version_code=71332&host_abi=arm64-v8a&dragon_device_type=phone&pv_player=71332&compliance_status=0&need_personal_recommend=1&player_so_load=1&is_android_pad_screen=0&iid=1000000000000002&device_id=1000000000000001&ts=1800000000&_rticket=1800000000000"
	if got := hongguoPlaybackQuery(identity, 1800000000, 1800000000000); got != want {
		t.Fatalf("reference query differs: %s", got)
	}
}

func TestHongguoPlaybackBypassesRegistrationAndSignatureCache(t *testing.T) {
	var lastDevice, lastSignature string
	d := sourceFixtureDownloader(t, func(r *http.Request) (*http.Response, error) {
		if r.URL.Path != hongguoVideoModelPath {
			t.Fatalf("playback attempted registration or another route: %s", r.URL.Path)
		}
		if r.Header.Get("Cookie") != "" {
			t.Fatal("playback sent a registration cookie")
		}
		if !strings.HasPrefix(r.URL.RawQuery, "ac=wifi&channel=update_64&aid=8662") {
			t.Fatal("signature preparation reordered the reference query")
		}
		if r.URL.Query().Get("ts") != r.Header.Get("X-Khronos") || r.URL.Query().Get("_rticket") != r.Header.Get("X-SS-Req-Ticket") {
			t.Fatal("signature timestamps do not match the sent query")
		}
		body, _ := io.ReadAll(r.Body)
		want := `{"biz_param":{"detail_page_version":0,"device_level":3,"disable_digg_stat":false,"need_all_video_definition":true,"need_mp4_align":false,"use_os_player":false,"use_server_dns":false,"video_platform":1024},"mixed_video_id_map":{"1004":["9001"]}}`
		if string(body) != want {
			t.Fatal("playback body differs from reference")
		}
		device, signature := r.URL.Query().Get("device_id"), r.Header.Get("X-Medusa")
		if device == "" || signature == "" || device == lastDevice || signature == lastSignature {
			t.Fatal("independent playback request reused identity or signature")
		}
		lastDevice, lastSignature = device, signature
		return sourceFixtureResponse(r, 200, hongguoRetryModelFixture), nil
	}, false)
	for range 2 {
		if _, err := d.resolveHongguoAppMedia(context.Background(), "9001"); err != nil {
			t.Fatal(err)
		}
	}
	status := d.hongguoClient().signatureSnapshot()
	if status.Generated != 2 || status.Reused != 0 || len(d.hongguoClient().signatures) != 0 {
		t.Fatal("playback used signature cache")
	}
}

func TestHongguoPlaybackBranchSelectionPreservesReferenceQuery(t *testing.T) {
	var identities [32]hongguoDeviceIdentity
	for i := range identities {
		identities[i] = hongguoDeviceIdentity{DeviceID: "1000000000000001", InstallID: "1000000000000002"}
	}
	client := &hongguoAppClient{}
	for second := int64(1800000000); second < 1800000032; second++ {
		r, _ := http.NewRequest(http.MethodPost, "https://api5-normal-sinfonlineb.fqnovel.com"+hongguoVideoModelPath, nil)
		client.preparePlaybackSignature(r, []byte("{}"), time.Unix(second, 0), identities)
		if hgBranchOf(r.URL.String(), []byte("{}"), uint32(second)) == 1 || !strings.HasPrefix(r.URL.RawQuery, "ac=wifi&channel=") {
			t.Fatal("reference branch selection failed")
		}
	}
}

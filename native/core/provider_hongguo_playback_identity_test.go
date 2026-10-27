package core

import (
	"context"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"testing"
)

func TestHongguoPlaybackIdentityRotatesWithoutChangingRegistration(t *testing.T) {
	var identities [][2]string
	d := sourceFixtureDownloader(t, func(r *http.Request) (*http.Response, error) {
		identities = append(identities, [2]string{r.URL.Query().Get("device_id"), r.URL.Query().Get("iid")})
		if r.Header.Get("Cookie") != "" {
			t.Fatal("playback forwarded registration cookies")
		}
		return sourceFixtureResponse(r, 200, hongguoRetryModelFixture), nil
	})
	d.cfg.dataDir = t.TempDir()
	d.hongguoClient().deviceIdentityPersisted = false
	registered, err := d.ensureHongguoDeviceIdentity(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(d.cfg.dataDir, "hongguo-device.json")
	before, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	for attempt := 0; attempt < 2; attempt++ {
		if _, err := d.resolveHongguoAppMedia(context.Background(), "9001"); err != nil {
			t.Fatal(err)
		}
	}
	if len(identities) != 2 || identities[0] == identities[1] {
		t.Fatal("independent playback requests reused temporary identity")
	}
	for _, identity := range identities {
		for _, raw := range identity {
			value, err := strconv.ParseUint(raw, 10, 64)
			if err != nil || value < 1_000_000_000_000_000 || value >= 1_000_000_000_000_000+(1<<48) {
				t.Fatal("temporary identity does not match upstream localId range")
			}
		}
	}
	after, err := os.ReadFile(path)
	if err != nil || string(before) != string(after) {
		t.Fatal("playback overwrote persisted registration")
	}
	current, err := d.ensureHongguoDeviceIdentity(context.Background())
	if err != nil || current != registered {
		t.Fatal("playback changed in-memory registration")
	}
}

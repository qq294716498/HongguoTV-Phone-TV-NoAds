package core

import (
	"context"
	"os"
	"testing"
	"time"
)

func TestLiveHongguoTemporaryPlaybackIdentity(t *testing.T) {
	if os.Getenv("HG_REGISTERED_PLAYBACK_LIVE") != "1" {
		t.Skip("set HG_REGISTERED_PLAYBACK_LIVE=1 for temporary identity metadata-only playback validation")
	}
	engine, err := newNativeEngine(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(engine.downloads.close)
	d := engine.downloader
	ctx, cancel := context.WithTimeout(context.Background(), 45*time.Second)
	defer cancel()
	identity, err := d.ensureHongguoDeviceIdentity(ctx)
	if err != nil {
		t.Fatalf("registration failed: %v", err)
	}
	for attempt := 0; attempt < 2; attempt++ {
		media, err := d.resolveHongguoAppMedia(ctx, "7693917197759958040")
		if err != nil || media.URL == "" {
			t.Fatalf("registered playback metadata attempt %d failed: %v", attempt+1, err)
		}
		after, err := d.ensureHongguoDeviceIdentity(ctx)
		if err != nil || after != identity {
			t.Fatal("playback changed registered identity")
		}
		t.Logf("attempt=%d quality=%d variants=%d", attempt+1, media.Quality, len(media.Variants))
	}
	state := d.hongguoClient().signatureSnapshot()
	t.Logf("generated=%d reused=%d refreshed=%d", state.Generated, state.Reused, state.Refreshed)
}

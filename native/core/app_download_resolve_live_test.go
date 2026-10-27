package core

import (
	"context"
	"os"
	"testing"
	"time"
)

func TestLiveHongguoDownloadRouteBatch(t *testing.T) {
	if os.Getenv("HG_DOWNLOAD_RESOLVE_LIVE") != "1" {
		t.Skip("set HG_DOWNLOAD_RESOLVE_LIVE=1 for four metadata-only download resolutions")
	}
	engine, err := newNativeEngine(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(engine.downloads.close)
	ctx, cancel := context.WithTimeout(context.Background(), 4*time.Minute)
	defer cancel()
	drama := nativeDrama{ID: "hongguo:7676383631534722073", Source: sourceHongguo}
	videos := []string{"7676396922176801817", "7676396783676705817", "7676396887611542553", "7676396911569407001"}
	chapters := make([]Chapter, len(videos))
	for i, video := range videos {
		chapters[i] = Chapter{Source: sourceHongguo, VideoURL: "hongguo-cenc://" + video}
	}
	failures := 0
	for index, chapter := range chapters {
		t.Logf("series=%s episode=%d video=%s", drama.ID, index+1, chapter.VideoURL)
		start := time.Now()
		media, err := engine.downloads.resolveDownloadMedia(ctx, nativeDownloadJob{Drama: nativeDrama{ID: drama.ID, Source: sourceHongguo}, Chapter: chapter, Index: index + 1})
		if err != nil || media.URL == "" {
			failures++
			t.Logf("download resolution episode=%d failed: %v", index+1, err)
			continue
		}
		t.Logf("episode=%d quality=%d variants=%d elapsedMs=%d", index+1, media.Quality, len(media.Variants), time.Since(start).Milliseconds())
	}
	if failures > 0 {
		t.Fatalf("%d of 4 target episodes failed metadata resolution", failures)
	}
}

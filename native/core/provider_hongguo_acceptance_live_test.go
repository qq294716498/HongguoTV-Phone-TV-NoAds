package core

import (
	"context"
	"encoding/hex"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestLiveHongguoPlaybackAndOfflineDownloads(t *testing.T) {
	if os.Getenv("HG_PLAYBACK_DOWNLOAD_ACCEPTANCE") != "1" {
		t.Skip("explicit upstream playback and complete download acceptance")
	}
	ffmpeg, err := exec.LookPath("ffmpeg")
	if err != nil {
		t.Fatal(err)
	}
	engine, err := newNativeEngine(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(engine.downloads.close)
	stream, err := newNativeStreamServer(engine.downloader)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		stream.server.Close()
		stream.mu.Lock()
		defer stream.mu.Unlock()
		for _, s := range stream.sessions {
			s.cancel()
		}
	})
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Minute)
	defer cancel()
	videos := []string{"7676396922176801817", "7676396783676705817", "7676396887611542553", "7676396911569407001"}
	if selected := os.Getenv("HG_ACCEPTANCE_VIDEOS"); selected != "" {
		videos = strings.Split(selected, ",")
	}
	series := os.Getenv("HG_ACCEPTANCE_SERIES")
	if series == "" {
		series = "7676383631534722073"
	}
	if !hongguoNumericID.MatchString(series) {
		t.Fatal("invalid series ID")
	}
	for i, video := range videos {
		t.Run(video, func(t *testing.T) {
			if !hongguoNumericID.MatchString(video) {
				t.Fatal("invalid video ID")
			}
			job := nativeDownloadJob{ID: fmt.Sprintf("acceptance-%d", i), Drama: nativeDrama{ID: "hongguo:" + series, Source: sourceHongguo}, Chapter: Chapter{Source: sourceHongguo, VideoURL: "hongguo-cenc://" + video}, Index: i + 1, Quality: 1080}
			media, err := engine.downloads.resolveDownloadMedia(ctx, job)
			if err != nil {
				t.Fatal(err)
			}
			address, _ := stream.nativeOpen(media)
			decode := func(label, address, key string) {
				t.Helper()
				stage, stop := context.WithTimeout(ctx, 2*time.Minute)
				defer stop()
				args := []string{"-v", "error", "-xerror", "-threads", "2"}
				if key != "" {
					args = append(args, "-decryption_key", key)
				}
				args = append(args, "-i", address, "-t", "8", "-map", "0:v:0", "-map", "0:a:0?", "-f", "null", "-")
				output, err := exec.CommandContext(stage, ffmpeg, args...).CombinedOutput()
				if err != nil {
					t.Fatalf("%s decode failed: %v (diagnostic bytes=%d)", label, err, len(output))
				}
				t.Logf("%s audio/video decode passed", label)
			}
			decode("Windows encrypted stream", address, hex.EncodeToString(media.CENCKey))
			decode("Android clear stream", address+"?cenc=clear", "")
			result, err := engine.downloads.transferMedia(ctx, job, media)
			if err != nil {
				t.Fatal(err)
			}
			local := filepath.Join(engine.downloads.jobDirectory(job), result.file)
			stat, err := os.Stat(local)
			if err != nil || stat.Size() == 0 {
				t.Fatal("empty download", err)
			}
			decode("offline downloaded file", local, result.key)
			t.Logf("complete download bytes=%d quality=%d variants=%d", stat.Size(), media.Quality, len(media.Variants))
		})
	}
}

func TestLiveHongguoContinuousPlaybackWithDownload(t *testing.T) {
	if os.Getenv("HG_SMOOTH_PLAYBACK_ACCEPTANCE") != "1" {
		t.Skip("explicit sustained upstream playback acceptance")
	}
	ffmpeg, err := exec.LookPath("ffmpeg")
	if err != nil {
		t.Fatal(err)
	}
	engine, err := newNativeEngine(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(engine.downloads.close)
	ctx, cancel := context.WithTimeout(context.Background(), 4*time.Minute)
	defer cancel()
	job := nativeDownloadJob{ID: "concurrent-download", Drama: nativeDrama{ID: "hongguo:7676383631534722073", Source: sourceHongguo}, Chapter: Chapter{Source: sourceHongguo, VideoURL: "hongguo-cenc://7676396922176801817"}, Index: 1, Quality: 1080}
	media, err := engine.downloads.resolveDownloadMedia(ctx, job)
	if err != nil {
		t.Fatal(err)
	}
	stream, err := newNativeStreamServer(engine.downloader)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		stream.server.Close()
		stream.mu.Lock()
		defer stream.mu.Unlock()
		for _, s := range stream.sessions {
			s.cancel()
		}
	})
	address, _ := stream.nativeOpen(media)
	completed := make(chan error, 1)
	go func() { _, err := engine.downloads.transferMedia(ctx, job, media); completed <- err }()
	start := time.Now()
	args := []string{"-v", "error", "-xerror", "-threads", "2", "-re", "-decryption_key", hex.EncodeToString(media.CENCKey), "-i", address, "-t", "45", "-map", "0:v:0", "-map", "0:a:0?", "-progress", "pipe:1", "-f", "null", "-"}
	output, err := exec.CommandContext(ctx, ffmpeg, args...).CombinedOutput()
	elapsed := time.Since(start)
	if err != nil || !strings.Contains(string(output), "progress=end") || elapsed > 65*time.Second {
		t.Fatalf("continuous playback failed: %v elapsed=%v outputBytes=%d", err, elapsed, len(output))
	}
	if err := <-completed; err != nil {
		t.Fatal("concurrent download", err)
	}
	t.Logf("45-second real-time playback with concurrent complete download passed in %s", elapsed.Round(time.Millisecond))
	start = time.Now()
	output, err = exec.CommandContext(ctx, ffmpeg, "-v", "error", "-xerror", "-threads", "2", "-ss", "30", "-i", address+"?cenc=clear", "-t", "8", "-f", "null", "-").CombinedOutput()
	if err != nil {
		t.Fatalf("seek decode failed: %v outputBytes=%d", err, len(output))
	}
	t.Logf("seek to 30 seconds and decode 8 seconds passed in %s", time.Since(start).Round(time.Millisecond))
}

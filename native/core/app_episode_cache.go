package core

import (
	"bytes"
	"context"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

type nativeEpisodeCache struct {
	mu              sync.Mutex
	plan            nativePlan
	manager         *nativeDownloads
	job             nativeDownloadJob
	entryID         string
	entry           string
	directory       string
	files           map[string]int64
	decoder         *nativeStreamSession
	online          bool
	session         *nativeStreamSession
	stream          *nativeStreamServer
	mediaURL        string
	startupHLS      bool
	startupRequired map[string]bool
	startupTargets  map[string]bool
	startupIndex    bool
	startupWorkers  sync.WaitGroup
	paused          bool
	pauseChanged    chan struct{}
	workSequence    uint64
	works           map[uint64]nativeEpisodeWork
}

func (engine *nativeEngine) startEpisodeCache(input nativeInput, plan nativePlan, choice nativePlaybackChoice, stream *nativeStreamServer) error {
	stream.mu.Lock()
	session := stream.sessions[choice.streamSession]
	stream.mu.Unlock()
	if session == nil {
		return errors.New("预缓冲播放会话已失效")
	}
	root, err := os.MkdirTemp(engine.directory, "playback-cache-")
	if err != nil {
		return errors.New("无法创建整集缓冲文件，请检查剩余存储空间")
	}
	job := nativeDownloadJob{ID: "next", Drama: input.Drama, Chapter: input.Chapter, Index: input.Index, Quality: input.Quality, State: "downloading"}
	manager := &nativeDownloads{root: root, engine: engine, jobs: map[string]*nativeDownloadRecord{job.ID: {nativeDownloadJob: job}}}
	parsed, _ := url.Parse(plan.URL)
	cache := &nativeEpisodeCache{plan: plan, manager: manager, job: job, entryID: filepath.Base(parsed.Path), directory: manager.jobDirectory(job), session: session, stream: stream, mediaURL: choice.media[choice.index].URL}
	cache.plan.PreloadState = "caching"
	session.mu.Lock()
	session.preload = cache
	session.mu.Unlock()
	go func() {
		defer os.RemoveAll(root)
		cache.run(session.ctx, input, choice.media[choice.index], stream)
		<-session.ctx.Done()
		cache.startupWorkers.Wait()
	}()
	return nil
}

func (engine *nativeEngine) nativePreloadStatus(id string) (nativePlan, error) {
	engine.mu.Lock()
	choice, exists := engine.playbacks[id]
	stream := engine.stream
	engine.mu.Unlock()
	if !exists || stream == nil {
		return nativePlan{}, errors.New("预缓冲会话已失效")
	}
	stream.mu.Lock()
	session := stream.sessions[choice.streamSession]
	if session != nil {
		session.lastUsed = time.Now()
	}
	stream.mu.Unlock()
	if session == nil {
		return nativePlan{}, errors.New("预缓冲会话已结束")
	}
	session.mu.Lock()
	cache := session.preload
	session.mu.Unlock()
	if cache == nil {
		return nativePlan{}, errors.New("未启动整集缓冲")
	}
	cache.mu.Lock()
	plan := cache.plan
	cache.mu.Unlock()
	if !plan.PreloadComplete {
		cache.manager.mu.Lock()
		record := cache.manager.jobs[cache.job.ID]
		plan.PrefetchedBytes, plan.PreloadTotal = record.Bytes, record.Total
		plan.PreloadProgress = min(record.Progress, .99)
		cache.manager.mu.Unlock()
	}
	return plan, nil
}

func (cache *nativeEpisodeCache) run(ctx context.Context, input nativeInput, media providerMedia, stream *nativeStreamServer) {
	ctx = context.WithValue(ctx, backgroundCatalogKey{}, true)
	ctx = context.WithValue(ctx, nativePreloadKey{}, true)
	ctx = context.WithValue(ctx, nativeStartupCacheKey{}, cache)
	forceHLS := false
	attempt, refreshedAttempt := 0, -1
	for ctx.Err() == nil {
		work, finish, err := cache.beginWork(ctx, true)
		if err != nil {
			return
		}
		cache.mu.Lock()
		if !cache.paused {
			cache.plan.PreloadState = "caching"
			cache.plan.PreloadError = ""
		}
		cache.mu.Unlock()
		err = work.Err()
		if err == nil && attempt > 0 && attempt%3 == 0 && refreshedAttempt != attempt {
			fresh, resolveErr := cache.manager.engine.downloader.resolveProviderMedia(work, Task{DramaID: input.Drama.ID, DramaTitle: input.Drama.Title, Chapter: input.Chapter, Index: input.Index})
			if resolveErr == nil {
				choices := nativePlaybackChoices(fresh, input.Quality)
				if len(choices.media) > 0 {
					candidate := choices.media[0]
					if !bytes.Equal(candidate.CENCKey, media.CENCKey) || !bytes.Equal(candidate.HLSKey, media.HLSKey) || candidate.Quality != media.Quality {
						err = errors.New("刷新地址的媒体参数已变化，等待重新确认")
					} else {
						media = candidate
					}
				}
			} else {
				err = resolveErr
			}
			if err == nil {
				refreshedAttempt = attempt
			}
		}
		var result nativeDownloadResult
		if err == nil {
			result, err = cache.manager.transferMedia(context.WithValue(work, nativeDownloadHLSKey{}, forceHLS), cache.job, media)
		}
		if err == nil && result.file == "media.mp4" && len(media.CENCKey) == 0 {
			file, openErr := os.Open(filepath.Join(cache.directory, result.file))
			if openErr != nil {
				err = openErr
			} else {
				prefix, readErr := io.ReadAll(io.LimitReader(file, 512))
				file.Close()
				if readErr != nil {
					err = readErr
				} else if bytes.HasPrefix(bytes.TrimSpace(bytes.TrimPrefix(prefix, []byte("\xef\xbb\xbf"))), []byte("#EXTM3U")) {
					forceHLS = true
					result, err = cache.manager.transferMedia(context.WithValue(work, nativeDownloadHLSKey{}, true), cache.job, media)
				}
			}
		}
		if err == nil {
			cache.mu.Lock()
			if !cache.paused {
				cache.plan.PreloadState = "verifying"
			}
			cache.mu.Unlock()
			err = cache.verify(work, result, stream)
		}
		cause := context.Cause(work)
		finish()
		if err == nil || ctx.Err() != nil {
			return
		}
		if errors.Is(cause, errNativePreloadPaused) {
			continue
		}
		cache.mu.Lock()
		if !cache.paused {
			cache.plan.PreloadState = "retrying"
			cache.plan.PreloadError = publicError(err).Error()
		}
		cache.mu.Unlock()
		delay := time.Duration(min(30, 3<<min(attempt, 4))) * time.Second
		attempt++
		if !cache.waitRetry(ctx, delay) {
			return
		}
	}
}

func (cache *nativeEpisodeCache) verify(ctx context.Context, result nativeDownloadResult, stream *nativeStreamServer) error {
	cache.manager.mu.Lock()
	record := *cache.manager.jobs[cache.job.ID]
	cache.manager.mu.Unlock()
	record.File = result.file
	if !cache.manager.localFilesValid(record) {
		return errNativeLocalFile
	}
	entries, err := os.ReadDir(cache.directory)
	if err != nil {
		return err
	}
	files := map[string]int64{}
	resources := map[string]nativeDownloadFileState{}
	var total int64
	for _, entry := range entries {
		if err := ctx.Err(); err != nil {
			return err
		}
		name := entry.Name()
		if entry.IsDir() || strings.HasPrefix(name, ".") || strings.HasSuffix(name, ".json") || strings.HasSuffix(name, ".part") {
			continue
		}
		info, err := entry.Info()
		if err != nil || !info.Mode().IsRegular() || info.Size() <= 0 {
			return errNativeLocalFile
		}
		if strings.HasSuffix(name, ".key") && info.Size() != 16 {
			return errors.New("缓冲的视频密钥不完整")
		}
		metadata, readErr := os.ReadFile(filepath.Join(cache.directory, name) + ".json")
		if readErr == nil {
			var state nativeDownloadFileState
			if json.Unmarshal(metadata, &state) != nil || !state.Complete || state.Total != info.Size() {
				return errNativeLocalFile
			}
			resources[name] = state
		} else if !os.IsNotExist(readErr) || name == "media.mp4" {
			return errNativeLocalFile
		}
		files[name] = info.Size()
		total += info.Size()
	}
	decoder := &nativeStreamSession{}
	if result.key != "" {
		decoder.cencKey, err = hex.DecodeString(result.key)
		if err != nil || len(decoder.cencKey) != 16 {
			return errors.New("缓冲的 CENC 密钥无效")
		}
		_, err = stream.nativeCENCIndex(ctx, decoder, nativeStreamAsset{address: filepath.Join(cache.directory, result.file)})
		if err != nil {
			return err
		}
	}
	if err := ctx.Err(); err != nil {
		return err
	}
	cache.publishCompletedResources(resources)
	cache.mu.Lock()
	cache.entry, cache.files, cache.decoder = result.file, files, decoder
	cache.plan.PreloadComplete = true
	cache.plan.StartupReady = true
	if strings.HasSuffix(result.file, ".m3u8") {
		cache.plan.MediaType = "hls"
	}
	cache.plan.PreloadProgress = 1
	cache.plan.PrefetchedBytes, cache.plan.PreloadTotal = total, total
	cache.plan.PreloadState, cache.plan.PreloadError = "complete", ""
	cache.plan.Quality = result.quality
	cache.plan.ExpiresAt = 0
	cache.plan.Key = result.key
	if parsed, err := url.Parse(cache.plan.URL); err == nil && parsed.Query().Get("cenc") == "clear" {
		cache.plan.Key = ""
	}
	cache.mu.Unlock()
	return nil
}

func (stream *nativeStreamServer) nativeServeEpisodeCache(writer http.ResponseWriter, request *http.Request, session *nativeStreamSession, parts []string) bool {
	session.mu.Lock()
	cache := session.preload
	session.mu.Unlock()
	if cache == nil {
		return false
	}
	cache.mu.Lock()
	complete, entry, decoder, files := cache.plan.PreloadComplete, cache.entry, cache.decoder, cache.files
	if !complete && len(parts) == 2 && parts[1] == cache.entryID {
		cache.online = true
	}
	online := cache.online
	cache.mu.Unlock()
	if !complete || online || len(parts) == 2 && parts[1] != cache.entryID {
		return false
	}
	name := entry
	if len(parts) == 3 {
		name = parts[2]
	}
	size, found := files[name]
	if !found {
		http.NotFound(writer, request)
		return true
	}
	file, err := os.Open(filepath.Join(cache.directory, name))
	if err != nil {
		http.Error(writer, "整集缓冲文件已丢失", http.StatusGone)
		return true
	}
	defer file.Close()
	info, err := file.Stat()
	if err != nil || info.Size() != size {
		http.Error(writer, "整集缓冲文件不完整", http.StatusGone)
		return true
	}
	ctx, cancel := context.WithCancel(request.Context())
	defer cancel()
	stop := context.AfterFunc(session.ctx, cancel)
	defer stop()
	writer.Header().Set("Cache-Control", "no-store")
	if request.URL.Query().Get("cenc") == "clear" {
		stream.nativeServeCENC(writer, request, decoder, nativeStreamAsset{address: file.Name()}, ctx)
		return true
	}
	if strings.HasSuffix(name, ".m3u8") {
		body, err := os.ReadFile(file.Name())
		if err != nil {
			http.Error(writer, "无法读取已缓冲播放列表", http.StatusGone)
			return true
		}
		lines := strings.Split(string(body), "\n")
		prefix := stream.address + "/" + parts[0] + "/cached/"
		for index, line := range lines {
			if line != "" && !strings.HasPrefix(line, "#") {
				lines[index] = prefix + line
			} else {
				lines[index] = nativePlaylistURI.ReplaceAllString(line, "URI=\""+prefix+"${1}\"")
			}
		}
		writer.Header().Set("Content-Type", "application/vnd.apple.mpegurl")
		http.ServeContent(writer, request.WithContext(ctx), name, time.Time{}, bytes.NewReader([]byte(strings.Join(lines, "\n"))))
		return true
	}
	http.ServeContent(writer, request.WithContext(ctx), name, time.Time{}, file)
	return true
}

package core

import (
	"context"
	"errors"
	"strings"
	"sync"
	"time"
)

var errNativePreloadPaused = errors.New("下一集预取已暂停")

type nativeEpisodeWork struct {
	cancel context.CancelCauseFunc
	done   chan struct{}
	wait   bool
}

func (cache *nativeEpisodeCache) pauseSignalLocked() chan struct{} {
	if cache.pauseChanged == nil {
		cache.pauseChanged = make(chan struct{})
	}
	return cache.pauseChanged
}

func (cache *nativeEpisodeCache) beginWork(parent context.Context, wait bool) (context.Context, func(), error) {
	for {
		cache.mu.Lock()
		if err := parent.Err(); err != nil {
			cache.mu.Unlock()
			return nil, nil, err
		}
		if err := cache.session.ctx.Err(); err != nil {
			cache.mu.Unlock()
			return nil, nil, err
		}
		if cache.paused {
			signal := cache.pauseSignalLocked()
			cache.mu.Unlock()
			select {
			case <-parent.Done():
				return nil, nil, parent.Err()
			case <-cache.session.ctx.Done():
				return nil, nil, cache.session.ctx.Err()
			case <-signal:
			}
			continue
		}
		ctx, cancel := context.WithCancelCause(parent)
		stop := context.AfterFunc(cache.session.ctx, func() { cancel(context.Canceled) })
		cache.workSequence++
		id := cache.workSequence
		work := nativeEpisodeWork{cancel: cancel, done: make(chan struct{}), wait: wait}
		if cache.works == nil {
			cache.works = make(map[uint64]nativeEpisodeWork)
		}
		cache.works[id] = work
		cache.mu.Unlock()
		var once sync.Once
		finish := func() {
			once.Do(func() {
				stop()
				cancel(context.Canceled)
				cache.mu.Lock()
				delete(cache.works, id)
				close(work.done)
				cache.mu.Unlock()
			})
		}
		return context.WithValue(ctx, nativeStartupCacheKey{}, cache), finish, nil
	}
}

func (cache *nativeEpisodeCache) setPaused(ctx context.Context, paused bool) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	cache.mu.Lock()
	if cache.session.ctx.Err() != nil {
		cache.mu.Unlock()
		return errors.New("预缓冲会话已结束")
	}
	if cache.paused != paused {
		cache.paused = paused
		signal := cache.pauseSignalLocked()
		cache.pauseChanged = make(chan struct{})
		close(signal)
	}
	if !cache.plan.PreloadComplete {
		if paused {
			cache.plan.PreloadState, cache.plan.PreloadError = "paused", ""
		} else if cache.plan.PreloadState == "paused" {
			cache.plan.PreloadState = "caching"
		}
	}
	var works []nativeEpisodeWork
	if paused {
		for _, work := range cache.works {
			works = append(works, work)
		}
	}
	cache.mu.Unlock()
	for _, work := range works {
		work.cancel(errNativePreloadPaused)
	}
	for _, work := range works {
		if work.wait {
			select {
			case <-ctx.Done():
				return ctx.Err()
			case <-work.done:
			}
		}
	}
	return nil
}

func (cache *nativeEpisodeCache) waitRetry(ctx context.Context, remaining time.Duration) bool {
	for remaining > 0 {
		cache.mu.Lock()
		paused := cache.paused
		signal := cache.pauseSignalLocked()
		cache.mu.Unlock()
		if paused {
			select {
			case <-ctx.Done():
				return false
			case <-signal:
			}
			continue
		}
		timer := time.NewTimer(remaining)
		start := time.Now()
		select {
		case <-ctx.Done():
			timer.Stop()
			return false
		case <-timer.C:
			return true
		case <-signal:
			timer.Stop()
			remaining -= time.Since(start)
		}
	}
	return ctx.Err() == nil
}

func (engine *nativeEngine) nativeSetPreloadPaused(ctx context.Context, input nativeInput) (nativePlan, error) {
	if err := ctx.Err(); err != nil {
		return nativePlan{}, err
	}
	if input.Paused == nil || strings.TrimSpace(input.PlaybackSession) == "" {
		return nativePlan{}, errors.New("预取控制请求无效")
	}
	engine.mu.Lock()
	choice, found := engine.playbacks[input.PlaybackSession]
	stream := engine.stream
	engine.mu.Unlock()
	if !found || stream == nil {
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
	if cache == nil || cache.job.Drama.ID != input.Drama.ID ||
		sourceFromDramaID(cache.job.Drama.ID) != sourceFromDramaID(input.Drama.ID) ||
		input.Drama.Source != "" && canonicalProviderSource(input.Drama.Source) != sourceFromDramaID(cache.job.Drama.ID) {
		return nativePlan{}, errors.New("预取控制会话不匹配")
	}
	if err := cache.setPaused(ctx, *input.Paused); err != nil {
		return nativePlan{}, err
	}
	return engine.nativePreloadStatus(input.PlaybackSession)
}

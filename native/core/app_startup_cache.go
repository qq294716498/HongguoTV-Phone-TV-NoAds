package core

import (
	"bytes"
	"context"
	"errors"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
)

type nativeStartupCacheKey struct{}

type nativeStartupPlaylist struct {
	address string
	base    string
	data    []byte
}

func nativeStartupCache(ctx context.Context) *nativeEpisodeCache {
	cache, _ := ctx.Value(nativeStartupCacheKey{}).(*nativeEpisodeCache)
	return cache
}

func (cache *nativeEpisodeCache) prepareStartup(bundle *nativeDownloadBundle, hls bool) {
	cache.mu.Lock()
	cache.startupHLS = hls
	if hls {
		cache.plan.MediaType = "hls"
		cache.startupRequired = make(map[string]bool, len(bundle.startup))
		cache.startupTargets = bundle.startup
		for _, playlist := range bundle.sources {
			cache.startupRequired[playlist.address] = true
		}
		for address := range bundle.startup {
			cache.startupRequired[address] = true
		}
	}
	cache.mu.Unlock()
	for _, playlist := range bundle.sources {
		cache.publishStartup(nativeStreamAsset{address: playlist.address, base: playlist.base, data: playlist.data, total: int64(len(playlist.data)), contentType: "application/vnd.apple.mpegurl"}, true, false)
	}
	if hls {
		ordered := make([]nativeDownloadAsset, 0, len(bundle.assets))
		for _, asset := range bundle.assets {
			if bundle.startup[asset.address] {
				ordered = append(ordered, asset)
			}
		}
		for _, asset := range bundle.assets {
			if !bundle.startup[asset.address] {
				ordered = append(ordered, asset)
			}
		}
		bundle.assets = ordered
	}
}

func (cache *nativeEpisodeCache) publishStartupFile(address, target string, metadata nativeDownloadFileState, header http.Header, received int64, complete, key bool) {
	if received <= 0 || !complete && metadata.Total <= 0 || cache.session.ctx.Err() != nil {
		return
	}
	cache.mu.Lock()
	needed := !cache.startupHLS || cache.startupTargets[address]
	cache.mu.Unlock()
	if !needed {
		return
	}
	cache.session.mu.Lock()
	previous := cache.session.startup[address]
	remaining := int64(nativePreloadLimit) - cache.session.startupBytes + int64(len(previous.data))
	cache.session.mu.Unlock()
	length := min(received, remaining)
	if length <= 0 || length <= int64(len(previous.data)) && !(complete && length == received && length == int64(len(previous.data))) || (!complete && length < 64<<10) {
		return
	}
	if !complete && length < remaining && length < max(64<<10, int64(len(previous.data))*4) {
		return
	}
	if length < metadata.Total && metadata.Validator == "" || key && (!complete || received != 16) {
		return
	}
	file, err := os.Open(target)
	if err != nil {
		return
	}
	data, err := io.ReadAll(io.LimitReader(file, length))
	file.Close()
	if err != nil || int64(len(data)) != length {
		return
	}
	asset := nativeStreamAsset{address: address, data: data, total: metadata.Total, contentType: header.Get("Content-Type"), etag: header.Get("ETag"), modified: header.Get("Last-Modified")}
	if asset.total <= 0 && complete {
		asset.total = received
	}
	if bytes.HasPrefix(bytes.TrimSpace(bytes.TrimPrefix(data, []byte("\xef\xbb\xbf"))), []byte("#EXTM3U")) {
		return
	}
	if key {
		asset.contentType = "application/octet-stream"
	}
	cache.publishStartup(asset, complete && length == received, key)
}

func (cache *nativeEpisodeCache) publishStartup(asset nativeStreamAsset, complete, key bool) {
	if len(asset.data) == 0 || cache.session.ctx.Err() != nil {
		return
	}
	session := cache.session
	session.mu.Lock()
	previous, exists := session.startup[asset.address]
	if session.onlineAssets[asset.address] || session.startupBytes-int64(len(previous.data))+int64(len(asset.data)) > nativePreloadLimit ||
		exists && (asset.total != previous.total || asset.validator() != previous.validator() || len(asset.data) < len(previous.data) || !bytes.Equal(previous.data, asset.data[:len(previous.data)])) {
		session.mu.Unlock()
		return
	}
	if session.startup == nil {
		session.startup = map[string]nativeStreamAsset{}
	}
	session.startup[asset.address] = asset
	session.startupBytes += int64(len(asset.data)) - int64(len(previous.data))
	for id, current := range session.assets {
		if current.address == asset.address {
			if asset.contentType == "" {
				asset.contentType = current.contentType
			}
			session.assets[id] = asset
		}
	}
	session.mu.Unlock()
	cache.mu.Lock()
	if cache.startupHLS {
		if complete {
			delete(cache.startupRequired, asset.address)
		}
		if len(cache.startupRequired) == 0 {
			cache.plan.StartupReady = true
		}
		cache.mu.Unlock()
		return
	}
	if key || strings.Contains(asset.contentType, "mpegurl") || asset.address != cache.mediaURL {
		cache.mu.Unlock()
		return
	}
	if len(session.cencKey) == 16 {
		if !cache.startupIndex && (asset.total == int64(len(asset.data)) || asset.etag != "" && !strings.HasPrefix(asset.etag, "W/")) {
			cache.startupIndex = true
			cache.startupWorkers.Add(1)
			go func() {
				defer cache.startupWorkers.Done()
				for {
					work, finish, err := cache.beginWork(session.ctx, true)
					if err != nil {
						return
					}
					_, err = cache.stream.nativeCENCIndex(work, session, asset)
					cause := context.Cause(work)
					finish()
					if errors.Is(cause, errNativePreloadPaused) {
						continue
					}
					cache.mu.Lock()
					cache.plan.StartupReady = cache.plan.PreloadComplete || err == nil && session.ctx.Err() == nil
					if err == nil {
						cache.plan.MediaType = "mp4"
					}
					cache.startupIndex = err == nil
					cache.mu.Unlock()
					return
				}
			}()
		}
	} else if (complete || len(asset.data) >= 256<<10) && len(asset.data) >= 12 && string(asset.data[4:8]) == "ftyp" {
		cache.plan.MediaType = "mp4"
		cache.plan.StartupReady = true
	}
	cache.mu.Unlock()
}

func (asset nativeStreamAsset) playlistBase() string {
	if asset.base != "" {
		return asset.base
	}
	return asset.address
}

func (cache *nativeEpisodeCache) publishCompletedResources(resources map[string]nativeDownloadFileState) {
	session := cache.session
	for name, metadata := range resources {
		if session.ctx.Err() != nil {
			return
		}
		session.mu.Lock()
		previous, exists := session.startup[metadata.URL]
		blocked := session.onlineAssets[metadata.URL]
		session.mu.Unlock()
		if blocked || exists && (previous.total != metadata.Total || previous.validator() != metadata.Validator) {
			continue
		}
		filename := filepath.Join(cache.directory, name)
		if len(previous.data) > 0 {
			file, err := os.Open(filename)
			if err != nil {
				continue
			}
			prefix, err := io.ReadAll(io.LimitReader(file, int64(len(previous.data))))
			file.Close()
			if err != nil || !bytes.Equal(prefix, previous.data) {
				continue
			}
		}
		asset := nativeStreamAsset{address: metadata.URL, file: filename, total: metadata.Total, contentType: previous.contentType}
		if strings.HasPrefix(metadata.Validator, "\"") {
			asset.etag = metadata.Validator
		} else {
			asset.modified = metadata.Validator
		}
		session.mu.Lock()
		if !session.onlineAssets[metadata.URL] {
			if session.startup == nil {
				session.startup = map[string]nativeStreamAsset{}
			}
			session.startupBytes -= int64(len(session.startup[metadata.URL].data))
			session.startup[metadata.URL] = asset
			for id, current := range session.assets {
				if current.address == metadata.URL && !current.invalid {
					updated := asset
					if updated.contentType == "" {
						updated.contentType = current.contentType
					}
					session.assets[id] = updated
				}
			}
		}
		session.mu.Unlock()
	}
}

func (asset nativeStreamAsset) validator() string {
	if asset.etag != "" && !strings.HasPrefix(asset.etag, "W/") {
		return asset.etag
	}
	if _, err := http.ParseTime(asset.modified); err == nil {
		return asset.modified
	}
	return ""
}

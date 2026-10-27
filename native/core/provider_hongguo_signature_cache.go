package core

import (
	"crypto/sha256"
	"net/http"
	"strconv"
	"time"
)

const hongguoSignatureLifetime = 30 * time.Second
const hongguoSignatureCacheLimit = 128

var hongguoSignatureHeaders = []string{"X-Gorgon", "X-Khronos", "X-Ladon", "X-Argus", "X-Helios", "X-Medusa", "X-SS-STUB", "X-SS-Req-Ticket"}

type hongguoCachedSignature struct {
	query       string
	headers     http.Header
	generatedAt time.Time
}

type hongguoSignatureStatus struct {
	Registered  bool      `json:"registered"`
	Generated   int       `json:"generated"`
	Reused      int       `json:"reused"`
	Refreshed   int       `json:"refreshed"`
	GeneratedAt time.Time `json:"generatedAt"`
	UsedAt      time.Time `json:"usedAt"`
	SuccessAt   time.Time `json:"successAt"`
	LastResult  string    `json:"lastResult"`
}

func (client *hongguoAppClient) prepareSignature(request *http.Request, body []byte, now time.Time, refresh bool) {
	query := request.URL.Query()
	query.Del("_rticket")
	playbackModel := request.Method == http.MethodPost && request.URL.Path == hongguoVideoModelPath
	if playbackModel {
		query.Del("ts")
	}
	canonical := *request.URL
	canonical.RawQuery = query.Encode()
	key := sha256.Sum256(append([]byte(request.Method+"\x00"+canonical.String()+"\x00"), body...))
	client.signatureMu.Lock()
	defer client.signatureMu.Unlock()
	if client.signatures == nil {
		client.signatures = map[[32]byte]hongguoCachedSignature{}
	}
	cached, found := client.signatures[key]
	age := now.Sub(cached.generatedAt)
	if !refresh && found && age >= 0 && age < hongguoSignatureLifetime {
		request.URL.RawQuery = cached.query
		for _, name := range hongguoSignatureHeaders {
			if value := cached.headers.Get(name); value != "" {
				request.Header.Set(name, value)
			}
		}
		client.signatureStatus.Reused++
	} else {
		if playbackModel {
			query.Set("ts", strconv.FormatInt(now.Unix(), 10))
		}
		query.Set("_rticket", strconv.FormatInt(now.UnixMilli(), 10))
		request.URL.RawQuery = query.Encode()
		signHongguoRequest(request, body, now)
		if len(client.signatures) >= hongguoSignatureCacheLimit && !found {
			var oldest [32]byte
			var oldestTime time.Time
			for candidate, value := range client.signatures {
				if oldestTime.IsZero() || value.generatedAt.Before(oldestTime) {
					oldest, oldestTime = candidate, value.generatedAt
				}
			}
			delete(client.signatures, oldest)
		}
		headers := http.Header{}
		for _, name := range hongguoSignatureHeaders {
			if value := request.Header.Get(name); value != "" {
				headers.Set(name, value)
			}
		}
		client.signatures[key] = hongguoCachedSignature{query: request.URL.RawQuery, headers: headers, generatedAt: now}
		client.signatureStatus.Generated++
		client.signatureStatus.GeneratedAt = now
		if refresh {
			client.signatureStatus.Refreshed++
		}
	}
	client.signatureStatus.UsedAt = now
}

func (client *hongguoAppClient) recordSignatureResult(result string) {
	client.signatureMu.Lock()
	defer client.signatureMu.Unlock()
	client.signatureStatus.LastResult = result
	if result == "请求成功" {
		client.signatureStatus.SuccessAt = time.Now()
	}
}

func (client *hongguoAppClient) signatureSnapshot() *hongguoSignatureStatus {
	client.signatureMu.Lock()
	status := client.signatureStatus
	client.signatureMu.Unlock()
	client.mu.Lock()
	status.Registered = client.deviceIdentity.DeviceID != "" && client.deviceIdentity.InstallID != "" && client.deviceIdentityPersisted
	client.mu.Unlock()
	return &status
}

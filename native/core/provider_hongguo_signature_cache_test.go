package core

import (
	"encoding/json"
	"net/http"
	"strconv"
	"strings"
	"testing"
	"time"
)

func TestHongguoPlaybackTimestampStaysWithCachedSignature(t *testing.T) {
	client := &hongguoAppClient{}
	now := time.Unix(1800000000, 0)
	prepare := func(at time.Time, refresh bool) *http.Request {
		request, _ := http.NewRequest(http.MethodPost, "https://example.test"+hongguoVideoModelPath+"?device_id=12345&iid=67890&ts=1", nil)
		client.prepareSignature(request, []byte("{}"), at, refresh)
		if request.URL.Query().Get("ts") != request.Header.Get("X-Khronos") {
			t.Fatal("query timestamp and signed timestamp disagree")
		}
		if request.URL.Query().Get("device_id") != "12345" || request.URL.Query().Get("iid") != "67890" {
			t.Fatal("signing changed the device identity")
		}
		return request
	}
	first := prepare(now, false)
	cached := prepare(now.Add(time.Second), false)
	if cached.URL.String() != first.URL.String() || cached.Header.Get("X-Medusa") != first.Header.Get("X-Medusa") {
		t.Fatal("timestamp change prevented signature reuse")
	}
	refreshed := prepare(now.Add(2*time.Second), true)
	if refreshed.URL.Query().Get("ts") != strconv.FormatInt(now.Unix()+2, 10) {
		t.Fatal("forced refresh retained stale timestamp")
	}
	expired := prepare(now.Add(time.Minute), false)
	if expired.URL.Query().Get("ts") != strconv.FormatInt(now.Unix()+60, 10) {
		t.Fatal("expired signature retained stale timestamp")
	}
}

func TestHongguoSharedSignatureCacheIsolationAndExpiry(t *testing.T) {
	client := &hongguoAppClient{}
	now := time.Unix(1800000000, 0)
	prepare := func(path, body string, at time.Time, refresh bool) *http.Request {
		request, _ := http.NewRequest(http.MethodPost, "https://example.test"+path+"?device_id=12345&iid=67890", strings.NewReader(body))
		client.prepareSignature(request, []byte(body), at, refresh)
		return request
	}
	first := prepare("/one", "a", now, false)
	again := prepare("/one", "a", now.Add(time.Second), false)
	if first.URL.String() != again.URL.String() || first.Header.Get("X-Medusa") != again.Header.Get("X-Medusa") {
		t.Fatal("identical request was resigned")
	}
	prepare("/two", "a", now.Add(2*time.Second), false)
	prepare("/one", "b", now.Add(3*time.Second), false)
	expired := prepare("/one", "a", now.Add(hongguoSignatureLifetime), false)
	if expired.Header.Get("X-SS-Req-Ticket") == first.Header.Get("X-SS-Req-Ticket") {
		t.Fatal("expired signature reused")
	}
	prepare("/one", "a", now.Add(hongguoSignatureLifetime+time.Second), true)
	state := client.signatureSnapshot()
	if state.Generated != 5 || state.Reused != 1 || state.Refreshed != 1 {
		t.Fatalf("wrong shared signature status: %+v", state)
	}
	encoded, _ := json.Marshal(state)
	if strings.Contains(string(encoded), "12345") || strings.Contains(string(encoded), "X-Medusa") {
		t.Fatal("signature status exposed credentials")
	}
}

func TestHongguoSignatureCacheIsBounded(t *testing.T) {
	client := &hongguoAppClient{}
	now := time.Now()
	for index := 0; index < hongguoSignatureCacheLimit+5; index++ {
		request, _ := http.NewRequest(http.MethodPost, "https://example.test/one", nil)
		client.prepareSignature(request, []byte{byte(index)}, now.Add(time.Duration(index)*time.Millisecond), false)
	}
	if len(client.signatures) != hongguoSignatureCacheLimit {
		t.Fatal("unbounded signature cache")
	}
}

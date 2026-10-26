package core

import (
	"encoding/json"
	"net/http"
	"strings"
	"testing"
	"time"
)

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

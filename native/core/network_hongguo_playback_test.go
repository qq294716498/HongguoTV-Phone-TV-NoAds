package core

import (
	"context"
	"io"
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestHongguoReferenceTransportUsesHTTP1WithoutAutomaticCompression(t *testing.T) {
	server := httptest.NewUnstartedServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/playback" {
			if r.ProtoMajor != 1 || r.Header.Get("Accept-Encoding") != "" {
				t.Errorf("reference transport differs: protocol=%s encoding=%s", r.Proto, r.Header.Get("Accept-Encoding"))
			}
		} else if r.ProtoMajor != 2 {
			t.Error("unrelated request lost HTTP/2")
		}
		w.Write([]byte("ok"))
	}))
	server.EnableHTTP2 = true
	server.StartTLS()
	defer server.Close()
	base := server.Client().Transport.(*http.Transport).Clone()
	base.ForceAttemptHTTP2 = true
	transport := newHongguoPlaybackTransport(base, base)
	defer transport.CloseIdleConnections()
	client := &http.Client{Transport: transport}
	for _, path := range []string{"/playback", "/ordinary"} {
		ctx := context.Background()
		if path == "/playback" {
			ctx = context.WithValue(ctx, hongguoPlaybackTransportKey{}, true)
		}
		r, _ := http.NewRequestWithContext(ctx, http.MethodGet, server.URL+path, nil)
		response, err := client.Do(r)
		if err != nil {
			t.Fatal(err)
		}
		io.Copy(io.Discard, response.Body)
		response.Body.Close()
	}
}

package core

import (
	"crypto/tls"
	"net/http"
)

type hongguoPlaybackTransportKey struct{}

type hongguoPlaybackTransport struct {
	base     http.RoundTripper
	playback *http.Transport
}

func newHongguoPlaybackTransport(base http.RoundTripper, transport *http.Transport) *hongguoPlaybackTransport {
	playback := transport.Clone()
	playback.ForceAttemptHTTP2 = false
	playback.TLSNextProto = map[string]func(string, *tls.Conn) http.RoundTripper{}
	if playback.TLSClientConfig == nil {
		playback.TLSClientConfig = &tls.Config{MinVersion: tls.VersionTLS12}
	}
	playback.TLSClientConfig.NextProtos = []string{"http/1.1"}
	playback.DisableCompression = true
	return &hongguoPlaybackTransport{base: base, playback: playback}
}

func (transport *hongguoPlaybackTransport) RoundTrip(request *http.Request) (*http.Response, error) {
	if request.Context().Value(hongguoPlaybackTransportKey{}) == true {
		return transport.playback.RoundTrip(request)
	}
	return transport.base.RoundTrip(request)
}

func (transport *hongguoPlaybackTransport) CloseIdleConnections() {
	transport.playback.CloseIdleConnections()
	if closer, ok := transport.base.(interface{ CloseIdleConnections() }); ok {
		closer.CloseIdleConnections()
	}
}

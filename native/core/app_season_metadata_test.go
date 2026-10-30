package core

import (
	"context"
	"errors"
	"net/http"
	"os"
	"testing"
	"time"
)

func TestNativeSeasonMetadataIsReadOnlyAndHongguoOnly(t *testing.T) {
	calls := 0
	d := sourceFixtureDownloader(t, func(request *http.Request) (*http.Response, error) {
		calls++
		if request.Method != http.MethodGet || request.URL.Host != "hongguoduanju.com" || request.URL.Path != "/detail" || request.URL.Query().Get("series_id") != "123" {
			t.Fatalf("unexpected request %s %s", request.Method, request.URL)
		}
		body := `<script>_ROUTER_DATA={"loaderData":{"detail_page":{"seriesDetail":{"series_id":"123","series_name":"合成第一季","season_info":{"series_group_id":"100"}}}}};</script>`
		return sourceFixtureResponse(request, http.StatusOK, body), nil
	}, false)
	engine := &nativeEngine{downloader: d}
	for _, drama := range []nativeDrama{
		{ID: "huangdou:123", Source: sourceHuangdou},
		{ID: "hongguo:123", Source: sourceHuangdou},
		{ID: "hongguo:invalid", Source: sourceHongguo},
	} {
		if _, err := engine.nativeSeasonMetadata(context.Background(), drama); err == nil {
			t.Fatal("invalid identity entered season metadata")
		}
	}
	if calls != 0 {
		t.Fatal("invalid metadata performed I/O")
	}
	if err := nativeAuthorizeInput(nativeInput{Action: "seasonMetadata", Drama: nativeDrama{ID: "huangdou:123", Source: sourceHuangdou}}); !errors.Is(err, errNativeBuildSource) {
		t.Fatal("non-Hongguo season metadata passed authorization")
	}
	input := nativeDrama{ID: "hongguo:123", Source: sourceHongguo, Title: "原合成", Episodes: 12}
	if err := nativeAuthorizeInput(nativeInput{Action: "seasonMetadata", Drama: input}); err != nil {
		t.Fatal(err)
	}
	result, err := engine.nativeSeasonMetadata(context.Background(), input)
	if err != nil {
		t.Fatal(err)
	}
	fresh := result.(map[string]any)["drama"].(nativeDrama)
	if calls != 1 || fresh.ID != input.ID || fresh.SeriesGroupID != "100" || fresh.RelatedAlbumID != "" || fresh.Episodes != 12 {
		t.Fatalf("wrong season metadata: %+v", fresh)
	}
	files, err := os.ReadDir(d.cfg.dataDir)
	if err != nil || len(files) != 0 {
		t.Fatal("read-only season metadata persisted state", files, err)
	}
}

func TestSeasonReadCancellationStopsOnlyItsHTTPContext(t *testing.T) {
	started := make(chan struct{})
	d := sourceFixtureDownloader(t, func(request *http.Request) (*http.Response, error) {
		close(started)
		<-request.Context().Done()
		return nil, request.Context().Err()
	}, false)
	engine := &nativeEngine{downloader: d}
	input := nativeInput{Action: "seasonMetadata", Session: "owner:season-0-metadata", Sequence: 1,
		Drama: nativeDrama{ID: "hongguo:123", Source: sourceHongguo}}
	work, finish, err := engine.beginRead(context.Background(), input)
	if err != nil {
		t.Fatal(err)
	}
	defer finish()
	peer, finishPeer, err := engine.beginRead(context.Background(), nativeInput{Session: "owner:season-1-metadata", Sequence: 2})
	if err != nil {
		t.Fatal(err)
	}
	defer finishPeer()
	ordinary, finishOrdinary, err := engine.beginRead(context.Background(), nativeInput{Session: "owner:catalog-hongguo", Sequence: 3})
	if err != nil {
		t.Fatal(err)
	}
	defer finishOrdinary()
	done := make(chan error, 1)
	go func() { _, err := engine.nativeSeasonMetadata(work, input.Drama); done <- err }()
	select {
	case <-started:
	case <-time.After(time.Second):
		t.Fatal("metadata did not reach HTTP transport")
	}
	engine.cancelRead(input)
	select {
	case err := <-done:
		if !errors.Is(err, context.Canceled) {
			t.Fatal("metadata HTTP context did not cancel", err)
		}
	case <-time.After(time.Second):
		t.Fatal("cancelled metadata still occupies HTTP transport")
	}
	if peer.Err() != nil || ordinary.Err() != nil {
		t.Fatal("one season cancellation affected another request")
	}
	input.Sequence = 4
	reused, finishReused, err := engine.beginRead(context.Background(), input)
	if err != nil {
		t.Fatal(err)
	}
	defer finishReused()
	engine.cancelRead(nativeInput{Session: input.Session, Sequence: 1})
	if reused.Err() != nil {
		t.Fatal("old cancellation cancelled reused slot")
	}
}

func TestSeasonReadSlotReuseDoesNotExhaustReadHistory(t *testing.T) {
	engine := &nativeEngine{}
	for sequence := int64(1); sequence <= 160; sequence++ {
		ctx, finish, err := engine.beginRead(context.Background(), nativeInput{Session: "owner:season-0-catalog", Sequence: sequence})
		if err != nil || ctx.Err() != nil {
			t.Fatal("reused season slot rejected", sequence, err)
		}
		finish()
	}
	if len(engine.reads) != 1 || engine.readCount != 0 {
		t.Fatalf("finished lookups exhausted read history: %d/%d", len(engine.reads), engine.readCount)
	}
}

func TestSeasonMetadataDispatchHonorsCancelRead(t *testing.T) {
	started := make(chan struct{})
	d := sourceFixtureDownloader(t, func(request *http.Request) (*http.Response, error) {
		close(started)
		<-request.Context().Done()
		return nil, request.Context().Err()
	}, false)
	engine := &nativeEngine{downloader: d}
	nativeState.Lock()
	previous := nativeState.engine
	nativeState.engine = engine
	nativeState.Unlock()
	input := nativeInput{Action: "seasonMetadata", Session: "owner:season-0-metadata", Sequence: 1,
		Drama: nativeDrama{ID: "hongguo:123", Source: sourceHongguo}}
	t.Cleanup(func() {
		engine.cancelRead(input)
		nativeState.Lock()
		nativeState.engine = previous
		nativeState.Unlock()
	})
	done := make(chan error, 1)
	go func() { _, err := nativeDispatch(input); done <- err }()
	select {
	case <-started:
	case <-time.After(time.Second):
		t.Fatal("dispatched metadata did not reach HTTP transport")
	}
	if _, err := nativeDispatch(nativeInput{Action: "cancelRead", Session: input.Session, Sequence: input.Sequence}); err != nil {
		t.Fatal(err)
	}
	select {
	case err := <-done:
		if !errors.Is(err, context.Canceled) {
			t.Fatal("dispatched metadata ignored cancellation", err)
		}
	case <-time.After(time.Second):
		t.Fatal("dispatched metadata did not release canceled HTTP request")
	}
	if engine.readCount != 0 {
		t.Fatal("canceled dispatch did not release native read capacity")
	}
}

package core

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"os"
	"strings"
	"testing"
)

func TestHongguoSeriesRelationsRemainSeparate(t *testing.T) {
	response := map[string]any{"data": map[string]any{"video_data": map[string]any{
		"series_id": "12345", "series_title": "合成系列第二季", "episode_cnt": 1,
		"season_info":      map[string]any{"series_group_id": json.Number("7674918785786072088")},
		"related_album_id": "7640040862889544729",
		"video_list":       []any{map[string]any{"vid": "9001", "vid_index": 1}},
	}}}
	entry, err := parseHongguoAppDetail(response, "12345")
	if err != nil {
		t.Fatal(err)
	}
	if entry.Drama.ID != "hongguo:12345" || entry.Drama.SeriesGroupID != "7674918785786072088" || entry.Drama.RelatedAlbumID != "7640040862889544729" {
		t.Fatalf("official relation IDs lost or conflated: %+v", entry.Drama)
	}
	web := `<script>_ROUTER_DATA = {"loaderData":{"detail_page":{"seriesDetail":{"series_id":"12345","series_name":"合成系列第二季","season_info":{"series_group_id":"7674918785786072088"}}}}};</script>`
	drama, err := parseHongguoSortDetail(web, "12345")
	if err != nil || drama.SeriesGroupID != entry.Drama.SeriesGroupID || drama.RelatedAlbumID != "" {
		t.Fatalf("web group ID became an album ID: %+v %v", drama, err)
	}
}

func TestHongguoRelationIDsRejectMalformedValues(t *testing.T) {
	for _, value := range []string{"", "0", "000", "-1", "1e3", "1.5", "https://example.test/1", strings.Repeat("1", 33)} {
		drama := hongguoDramaFromAny(map[string]any{
			"series_id": "12345", "series_name": "合成系列",
			"season_info": map[string]any{"series_group_id": value}, "related_album_id": value,
		}, "")
		if drama.SeriesGroupID != "" || drama.RelatedAlbumID != "" {
			t.Fatalf("invalid relation ID accepted: %q", value)
		}
	}
	wrapped := hongguoDramaFromAny(map[string]any{
		"series_id":   "12345",
		"video_data":  map[string]any{"series_id": "12345", "series_title": "合成系列"},
		"season_info": map[string]any{"series_group_id": "100"}, "related_album_id": "200",
	}, "")
	if wrapped.SeriesGroupID != "100" || wrapped.RelatedAlbumID != "200" {
		t.Fatal("wrapper relation metadata lost")
	}
	foreign := hongguoDramaFromAny(map[string]any{
		"series_id":   "54321",
		"video_data":  map[string]any{"series_id": "12345", "series_title": "合成系列"},
		"season_info": map[string]any{"series_group_id": "100"}, "related_album_id": "200",
	}, "")
	if foreign.SeriesGroupID != "" || foreign.RelatedAlbumID != "" {
		t.Fatal("wrapper relation metadata leaked from another identity")
	}
}

func TestHongguoSeriesRelationsSurviveBridgeAndLegacyMerge(t *testing.T) {
	original := Drama{ID: "hongguo:12345", SeriesGroupID: "100", RelatedAlbumID: "200", Title: "合成系列第二季"}
	normalized := nativeNormalize(original)
	encoded, err := json.Marshal(normalized)
	if err != nil {
		t.Fatal(err)
	}
	var restored nativeDrama
	if err := json.Unmarshal(encoded, &restored); err != nil || restored.SeriesGroupID != "100" || restored.RelatedAlbumID != "200" || restored.ID != original.ID {
		t.Fatalf("relation metadata lost across native bridge: %v", err)
	}
	merged := mergeNativeDrama(restored, nativeDrama{ID: original.ID, Title: "更新元数据"})
	if merged.SeriesGroupID != "100" || merged.RelatedAlbumID != "200" {
		t.Fatal("sparse metadata erased known relations")
	}
	changed := mergeNativeDrama(merged, nativeDrama{ID: original.ID, SeriesGroupID: "300", RelatedAlbumID: "400"})
	if changed.SeriesGroupID != "300" || changed.RelatedAlbumID != "400" {
		t.Fatal("fresh official relation IDs did not replace old IDs")
	}
	other := mergeNativeDrama(merged, nativeDrama{ID: "hongguo:54321"})
	if other.SeriesGroupID != "" || other.RelatedAlbumID != "" {
		t.Fatal("relation metadata leaked to another drama")
	}
	var old nativeDrama
	if err := json.Unmarshal([]byte(`{"id":"hongguo:12345","title":"旧配置"}`), &old); err != nil || old.SeriesGroupID != "" || old.RelatedAlbumID != "" {
		t.Fatal(err)
	}
	legacy := migrateNativeDrama(nativeDrama{ID: "hongguo:12345", SeriesGroupID: "invalid", RelatedAlbumID: "0"})
	if legacy.SeriesGroupID != "" || legacy.RelatedAlbumID != "" {
		t.Fatal("untrusted stored relation metadata was not sanitized")
	}
}

func TestHongguoSeriesRelationsMergeOnlySameIdentity(t *testing.T) {
	base := Drama{ID: "hongguo:12345"}
	extra := Drama{ID: base.ID, SeriesGroupID: "100", RelatedAlbumID: "200"}
	merged := mergeDramaMetadata(base, extra)
	if merged.SeriesGroupID != "100" || merged.RelatedAlbumID != "200" {
		t.Fatal("same-drama relation metadata lost")
	}
	extra.ID = "hongguo:54321"
	merged = mergeDramaMetadata(base, extra)
	if merged.SeriesGroupID != "" || merged.RelatedAlbumID != "" {
		t.Fatal("relation metadata merged from a different drama")
	}
}

func TestHongguoWebSeriesMetadataIsAnonymousAndChecksIdentity(t *testing.T) {
	for _, id := range []string{"12345", "54321"} {
		t.Run(id, func(t *testing.T) {
			calls := 0
			d := sourceFixtureDownloader(t, func(request *http.Request) (*http.Response, error) {
				calls++
				if request.Method != http.MethodGet || request.URL.Host != "hongguoduanju.com" || request.URL.Path != "/detail" || request.URL.Query().Encode() != "series_id=12345" {
					t.Fatalf("unexpected metadata route: %s %s", request.Method, request.URL)
				}
				for _, key := range []string{"Cookie", "Authorization", "X-Gorgon", "X-Argus", "X-Medusa"} {
					if request.Header.Get(key) != "" {
						t.Fatal("anonymous metadata request carried identity headers", key)
					}
				}
				body := `<script>_ROUTER_DATA = {"loaderData":{"detail_page":{"seriesDetail":{"series_id":"` + id + `","series_name":"合成系列第二季","season_info":{"series_group_id":"100"}}}}};</script>`
				return sourceFixtureResponse(request, http.StatusOK, body), nil
			}, false)
			drama, err := d.hongguoWebSeriesMetadata(context.Background(), "12345")
			if id == "12345" {
				if err != nil || drama.SeriesGroupID != "100" || drama.RelatedAlbumID != "" {
					t.Fatalf("anonymous metadata request failed: %+v %v", drama, err)
				}
			} else if err == nil {
				t.Fatal("metadata for another drama was accepted")
			}
			if calls != 1 || d.hongguo != nil {
				t.Fatal("metadata request initialized or registered an App identity")
			}
			files, err := os.ReadDir(d.cfg.dataDir)
			if err != nil || len(files) != 0 {
				t.Fatalf("anonymous metadata wrote persistent state: %v", err)
			}
		})
	}
}

func TestHongguoWebSeriesMetadataHonorsCancellationAndAccessFailure(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	calls := 0
	d := sourceFixtureDownloader(t, func(request *http.Request) (*http.Response, error) {
		calls++
		return sourceFixtureResponse(request, http.StatusForbidden, "blocked"), nil
	}, false)
	for _, id := range []string{"", "0", "-1", "123?other=1", "1/2", strings.Repeat("1", 33)} {
		if _, err := d.hongguoWebSeriesMetadata(context.Background(), id); err == nil || calls != 0 {
			t.Fatalf("invalid metadata ID caused a request: %q %v", id, err)
		}
	}
	if _, err := d.hongguoWebSeriesMetadata(ctx, "12345"); !errors.Is(err, context.Canceled) || calls != 0 {
		t.Fatalf("cancelled lookup performed a request: %v", err)
	}
	if _, err := d.hongguoWebSeriesMetadata(context.Background(), "12345"); err == nil || calls != 1 {
		t.Fatalf("denied lookup was retried or accepted: calls=%d err=%v", calls, err)
	}
	if d.hongguo != nil {
		t.Fatal("denied metadata request initialized an App identity")
	}
}

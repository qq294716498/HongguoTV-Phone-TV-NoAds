package core

import (
	"context"
	"encoding/json"
	"os"
	"strings"
	"testing"
	"time"
)

func TestLiveHongguoSeriesLookupExport(t *testing.T) {
	path := os.Getenv("HG_SERIES_EXPORT")
	if path == "" {
		t.Skip("explicit series lookup acceptance export")
	}
	engine, err := newNativeEngine(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(engine.downloads.close)
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Minute)
	defer cancel()
	rows := map[string]nativeDrama{}
	for _, query := range []string{"觉醒伪神", "神明弃我我自为神"} {
		for page := 1; page <= 3; page++ {
			result, err := engine.nativeCatalog(ctx, nativeInput{Source: sourceHongguo, Query: query, Page: page, Force: page == 1})
			if err != nil {
				t.Logf("query=%s page=%d error=%v", query, page, publicError(err))
				break
			}
			for _, drama := range result.Items {
				if strings.Contains(drama.Title, "伪神") || strings.Contains(drama.Title, "神明弃我") {
					drama.Cover = ""
					rows[drama.ID] = drama
				}
			}
			t.Logf("query=%s page=%d items=%d more=%t warning=%s", query, page, len(result.Items), result.HasMore, result.Warning)
			if !result.HasMore || result.Warning != "" {
				break
			}
		}
	}
	if len(rows) == 0 {
		t.Fatal("no target series returned")
	}

	details := map[string]any{}
	for _, id := range []string{"hongguo:7676383631534722073", "hongguo:7677963872489196569"} {
		drama, found := rows[id]
		if !found {
			t.Fatalf("required season missing: %s", id)
		}
		detail, err := engine.nativeDetail(ctx, drama)
		if err != nil {
			t.Fatalf("detail %s: %v", id, publicError(err))
		}
		info := detail.(map[string]any)
		fresh := info["drama"].(nativeDrama)
		fresh.Cover = ""
		info["drama"] = fresh
		rows[id] = fresh
		details[id] = info
	}
	detailJSON, err := json.MarshalIndent(details, "", "  ")
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path+".details.json", detailJSON, 0600); err != nil {
		t.Fatal(err)
	}
	entries := []nativeDrama{}
	for _, drama := range rows {
		entries = append(entries, drama)
		t.Logf("id=%s title=%s description=%s", drama.ID, drama.Title, drama.Description)
	}
	data, err := json.MarshalIndent(entries, "", "  ")
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, data, 0600); err != nil {
		t.Fatal(err)
	}
}

func TestLiveHongguoSourceHealth(t *testing.T) {
	if os.Getenv("HG_HEALTH_LIVE") != "1" {
		t.Skip("explicit source health acceptance")
	}
	engine, err := newNativeEngine(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(engine.downloads.close)
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Minute)
	defer cancel()
	err = engine.checkSource(ctx, sourceHongguo, nativeDrama{ID: "hongguo:7676383631534722073", Source: sourceHongguo, Title: "觉醒伪神：神明弃我我自为神2"}, true)
	health := engine.sourceStatus(sourceHongguo).Health
	if health != nil {
		for _, step := range health.Steps {
			t.Logf("step=%s state=%s status=%d message=%s", step.Name, step.State, step.HTTPStatus, step.Message)
		}
	}
	if err != nil {
		t.Fatal(publicError(err))
	}
	if health == nil || health.State != "ok" || len(health.Steps) != 6 {
		t.Fatal("incomplete source health report")
	}
}

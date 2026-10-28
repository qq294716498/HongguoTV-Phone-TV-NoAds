package core

import (
	"context"
	"encoding/json"
	"os"
	"strings"
	"testing"
	"time"
)

func TestLiveHongguoLinggenSeasons(t *testing.T) {
	output := os.Getenv("HG_LINGGEN_EXPORT")
	if output == "" {
		t.Skip("explicit Linggen season metadata acceptance")
	}
	engine, err := newNativeEngine(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(engine.downloads.close)
	ctx, cancel := context.WithTimeout(context.Background(), 4*time.Minute)
	defer cancel()
	rows := map[string]nativeDrama{}
	searches := []map[string]any{}
	for _, query := range []string{"谁说没灵根不能修仙的？之无灵证道", "谁说没灵根不能修仙的？之无灵证道 第四十三季", "谁说没灵根不能修仙的？之无灵证道 第43季", "无灵证道 第43季"} {
		for page := 1; page <= 5; page++ {
			result, err := engine.nativeCatalog(ctx, nativeInput{Source: sourceHongguo, Query: query, Page: page, Force: page == 1})
			if err != nil {
				t.Logf("query=%s page=%d error=%v", query, page, publicError(err))
				break
			}
			items := []nativeDrama{}
			for _, d := range result.Items {
				d.Cover = ""
				items = append(items, d)
				if strings.Contains(d.Title, "灵根") || strings.Contains(d.Title, "无灵证道") {
					rows[d.ID] = d
				}
			}
			searches = append(searches, map[string]any{"query": query, "page": page, "items": items, "hasMore": result.HasMore, "warning": result.Warning})
			t.Logf("query=%s page=%d items=%d more=%t warning=%s", query, page, len(items), result.HasMore, result.Warning)
			if !result.HasMore || result.Warning != "" {
				break
			}
		}
	}
	details := map[string]any{}
	for id, d := range rows {
		if !strings.HasSuffix(d.Title, "42季") && !strings.HasSuffix(d.Title, "43季") {
			continue
		}
		detail, err := engine.nativeDetail(ctx, d)
		if err != nil {
			t.Logf("detail=%s error=%v", id, publicError(err))
			continue
		}
		data := detail.(map[string]any)
		fresh := data["drama"].(nativeDrama)
		fresh.Cover = ""
		data["drama"] = fresh
		details[id] = data
		t.Logf("id=%s title=%s description=%s", id, fresh.Title, fresh.Description)
	}
	data, err := json.MarshalIndent(map[string]any{"searches": searches, "details": details}, "", "  ")
	if err != nil {
		t.Fatal(err)
	}
	if err = os.WriteFile(output, data, 0600); err != nil {
		t.Fatal(err)
	}
	if len(details) < 2 {
		t.Fatal("required target seasons not both returned")
	}
}

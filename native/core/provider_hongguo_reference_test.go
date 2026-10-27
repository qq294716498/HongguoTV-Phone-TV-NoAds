package core

import (
	"encoding/json"
	"os"
	"testing"
)

func TestHongguoMedusaMatchesReferenceAcrossRandomSeeds(t *testing.T) {
	var vectors []struct {
		Timestamp                   uint32
		URL, Body, Signature        string
		MessageRand, Random, XmRand uint32
		EnvLaunch, EnvPID           int64
	}
	body, err := os.ReadFile("testdata/hongguo_reference_medusa.json")
	if err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal(body, &vectors); err != nil {
		t.Fatal(err)
	}
	if len(vectors) != 12 {
		t.Fatal("reference vectors missing")
	}
	for i, v := range vectors {
		ctx := hgMedusaContext{MessageRand: v.MessageRand, EnvLaunch: v.EnvLaunch, EnvPID: v.EnvPID, Nonce: "AAAAAAAAAAAAAAAAAAAAAAAA", Started: 1700000000000, NowUnix: 1700000000}
		got := hgBuildMedusaWith(v.URL, []byte(v.Body), v.Timestamp, "1000000000000001", "7.1.3.32", ctx, v.Random, v.XmRand)
		if got != v.Signature {
			t.Errorf("reference signature mismatch at vector %d", i)
		}
	}
}

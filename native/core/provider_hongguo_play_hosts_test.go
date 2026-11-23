// SPDX-License-Identifier: GPL-3.0-only
package core

import (
	"context"
	"fmt"
	"net/http"
	"testing"
)

// 换机顺序：失败的主机进冷却、排到队尾；成功的主机立刻回到队首。
func TestHongguoPlayHostOrderPrefersHealthyHosts(t *testing.T) {
	d := &Downloader{}
	state := d.hongguoPlayHostState()
	hosts := state.order()
	if len(hosts) != len(hongguoPlayModelHosts) || hosts[0] != hongguoPlayModelHosts[0] {
		t.Fatalf("初始顺序应保持主机池原序: %v", hosts)
	}
	state.mark(hongguoPlayModelHosts[0], errHongguoEmptyResponse)
	state.mark(hongguoPlayModelHosts[2], nil)
	ordered := state.order()
	if ordered[len(ordered)-1] != hongguoPlayModelHosts[0] {
		t.Fatalf("空正文的主机应排到队尾: %v", ordered)
	}
	if ordered[0] != hongguoPlayModelHosts[2] {
		t.Fatalf("最近成功的主机应排到队首: %v", ordered)
	}
}

// 一台机器给空正文时换下一台，取到即停，且不再回头打坏机器。
func TestHongguoMobileModelSwitchesHostOnEmptyBody(t *testing.T) {
	first, second := hongguoPlayModelHosts[0], hongguoPlayModelHosts[1]
	var seen []string
	d := sourceFixtureDownloader(t, func(r *http.Request) (*http.Response, error) {
		seen = append(seen, r.URL.Scheme+"://"+r.URL.Host)
		if r.URL.Path != hongguoPlayModelPath {
			t.Fatalf("unexpected path %s", r.URL.Path)
		}
		if len(seen) == 1 {
			return sourceFixtureResponse(r, 200, ""), nil
		}
		return sourceFixtureResponse(r, 200, mobileFixtureModel("9001", true, false)), nil
	})
	searchFixtureIdentity(d)
	media, err := d.resolveHongguoMobileMedia(context.Background(), "9001")
	if err != nil || media.URL != "https://media.example.test/test.mp4" {
		t.Fatalf("换机取流失败: %v", err)
	}
	if len(seen) != 2 || seen[0] != first || seen[1] != second {
		t.Fatalf("换机顺序不符: %v", seen)
	}
	// 下一次取流的首台应是被记住的成功主机。
	if next := d.hongguoPlayHostState().order()[0]; next != second {
		t.Fatalf("成功主机未回到队首: %s", next)
	}
}

// 业务错误码与 429 不换机，避免放大请求量。
func TestHongguoPlayHostRetryableOnlyForTransportAndEmpty(t *testing.T) {
	for _, tc := range []struct {
		name string
		err  error
		want bool
	}{
		{"empty", fmt.Errorf("%w（v5 player）", errHongguoEmptyResponse), true},
		{"canceled", context.Canceled, false},
		{"deadline", context.DeadlineExceeded, false},
		{"business", fmt.Errorf("红果 v5 播放接口返回错误（%s）", "110001"), false},
	} {
		if got := hongguoPlayHostRetryable(tc.err); got != tc.want {
			t.Fatalf("%s: got %v want %v", tc.name, got, tc.want)
		}
	}
}

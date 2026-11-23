// SPDX-License-Identifier: GPL-3.0-only
package core

import (
	"context"
	"errors"
	"net"
	"strings"
	"sync"
	"time"
)

// 红果 v5 播放接口的主机池。
//
// 依据官方客户端（短剧播放器 1.2.32，Go + WebView2）的二进制结构：其 hgapi 包内
// 有 hostPicker（markGood / markBad 记录每台机器的成败与耗时，order 按健康度取
// 顺序）、callPlayHosts（单机请求一次，成功记好、失败记坏）、callPlayRace（主备
// 目标并发，先返回者胜）。同一份 multi_video_model 播放模型请求在下列主机上都成立，
// 但上游会按时间窗让其中一部分返回 HTTP 200 + 0 字节正文 —— 这正是本仓库此前只写
// 死 sinfonlinea 一台机器时「偶发取不到片源」的成因。本文件把这条策略搬过来：
// 依次换机重试，失败的主机冷却一段时间，成功的主机立刻回到队首。
const hongguoPlayModelPath = "/novel/player/multi_video_model/player/v1"

var hongguoPlayModelHosts = []string{
	"https://api5-normal-sinfonlinea.fqnovel.com",
	"https://api5-normal-sinfonlineb.fqnovel.com",
	"https://api5-normal-sinfonlinec.fqnovel.com",
	"https://api3-normal-sinfonlinea.fqnovel.com",
}

// hongguoPlayHostCooldown 是失败主机的冷却时长：官方客户端的 markBad 只是让该机
// 在一段时间内排到最后，而不是永久拉黑（上游的坏窗口是分钟级的）。
const hongguoPlayHostCooldown = 2 * time.Minute

type hongguoPlayHostHealth struct {
	mu   sync.Mutex
	bad  map[string]time.Time
	last map[string]time.Time
}

func newHongguoPlayHostHealth() *hongguoPlayHostHealth {
	return &hongguoPlayHostHealth{bad: map[string]time.Time{}, last: map[string]time.Time{}}
}

func (d *Downloader) hongguoPlayHostState() *hongguoPlayHostHealth {
	d.playHostMu.Lock()
	defer d.playHostMu.Unlock()
	if d.playHosts == nil {
		d.playHosts = newHongguoPlayHostHealth()
	}
	return d.playHosts
}

// order 返回按健康度排序的主机列表：正常主机保持原始顺序（最近的赢家排最前），
// 仍在冷却期内的主机挪到队尾。
func (health *hongguoPlayHostHealth) order() []string {
	now := time.Now()
	health.mu.Lock()
	defer health.mu.Unlock()
	fresh := make([]string, 0, len(hongguoPlayModelHosts))
	cooling := make([]string, 0, len(hongguoPlayModelHosts))
	for _, host := range hongguoPlayModelHosts {
		if failedAt, ok := health.bad[host]; ok && now.Sub(failedAt) < hongguoPlayHostCooldown {
			cooling = append(cooling, host)
			continue
		}
		fresh = append(fresh, host)
	}
	// 最近成功过的主机优先，其次是还没试过的。
	sortHostsByRecency(fresh, health.last)
	if len(fresh) == 0 {
		// 全部在冷却期内：仍要按最近表现排队，不能因为都坏就一台都不试。
		sortHostsByRecency(cooling, health.last)
		return cooling
	}
	return append(fresh, cooling...)
}

func sortHostsByRecency(hosts []string, last map[string]time.Time) {
	if len(hosts) < 2 {
		return
	}
	weight := func(host string) time.Time {
		if at, ok := last[host]; ok {
			return at
		}
		return time.Time{}
	}
	for i := 1; i < len(hosts); i++ {
		for j := i; j > 0 && weight(hosts[j]).After(weight(hosts[j-1])); j-- {
			hosts[j], hosts[j-1] = hosts[j-1], hosts[j]
		}
	}
}

// mark 记录一次请求结果：成功的机器移到队首，可重试的失败进入冷却。
func (health *hongguoPlayHostHealth) mark(host string, err error) {
	now := time.Now()
	health.mu.Lock()
	defer health.mu.Unlock()
	if err == nil {
		delete(health.bad, host)
		health.last[host] = now
		return
	}
	if hongguoPlayHostRetryable(err) {
		health.bad[host] = now
	}
}

// hongguoPlayHostRetryable 判断一次失败是否值得换一台机器再试。
//
// 只换机重试「网络层失败」与「HTTP 200 + 0 字节」这两类：它们与主机相关，换机
// 有效。业务错误码（如未返回所选集）、4xx、429、正文过大都与机器无关，换机只会
// 放大请求量，直接失败交给上层的 video_tab 回退。
func hongguoPlayHostRetryable(err error) bool {
	if err == nil {
		return false
	}
	if errors.Is(err, errHongguoEmptyResponse) {
		return true
	}
	if errors.Is(err, context.Canceled) || errors.Is(err, context.DeadlineExceeded) {
		// 整体预算已经用完，换机也来不及；本轮直接结束。
		return false
	}
	var netErr net.Error
	return errors.As(err, &netErr)
}

// hongguoPlayHostName 用于诊断事件里展示主机名。
func hongguoPlayHostName(host string) string {
	return strings.TrimPrefix(strings.TrimPrefix(host, "https://"), "http://")
}

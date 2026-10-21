package core

import (
	"encoding/base64"
	"encoding/hex"
	"net/http"
	"os"
	"strings"
	"testing"
	"time"
)

// SM3 标准测试向量。Go 标准库没有 SM3，实现是手写的，必须先钉住这一条，
// 否则 x-medusa 全链路都会静默算错。
func TestHongguoSM3MatchesStandardVector(t *testing.T) {
	cases := map[string]string{
		"abc": "66c7f0f462eeedd9d1f2d46bdc10e4e24167c4875cf2f7a2297da02b8f4ba8e0",
		"":    "1ab21d8355cfa17f8e61194831e81a8f22bec8c728fefb747ed035eb5082aa2b",
	}
	for input, want := range cases {
		if got := hgHex(hgSM3([]byte(input))); got != want {
			t.Fatalf("SM3(%q) = %s, want %s", input, got, want)
		}
	}
}

// 缺任何一个签名头，官方播放接口都会返回 HTTP 200 空正文。
func TestSignHongguoRequestEmitsSixHeaders(t *testing.T) {
	body := []byte(`{"biz_param":{"video_platform":1024}}`)
	request, err := http.NewRequest(
		http.MethodPost,
		"https://api5-normal-sinfonlineb.fqnovel.com"+hongguoVideoModelPath+
			"?device_id=1234567890123456&version_name=7.1.3.32&_rticket=1700000000000",
		strings.NewReader(string(body)),
	)
	if err != nil {
		t.Fatalf("构造请求失败: %v", err)
	}
	now := time.Unix(1700000000, 0)
	signHongguoRequest(request, body, now)

	required := []string{"X-Gorgon", "X-Khronos", "X-Ladon", "X-Argus", "X-Helios", "X-Medusa"}
	for _, name := range required {
		if value := request.Header.Get(name); value == "" {
			t.Fatalf("缺少签名头 %s", name)
		}
	}
	if got := request.Header.Get("X-Khronos"); got != "1700000000" {
		t.Fatalf("X-Khronos = %s, want 1700000000", got)
	}
	if got, want := request.Header.Get("X-Ladon"), base64.StdEncoding.EncodeToString(hgBe32(1700000000)); got != want {
		t.Fatalf("X-Ladon = %s, want %s", got, want)
	}
	if got, want := request.Header.Get("X-Argus"), base64.StdEncoding.EncodeToString(hgLe32(1700000000)); got != want {
		t.Fatalf("X-Argus = %s, want %s", got, want)
	}
	if request.Header.Get("X-SS-STUB") == "" {
		t.Fatal("缺少 X-SS-STUB")
	}
	if request.Header.Get("X-SS-Req-Ticket") == "" {
		t.Fatal("缺少 X-SS-Req-Ticket")
	}
	for _, name := range []string{"X-Gorgon", "X-Ladon", "X-Argus", "X-Helios", "X-Medusa"} {
		if _, err := base64.StdEncoding.DecodeString(request.Header.Get(name)); err == nil {
			continue
		}
		if name == "X-Gorgon" {
			continue
		}
		t.Fatalf("%s 不是合法的 base64: %s", name, request.Header.Get(name))
	}
}

// 签名内部按 iv 低 4 位选分支，落到 1 时服务端不接受；
// signHongguoRequest 必须通过抖动 _rticket 把分支推离 1。
func TestSignHongguoRequestAvoidsRejectedBranch(t *testing.T) {
	body := []byte(`{"biz_param":{"video_platform":1024}}`)
	for offset := 0; offset < 64; offset++ {
		now := time.Unix(1700000000+int64(offset), 0)
		request, err := http.NewRequest(
			http.MethodPost,
			"https://api5-normal-sinfonlineb.fqnovel.com"+hongguoVideoModelPath+
				"?device_id=1234567890123456&version_name=7.1.3.32",
			strings.NewReader(string(body)),
		)
		if err != nil {
			t.Fatalf("构造请求失败: %v", err)
		}
		signHongguoRequest(request, body, now)
		if branch := hgBranchOf(request.URL.String(), body, uint32(now.Unix())); branch == 1 {
			t.Fatalf("ts=%d 抖动后仍是 branch==1", now.Unix())
		}
	}
}

// 与参考实现（sunnysky123/hongguo-web pure-sign.js）逐字节比对。
// 期望值由 Node 侧以固定输入生成，任何位运算语义偏移都会在这里暴露。
func TestHongguoSignGoldenValues(t *testing.T) {
	query := "device_id=1234567890123456&version_name=7.1.3.32&_rticket=1700000000000"
	body := []byte(`{"biz_param":{"video_platform":1024}}`)
	const ts = uint32(1700000000)
	rawURL := "https://api5-normal-sinfonlineb.fqnovel.com" + hongguoVideoModelPath + "?" + query

	if got, want := hgXGorgon(query, body, ts, 0x5a3c),
		"84043c5a4001d7f13e8d8c0d5c51fffe947c5eca3b3ae360e4f4"; got != want {
		t.Fatalf("x-gorgon = %s, want %s", got, want)
	}
	if got, want := hgHeliosWith(ts, 0x5f3759df),
		"31k3XyU8JrE4X57lcCNiui/SgyhKdrQ7pX2MvEcq6V05pLh4"; got != want {
		t.Fatalf("x-helios = %s, want %s", got, want)
	}
	// 该样本落在 branch==2，走 md5SumV3 变体路径。
	if got := hgBranchOf(rawURL, body, ts); got != 2 {
		t.Fatalf("branchOf = %d, want 2", got)
	}
	if got, want := hgB64(hgBe32(ts)), "ZVPxAA=="; got != want {
		t.Fatalf("x-ladon = %s, want %s", got, want)
	}
	if got, want := hgB64(hgLe32(ts)), "APFTZQ=="; got != want {
		t.Fatalf("x-argus = %s, want %s", got, want)
	}
}

// AesV3 变体、xmxor、keyHash 是 x-medusa 的核心，逐字节比对参考实现。
func TestHongguoCipherGoldenValues(t *testing.T) {
	data := make([]byte, 64)
	for i := range data {
		data[i] = byte(i*7 + 3)
	}
	key := hgUnhex("f1593376766ea98d34f31b057a9d5be4")
	iv := hgUnhex("1fe109a4125283f418de9e051a969e12")
	want := map[uint32]string{
		1700000000: "8e230a110817242d343b024950575c65ec537a81988f969c24abb2bdc0cfced4dce3aaf5f8ff040c143b622d303f3c45cc735a65686f747d848bd299b0a7aeb5bc",
		1700000001: "c9230a111817242c343b024d40575c646c537a818887949c24abb2b9d0cfced55ce3eaf5e8f7040c143b622d20373c444c535a657867767d84abd299b0a7acb53c",
		1700000002: "a6034a150817262c343b024d505f5e656c533a85988f969ca4abb2b9c0c7ccd45ce3aaf1e8ff040c141b222d303f3c454c535a657867747d84ab929db0afacb53c",
		1700000003: "08234a15181f242cb41b0249405f5e64ec533a85888f949ca4abf2b9c0cfccd55cc3eaf1f8f7060d141b222d30373c454c731a61686f747d04abd299a0a7acb53c",
	}
	for khronos, expected := range want {
		if got := hgHex(hgNewAesV3(key, khronos).encrypt(data, iv)); got != expected {
			t.Fatalf("aesV3 khronos=%d\n got %s\nwant %s", khronos, got, expected)
		}
	}

	xkey := make([]byte, 32)
	for i := range xkey {
		xkey[i] = byte(i*11 + 5)
	}
	if got, expected := hgHex(hgXmxor(data, xkey)),
		"c6f0be038a7e460ca4a134229799d41353254bc5333f317eb9703fc31b5edaf7b11ab87d85cc30fdcb47cc1398e238476db0a953ad2d4bef37bb9f49ff097864"; got != expected {
		t.Fatalf("xmxor\n got %s\nwant %s", got, expected)
	}

	hash, seed := hgKeyHash(hgMedusaSignKey, 0x12345678)
	if got, expected := hgHex(hash), "489143ef7f0135c393ebcef82f8e631276f292343e2bc4603e9d62b236414918"; got != expected {
		t.Fatalf("keyHash hash = %s, want %s", got, expected)
	}
	if got, expected := hgHex(seed), "d85ffeff"; got != expected {
		t.Fatalf("keyHash seed = %s, want %s", got, expected)
	}
}

// hashF13 覆盖三条分支：branch==2（md5V3 变体）、branch==0（主分支）、其它（短路径）。
func TestHongguoHashF13GoldenValues(t *testing.T) {
	cases := []struct {
		query, body string
		khronos     uint32
		want        string
	}{
		{"device_id=1234567890123456&version_name=7.1.3.32&_rticket=1700000000000",
			`{"biz_param":{"video_platform":1024}}`, 1700000000,
			"074e4968e955e394b58e08b442e0bc20af180de2"},
		{"a=1&b=2", "{}", 1700000005,
			"2b19648138724a7a2eaf1da95d6ac0902cffc5d9"},
		{"x=9", "", 1700000010,
			"06108abf81691152f57f08fbe3ff1f96000000000000000000000000000000003f8ac19a"},
	}
	for _, item := range cases {
		bodyMd5 := make([]byte, 16)
		if item.body != "" {
			bodyMd5 = hgMD5([]byte(item.body))
		}
		querySm3 := hgSM3([]byte(item.query))
		if got := hgHex(hgHashF13(querySm3, bodyMd5, hgLe32(item.khronos), item.khronos)); got != item.want {
			t.Fatalf("hashF13(query=%q, body=%q, ts=%d)\n got %s\nwant %s",
				item.query, item.body, item.khronos, got, item.want)
		}
	}
}

// medusa 的 protobuf 消息体逐字节比对（固定 nonce / 时间 / 随机量）。
func TestHongguoMedusaMessageGoldenValue(t *testing.T) {
	const query = "device_id=1234567890123456&version_name=7.1.3.32&_rticket=1700000000000"
	body := []byte(`{"biz_param":{"video_platform":1024}}`)
	ctx := hgMedusaContext{
		MessageRand: 0x12345678,
		EnvLaunch:   105,
		EnvPID:      11000,
		Nonce:       "AAAAAAAAAAAAAAAAAAAAAAAA",
		Started:     1700000000000,
		NowUnix:     1700000000,
	}
	// 期望值由参考实现生成后直接落盘，避免手工转抄出错。
	raw, err := os.ReadFile("testdata/hongguo_medusa_message.hex")
	if err != nil {
		t.Fatalf("读取 medusa 基准文件失败: %v", err)
	}
	want := strings.TrimSpace(string(raw))
	got := hgHex(hgMedusaMessage("https://x/?"+query, body, 1700000000, "1234567890123456", "7.1.3.32", ctx))
	if got != want {
		if os.Getenv("HG_DUMP_MSG") == "1" {
			t.Logf("GOT_MSG=%s", got)
			t.Logf("WANT_MSG=%s", want)
		}
		gotBytes, _ := hex.DecodeString(got)
		wantBytes, _ := hex.DecodeString(want)
		limit := len(gotBytes)
		if len(wantBytes) < limit {
			limit = len(wantBytes)
		}
		for i := 0; i < limit; i++ {
			if gotBytes[i] != wantBytes[i] {
				from := i - 6
				if from < 0 {
					from = 0
				}
				t.Fatalf("medusa 消息在第 %d 字节分叉（got %d 字节 / want %d 字节）\n got …%s…\nwant …%s…",
					i, len(gotBytes), len(wantBytes),
					hgHex(gotBytes[from:minInt(len(gotBytes), i+10)]),
					hgHex(wantBytes[from:minInt(len(wantBytes), i+10)]))
			}
		}
		t.Fatalf("medusa 消息长度不一致: got %d, want %d", len(gotBytes), len(wantBytes))
	}
}

func TestHongguoHeliosDeterministic(t *testing.T) {
	first := hgHeliosWith(1700000000, 0x5f3759df)
	second := hgHeliosWith(1700000000, 0x5f3759df)
	if first != second {
		t.Fatal("helios 在相同输入下不稳定")
	}
	decoded, err := base64.StdEncoding.DecodeString(first)
	if err != nil {
		t.Fatalf("helios 不是合法 base64: %v", err)
	}
	if len(decoded) < 20 {
		t.Fatalf("helios 长度异常: %d", len(decoded))
	}
	if other := hgHeliosWith(1700000001, 0x5f3759df); other == first {
		t.Fatal("helios 未随 khronos 变化")
	}
}

func TestHongguoMedusaRespondsToBody(t *testing.T) {
	rawURL := "https://api5-normal-sinfonlineb.fqnovel.com" + hongguoVideoModelPath +
		"?device_id=1234567890123456&version_name=7.1.3.32&_rticket=1700000000000"
	first := hgBuildMedusa(rawURL, []byte(`{"a":1}`), 1700000000, "1234567890123456", "7.1.3.32")
	second := hgBuildMedusa(rawURL, []byte(`{"a":2}`), 1700000000, "1234567890123456", "7.1.3.32")
	if first == "" || second == "" {
		t.Fatal("medusa 为空")
	}
	if first == second {
		t.Fatal("medusa 未随请求体变化，签名链路可能未生效")
	}
	if _, err := base64.StdEncoding.DecodeString(first); err != nil {
		t.Fatalf("medusa 不是合法 base64: %v", err)
	}
}

func TestHongguoBranchOfRange(t *testing.T) {
	body := []byte(`{"a":1}`)
	for _, ts := range []uint32{1700000000, 1700000001, 1700000002, 1700000003, 1700000004} {
		branch := hgBranchOf("https://api5-normal-sinfonlineb.fqnovel.com/x?a=1&_rticket=1", body, ts)
		if branch < 0 || branch > 2 {
			t.Fatalf("branch 越界: %d", branch)
		}
	}
}

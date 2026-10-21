package core

import (
	"crypto/md5"
	crand "crypto/rand"
	"encoding/base64"
	"encoding/binary"
	"encoding/hex"
	"math"
	"net/url"
	"strconv"
	"strings"
	"sync"
	"time"
)

// 红果 App 接口六个签名头的纯 Go 实现。
//
// 算法移植自 sunnysky123/hongguo-web 的 server/src/core/pure-sign.js，
// 其上游为 jackotom/hongguo-drama。字节级对齐要求：任何一处位运算语义
// 偏移都会导致 x-medusa 校验失败、上游返回 HTTP 200 空正文。
//
// 三个必须守住的原实现语义：
//   1. Java int 为 32 位有符号，溢出按补码回绕 —— Go 侧统一用 uint32 承载。
//   2. JS 的 |0 / >> / >>> 分别对应 int32 转换、算术右移、逻辑右移。
//   3. JS 越界读 Buffer 返回 undefined，位运算中视作 0 —— 见 hgAESSrc。

// ==================== 基础位运算 ====================

// hgRandUint32 对应 Java 的 Random.nextInt()：返回 32 位随机量。
func hgRandUint32() uint32 {
	var buffer [4]byte
	if _, err := crand.Read(buffer[:]); err != nil {
		return uint32(time.Now().UnixNano())
	}
	return binary.LittleEndian.Uint32(buffer[:])
}

// hgRandInt 对应 Java 的 Random.nextInt(n)：返回 [0, n) 的整数。
func hgRandInt(n int) int {
	if n <= 0 {
		return 0
	}
	var buffer [8]byte
	if _, err := crand.Read(buffer[:]); err != nil {
		return int(time.Now().UnixNano() % int64(n))
	}
	return int(binary.LittleEndian.Uint64(buffer[:]) % uint64(n))
}

func hgRotl32(x uint32, n int) uint32 {
	k := uint(n) & 31
	if k == 0 {
		return x
	}
	return x<<k | x>>(32-k)
}

func hgRotr32(x uint32, n int) uint32 {
	k := uint(n) & 31
	if k == 0 {
		return x
	}
	return x>>k | x<<(32-k)
}

func hgRotl8(x byte) byte {
	return x<<4 | x>>4
}

func hgRotl8x3(x byte) byte {
	return x<<3 | x>>5
}

func hgReverse8(v byte) byte {
	var r byte
	for i := 0; i < 8; i++ {
		r = r<<1 | (v>>uint(i))&1
	}
	return r
}

func hgLe32(v uint32) []byte {
	b := make([]byte, 4)
	binary.LittleEndian.PutUint32(b, v)
	return b
}

func hgBe32(v uint32) []byte {
	b := make([]byte, 4)
	binary.BigEndian.PutUint32(b, v)
	return b
}

func hgReadLe32(b []byte, off int) uint32 {
	return binary.LittleEndian.Uint32(b[off:])
}

func hgReadBe32(b []byte, off int) uint32 {
	return binary.BigEndian.Uint32(b[off:])
}

func hgReadU64Le(b []byte, off int) uint64 {
	return binary.LittleEndian.Uint64(b[off:])
}

func hgPutU64Le(b []byte, off int, v uint64) {
	binary.LittleEndian.PutUint64(b[off:], v)
}

// hgRotr64 对应 Java 的 Long.rotateRight。
func hgRotr64(x uint64, n int) uint64 {
	k := uint(n) & 63
	if k == 0 {
		return x
	}
	return x>>k | x<<(64-k)
}

func hgHex(data []byte) string {
	return hex.EncodeToString(data)
}

func hgUnhex(text string) []byte {
	data, err := hex.DecodeString(strings.TrimSpace(text))
	if err != nil {
		panic("红果签名内置常量解码失败: " + err.Error())
	}
	return data
}

func hgB64(data []byte) string {
	return base64.StdEncoding.EncodeToString(data)
}

func hgMD5(data []byte) []byte {
	sum := md5.Sum(data)
	return sum[:]
}

// ==================== SM3（Go 标准库未提供，按 GB/T 32905 实现） ====================

var hgSM3IV = [8]uint32{
	0x7380166f, 0x4914b2b9, 0x172442d7, 0xda8a0600,
	0xa96f30bc, 0x163138aa, 0xe38dee4d, 0xb0fb0e4e,
}

func hgSM3P0(x uint32) uint32 {
	return x ^ hgRotl32(x, 9) ^ hgRotl32(x, 17)
}

func hgSM3P1(x uint32) uint32 {
	return x ^ hgRotl32(x, 15) ^ hgRotl32(x, 23)
}

func hgSM3Block(h *[8]uint32, block []byte) {
	var w [68]uint32
	var w1 [64]uint32
	for i := 0; i < 16; i++ {
		w[i] = binary.BigEndian.Uint32(block[i*4:])
	}
	for i := 16; i < 68; i++ {
		w[i] = hgSM3P1(w[i-16]^w[i-9]^hgRotl32(w[i-3], 15)) ^ hgRotl32(w[i-13], 7) ^ w[i-6]
	}
	for i := 0; i < 64; i++ {
		w1[i] = w[i] ^ w[i+4]
	}
	a, b, c, d, e, f, g, hh := h[0], h[1], h[2], h[3], h[4], h[5], h[6], h[7]
	for j := 0; j < 64; j++ {
		var ff, gg, tj uint32
		if j < 16 {
			ff = a ^ b ^ c
			gg = e ^ f ^ g
			tj = 0x79cc4519
		} else {
			ff = (a & b) | (a & c) | (b & c)
			gg = (e & f) | (^e & g)
			tj = 0x7a879d8a
		}
		ss1 := hgRotl32(hgRotl32(a, 12)+e+hgRotl32(tj, j), 7)
		ss2 := ss1 ^ hgRotl32(a, 12)
		tt1 := ff + d + ss2 + w1[j]
		tt2 := gg + hh + ss1 + w[j]
		d = c
		c = hgRotl32(b, 9)
		b = a
		a = tt1
		hh = g
		g = hgRotl32(f, 19)
		f = e
		e = hgSM3P0(tt2)
	}
	h[0] ^= a
	h[1] ^= b
	h[2] ^= c
	h[3] ^= d
	h[4] ^= e
	h[5] ^= f
	h[6] ^= g
	h[7] ^= hh
}

func hgSM3(data []byte) []byte {
	padded := make([]byte, len(data))
	copy(padded, data)
	padded = append(padded, 0x80)
	for len(padded)%64 != 56 {
		padded = append(padded, 0)
	}
	var tail [8]byte
	binary.BigEndian.PutUint64(tail[:], uint64(len(data))*8)
	padded = append(padded, tail[:]...)

	h := hgSM3IV
	for i := 0; i < len(padded); i += 64 {
		hgSM3Block(&h, padded[i:i+64])
	}
	out := make([]byte, 32)
	for i := 0; i < 8; i++ {
		binary.BigEndian.PutUint32(out[i*4:], h[i])
	}
	return out
}

// ==================== protobuf 手写编码 ====================

func hgVarint(value uint64) []byte {
	out := make([]byte, 0, 10)
	for value > 127 {
		out = append(out, byte(value&127)|128)
		value >>= 7
	}
	return append(out, byte(value))
}

func hgZigzag(value int64) uint64 {
	if value < 0 {
		return uint64(-value)*2 - 1
	}
	return uint64(value) * 2
}

type hgProtoField struct {
	Tag   int
	Value any
	Type  string
}

func hgProtoFieldBytes(field hgProtoField) []byte {
	if field.Value == nil {
		return nil
	}
	// 与 JS 的 proto() 一致：未显式声明类型时按 string 处理。
	fieldType := field.Type
	if fieldType == "" {
		fieldType = "string"
	}
	switch fieldType {
	case "string":
		text, _ := field.Value.(string)
		if text == "" {
			return nil
		}
		body := []byte(text)
		return append(append(hgVarint(uint64(field.Tag)<<3|2), hgVarint(uint64(len(body)))...), body...)
	case "bytes", "message":
		body, _ := field.Value.([]byte)
		return append(append(hgVarint(uint64(field.Tag)<<3|2), hgVarint(uint64(len(body)))...), body...)
	case "float":
		number, _ := field.Value.(float64)
		body := make([]byte, 4)
		binary.LittleEndian.PutUint32(body, math.Float32bits(float32(number)))
		return append(hgVarint(uint64(field.Tag)<<3|5), body...)
	default:
		number := hgAsInt64(field.Value)
		head := hgVarint(uint64(field.Tag) << 3)
		if field.Type == "sint" {
			return append(head, hgVarint(hgZigzag(number))...)
		}
		return append(head, hgVarint(uint64(number))...)
	}
}

func hgAsInt64(value any) int64 {
	switch typed := value.(type) {
	case int:
		return int64(typed)
	case int64:
		return typed
	case uint32:
		return int64(typed)
	case float64:
		return int64(typed)
	default:
		return 0
	}
}

func hgProto(fields ...hgProtoField) []byte {
	var out []byte
	for _, field := range fields {
		out = append(out, hgProtoFieldBytes(field)...)
	}
	return out
}

// ==================== hashF13 家族 ====================

// hgGetIv：按字节奇偶交替混合的 32 位状态机。
func hgGetIv(iv uint32, data []byte) uint32 {
	value := iv
	for i, current := range data {
		if i&1 == 0 {
			value = value>>4 ^ value ^ value<<6 ^ uint32(current)
		} else {
			value = ^(value>>7 ^ value ^ (uint32(current) | value<<12))
		}
	}
	return value
}

// hgSumMd5：取前 12 字节的固定轮混淆，末位或 4 再异或 0x1000000。
func hgSumMd5(data []byte) uint32 {
	check := uint32(0x20220420)
	for i := 0; i < 12; i++ {
		var temp uint32
		if i&1 == 0 {
			temp = check>>3 ^ check
		} else {
			temp = check>>5 ^ check
		}
		if i&1 == 0 {
			check = uint32(data[i]) ^ check<<7
		} else {
			check = uint32(data[i]) | check<<11
		}
		if i&1 != 0 {
			check = ^check
		}
		check ^= temp
	}
	return (check | 4) ^ 0x1000000
}

var hgBranch2SV = [64]uint32{
	0xa7aefe20, 0x7149f1d6, 0x47e4ca07, 0xe9b58f67, 0x93b924de, 0xc614d0f5, 0x38afe0ef, 0xb2bbad73,
	0xe24444c3, 0x9d3aec9b, 0xdf7b37e4, 0xd8b16d40, 0xf8ac31b8, 0x76b9a90b, 0x31d833ee, 0x953fce64,
	0x353595a4, 0x4609c13b, 0x36925008, 0x8c6d0925, 0x5df5c177, 0x1cfbf52b, 0x8a4fa7f0, 0x114ca35e,
	0x8193f984, 0x7a7a8733, 0x316ab4d5, 0x3c20cfc9, 0xa6d84453, 0x3a18500c, 0x798ec47a, 0x97a76b28,
	0x66c4ff96, 0x51716443, 0x0dd2fc3b, 0xb5696da7, 0xbbeb3ac5, 0x5c53d204, 0xd32608ce, 0x7279b9ec,
	0xf4188ecf, 0xf7d793db, 0x332cc491, 0xab76ae15, 0x9bebe727, 0x18a01384, 0x5be9f8a7, 0x5f90a754,
	0x39b663c0, 0x36673c83, 0x7c92f514, 0x9d7d94d7, 0xe2e8d9aa, 0x5f7e9ea9, 0x7abd4551, 0x569e05da,
	0x40a25632, 0x3df5a9a5, 0xbab37d80, 0x454286dc, 0x3f5d4e78, 0x03d7b75d, 0xb1fe4af7, 0xa5ab26a3,
}

var hgBranch2Orders = hgUnhex(
	"0f0704000908030a060b050d0e010c02" +
		"0f05080c0009020103070e060b0a0d04" +
		"060500070c000a04080f010b0d09020e" +
		"060b02050403080101070a000d0c090e" +
		"0d070e0f0b0208030c0509010004060a" +
		"0d0902060f0b0a040807000c0503010e" +
		"0c090f07060f030e020d0405010b0a00" +
		"0c050a090e0802040407030f01060b00" +
		"0b0f0408020a0700090d06010e03050c" +
		"0b060a0508020c03070f0e090d000104" +
		"0906080f050800040a0b030d01020c0e" +
		"090d0c0604070a03030f00080105020e" +
		"01000d0f090a0b0e0402080703060c05" +
		"01080a0c0f0905060b000304020e070d" +
		"04080f000c0f0e0d0a01060207090503" +
		"040205080d0b0a0606000e0f070c0903" +
		"0a08040f000b01060d0c0709030e0502" +
		"0a070b050f00020e0108030d0c060904" +
		"0d070f08050f06040b0a0e0c09000203" +
		"0d0c020704010b0e0e08060f09050003")

func hgMD5V3Step(kind int, a, b, c, d, m, shift, constant uint32) uint32 {
	var f uint32
	switch kind {
	case 0:
		f = (b & c) | (^b & d)
	case 1:
		f = (b & d) | (c & ^d)
	case 2:
		f = b ^ c ^ d
	default:
		f = c ^ (b | ^d)
	}
	return b + hgRotl32(a+f+m+constant, int(shift))
}

var (
	hgMD5Shifts0 = [16]int{7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22}
	hgMD5Shifts1 = [16]int{5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20}
	hgMD5Shifts2 = [16]int{4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23}
	hgMD5Shifts3 = [16]int{6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21}
)

// hgMD5SumV3：MD5 变体，固定轮常量表 + 消息编排表驱动的 64 轮压缩。
func hgMD5SumV3(message []byte, countV2 uint32, orders []byte, countV1 int) []byte {
	var sv [64]uint32
	for i := range sv {
		sv[i] = hgRotr32(hgBranch2SV[i], countV1)
	}
	start := [4]uint32{
		hgRotr32(0x79e0f2fb, int(countV2)),
		hgRotr32(0xc8b52570, int(countV2)),
		hgRotr32(0xebc2f8cd, int(countV2)),
		hgRotr32(0x7c104d93, int(countV2)),
	}
	endCount := (countV2 + 6) & 255
	end := [4]uint32{
		hgRotr32(0x19be4866, int(endCount)),
		hgRotr32(0xe85986b4, int(endCount)),
		hgRotr32(0xe19b326e, int(endCount)),
		hgRotr32(0x71d1d7d4, int(endCount)),
	}
	var m [16]uint32
	for i := 0; i < 16; i++ {
		m[i] = hgReadLe32(message, i*4)
	}
	a, b, c, d := start[0], start[1], start[2], start[3]

	shiftTables := [4][16]int{hgMD5Shifts0, hgMD5Shifts1, hgMD5Shifts2, hgMD5Shifts3}
	for kind := 0; kind < 4; kind++ {
		shifts := shiftTables[kind]
		offset := kind * 16
		for i := 0; i < 16; i++ {
			phase := i & 3
			var order byte
			if offset+i < len(orders) {
				order = orders[offset+i]
			}
			mm := m[int(order)&0xff]
			cc := sv[offset+i]
			var next uint32
			switch phase {
			case 0:
				next = hgMD5V3Step(kind, a, b, c, d, mm, uint32(shifts[i]), cc)
				a = next
			case 1:
				next = hgMD5V3Step(kind, d, a, b, c, mm, uint32(shifts[i]), cc)
				d = next
			case 2:
				next = hgMD5V3Step(kind, c, d, a, b, mm, uint32(shifts[i]), cc)
				c = next
			default:
				next = hgMD5V3Step(kind, b, c, d, a, mm, uint32(shifts[i]), cc)
				b = next
			}
		}
	}
	ret := make([]byte, 16)
	binary.LittleEndian.PutUint32(ret[0:], (start[0]+a)^end[0])
	binary.LittleEndian.PutUint32(ret[4:], (start[1]+b)^end[1])
	binary.LittleEndian.PutUint32(ret[8:], (start[2]+c)^end[2])
	binary.LittleEndian.PutUint32(ret[12:], (start[3]+d)^end[3])
	return append(ret, hgLe32(hgSumMd5(ret))...)
}

var hgBranch2N1 = [5]uint32{0x8980f29b, 0xeb549c7f, 0xb08726db, 0xd40cb5e6, 0xe8f559e4}
var hgBranch2Seed = [8]byte{0x84, 0x96, 0x77, 0x9d, 0xd4, 0x15, 0x0b, 0xf8}

func hgBranch2F13(iv uint32, querySm3, bodyMd5, tsBytes []byte, khronos uint32) []byte {
	v := (iv & 13) * 86
	ivV0 := int((v>>15)&255) + int((v>>8)&255)
	if ivV0 >= len(hgBranch2N1) {
		ivV0 = len(hgBranch2N1) - 1
	}
	n1 := hgBranch2N1[ivV0]
	countV1 := int((n1 + khronos + 1) & 255)
	countV2 := n1 + khronos
	shift := int((countV2 + 5) & 7)
	pad := make([]byte, 8)
	for i := 0; i < 8; i++ {
		pad[i] = byte((uint32(hgBranch2Seed[i]) | uint32(hgBranch2Seed[i])<<8) >> uint(shift))
	}
	input := make([]byte, 0, 64)
	input = append(input, querySm3...)
	input = append(input, bodyMd5...)
	input = append(input, tsBytes...)
	input = append(input, pad...)
	input = append(input, hgUnhex("a0010000")...)

	from := ivV0 << 6
	to := (ivV0 + 1) << 6
	if from > len(hgBranch2Orders) {
		from = len(hgBranch2Orders)
	}
	if to > len(hgBranch2Orders) {
		to = len(hgBranch2Orders)
	}
	orders := hgBranch2Orders[from:to]
	return hgMD5SumV3(input, countV2, orders, countV1)
}

var hgF13IV1 = [6]uint32{0xc4a78580, 0xb3c0fd39, 0xc58c5686, 0xc9aa3ba7, 0xf5a7adf2, 0x963c2ed1}

var hgF13TT02 = [64]uint32{
	0xebb64faf, 0x07aadcc2, 0xcf3187bf, 0xe01138ff, 0x6d0bfcff, 0x5a30a3be, 0xb41ad638, 0x34180eb8,
	0xf233eb6f, 0xb1a584cc, 0xccc30dc7, 0x47d1db51, 0xd55653de, 0x70a84fa1, 0x57473c12, 0xf76f0288,
	0x2c077f0a, 0xda0dcad0, 0xfbb86f6c, 0xfdc4cf00, 0x688a020d, 0xe676c6a6, 0x8cd6338b, 0x1a3c8d0e,
	0xcce8b06b, 0x6ad0ed0b, 0xa0522717, 0xdc71ac83, 0x2285db71, 0xd5b4dda6, 0x736f8650, 0x6560306c,
	0x617ce2a6, 0xe423417e, 0x0a40e143, 0x544e4032, 0x88dffb2a, 0x716c1ae0, 0x4c467a88, 0x05b23bb3,
	0xe1d0b866, 0xbaa3dcb8, 0xae3374d3, 0xc3381a50, 0x1702f75b, 0xfe6da368, 0xf0b4cf48, 0x4e0ffbb8,
	0x72aad10d, 0x26c53a3d, 0xf2bce0f6, 0xb4557581, 0x4a257fdd, 0x8c3182a2, 0xab0b3b86, 0x3d5dfb14,
	0x4f103634, 0xd37b52d7, 0x444eff16, 0xeb0a33d1, 0x6ca86f6e, 0x0284ba7, 0x08387cfa, 0x5fb37586,
}

var hgF13Chosen = [6][11]int{
	{101, 5, 7, 6, 3, 2, 1, 0, 5, 4, 3},
	{96, 0, 6, 7, 5, 3, 2, 1, 5, 4, 4},
	{96, 7, 6, 2, 1, 4, 0, 5, 4, 3, 5},
	{99, 3, 6, 2, 4, 5, 1, 0, 0, 7, 6},
	{96, 0, 5, 6, 7, 3, 1, 2, 5, 4, 4},
	{100, 2, 0, 3, 5, 4, 6, 7, 2, 1, 5},
}

var hgF13InitRaw = [8]uint32{
	0x7aba4fc8, 0x67166507, 0x6403fa00, 0x340f512f,
	984304912, 3005047866, 2874125293, 2152413264,
}

// hgHashF13：按 iv 低 4 位选分支（0 主分支、1 服务端不接受、2 备用变体）。
func hgHashF13(querySm3, bodyMd5, tsBytes []byte, khronos uint32) []byte {
	iv := hgGetIv(hgGetIv(hgGetIv(0x20230928, querySm3), bodyMd5), tsBytes)
	low := int(iv & 15)
	ivV0 := (low * 171) >> 9
	branch := low - ivV0*3
	if branch == 2 {
		return hgBranch2F13(iv, querySm3, bodyMd5, tsBytes, khronos)
	}
	if branch != 0 {
		sum := hgSumMd5(append(append([]byte{}, querySm3...), bodyMd5...))
		merged := append([]byte{}, querySm3[0:16]...)
		merged = append(merged, bodyMd5...)
		return append(merged, hgLe32(sum)...)
	}

	ivV1 := hgF13IV1[ivV0]
	countV1 := int((ivV1 + khronos + 1) & 255)
	countV2 := ivV1 + khronos
	var tt [64]uint32
	for i := range tt {
		tt[i] = hgRotr32(hgF13TT02[i], countV1)
	}
	n0 := int((countV2 + 2) & 7)
	seed := [4]byte{0xfa, 0x45, 0x61, 0xd7}
	pad := make([]byte, 4)
	for i := 0; i < 4; i++ {
		pad[i] = byte((uint32(seed[i]) | uint32(seed[i])<<8) >> uint(n0))
	}
	data := make([]byte, 0, 64)
	data = append(data, querySm3...)
	data = append(data, bodyMd5...)
	data = append(data, tsBytes...)
	data = append(data, pad...)
	data = append(data, hgUnhex("00000000000001a0")...)

	di := make([]uint32, 0, len(data)/4+128)
	for i := 0; i+3 < len(data); i += 4 {
		di = append(di, hgReadBe32(data, i))
	}
	di0 := di[0]
	for i := 0; i < 112; i++ {
		di1 := di[i+1]
		di14 := di[i+14]
		r1 := hgRotl32(di1, 14) ^ hgRotl32(di1, 25) ^ di1>>3
		r2 := hgRotl32(di14, 13) ^ hgRotl32(di14, 15) ^ di14>>10
		di = append(di, di0+di[i+9]+r1+r2)
	}

	var init [8]uint32
	for i := 0; i < 8; i++ {
		init[i] = hgRotr32(hgF13InitRaw[i], int(countV2&31))
	}
	chosen := hgF13Chosen[ivV0]
	d := init
	for i := 0; i < chosen[0]; i++ {
		base := ivV1 + uint32(i)
		n0v := di[base&127]
		n1 := ((d[chosen[3]] ^ d[chosen[4]]) & d[chosen[1]]) ^ d[chosen[3]]
		n2 := hgRotl32(d[chosen[1]], 26) ^ hgRotl32(d[chosen[1]], 21) ^ hgRotl32(d[chosen[1]], 7)
		n4 := n0v + n1 + n2 + tt[base&63] + d[chosen[5]]
		n5 := hgRotl32(d[chosen[2]], 30) ^ hgRotl32(d[chosen[2]], 19) ^ hgRotl32(d[chosen[2]], 10)
		n6 := (d[chosen[2]] & d[chosen[6]]) | ((d[chosen[2]] | d[chosen[6]]) & d[chosen[7]])
		n7 := n5 + n6
		old := d[chosen[9]]
		last := d[7]
		for k := 7; k >= 1; k-- {
			d[k] = d[k-1]
		}
		d[0] = last
		d[chosen[10]] = n7 + n4
		d[chosen[8]] = old + n4
	}
	ret := make([]byte, 32)
	for i := 0; i < 8; i++ {
		binary.BigEndian.PutUint32(ret[i*4:], d[i]+init[i])
	}
	for i := 0; i < 16; i++ {
		ret[i] ^= ret[i+16]
	}
	head := ret[:16]
	return append(append([]byte{}, head...), hgLe32(hgSumMd5(head))...)
}

// ==================== x-gorgon ====================

// hgRC4Gorgon：RC4 变体（KSA 只赋值不交换，PRGA 异或 s[(y+y)&255]）。
func hgRC4Gorgon(data, key []byte) []byte {
	var s [256]byte
	for i := 0; i < 256; i++ {
		s[i] = byte(i)
	}
	j := 0
	for i := 0; i < 256; i++ {
		j = (j + int(s[i]) + int(key[i%len(key)])) & 255
		s[i] = s[j]
	}
	out := make([]byte, len(data))
	i, j := 0, 0
	for k := 0; k < len(data); k++ {
		i++
		x := s[i]
		j += int(x)
		y := s[j&255]
		s[i] = y
		out[k] = data[k] ^ s[(int(y)+int(y))&255]
	}
	return out
}

func hgXGorgon(query string, body []byte, timestamp uint32, random int) string {
	queryHash := hgMD5([]byte(query))
	input := make([]byte, 0, 20)
	input = append(input, queryHash[0:4]...)
	if len(body) > 0 {
		bodyHash := hgMD5(body)
		input = append(input, bodyHash[0:4]...)
	} else {
		input = append(input, 0, 0, 0, 0)
	}
	input = append(input, 0, 0, 0, 0)
	input = append(input, hgLe32(67503104)...)
	input = append(input, hgBe32(timestamp)...)
	key := []byte{0x4a, 0x40, 0x16, byte(random>>8) & 255, 0x47, 0x6c, 0x01, byte(random) & 255}
	out := hgRC4Gorgon(input, key)
	for i := range out {
		value := hgRotl8(out[i])
		next := out[0]
		if i+1 < len(out) {
			next = out[i+1]
		}
		out[i] = ^hgReverse8(next^value) ^ 20
	}
	signature := append(hgUnhex("8404"), byte(random)&255, byte(random>>8)&255, 0x40, 0x01)
	return hgHex(append(signature, out...))
}

// ==================== AesV3（medusa 内置的 AES 变体） ====================

var hgAESSBoxOnce sync.Once
var hgAESSBox []byte

const hgAESSBoxB64 = "+n0Ia5xZs0sEXznQOEqRmQBnpiCf9U2Ccybu3xhmgzOAAxn72f6uqqmwUsYL83klTni0NqxdGieeiNu9PGPsSRXBMB/cuFbUbM3KCUPINaPvHvSW0vwOcnuUhNHqRVpiAj/TEoE0K91+5ijypUYTATsh9mE3KSoN7Yyvv51cuyR2D3XkU4nhmI2xmmVwT1RMWKtub4sjxAcRDLrPoKSO2AU9FLLadMPX577Wf95IFj6FkKFVt3dCIsmGUC4X+WQxLJvxbRxEaOPpqJOXyzJX6+Vxaq3AzMfF/WAdoi1Hp+JRaV56zgpBtpWP97mH4DoGEIq1+FvV8LyS/3wvwugbQOwb2r26mJEMsiuDQTRn+wrYdrVGBVlhI3WQhyrjUBVMrLF5667llUcEaPCGPVGLD8qO5LlO8hKCvA7V9+8oJc9bXelqVQLhM76T5/WtnT45JKji+hdX0HoNCDDWuKON/QeaxB5uImSX0h2wv0VmP2zd2yeApxHcpsVS+MC2yFwAc2B7oBkTqsk1SEvTpM2fmfMQREBUfin0Bh+iq6EvPPavhWI2IX9e3yAas7Tm/3KEj2UmlFp36kN4x0rMLBRrxuh0U/zUHM4xcAMYjJY4MonxOl/X+alpt2M3WMI7w3HLnpIBigtNiJu7T21v4P6lSd5WFgntnMEt7oF92XzRLkJbTcGmXepE/UVOG6E/0YnhfS+q26utWcuxzpooyeD2cDlK1/8w9d28VzsRjbLuALbmGlp8+d7EzS6Au7lMpZ+ECMZvQmzwJ+eLOpxR+2chdUExp8ogQyq3v9l68rX4jCwjg0+PYKAEEzcU4wHFY2ZcdIHfWL1okD3SszT0GZMyKdZJrg1L2AeerB4tC0C4crp2EHGo5FYdSP7lwkeR2ocmnR+Ia8CYviUJlzOjhRZef9xuVOn3qcjow3fQgivsAmKKkg4+sA8F8/GWeDiGNhg8JM8KtFPMYWWkx5TVFX5t73kiNRJqjlIGVXtGZFCV4gzt0xcDopuZ6xz8r9Rzafpf9ywev8jh8592gHFIqpStZPuJxmDDMrNN0uBE3V+oscdoIzTJbRJ/t+sVvqnReJOgDJKk10fjisJwqyZBmnmn2BSFj8BvVtCMEbkuPOKdzw7eA11GPs04Qw8zWtkaZWwiO/wwpojqN6K0jY5RnNZA7vn4hPSul+nKCkVnVwQvg1zVxcSCtqORmB9KrJaBbssbCQivGJVJfVTt+hYxOtq4ZvWl8f4QAQZ0zGPffCgl9s6yT4vlvIdpu4YhBwA25wtQWZsc6GJYGWHyvSdeuh3mmUI9DSq13Fsp8C1MU3tqc04/df9LoTUXVXI5INOw/e8C7Hd+5CvbkMEFnnrUUmskEw=="

func hgSBox() []byte {
	hgAESSBoxOnce.Do(func() {
		data, err := base64.StdEncoding.DecodeString(hgAESSBoxB64)
		if err != nil {
			panic("红果签名 S 盒解码失败: " + err.Error())
		}
		hgAESSBox = data
	})
	return hgAESSBox
}

// hgAESSrc：JS 越界读返回 undefined，位运算中等价于 0。
func hgAESSrc(data []byte, idx int) byte {
	if idx >= 0 && idx < len(data) {
		return data[idx]
	}
	return 0
}

func hgAESPut(out []byte, idx int, value byte) {
	if idx >= 0 && idx < len(out) {
		out[idx] = value
	}
}

func hgAESMatrix(bytes []byte) [4][4]byte {
	var rows [4][4]byte
	for i := 0; i < 4; i++ {
		for j := 0; j < 4; j++ {
			rows[i][j] = bytes[i*4+j]
		}
	}
	return rows
}

func hgAESFlat(rows [4][4]byte) []byte {
	out := make([]byte, 16)
	for i := 0; i < 4; i++ {
		for j := 0; j < 4; j++ {
			out[i*4+j] = rows[i][j]
		}
	}
	return out
}

func hgAESXt(x byte) byte {
	if x&128 != 0 {
		return (x << 1) ^ 0x1b
	}
	return x << 1
}

func hgAESMix(rows *[4][4]byte) {
	for i := 0; i < 4; i++ {
		t := rows[0][i] ^ rows[1][i] ^ rows[2][i] ^ rows[3][i]
		u := rows[0][i]
		rows[0][i] ^= t ^ hgAESXt(rows[0][i]^rows[1][i])
		rows[1][i] ^= t ^ hgAESXt(rows[1][i]^rows[2][i])
		rows[2][i] ^= t ^ hgAESXt(rows[2][i]^rows[3][i])
		rows[3][i] ^= t ^ hgAESXt(rows[3][i]^u)
	}
}

type hgAesV3 struct {
	box   []byte
	con2  [4]int
	order [16]int
	keys  [12][4]byte
}

var hgAESCon2 = [4][4]int{
	{1, 0, 2, 3}, {2, 0, 3, 1}, {0, 1, 3, 2}, {1, 0, 2, 3},
}

var hgAESOrder = [4][16]int{
	{0, 9, 14, 11, 4, 13, 2, 7, 8, 1, 6, 15, 12, 5, 10, 3},
	{0, 9, 14, 15, 4, 13, 2, 7, 8, 1, 6, 3, 12, 5, 10, 11},
	{0, 9, 14, 7, 4, 13, 2, 11, 8, 1, 6, 3, 12, 5, 10, 15},
	{0, 9, 14, 11, 4, 13, 2, 7, 8, 1, 6, 15, 12, 5, 10, 3},
}

var hgAESInit = [4]uint32{0xca025ddc, 0x823dc546, 0xc9420583, 0xc298225f}

func hgNewAesV3(key []byte, khronos uint32) *hgAesV3 {
	wordSize := int(khronos & 3)
	sbox := hgSBox()
	aes := &hgAesV3{
		box:   sbox[wordSize*256 : (wordSize+1)*256],
		con2:  hgAESCon2[wordSize],
		order: hgAESOrder[wordSize],
	}
	init := hgAESInit[wordSize]
	initial := make([]byte, 16)
	for i := 0; i < 4; i++ {
		binary.LittleEndian.PutUint32(initial[i*4:], init)
	}
	expanded := make([]byte, 48)
	for i := 0; i < 16; i++ {
		expanded[i] = initial[i] ^ key[i%len(key)]
	}
	rounds := uint(8)
	for i := 4; i < 12; i++ {
		at := 4 * (i - 1)
		a := expanded[at]
		b := expanded[at+1]
		c := expanded[at+2]
		d := expanded[at+3]
		if i&3 == 0 {
			t := byte((init >> (rounds & 24)) ^ uint32(aes.box[b]))
			b = aes.box[c]
			c = aes.box[d]
			d = aes.box[a]
			a = t
		}
		rounds += 2
		expanded[at+4] = a ^ expanded[at-12]
		expanded[at+5] = b ^ expanded[at-11]
		expanded[at+6] = c ^ expanded[at-10]
		expanded[at+7] = d ^ expanded[at-9]
	}
	for i := 0; i < 12; i++ {
		for j := 0; j < 4; j++ {
			aes.keys[i][j] = expanded[i*4+j]
		}
	}
	return aes
}

func (aes *hgAesV3) add(rows *[4][4]byte, key [4][4]byte) {
	for i := 0; i < 4; i++ {
		for j := 0; j < 4; j++ {
			rows[i][j] ^= key[i][j]
		}
	}
}

func (aes *hgAesV3) addCon(rows *[4][4]byte, ks [4][4]byte) {
	for i := 0; i < 4; i++ {
		for j := 0; j < 4; j++ {
			rows[i][j] ^= ks[i][aes.con2[j]]
		}
	}
}

func (aes *hgAesV3) sub(rows *[4][4]byte) {
	for i := 0; i < 4; i++ {
		for j := 0; j < 4; j++ {
			rows[i][j] = aes.box[rows[i][j]]
		}
	}
	old := *rows
	for i := 0; i < 4; i++ {
		rows[i] = old[aes.con2[i]]
	}
}

func (aes *hgAesV3) shift(rows *[4][4]byte) {
	flat := hgAESFlat(*rows)
	var next [4][4]byte
	for i := 0; i < 16; i++ {
		next[i/4][i%4] = flat[aes.order[i]]
	}
	*rows = next
}

func (aes *hgAesV3) shiftCon(rows *[4][4]byte) {
	old := *rows
	for i := 0; i < 4; i++ {
		for j := 0; j < 4; j++ {
			rows[i][j] = old[i][aes.con2[j]]
		}
	}
}

func (aes *hgAesV3) subKeys(from int) [4][4]byte {
	var out [4][4]byte
	for i := 0; i < 4; i++ {
		out[i] = aes.keys[from+i]
	}
	return out
}

func (aes *hgAesV3) block(value []byte) []byte {
	rows := hgAESMatrix(value)
	aes.addCon(&rows, aes.subKeys(0))
	for i := 1; i < 3; i++ {
		aes.sub(&rows)
		aes.shift(&rows)
		if i == 1 {
			aes.shiftCon(&rows)
			hgAESMix(&rows)
		}
		aes.addCon(&rows, aes.subKeys(i*4))
	}
	aes.add(&rows, aes.subKeys(4))
	return hgAESFlat(rows)
}

// encrypt：明文具化到 32 字节 -> CBC 两轮 -> 按 key 逐位回填源数据，末尾缀 key 末字节。
func (aes *hgAesV3) encrypt(data, iv []byte) []byte {
	plaintext := make([]byte, 32)
	for i := 0; i < 31; i++ {
		at := i * 8
		var n byte
		n = (hgAESSrc(data, at) >> 4) & 2
		n |= hgAESSrc(data, at+1) & 64
		n |= (hgAESSrc(data, at+2) >> 2) & 1
		n |= (hgAESSrc(data, at+3) << 3) & 128
		n |= (hgAESSrc(data, at+4) >> 1) & 4
		n |= (hgAESSrc(data, at+5) << 3) & 16
		n |= (hgAESSrc(data, at+6) << 5) & 32
		n |= (hgAESSrc(data, at+7) >> 4) & 8
		plaintext[i] = n
	}
	plaintext[31] = 1

	var key []byte
	previous := append([]byte{}, iv...)
	for i := 0; i < len(plaintext); i += 16 {
		block := make([]byte, 16)
		for j := 0; j < 16; j++ {
			block[j] = plaintext[i+j] ^ previous[j]
		}
		value := aes.block(block)
		key = append(key, value...)
		previous = value
	}
	out := append([]byte{}, data...)
	for i := 0; i < 31; i++ {
		at := i * 8
		k := key[i]
		hgAESPut(out, at, (hgAESSrc(out, at)&0xdf)|((k<<4)&32))
		hgAESPut(out, at+1, (hgAESSrc(out, at+1)&0xbf)|(k&64))
		hgAESPut(out, at+2, (hgAESSrc(out, at+2)&0xfb)|((k<<2)&4))
		hgAESPut(out, at+3, (hgAESSrc(out, at+3)&0xef)|((k>>3)&16))
		hgAESPut(out, at+4, (hgAESSrc(out, at+4)&0xf7)|((k+k)&8))
		hgAESPut(out, at+5, (hgAESSrc(out, at+5)&0xfd)|((k>>3)&2))
		hgAESPut(out, at+6, (hgAESSrc(out, at+6)&0xfe)|((k>>5)&1))
		hgAESPut(out, at+7, (hgAESSrc(out, at+7)&0x7f)|((k<<4)&128))
	}
	return append([]byte{key[len(key)-1]}, out...)
}

// ==================== xmxor / keyHash / x-medusa / x-helios ====================

// hgXmxor：按 key 表逐字节混淆 + 三段尾部修正。
func hgXmxor(data, key []byte) []byte {
	encoded := make([]byte, len(data))
	for i := 0; i < len(data); i++ {
		at := (i * 4) & 28
		d0 := key[at]
		d1 := key[at+1]
		d2 := hgRotl8(data[i]) + d0
		d2 = ^d2 ^ d1
		d2 = hgRotl8x3(d2)
		d2 = d2 + d1
		d2 = d2 ^ d0
		encoded[len(data)-i-1] = ^d2
	}
	last := encoded[len(encoded)-1] ^ encoded[len(encoded)-2]
	first := encoded[0]
	encoded[0] = (^last) + first
	encoded[1] = (encoded[0] ^ encoded[len(encoded)-1] ^ 254) + encoded[1]
	encoded[2] = encoded[2] + (((last - first) ^ hgRotl8x3(encoded[1])) ^ 2)
	for i := 0; i < len(encoded)-4; i++ {
		temp := hgRotl8x3(encoded[i+2]) ^ encoded[i+1] ^ byte(i+3)
		encoded[i+3] = (^temp) + encoded[i+3]
	}
	encoded[len(encoded)-1] = encoded[len(encoded)-1] ^ encoded[len(encoded)-2]
	var sum byte
	for i := 0; i < len(encoded)-1; i++ {
		sum += encoded[i+1]
	}
	encoded[0] = (encoded[0] ^ encoded[1]) + sum
	return encoded
}

var hgMedusaSignKey = hgUnhex("8ebdfa3806ecc5cee79423e6029ed82540bc2218bb7eaef71cb691f7aa8aa2f5")
var hgMedusaAESKey = hgUnhex("f1593376766ea98d34f31b057a9d5be4")
var hgMedusaAESIV = hgUnhex("1fe109a4125283f418de9e051a969e12")
var hgMedusaMagic16 = hgUnhex("f7e85ffad7d7dc3bd62ac87057cf6118")
var hgMedusaMagic8 = hgUnhex("4001000000000000")
var hgMedusaVersionBytes = hgUnhex("03000000f7e85ffad7d7dc3bd62ac87057cf6118")

var hgProcessOnce sync.Once
var hgProcessNonce string
var hgProcessStarted int64

func hgProcessState() (string, int64) {
	hgProcessOnce.Do(func() {
		nonce := make([]byte, 18)
		for i := range nonce {
			nonce[i] = byte(hgRandUint32())
		}
		hgProcessNonce = base64.RawURLEncoding.EncodeToString(nonce)
		hgProcessStarted = time.Now().UnixMilli()
	})
	return hgProcessNonce, hgProcessStarted
}

// hgKeyHash：signKey || le32(random) || signKey 的 SM3，附一个由 random 派生的 4 字节种子。
func hgKeyHash(signKey []byte, random uint32) ([]byte, []byte) {
	input := make([]byte, 0, len(signKey)*2+4)
	input = append(input, signKey...)
	input = append(input, hgLe32(random)...)
	input = append(input, signKey...)
	hash := hgSM3(input)
	d1 := (random >> 16) & 255
	d2 := ((d1 << 11) | (random >> 24)) ^ (d1 >> 5) ^ d1
	d2 = ^d2
	return hash, hgLe32(d2)
}

// hgMedusaContext 收拢 medusa 里所有非确定输入，便于逐字节比对与复现。
type hgMedusaContext struct {
	MessageRand uint32
	EnvLaunch   int64
	EnvPID      int64
	Nonce       string
	Started     int64
	NowUnix     int64
}

func hgNewMedusaContext() hgMedusaContext {
	nonce, started := hgProcessState()
	return hgMedusaContext{
		MessageRand: hgRandUint32(),
		EnvLaunch:   int64(100 + hgRandInt(21)),
		EnvPID:      int64(10001 + hgRandInt(2000)),
		Nonce:       nonce,
		Started:     started,
		NowUnix:     time.Now().Unix(),
	}
}

// hgDeviceProtoWith：设备信息 protobuf，用显式 nonce / started 便于比对。
func hgDeviceProtoWith(deviceID, version, nonce string, started int64) []byte {
	return hgProto(
		hgProtoField{Tag: 1, Value: int64(1), Type: "sint"},
		hgProtoField{Tag: 2, Value: int64(2), Type: "sint"},
		hgProtoField{Tag: 3, Value: "8662"},
		hgProtoField{Tag: 4, Value: deviceID},
		hgProtoField{Tag: 5, Value: nonce},
		hgProtoField{Tag: 6, Value: "!noperm!"},
		hgProtoField{Tag: 7, Value: int64(-888888), Type: "sint"},
		hgProtoField{Tag: 8, Value: int64(-888888), Type: "sint"},
		hgProtoField{Tag: 9, Value: int64(3), Type: "sint"},
		hgProtoField{Tag: 10, Value: int64(-888888), Type: "sint"},
		hgProtoField{Tag: 11, Value: "!notset!"},
		hgProtoField{Tag: 12, Value: "Asia/Shanghai,8"},
		hgProtoField{Tag: 13, Value: "zh_CN"},
		hgProtoField{Tag: 14, Value: int64(4), Type: "sint"},
		hgProtoField{Tag: 16, Value: float64(0), Type: "float"},
		hgProtoField{Tag: 17, Value: float64(0), Type: "float"},
		hgProtoField{Tag: 18, Value: float64(0), Type: "float"},
		hgProtoField{Tag: 19, Value: float64(0), Type: "float"},
		hgProtoField{Tag: 20, Value: float64(0), Type: "float"},
		hgProtoField{Tag: 21, Value: float64(0), Type: "float"},
		hgProtoField{Tag: 22, Value: "16"},
		hgProtoField{Tag: 23, Value: int64(41), Type: "sint"},
		hgProtoField{Tag: 24, Value: int64(36), Type: "sint"},
		hgProtoField{Tag: 25, Value: started, Type: "sint"},
		hgProtoField{Tag: 26, Value: started, Type: "sint"},
		hgProtoField{Tag: 27, Value: started, Type: "sint"},
		hgProtoField{Tag: 28, Value: started, Type: "sint"},
		hgProtoField{Tag: 29, Value: int64(-1), Type: "sint"},
		hgProtoField{Tag: 30, Value: "25053RT47C"},
		hgProtoField{Tag: 31, Value: "Redmi"},
		hgProtoField{Tag: 32, Value: "25053RT47C"},
		hgProtoField{Tag: 33, Value: "25053RT47C"},
		hgProtoField{Tag: 34, Value: "Xiaomi"},
		hgProtoField{Tag: 35, Value: "Redmi"},
		hgProtoField{Tag: 36, Value: "Redmi"},
		hgProtoField{Tag: 38, Value: int64(31), Type: "sint"},
	)
}

// hgDeviceProto 使用进程级 nonce / 启动时间。
func hgDeviceProto(deviceID, version string) []byte {
	nonce, started := hgProcessState()
	return hgDeviceProtoWith(deviceID, version, nonce, started)
}

const hgMedusaRuntimeJSON = `{"cmr":16777216,"cmr2":16777216,"un_h":1879194040,"vpn":0,` +
	`"kd":0,"fkd":3672518972,"pd":-1872573247,"dyn":"",` +
	`"do":0,"tk":true}`

// hgMedusaMessage 组装 medusa 的 protobuf 消息体（混淆前）。
func hgMedusaMessage(rawURL string, body []byte, khronos uint32, deviceID, version string, ctx hgMedusaContext) []byte {
	bodyMd5 := make([]byte, 16)
	if len(body) > 0 {
		bodyMd5 = hgMD5(body)
	}
	query := hgQueryOf(rawURL)
	querySm3 := hgSM3([]byte(query))
	ts := hgLe32(khronos)
	queryBodyTs := hgHashF13(querySm3, bodyMd5, ts, khronos)

	env := hgProto(
		hgProtoField{Tag: 1, Value: ctx.EnvLaunch, Type: "sint"},
		hgProtoField{Tag: 2, Value: int64(146331399), Type: "sint"},
		hgProtoField{Tag: 3, Value: int64(146331396), Type: "sint"},
		hgProtoField{Tag: 5, Value: int64(7), Type: "sint"},
		hgProtoField{Tag: 6, Value: "v04.06.04.03-bugfix"},
		hgProtoField{Tag: 7, Value: ctx.EnvPID, Type: "sint"},
		hgProtoField{Tag: 12, Value: hgDeviceProtoWith(deviceID, version, ctx.Nonce, ctx.Started), Type: "message"},
		hgProtoField{Tag: 13, Type: "message", Value: hgProto(
			hgProtoField{Tag: 1, Value: ctx.NowUnix, Type: "sint"},
			hgProtoField{Tag: 2, Value: int64(-2), Type: "sint"},
			hgProtoField{Tag: 4, Value: int64(200), Type: "sint"},
		)},
		hgProtoField{Tag: 14, Value: version},
	)
	queryHash := hgSM3(append(append([]byte(query), bodyMd5...), []byte("none")...))

	nested := hgProto(
		hgProtoField{Tag: 1, Value: int64(111), Type: "sint"},
		hgProtoField{Tag: 2, Value: int64(10), Type: "sint"},
		hgProtoField{Tag: 3, Value: int64(694367), Type: "sint"},
		hgProtoField{Tag: 5, Value: int64(586952199), Type: "sint"},
	)
	return hgProto(
		hgProtoField{Tag: 1, Value: hgMedusaMagic16, Type: "bytes"},
		hgProtoField{Tag: 2, Value: int64(3), Type: "sint"},
		hgProtoField{Tag: 3, Value: int64(ctx.MessageRand), Type: "sint"},
		hgProtoField{Tag: 4, Value: "8662"},
		hgProtoField{Tag: 5, Value: deviceID},
		hgProtoField{Tag: 6, Value: "1588093228"},
		hgProtoField{Tag: 7, Value: version},
		hgProtoField{Tag: 8, Value: "v04.06.04-ml-android"},
		hgProtoField{Tag: 9, Value: int64(67503104), Type: "sint"},
		hgProtoField{Tag: 10, Value: hgMedusaMagic8, Type: "bytes"},
		hgProtoField{Tag: 12, Value: int64(khronos), Type: "sint"},
		hgProtoField{Tag: 13, Value: queryBodyTs, Type: "bytes"},
		hgProtoField{Tag: 14, Value: querySm3[0:6], Type: "bytes"},
		hgProtoField{Tag: 15, Value: nested, Type: "message"},
		hgProtoField{Tag: 16, Value: ctx.Nonce},
		hgProtoField{Tag: 17, Value: int64(khronos), Type: "sint"},
		hgProtoField{Tag: 19, Value: queryHash, Type: "bytes"},
		hgProtoField{Tag: 20, Value: "none"},
		hgProtoField{Tag: 21, Value: int64(312), Type: "sint"},
		hgProtoField{Tag: 23, Value: env, Type: "message"},
		hgProtoField{Tag: 24, Value: hgMedusaRuntimeJSON},
	)
}

// hgBuildMedusa：构造 x-medusa。
func hgBuildMedusa(rawURL string, body []byte, khronos uint32, deviceID, version string) string {
	return hgBuildMedusaWith(rawURL, body, khronos, deviceID, version, hgNewMedusaContext(), hgRandUint32(), hgRandUint32())
}

func hgBuildMedusaWith(rawURL string, body []byte, khronos uint32, deviceID, version string,
	ctx hgMedusaContext, random, xmRand uint32) string {
	querySm3 := hgSM3([]byte(hgQueryOf(rawURL)))
	bodyMd5 := make([]byte, 16)
	if len(body) > 0 {
		bodyMd5 = hgMD5(body)
	}
	ts := hgLe32(khronos)
	queryBodyTs := hgHashF13(querySm3, bodyMd5, ts, khronos)
	message := hgMedusaMessage(rawURL, body, khronos, deviceID, version, ctx)

	hash, seed := hgKeyHash(hgMedusaSignKey, random)
	transformed := hgXmxor(message, hash)
	transformed = append(append([]byte{}, hgMedusaMagic8...), transformed...)
	for i, j := 0, len(transformed)-1; i < j; i, j = i+1, j-1 {
		transformed[i], transformed[j] = transformed[j], transformed[i]
	}
	for i := range transformed {
		transformed[i] ^= seed[^i&3]
	}
	check := uint32(querySm3[0]&63)<<14 | 0x18000001 | uint32(queryBodyTs[0]&63)<<8
	packed := make([]byte, 0, len(transformed)+11)
	packed = append(packed, 0x35)
	packed = append(packed, hgLe32(xmRand)...)
	packed = append(packed, hgLe32(check)...)
	packed = append(packed, transformed...)
	packed = append(packed, byte(random>>16)&255, byte(random>>24)&255)

	encrypted := hgNewAesV3(hgMedusaAESKey, khronos).encrypt(packed, hgMedusaAESIV)
	prefix := make([]byte, 20)
	for i := 0; i < 20; i += 4 {
		binary.LittleEndian.PutUint32(prefix[i:], hgReadLe32(hgMedusaVersionBytes, i)^khronos)
	}
	out := append(prefix, byte(random)&255, byte(random>>8)&255, 0, 1)
	return hgB64(append(out, encrypted...))
}

// hgHelios：md5 ASCII 化 -> 64 位字表 -> 34 轮扩展 -> 分组类 Feistel。
func hgHelios(khronos uint32) string {
	return hgHeliosWith(khronos, hgRandUint32())
}

func hgHeliosWith(khronos uint32, random uint32) string {
	digest := hgMD5(append(hgLe32(random), []byte("8662")...))
	ascii := []byte(hgHex(digest))
	var words [4]uint64
	for i := 0; i < 4; i++ {
		words[i] = hgReadU64Le(ascii, i*8)
	}

	queue := []uint64{words[2], words[3]}
	b0 := words[0]
	b8 := words[1]
	table := make([]uint64, 35)
	table[0] = words[0]
	for i := 0; i < 34; i++ {
		x8 := hgRotr64(b8, 8) + b0
		x8 ^= uint64(i)
		queue = append(queue, x8)
		x8 ^= hgRotr64(b0, 61)
		table[i+1] = x8
		b0 = x8
		b8 = queue[0]
		queue = queue[1:]
	}

	text := strconv.FormatUint(uint64(khronos), 10) + "-1588093228-8662"
	tb := []byte(text)
	padLen := (len(tb) + 1 + 15) / 16 * 16
	pad := make([]byte, padLen)
	padFill := byte(16 - len(tb)%16)
	for i := range pad {
		pad[i] = padFill
	}
	copy(pad, tb)

	var output []byte
	for at := 0; at < len(pad); at += 16 {
		a := hgReadU64Le(pad, at)
		b := hgReadU64Le(pad, at+8)
		for i := 0; i < 34; i++ {
			b = table[i] ^ (a + hgRotr64(b, 8))
			a = b ^ hgRotr64(a, 61)
		}
		block := make([]byte, 16)
		hgPutU64Le(block, 0, a)
		hgPutU64Le(block, 8, b)
		output = append(output, block...)
	}
	return hgB64(append(hgLe32(random), output...))
}

// ==================== 入口 ====================

func hgQueryOf(rawURL string) string {
	if index := strings.IndexByte(rawURL, '?'); index >= 0 {
		return rawURL[index+1:]
	}
	return ""
}

func hgParamOf(query, key, fallback string) string {
	for _, pair := range strings.Split(query, "&") {
		index := strings.IndexByte(pair, '=')
		if index <= 0 {
			continue
		}
		if pair[:index] == key {
			if value := pair[index+1:]; value != "" {
				return value
			}
		}
	}
	return fallback
}

// hgBranchOf 与 hgHashF13 用同一分支计算；结果为 1 时服务端不接受，
// 调用方必须抖动 _rticket 重新签名。
func hgBranchOf(rawURL string, body []byte, khronos uint32) int {
	bodyMd5 := make([]byte, 16)
	if len(body) > 0 {
		bodyMd5 = hgMD5(body)
	}
	query := hgSM3([]byte(hgQueryOf(rawURL)))
	iv := hgGetIv(hgGetIv(hgGetIv(0x20230928, query), bodyMd5), hgLe32(khronos))
	low := int(iv & 15)
	return low - (((low * 171) >> 9) * 3)
}

// hgSignHeaders 返回需要合并进请求头的六个签名字段。
// rawURL 必须与最终发出的请求字节一致（含 query 与 _rticket）。
func hgSignHeaders(rawURL string, body []byte, khronos uint32, deviceID, version string) map[string]string {
	query := hgQueryOf(rawURL)
	headers := make(map[string]string, 6)
	headers["x-gorgon"] = hgXGorgon(query, body, khronos, hgRandInt(65536))
	headers["x-khronos"] = strconv.FormatUint(uint64(khronos), 10)
	headers["x-ladon"] = hgB64(hgBe32(khronos))
	headers["x-argus"] = hgB64(hgLe32(khronos))
	headers["x-helios"] = hgHelios(khronos)
	headers["x-medusa"] = hgBuildMedusa(rawURL, body, khronos, deviceID, version)
	return headers
}

// hgBumpTicket 把 _rticket 自增 1 并重建 query；缺失时先补一个再自增。
func hgBumpTicket(rawQuery string) (string, bool) {
	values, err := url.ParseQuery(rawQuery)
	if err != nil {
		return rawQuery, false
	}
	current, err := strconv.ParseInt(values.Get("_rticket"), 10, 64)
	if err != nil {
		current = time.Now().UnixMilli()
	}
	values.Set("_rticket", strconv.FormatInt(current+1, 10))
	return values.Encode(), true
}

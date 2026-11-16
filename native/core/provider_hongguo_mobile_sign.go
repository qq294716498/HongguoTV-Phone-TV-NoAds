// SPDX-License-Identifier: GPL-3.0-only
package core

import (
	"encoding/binary"
	"errors"
	"net/http"
	"strconv"
	"time"
)

var hgV5Magic = hgUnhex("2d4b4fca49750d433fb5ae2c226dcc56")
var hgV5SignKey = hgUnhex("b23c2a470a20d105dc3f8c4438f8272ed46d6c89ffdcdedd5108698d26e9489d")

func hgV5Hash(querySm3, bodyMd5 []byte, khronos uint32) []byte {
	tsBytes := hgLe32(khronos)
	ivV1 := uint32(0x9d4a97c2)
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
	for i := 0; i < 112; i++ {
		di1 := di[i+1]
		di14 := di[i+14]
		r1 := hgRotl32(di1, 14) ^ hgRotl32(di1, 25) ^ di1>>3
		r2 := hgRotl32(di14, 13) ^ hgRotl32(di14, 15) ^ di14>>10
		di = append(di, di[i]+di[i+9]+r1+r2)
	}

	var init [8]uint32
	for i := 0; i < 8; i++ {
		init[i] = hgRotr32(hgF13InitRaw[i], int(countV2&31))
	}
	chosen := [11]int{96, 1, 3, 4, 0, 6, 5, 2, 0, 7, 7}
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
	return append(append([]byte{}, head...), hgLe32((hgSumMd5(head) | 0x20))...)
}

var hgV5SBox = hgUnhex("53290fe9e51f316f90f74a7e034d367784ab49237cd0135cdc632c322fd3be0e2624a417ecd9151a7ff64f60730a87f9445ec6ada2f865d22b696c4188f24c0df37b75510b939f6bc2fe6883e68bc8c722181ba0bdb08c9871b50c9a16b46eea8eed20ba4b8a14e0fcf1468dbbef05a93e5a9d7dcf06898635c1fd99f5de287a80c594daaab19b6279fbd75070cb52eb2555c456e39e7839853874e2f0013ac0b64742d8ca10e4b79c955de8b843ce4ed464a6a72ed508091c92e7b3eedd1e1dd12afac321618fa3d65f9167c982f43d66a53c6a1997585b346dbf9672ff37cdbc073b2dae11453304df00815476b2a13fccdb30b957a8acafe127400248591238922563e36406d37a24100b7902a028044e218453c2a399199c9d13dc40c55ba67e502273850ebdc1a2e2188b8f2d9e3cb909b8c46a2a9f4a6dd93007eafa65b7b3a881aa908cc74f0ad76bbbb58617c37012ca05a469fd44e62eecf1e4272ce860c0ae5eadf99b20d8f0234174006f3f110d7657d01645d4eff8f71471cbfe1cb2f52648727bf3c9de55153e031b4d61757db63dbf7782eeafe9018a8891362fb14759ac32bab03b349aeb5a377c5156be4c8dfbe13a684bda39cf836697c894545fe0f2491acea9fc6252f4ff1e0fe72bd2df6e67a7f635e5bcc6d1a5dd951d89960887a18eb40c785cdb1f80ed42299333ab98cdd67f316cd54346585dccd759fb722789b08807cc0fda293f7e5e1819bb0353517020b31d3d00374952bea2c421e862040a9ec892a05b266b7a0d0cc316f483b81af39715657ffe32ad8de0c13077646035236ee5363e5f900e9a7cf850a81cd9960b6df73317226f99eaa6fff15cec34acb98246639b918ab2851466a7cdfc4ad1b52c2ae95a58d3734e47ddd5b7560193f644ef9c408b7dee39b4d6aabf4de761e3252d4c7ba3843187745d55e6a5db05d42b45caed43c0c5d0b64bfa9d94a4a9d8f2f0e1a108dcfd288fd2bc1fc7bd675412138169cb09249875ba3b68cfb11180afae104fc9789571c6dfce02413886796ae21e3c488cc21b9f423a066c2eabf98e2fdeeb5776e4f5d09a515ba58cbbab3e37b09fd4f6d9244df80512e84cd7956be301cf64f1429d58577cc241f3a2c655144f81aaf95a4e108da894b38970561ae9002619fbbac91fa922ed202bfc62cb08e0de2a7f3631435f8b47c8a3c563b4db4071ce74c46da6fa696a9e282d1e825d663b93bfd56c48dce1884bb10fccea063929f746443fd830a4232e53da21a1f2d1bdfebc3a02c10a1b8ad31d04fd616590d272ac737e98eb33af60528716bee78ec0ee8699031177277d9cff32542c67caf5f44591681335ae0e178f3409a7803db83892dde5b9b7f0c750e24aef077badd678a09b850b84ec1597e4963cb5e675df1c0d6fb618496ecd76c35c798325590c2fb27a5e")

func hgV5Carrier(key, source, iv []byte, ts uint32) []byte {
	aes := hgNewAesProfile(key, ts, true)
	wire := [8]uint{6, 5, 3, 4, 2, 7, 1, 0}
	compact := [8]uint{1, 7, 3, 6, 2, 0, 4, 5}
	plaintext := make([]byte, 32)
	for i := 0; i < 31; i++ {
		for j := 0; j < 8; j++ {
			plaintext[i] |= ((source[i*8+j] >> wire[j]) & 1) << compact[j]
		}
	}
	plaintext[31] = 1
	var cipher []byte
	previous := iv
	for i := 0; i < 32; i += 16 {
		block := make([]byte, 16)
		for j := 0; j < 16; j++ {
			block[j] = plaintext[i+j] ^ previous[j]
		}
		previous = aes.block(block)
		cipher = append(cipher, previous...)
	}
	out := append([]byte{}, source...)
	for i := 0; i < 31; i++ {
		for j := 0; j < 8; j++ {
			at := i*8 + j
			out[at] = (out[at] & ^(byte(1) << wire[j])) | (((cipher[i] >> compact[j]) & 1) << wire[j])
		}
	}
	return append([]byte{cipher[31]}, out...)
}

func hgV5Medusa(rawURL string, body []byte, ts uint32, deviceID string, ctx hgMedusaContext, nonce, packedRand uint32) string {
	query := hgSM3([]byte(hgQueryOf(rawURL)))
	f13 := hgV5Hash(query, hgMD5(body), ts)
	flags := make([]byte, 8)
	device := hgProto(
		hgProtoField{1, int64(1), "sint"}, hgProtoField{2, int64(2), "sint"},
		hgProtoField{3, "8662", ""}, hgProtoField{4, deviceID, ""}, hgProtoField{5, ctx.Nonce, ""},
		hgProtoField{6, "!noperm!", ""}, hgProtoField{12, "Asia/Shanghai,8", ""}, hgProtoField{13, "zh_CN", ""},
		hgProtoField{22, "12", ""}, hgProtoField{25, ctx.Started, "sint"},
		hgProtoField{30, "PGT-AN10", ""}, hgProtoField{31, "HONOR", ""}, hgProtoField{32, "PGT-AN10", ""}, hgProtoField{34, "HONOR", ""},
	)
	env := hgProto(hgProtoField{6, "v04.10.03.04-bugfix", ""}, hgProtoField{8, "vivo_8662_64", ""},
		hgProtoField{12, device, "message"}, hgProtoField{14, "7.4.3.32", ""})
	counts := hgProto(hgProtoField{1, int64(1), "sint"}, hgProtoField{2, int64(1), "sint"}, hgProtoField{3, int64(1), "sint"}, hgProtoField{5, int64(1), "sint"})
	message := hgProto(
		hgProtoField{1, hgV5Magic, "bytes"}, hgProtoField{2, int64(5), "sint"}, hgProtoField{3, int64(ctx.MessageRand), "sint"},
		hgProtoField{4, "8662", ""}, hgProtoField{5, deviceID, ""}, hgProtoField{6, "646637794", ""},
		hgProtoField{7, "7.4.3.32", ""}, hgProtoField{8, "v04.10.03-ml-android", ""}, hgProtoField{9, int64(0x040a0300), "sint"},
		hgProtoField{10, flags, "bytes"}, hgProtoField{12, int64(ts), "sint"}, hgProtoField{13, f13, "bytes"}, hgProtoField{14, query[:6], "bytes"},
		hgProtoField{15, counts, "message"}, hgProtoField{17, int64(ts), "sint"}, hgProtoField{20, "none", ""}, hgProtoField{21, int64(377), "sint"},
		hgProtoField{23, env, "message"}, hgProtoField{24, `{"cmr":16777216,"cmr2":16777216,"un_h":11,"vpn":0,"kd":0,"dyn":"","do":1,"tk":true}`, ""},
	)
	hash, seed := hgKeyHash(hgV5SignKey, nonce)
	transformed := append(flags, hgXmxor(message, hash)...)
	for i, j := 0, len(transformed)-1; i < j; i, j = i+1, j-1 {
		transformed[i], transformed[j] = transformed[j], transformed[i]
	}
	for i := range transformed {
		transformed[i] ^= seed[^i&3]
	}
	check := uint32(0x18000001) | uint32(query[0]&63)<<14 | uint32(f13[0]&63)<<8
	packed := append([]byte{0xca}, hgLe32(packedRand)...)
	packed = append(packed, hgLe32(check)...)
	packed = append(packed, transformed...)
	packed = append(packed, byte(nonce>>16), byte(nonce>>24))
	encrypted := hgV5Carrier(hgMD5(hgV5SignKey[:16]), packed, hgMD5(hgV5SignKey[16:]), ts)
	prefix := append(hgLe32(5), hgV5Magic...)
	for i := range prefix {
		prefix[i] ^= hgLe32(ts)[i&3]
	}
	return hgB64(append(append(prefix, byte(nonce), byte(nonce>>8), 0, 1), encrypted...))
}

func signHongguoMobileRequest(request *http.Request, body []byte, now time.Time) error {
	ts := uint32(now.Unix())
	for i := 0; i < 1024; i++ {
		query := hgSM3([]byte(request.URL.RawQuery))
		iv := hgGetIv(hgGetIv(hgGetIv(0x20230928, query), hgMD5(body)), hgLe32(ts))
		if iv&15 == 12 {
			request.Header.Set("X-Khronos", strconv.FormatUint(uint64(ts), 10))
			request.Header.Set("X-Helios", hgHeliosLicense(ts, hgRandUint32(), "646637794"))
			request.Header.Set("X-Medusa", hgV5Medusa(request.URL.String(), body, ts, request.URL.Query().Get("device_id"), hgNewMedusaContext(), hgRandUint32(), hgRandUint32()))
			return nil
		}
		next, ok := hgBumpTicket(request.URL.RawQuery)
		if !ok {
			break
		}
		request.URL.RawQuery = next
	}
	return errors.New("红果 v5 播放请求签名准备失败")
}

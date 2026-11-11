package core

import (
	"encoding/base64"
	"strings"
)

func nativeDecodeTextCover(data []byte) ([]byte, bool) {
	if len(data) < 16 {
		return nil, false
	}
	for index, char := range []byte("data:") {
		if data[index]^18 != char {
			return nil, false
		}
	}
	decoded := append([]byte(nil), data...)
	for index := 0; index < min(4096, len(decoded)); index++ {
		decoded[index] ^= 18
	}
	text := string(decoded)
	comma := strings.IndexByte(text, ',')
	if comma < 0 {
		return nil, false
	}
	header := strings.ToLower(text[:comma])
	if !strings.HasPrefix(header, "data:image/") || !strings.HasSuffix(header, ";base64") {
		return nil, false
	}
	payload := strings.Map(func(char rune) rune {
		switch char {
		case ' ', '\t', '\r', '\n':
			return -1
		}
		return char
	}, text[comma+1:])
	image, err := base64.StdEncoding.DecodeString(payload)
	if err != nil {
		image, err = base64.RawStdEncoding.DecodeString(payload)
	}
	if err != nil || !nativeIsCoverImage(image) {
		return nil, false
	}
	return image, true
}

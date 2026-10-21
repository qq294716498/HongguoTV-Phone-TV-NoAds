package core

func hongguoMediaContentType(value, fallback int) int {
	if value >= 1 && value <= 7 || value >= 1000 && value <= 1011 {
		return value
	}
	return fallback
}

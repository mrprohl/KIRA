package guard

import (
	"math/big"
	"regexp"
	"strings"
)

// Pattern check: unambiguous data found without a model (microseconds). A hit counts as a privacy hit.

var (
	reIBAN       = regexp.MustCompile(`\b[A-Z]{2}[0-9]{2}(?:[ ]?[A-Z0-9]){11,30}\b`)
	reCard       = regexp.MustCompile(`\b[3-6](?:[ -]?[0-9]){12,18}\b`)
	reEmail      = regexp.MustCompile(`[A-Za-z0-9._%+-]+@([A-Za-z0-9-]+\.)+[A-Za-z]{2,}`)
	rePhoneIntl  = regexp.MustCompile(`(?:\+|\b00)[1-9][0-9]{0,2}[ /-]?\(?[0-9]{1,5}\)?[ /-]?[0-9]{3,}(?:[ /-]?[0-9]{1,6})?`)
	rePhoneDE    = regexp.MustCompile(`\b0[1-9][0-9]{1,4}[ /-]?[0-9]{4,10}\b`)
	rePrivateKey = regexp.MustCompile(`-----BEGIN [A-Z ]*PRIVATE KEY-----`)
	reAPIKey     = regexp.MustCompile(`\b(?:sk-[A-Za-z0-9_-]{20,}|ghp_[A-Za-z0-9]{36}|github_pat_[A-Za-z0-9_]{40,}|AKIA[0-9A-Z]{16}|xox[baprs]-[A-Za-z0-9-]{10,}|AIza[0-9A-Za-z_-]{35}|glpat-[A-Za-z0-9_-]{20,})`)
	rePassword   = regexp.MustCompile(`(?i)\b(?:passwor[dt]|kennwort|passwd|pwd)\s*[:=]\s*\S{4,}`)
)

// example domains are not personal data (documentation, templates)
var exampleDomains = []string{"example.com", "example.org", "example.net", "example.de", "beispiel.de"}

// Patterns returns the categories found in text (sorted, unique).
func Patterns(text string) []string {
	found := map[string]bool{}
	for _, m := range reIBAN.FindAllString(text, -1) {
		if validIBAN(m) {
			found["iban"] = true
			break
		}
	}
	for _, m := range reCard.FindAllString(text, -1) {
		if luhn(m) {
			found["credit_card"] = true
			break
		}
	}
	for _, m := range reEmail.FindAllString(text, -1) {
		if !isExampleAddress(m) {
			found["email"] = true
			break
		}
	}
	if rePhoneIntl.MatchString(text) || rePhoneDE.MatchString(text) {
		found["phone"] = true
	}
	if rePrivateKey.MatchString(text) {
		found["private_key"] = true
	}
	if reAPIKey.MatchString(text) {
		found["api_key"] = true
	}
	if rePassword.MatchString(text) {
		found["password"] = true
	}
	return sortedKeys(found)
}

func isExampleAddress(addr string) bool {
	domain := strings.ToLower(addr[strings.LastIndex(addr, "@")+1:])
	for _, d := range exampleDomains {
		if domain == d || strings.HasSuffix(domain, "."+d) {
			return true
		}
	}
	return false
}

// validIBAN: length 15–34 and checksum mod 97 == 1
func validIBAN(s string) bool {
	s = strings.ReplaceAll(s, " ", "")
	if len(s) < 15 || len(s) > 34 {
		return false
	}
	r := s[4:] + s[:4]
	var b strings.Builder
	for _, ch := range r {
		switch {
		case ch >= '0' && ch <= '9':
			b.WriteRune(ch)
		case ch >= 'A' && ch <= 'Z':
			b.WriteString(big.NewInt(int64(ch - 'A' + 10)).String())
		default:
			return false
		}
	}
	n, ok := new(big.Int).SetString(b.String(), 10)
	return ok && new(big.Int).Mod(n, big.NewInt(97)).Int64() == 1
}

// luhn: 13–19 digits with a valid Luhn checksum
func luhn(s string) bool {
	digits := make([]int, 0, 19)
	for _, ch := range s {
		if ch >= '0' && ch <= '9' {
			digits = append(digits, int(ch-'0'))
		}
	}
	if len(digits) < 13 || len(digits) > 19 {
		return false
	}
	sum := 0
	for i := len(digits) - 1; i >= 0; i-- {
		d := digits[i]
		if (len(digits)-1-i)%2 == 1 {
			d *= 2
			if d > 9 {
				d -= 9
			}
		}
		sum += d
	}
	return sum%10 == 0
}

package main

import (
	"crypto/sha256"
	"crypto/subtle"
	"net/http"
	"net/netip"
	"strings"
)

type securityPolicy struct {
	AllowlistEntries  []string `json:"allowlistEntries"`
	AuthHeaderEnabled bool     `json:"authHeaderEnabled"`
	AuthHeaderName    string   `json:"authHeaderName"`
	AuthHeaderSecret  string   `json:"authHeaderSecret"`
}

func (p securityPolicy) allows(headers http.Header) (bool, string) {
	ip, unambiguous := sourceIP(headers)
	if !unambiguous {
		return false, "unknown"
	}
	if p.AuthHeaderEnabled {
		name := strings.TrimSpace(p.AuthHeaderName)
		values := headers.Values(name)
		if name == "" || p.AuthHeaderSecret == "" || len(values) != 1 {
			return false, ip
		}
		want, got := sha256.Sum256([]byte(p.AuthHeaderSecret)), sha256.Sum256([]byte(values[0]))
		if subtle.ConstantTimeCompare(want[:], got[:]) != 1 {
			return false, ip
		}
	}
	entries := make([]string, 0, len(p.AllowlistEntries))
	for _, entry := range p.AllowlistEntries {
		if trimmed := strings.TrimSpace(entry); trimmed != "" {
			entries = append(entries, trimmed)
		}
	}
	if len(entries) == 0 {
		return true, ip
	}
	address, err := netip.ParseAddr(ip)
	if err != nil {
		return false, ip
	}
	allowed := false
	for _, entry := range entries {
		entry = strings.TrimSpace(entry)
		if entry == "" {
			continue
		}
		if prefix, err := netip.ParsePrefix(entry); err == nil {
			allowed = allowed || prefix.Contains(address)
		} else if exact, err := netip.ParseAddr(entry); err == nil {
			allowed = allowed || exact == address
		} else {
			return false, ip // An invalid policy never silently becomes allow-all.
		}
	}
	return allowed, ip
}

func sourceIP(headers http.Header) (string, bool) {
	if values, exists := headers[http.CanonicalHeaderKey("CF-Connecting-IP")]; exists {
		if len(values) != 1 || strings.Contains(values[0], ",") {
			return "unknown", false
		}
		return strings.TrimSpace(values[0]), true
	}
	values := headers.Values("X-Forwarded-For")
	if len(values) > 1 {
		return "unknown", false
	}
	if len(values) == 1 {
		first, _, _ := strings.Cut(values[0], ",")
		return strings.TrimSpace(first), true
	}
	return "unknown", true
}

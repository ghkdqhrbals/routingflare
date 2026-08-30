package main

import (
	"bufio"
	"context"
	"crypto/rand"
	"encoding/hex"
	"fmt"
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/gorilla/websocket"
)

// Opt-in: a temporary, secret-protected echo service; never touches saved DNS routes.
func TestCloudflaredWebSocketEndToEnd(t *testing.T) {
	binary := os.Getenv("ROUTINGFLARE_TEST_CLOUDFLARED")
	if binary == "" {
		t.Skip("set ROUTINGFLARE_TEST_CLOUDFLARED to run the public tunnel smoke test")
	}
	secretBytes := make([]byte, 32)
	if _, err := rand.Read(secretBytes); err != nil {
		t.Fatal(err)
	}
	secret := hex.EncodeToString(secretBytes)
	upgrader := websocket.Upgrader{Subprotocols: []string{"routingflare-test"}, EnableCompression: true, CheckOrigin: func(r *http.Request) bool {
		return r.Header.Get("Origin") == "https://probe.example.com" && r.Header.Get("X-Probe-Key") == secret
	}}
	origin := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		conn, err := upgrader.Upgrade(w, r, nil)
		if err != nil {
			return
		}
		defer conn.Close()
		for {
			kind, body, err := conn.ReadMessage()
			if err != nil {
				return
			}
			if err := conn.WriteMessage(kind, body); err != nil {
				return
			}
		}
	}))
	t.Cleanup(origin.Close)
	u, _ := url.Parse(origin.URL)
	port, _ := strconv.Atoi(u.Port())
	p := startTestProxy(t, origin.URL, testRoute{Port: port, Path: "/", Open: true, Security: &testSecurity{Allowlist: []string{}, Enabled: true, Name: "X-Probe-Key", Secret: secret}})
	config := filepath.Join(t.TempDir(), "quick.yml")
	if err := os.WriteFile(config, []byte("no-autoupdate: true\nloglevel: info\n"), 0600); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 90*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, binary, "tunnel", "--config", config, "--url", p.url)
	pipe, err := cmd.StdoutPipe()
	if err != nil {
		t.Fatal(err)
	}
	cmd.Stderr = cmd.Stdout
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	finished := make(chan struct{})
	addresses := make(chan string, 1)
	logs := &lockedLog{}
	go func() {
		pattern := regexp.MustCompile(`https://[a-zA-Z0-9-]+\.trycloudflare\.com`)
		scanner := bufio.NewScanner(pipe)
		for scanner.Scan() {
			line := scanner.Text()
			fmt.Fprintln(logs, line)
			if address := pattern.FindString(line); address != "" {
				select {
				case addresses <- address:
				default:
				}
			}
		}
		_ = cmd.Wait()
		close(finished)
	}()
	t.Cleanup(func() {
		_ = cmd.Process.Signal(os.Interrupt)
		select {
		case <-finished:
		case <-time.After(5 * time.Second):
			cancel()
			<-finished
		}
	})
	var public string
	select {
	case public = <-addresses:
	case <-ctx.Done():
		t.Fatalf("quick URL was not issued: %s", logs.text())
	case <-finished:
		t.Fatalf("cloudflared exited: %s", logs.text())
	}
	dialer := websocket.Dialer{Subprotocols: []string{"routingflare-test"}, EnableCompression: true, HandshakeTimeout: 5 * time.Second}
	if dnsServer := os.Getenv("ROUTINGFLARE_TEST_DNS_SERVER"); dnsServer != "" {
		resolver := &net.Resolver{PreferGo: true, Dial: func(ctx context.Context, network, _ string) (net.Conn, error) {
			return (&net.Dialer{}).DialContext(ctx, network, dnsServer)
		}}
		dialer.NetDialContext = (&net.Dialer{Resolver: resolver}).DialContext
		t.Logf("Test client DNS resolver: %s (system DNS unchanged)", dnsServer)
	}
	headers := http.Header{"Origin": []string{"https://probe.example.com"}, "X-Probe-Key": []string{secret}}
	var conn *websocket.Conn
	var response *http.Response
	for conn == nil {
		conn, response, err = dialer.DialContext(ctx, "wss"+strings.TrimPrefix(public, "https")+"/socket", headers)
		if conn != nil {
			break
		}
		if response != nil {
			response.Body.Close()
		}
		select {
		case <-ctx.Done():
			t.Fatalf("public WebSocket failed: %v\n%s", err, logs.text())
		case <-time.After(time.Second):
		}
	}
	defer conn.Close()
	if response.StatusCode != 101 || conn.Subprotocol() != "routingflare-test" {
		t.Fatal("public WebSocket handshake changed")
	}
	_ = conn.SetReadDeadline(time.Now().Add(10 * time.Second))
	for _, kind := range []int{websocket.TextMessage, websocket.BinaryMessage} {
		message := []byte("public-proxy-roundtrip")
		if kind == websocket.BinaryMessage {
			message = []byte{0, 255, 17, 42}
		}
		if err := conn.WriteMessage(kind, message); err != nil {
			t.Fatal(err)
		}
		gotKind, got, err := conn.ReadMessage()
		if err != nil || gotKind != kind || string(got) != string(message) {
			t.Fatalf("public roundtrip failed: %v", err)
		}
	}
	_ = conn.WriteControl(websocket.CloseMessage, websocket.FormatCloseMessage(1000, "done"), time.Now().Add(time.Second))
	_, _, err = conn.ReadMessage()
	if !websocket.IsCloseError(err, 1000) {
		t.Fatalf("public close frame changed: %v", err)
	}
	t.Log("Cloudflare -> cloudflared -> Swift-owned proxy -> origin: 101, text, binary and close verified")
}

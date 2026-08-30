package main

import (
	"bufio"
	"bytes"
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/gorilla/websocket"
)

type testSecurity struct {
	Allowlist []string `json:"allowlistEntries"`
	Enabled   bool     `json:"authHeaderEnabled"`
	Name      string   `json:"authHeaderName"`
	Secret    string   `json:"authHeaderSecret"`
}

type testRoute struct {
	Host     string        `json:"hostname"`
	Port     int           `json:"targetPort"`
	Path     string        `json:"targetPath"`
	Security *testSecurity `json:"security,omitempty"`
	Open     bool          `json:"isOpen"`
}

type testConfig struct {
	ID      int          `json:"id"`
	Version int          `json:"version"`
	Routes  []testRoute  `json:"routes"`
	Port    int          `json:"fallbackTargetPort"`
	Default testSecurity `json:"defaultPolicy"`
}

type testEvent struct {
	Type    string `json:"type"`
	ID      int    `json:"id"`
	Port    int    `json:"port"`
	Message string `json:"message"`
}

type lockedLog struct {
	sync.Mutex
	buffer bytes.Buffer
}

func (l *lockedLog) Write(b []byte) (int, error) {
	l.Lock()
	defer l.Unlock()
	return l.buffer.Write(b)
}
func (l *lockedLog) text() string { l.Lock(); defer l.Unlock(); return l.buffer.String() }

type testProxy struct {
	url          string
	input        io.WriteCloser
	cmd          *exec.Cmd
	events       chan testEvent
	done         chan struct{}
	log          *lockedLog
	config       testConfig
	exitError    error
	expectKilled bool
}

func startTestProxy(t *testing.T, origin string, routes ...testRoute) *testProxy {
	t.Helper()
	u, err := url.Parse(origin)
	if err != nil {
		t.Fatal(err)
	}
	port, _ := strconv.Atoi(u.Port())
	config := testConfig{ID: 1, Version: 1, Routes: routes, Port: port, Default: testSecurity{Allowlist: []string{}}}
	if config.Routes == nil {
		config.Routes = []testRoute{}
	}
	binary := os.Getenv("ROUTINGFLARE_PROXY_TEST_BINARY")
	if binary == "" {
		binary, _ = filepath.Abs("../.build/proxy/routingflare-proxy")
	}
	cmd := exec.Command(binary)
	input, err := cmd.StdinPipe()
	if err != nil {
		t.Fatal(err)
	}
	output, err := cmd.StdoutPipe()
	if err != nil {
		t.Fatal(err)
	}
	p := &testProxy{input: input, cmd: cmd, config: config, events: make(chan testEvent, 64), done: make(chan struct{}), log: &lockedLog{}}
	cmd.Stderr = p.log
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	go func() {
		scanner := bufio.NewScanner(output)
		scanner.Buffer(make([]byte, 4096), 2<<20)
		for scanner.Scan() {
			var event testEvent
			if json.Unmarshal(scanner.Bytes(), &event) == nil {
				if event.Type == "log" {
					fmt.Fprintln(p.log, event.Message)
				} else {
					p.events <- event
				}
			}
		}
		p.exitError = cmd.Wait()
		close(p.done)
	}()
	t.Cleanup(func() {
		_ = input.Close()
		select {
		case <-p.done:
		case <-time.After(4 * time.Second):
			_ = cmd.Process.Kill()
			<-p.done
			t.Error("proxy did not exit after its owner closed stdin")
		}
		if p.exitError != nil && !p.expectKilled {
			t.Errorf("proxy process failed: %v\n%s", p.exitError, p.log.text())
		}
	})
	p.send(t, config)
	event := p.wait(t, "ready", 1)
	p.url = "http://127.0.0.1:" + strconv.Itoa(event.Port)
	return p
}

func (p *testProxy) send(t *testing.T, config testConfig) {
	t.Helper()
	if err := json.NewEncoder(p.input).Encode(config); err != nil {
		t.Fatal(err)
	}
}

func (p *testProxy) wait(t *testing.T, kind string, id int) testEvent {
	t.Helper()
	timer := time.NewTimer(5 * time.Second)
	defer timer.Stop()
	for {
		select {
		case event := <-p.events:
			if event.Type == "error" {
				t.Fatalf("proxy error: %s", event.Message)
			}
			if event.Type == kind && event.ID == id {
				return event
			}
		case <-p.done:
			t.Fatalf("proxy exited: %s", p.log.text())
		case <-timer.C:
			t.Fatalf("missing %s acknowledgement: %s", kind, p.log.text())
		}
	}
}

func (p *testProxy) update(t *testing.T, routes []testRoute) {
	t.Helper()
	p.config.ID++
	p.config.Routes = routes
	p.send(t, p.config)
	p.wait(t, "applied", p.config.ID)
}

func client(t *testing.T) *http.Client {
	t.Helper()
	transport := &http.Transport{Proxy: nil, DisableCompression: true}
	t.Cleanup(transport.CloseIdleConnections)
	return &http.Client{Transport: transport, Timeout: 4 * time.Second, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
}

func getBody(t *testing.T, resp *http.Response) []byte {
	t.Helper()
	defer resp.Body.Close()
	b, err := io.ReadAll(resp.Body)
	if err != nil {
		t.Fatal(err)
	}
	return b
}

func TestSplitContentLengthUpload(t *testing.T) {
	want := bytes.Repeat([]byte("split-body\x00\xff"), 400_000)
	origin := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, err := io.ReadAll(r.Body)
		if err != nil {
			http.Error(w, err.Error(), 400)
			return
		}
		fmt.Fprintf(w, "%x", sha256.Sum256(body))
	}))
	defer origin.Close()
	p := startTestProxy(t, origin.URL)
	reader, writer := io.Pipe()
	req, _ := http.NewRequest("POST", p.url+"/upload", reader)
	req.ContentLength = int64(len(want))
	go func() {
		defer writer.Close()
		_, _ = writer.Write(want[:128])
		time.Sleep(50 * time.Millisecond)
		_, _ = writer.Write(want[128:])
	}()
	resp, err := client(t).Do(req)
	if err != nil {
		t.Fatal(err)
	}
	if got := string(getBody(t, resp)); got != fmt.Sprintf("%x", sha256.Sum256(want)) {
		t.Fatalf("upload truncated/corrupted: status %d, response %q", resp.StatusCode, got)
	}
}

func TestChunkedUploadAndTrailers(t *testing.T) {
	origin := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, err := io.ReadAll(r.Body)
		if err != nil {
			http.Error(w, err.Error(), 400)
			return
		}
		w.Header().Set("X-Received-Trailer", r.Trailer.Get("X-Checksum"))
		_, _ = w.Write(body)
	}))
	defer origin.Close()
	p := startTestProxy(t, origin.URL)
	reader, writer := io.Pipe()
	req, _ := http.NewRequest("PUT", p.url+"/upload", reader)
	req.Trailer = http.Header{"X-Checksum": nil}
	go func() {
		_, _ = writer.Write([]byte("first\x00"))
		time.Sleep(30 * time.Millisecond)
		_, _ = writer.Write([]byte("second\xff"))
		req.Trailer.Set("X-Checksum", "complete")
		_ = writer.Close()
	}()
	resp, err := client(t).Do(req)
	if err != nil {
		t.Fatal(err)
	}
	if got := string(getBody(t, resp)); got != "first\x00second\xff" {
		t.Fatalf("chunk framing leaked or upload lost: %q", got)
	}
	if got := resp.Header.Get("X-Received-Trailer"); got != "complete" {
		t.Fatalf("request trailer lost: %q", got)
	}
}

func TestStreamingBeforeOriginFinishes(t *testing.T) {
	for _, contentType := range []string{"text/event-stream", "application/octet-stream"} {
		t.Run(contentType, func(t *testing.T) {
			release := make(chan struct{})
			origin := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				w.Header().Set("Content-Type", contentType)
				w.Header().Set("Trailer", "X-Stream-End")
				_, _ = w.Write([]byte("data: first\n\n"))
				w.(http.Flusher).Flush()
				select {
				case <-release:
				case <-r.Context().Done():
					return
				}
				_, _ = w.Write([]byte("data: last\n\n"))
				w.Header().Set("X-Stream-End", "complete")
			}))
			defer origin.Close()
			var once sync.Once
			defer once.Do(func() { close(release) })
			p := startTestProxy(t, origin.URL)
			resp, err := client(t).Get(p.url + "/events")
			if err != nil {
				t.Fatalf("response buffered until completion: %v", err)
			}
			defer resp.Body.Close()
			first := make([]byte, len("data: first\n\n"))
			if _, err := io.ReadFull(resp.Body, first); err != nil {
				t.Fatal(err)
			}
			if string(first) != "data: first\n\n" {
				t.Fatalf("first event changed: %q", first)
			}
			once.Do(func() { close(release) })
			if got := string(getBody(t, resp)); got != "data: last\n\n" {
				t.Fatalf("last event changed: %q", got)
			}
			if resp.Trailer.Get("X-Stream-End") != "complete" {
				t.Fatal("response trailer lost")
			}
		})
	}
}

func webSocketOrigin(t *testing.T) *httptest.Server {
	t.Helper()
	upgrader := websocket.Upgrader{
		Subprotocols: []string{"routingflare-test"}, EnableCompression: true,
		CheckOrigin: func(r *http.Request) bool {
			return r.Host == "public.example.com" && r.Header.Get("Origin") == "https://public.example.com" && r.Header.Get("Cookie") == "session=test"
		},
	}
	return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		conn, err := upgrader.Upgrade(w, r, http.Header{"X-Origin-Handshake": []string{"kept"}})
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
}

func dialWebSocket(t *testing.T, address string, extra http.Header) (*websocket.Conn, *http.Response, error) {
	t.Helper()
	headers := http.Header{"Host": []string{"public.example.com"}, "Origin": []string{"https://public.example.com"}, "Cookie": []string{"session=test"}}
	for k, v := range extra {
		headers[k] = v
	}
	dialer := websocket.Dialer{Subprotocols: []string{"routingflare-test"}, EnableCompression: true, HandshakeTimeout: 3 * time.Second}
	return dialer.Dial("ws"+strings.TrimPrefix(address, "http")+"/socket?token=a%2Fb", headers)
}

func TestWebSocketNegotiationFramesAndReconnect(t *testing.T) {
	origin := webSocketOrigin(t)
	defer origin.Close()
	p := startTestProxy(t, origin.URL)
	for _, address := range []string{origin.URL, p.url, p.url} {
		conn, resp, err := dialWebSocket(t, address, nil)
		if err != nil {
			t.Fatalf("WebSocket at %s: %v (response %v)", address, err, resp)
		}
		if resp.StatusCode != 101 || conn.Subprotocol() != "routingflare-test" || resp.Header.Get("X-Origin-Handshake") != "kept" || !strings.Contains(resp.Header.Get("Sec-Websocket-Extensions"), "permessage-deflate") {
			t.Fatal("handshake changed")
		}
		_ = conn.SetReadDeadline(time.Now().Add(3 * time.Second))
		for _, kind := range []int{websocket.TextMessage, websocket.BinaryMessage} {
			want := bytes.Repeat([]byte("message"), 150_000)
			if kind == websocket.BinaryMessage {
				want = make([]byte, 2<<20)
				if _, err := rand.Read(want); err != nil {
					t.Fatal(err)
				}
			}
			if err := conn.WriteMessage(kind, want); err != nil {
				t.Fatal(err)
			}
			gotKind, got, err := conn.ReadMessage()
			if err != nil {
				t.Fatal(err)
			}
			if gotKind != kind || !bytes.Equal(got, want) {
				t.Fatal("WebSocket frame data changed")
			}
		}
		pong := make(chan string, 1)
		conn.SetPongHandler(func(data string) error { pong <- data; return nil })
		if err := conn.WriteControl(websocket.PingMessage, []byte("heartbeat"), time.Now().Add(time.Second)); err != nil {
			t.Fatal(err)
		}
		if err := conn.WriteMessage(websocket.TextMessage, []byte("after-ping")); err != nil {
			t.Fatal(err)
		}
		if _, _, err := conn.ReadMessage(); err != nil {
			t.Fatal(err)
		}
		select {
		case value := <-pong:
			if value != "heartbeat" {
				t.Fatal("pong payload changed")
			}
		case <-time.After(time.Second):
			t.Fatal("pong lost")
		}
		_ = conn.WriteControl(websocket.CloseMessage, websocket.FormatCloseMessage(1000, "done"), time.Now().Add(time.Second))
		_, _, err = conn.ReadMessage()
		if !websocket.IsCloseError(err, 1000) {
			t.Fatalf("close frame not preserved: %v", err)
		}
		conn.Close()
	}
}

func TestWebSocketServerFirstFrameAndFragmentedMessages(t *testing.T) {
	upgrader := websocket.Upgrader{WriteBufferSize: 128, CheckOrigin: func(*http.Request) bool { return true }}
	origin := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		conn, err := upgrader.Upgrade(w, r, nil)
		if err != nil {
			return
		}
		defer conn.Close()
		_ = conn.WriteMessage(websocket.TextMessage, []byte("ready-before-client-message"))
		kind, body, err := conn.ReadMessage()
		if err != nil {
			return
		}
		_ = conn.WriteMessage(kind, body)
		_ = conn.WriteControl(websocket.CloseMessage, websocket.FormatCloseMessage(websocket.ClosePolicyViolation, "origin policy"), time.Now().Add(time.Second))
	}))
	t.Cleanup(origin.Close)
	p := startTestProxy(t, origin.URL)
	dialer := websocket.Dialer{WriteBufferSize: 128, HandshakeTimeout: 3 * time.Second}
	conn, _, err := dialer.Dial("ws"+strings.TrimPrefix(p.url, "http")+"/socket", nil)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	_ = conn.SetReadDeadline(time.Now().Add(3 * time.Second))
	if _, body, err := conn.ReadMessage(); err != nil || string(body) != "ready-before-client-message" {
		t.Fatalf("server-first WebSocket frame lost: %v", err)
	}
	writer, err := conn.NextWriter(websocket.BinaryMessage)
	if err != nil {
		t.Fatal(err)
	}
	want := bytes.Repeat([]byte{0, 255, 13, 10, 42}, 50_000)
	for offset := 0; offset < len(want); {
		end := min(offset+997, len(want))
		if _, err := writer.Write(want[offset:end]); err != nil {
			t.Fatal(err)
		}
		offset = end
	}
	if err := writer.Close(); err != nil {
		t.Fatal(err)
	}
	if kind, body, err := conn.ReadMessage(); err != nil || kind != websocket.BinaryMessage || !bytes.Equal(body, want) {
		t.Fatalf("fragmented WebSocket message changed: %v", err)
	}
	_, _, err = conn.ReadMessage()
	closeError, ok := err.(*websocket.CloseError)
	if !ok || closeError.Code != websocket.ClosePolicyViolation || closeError.Text != "origin policy" {
		t.Fatalf("origin close code/reason changed: %v", err)
	}
}

func TestStopClosesEstablishedWebSocket(t *testing.T) {
	origin := webSocketOrigin(t)
	defer origin.Close()
	p := startTestProxy(t, origin.URL)
	conn, _, err := dialWebSocket(t, p.url, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	_ = p.input.Close()
	_ = conn.SetReadDeadline(time.Now().Add(2 * time.Second))
	_, _, err = conn.ReadMessage()
	if ne, ok := err.(net.Error); ok && ne.Timeout() {
		t.Fatal("WebSocket stayed alive after proxy stop")
	}
	if err == nil {
		t.Fatal("expected connection to close")
	}
}

func TestRejectedUpgradeDoesNotBypassNextRequestSecurity(t *testing.T) {
	origin := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { _, _ = io.WriteString(w, r.URL.Path) }))
	defer origin.Close()
	u, _ := url.Parse(origin.URL)
	port, _ := strconv.Atoi(u.Port())
	p := startTestProxy(t, origin.URL,
		testRoute{Host: "public.example.com", Port: port, Path: "/", Open: true},
		testRoute{Host: "public.example.com", Port: port, Path: "/private", Open: true, Security: &testSecurity{Allowlist: []string{}, Enabled: true, Name: "X-Secret", Secret: "required"}},
	)
	conn, err := net.DialTimeout("tcp", strings.TrimPrefix(p.url, "http://"), time.Second)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	_ = conn.SetDeadline(time.Now().Add(3 * time.Second))
	_, _ = io.WriteString(conn, "GET /reject HTTP/1.1\r\nHost: public.example.com\r\nConnection: Upgrade\r\nUpgrade: websocket\r\n\r\n")
	reader := bufio.NewReader(conn)
	first, err := http.ReadResponse(reader, nil)
	if err != nil {
		t.Fatal(err)
	}
	_ = getBody(t, first)
	_, _ = io.WriteString(conn, "GET /private HTTP/1.1\r\nHost: public.example.com\r\nConnection: close\r\n\r\n")
	second, err := http.ReadResponse(reader, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer second.Body.Close()
	if second.StatusCode != 403 {
		t.Fatalf("request after rejected upgrade bypassed security: %d", second.StatusCode)
	}
}

func TestCancellationReachesStreamingOrigin(t *testing.T) {
	cancelled := make(chan struct{})
	origin := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		_, _ = io.WriteString(w, "data: ready\n\n")
		w.(http.Flusher).Flush()
		<-r.Context().Done()
		close(cancelled)
	}))
	t.Cleanup(origin.Close)
	p := startTestProxy(t, origin.URL)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	req, _ := http.NewRequestWithContext(ctx, "GET", p.url+"/events", nil)
	resp, err := client(t).Do(req)
	if err != nil {
		t.Fatal(err)
	}
	_ = resp.Body.Close()
	cancel()
	select {
	case <-cancelled:
	case <-time.After(2 * time.Second):
		t.Fatal("client cancellation did not cancel origin request")
	}
}

func TestOwnerDeathClosesEstablishedWebSocket(t *testing.T) {
	origin := webSocketOrigin(t)
	t.Cleanup(origin.Close)
	p := startTestProxy(t, origin.URL)
	conn, _, err := dialWebSocket(t, p.url, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	p.expectKilled = true
	if err := p.cmd.Process.Kill(); err != nil {
		t.Fatal(err)
	}
	_ = conn.SetReadDeadline(time.Now().Add(3 * time.Second))
	_, _, err = conn.ReadMessage()
	if ne, ok := err.(net.Error); ok && ne.Timeout() {
		t.Fatal("orphaned proxy kept the WebSocket open after owner death")
	}
	if err == nil {
		t.Fatal("WebSocket should close after owner death")
	}
}

func TestWebSocketPolicyChangesDoNotInterruptExistingStreams(t *testing.T) {
	origin := webSocketOrigin(t)
	t.Cleanup(origin.Close)
	u, _ := url.Parse(origin.URL)
	port, _ := strconv.Atoi(u.Port())
	routes := []testRoute{{Host: "public.example.com", Port: port, Path: "/", Open: true}}
	p := startTestProxy(t, origin.URL, routes...)
	conn, _, err := dialWebSocket(t, p.url, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	routes[0].Security = &testSecurity{Allowlist: []string{"203.0.113.0/24"}, Enabled: true, Name: "X-Secret", Secret: "required"}
	p.update(t, routes)
	_, resp, err := dialWebSocket(t, p.url, nil)
	if err == nil || resp == nil || resp.StatusCode != 403 {
		t.Fatalf("unauthorized WebSocket accepted: %v %v", err, resp)
	}
	resp.Body.Close()
	allowed, _, err := dialWebSocket(t, p.url, http.Header{"X-Secret": []string{"required"}, "Cf-Connecting-Ip": []string{"203.0.113.42"}})
	if err != nil {
		t.Fatal(err)
	}
	allowed.Close()
	_ = conn.SetReadDeadline(time.Now().Add(time.Second))
	if err := conn.WriteMessage(websocket.TextMessage, []byte("still-open")); err != nil {
		t.Fatal(err)
	}
	_, body, err := conn.ReadMessage()
	if err != nil || string(body) != "still-open" {
		t.Fatalf("policy update interrupted established stream: %v", err)
	}
}

func TestWebSocketOriginDenialIsPreserved(t *testing.T) {
	origin := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("WWW-Authenticate", "Bearer")
		http.Error(w, "origin rejected the handshake", http.StatusUnauthorized)
	}))
	t.Cleanup(origin.Close)
	p := startTestProxy(t, origin.URL)
	_, response, err := dialWebSocket(t, p.url, nil)
	if err == nil || response == nil || response.StatusCode != 401 {
		t.Fatalf("origin WebSocket denial changed: %v %v", response, err)
	}
	if string(getBody(t, response)) != "origin rejected the handshake\n" || response.Header.Get("WWW-Authenticate") != "Bearer" {
		t.Fatal("origin denial body/headers changed")
	}
	_ = p.input.Close()
	select {
	case <-p.done:
	case <-time.After(3 * time.Second):
		t.Fatal("proxy did not stop")
	}
	if !strings.Contains(p.log.text(), "WebSocket handshake returned 401") {
		t.Fatalf("missing actionable handshake status: %s", p.log.text())
	}
}

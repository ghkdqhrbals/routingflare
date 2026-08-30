package main

import (
	"bufio"
	"bytes"
	"compress/gzip"
	"context"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"net/http/httptrace"
	"net/textproto"
	"net/url"
	"reflect"
	"strconv"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

func TestHeadersCookiesHostAndEncodedURL(t *testing.T) {
	wantURI := "/files/a%2Fb/%E2%9C%93?a=%2f%26&a=b+z&opaque=x;y"
	captured := make(chan *http.Request, 2)
	origin := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		captured <- r.Clone(context.Background())
		w.Header().Add("Set-Cookie", "first=1; Expires=Wed, 21 Oct 2037 07:28:00 GMT; Path=/")
		w.Header().Add("Set-Cookie", "second=2; HttpOnly; Path=/")
		w.Header().Add("X-Multiple", "one")
		w.Header().Add("X-Multiple", "two")
		w.Header().Set("Location", "https://public.example.com/login")
		w.Header().Set("Connection", "X-Response-Hop")
		w.Header().Set("X-Response-Hop", "remove")
		w.WriteHeader(http.StatusFound)
		_, _ = io.WriteString(w, "redirect-body")
	}))
	t.Cleanup(origin.Close)
	p := startTestProxy(t, origin.URL)
	req, _ := http.NewRequest("GET", p.url+wantURI, nil)
	req.Host = "public.example.com"
	req.Header = http.Header{
		"Authorization": []string{"Bearer unchanged"}, "Cookie": []string{"first=1", "second=2"},
		"Origin": []string{"https://public.example.com"}, "X-Multiple": []string{"one", "two"},
		"Forwarded": []string{"for=203.0.113.5;proto=https"}, "X-Forwarded-For": []string{"203.0.113.5"},
		"X-Forwarded-Host": []string{"public.example.com"}, "X-Forwarded-Proto": []string{"https"},
		"Connection": []string{"keep-alive, X-Request-Hop"}, "X-Request-Hop": []string{"remove"},
	}
	resp, err := client(t).Do(req)
	if err != nil {
		t.Fatal(err)
	}
	if resp.StatusCode != 302 || string(getBody(t, resp)) != "redirect-body" {
		t.Fatal("redirect was followed or changed")
	}
	if len(resp.Header.Values("Set-Cookie")) != 2 || len(resp.Header.Values("X-Multiple")) != 2 {
		t.Fatal("duplicate response header lost")
	}
	if resp.Header.Get("X-Response-Hop") != "" {
		t.Fatal("hop-by-hop response field forwarded")
	}
	got := <-captured
	if got.Host != req.Host || got.RequestURI != wantURI {
		t.Fatalf("Host/URI changed: %s %s", got.Host, got.RequestURI)
	}
	for _, name := range []string{"Authorization", "Cookie", "Origin", "X-Multiple", "Forwarded", "X-Forwarded-For", "X-Forwarded-Host", "X-Forwarded-Proto"} {
		if !reflect.DeepEqual(got.Header.Values(name), req.Header.Values(name)) {
			t.Fatalf("%s changed: %v", name, got.Header.Values(name))
		}
	}
	if got.Header.Get("X-Request-Hop") != "" {
		t.Fatal("hop-by-hop request field forwarded")
	}
	second, err := client(t).Get(p.url + "/other-client")
	if err != nil {
		t.Fatal(err)
	}
	_ = getBody(t, second)
	if (<-captured).Header.Get("Cookie") != "" {
		t.Fatal("proxy shared a cookie jar between clients")
	}
}

func TestCompressedBinaryHeadRangeAndOriginErrors(t *testing.T) {
	var encoded bytes.Buffer
	compressor := gzip.NewWriter(&encoded)
	_, _ = compressor.Write(bytes.Repeat([]byte{0, 255, 17, 42}, 32_000))
	_ = compressor.Close()
	origin := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/head":
			w.Header().Set("Content-Length", "4096")
			w.WriteHeader(200)
		case "/cached":
			w.Header().Set("ETag", "\"kept\"")
			w.WriteHeader(304)
		case "/cors":
			w.Header().Set("Access-Control-Allow-Origin", r.Header.Get("Origin"))
			w.Header().Set("Access-Control-Allow-Headers", "Authorization")
			w.WriteHeader(204)
		case "/range":
			w.Header().Set("Content-Range", "bytes 3-6/10")
			w.WriteHeader(206)
			_, _ = io.WriteString(w, "3456")
		case "/denied":
			w.Header().Set("WWW-Authenticate", "Bearer")
			w.WriteHeader(403)
			_, _ = io.WriteString(w, "origin permission denied")
		default:
			w.Header().Set("Content-Encoding", "gzip")
			w.Header().Set("Content-Type", "application/octet-stream")
			_, _ = w.Write(encoded.Bytes())
		}
	}))
	t.Cleanup(origin.Close)
	p := startTestProxy(t, origin.URL)
	for _, tc := range []struct {
		method, path string
		status       int
		body         []byte
	}{
		{"GET", "/binary", 200, encoded.Bytes()}, {"HEAD", "/head", 200, nil}, {"GET", "/cached", 304, nil},
		{"OPTIONS", "/cors", 204, nil}, {"GET", "/range", 206, []byte("3456")}, {"PUT", "/denied", 403, []byte("origin permission denied")},
	} {
		req, _ := http.NewRequest(tc.method, p.url+tc.path, nil)
		req.Header.Set("Range", "bytes=3-6")
		req.Header.Set("Origin", "https://public.example.com")
		resp, err := client(t).Do(req)
		if err != nil {
			t.Fatal(err)
		}
		if resp.StatusCode != tc.status || !bytes.Equal(getBody(t, resp), tc.body) {
			t.Fatalf("%s semantics changed", tc.path)
		}
		if tc.path == "/head" && resp.ContentLength != 4096 {
			t.Fatal("HEAD representation length changed")
		}
		if tc.path == "/binary" && resp.Header.Get("Content-Encoding") != "gzip" {
			t.Fatal("compression header lost")
		}
		if tc.path == "/cors" && resp.Header.Get("Access-Control-Allow-Origin") != "https://public.example.com" {
			t.Fatal("CORS response changed")
		}
		if tc.path == "/range" && resp.Header.Get("Content-Range") != "bytes 3-6/10" {
			t.Fatal("range response changed")
		}
		if tc.path == "/denied" && resp.Header.Get("WWW-Authenticate") != "Bearer" {
			t.Fatal("origin auth response changed")
		}
	}
}

func TestHTTP2UploadAndResponseTrailers(t *testing.T) {
	origin := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, err := io.ReadAll(r.Body)
		if err != nil {
			http.Error(w, err.Error(), 400)
			return
		}
		w.Header().Set("X-Request-Trailer", r.Trailer.Get("X-Checksum"))
		w.Header().Set("Trailer", "X-Complete")
		_, _ = w.Write(body)
		w.Header().Set("X-Complete", "yes")
	}))
	t.Cleanup(origin.Close)
	p := startTestProxy(t, origin.URL)
	protocols := new(http.Protocols)
	protocols.SetUnencryptedHTTP2(true)
	transport := &http.Transport{Protocols: protocols, DisableCompression: true}
	t.Cleanup(transport.CloseIdleConnections)
	reader, writer := io.Pipe()
	req, _ := http.NewRequest("POST", p.url+"/upload", reader)
	req.Trailer = http.Header{"X-Checksum": nil}
	go func() {
		_, _ = writer.Write([]byte("h2-upload"))
		req.Trailer.Set("X-Checksum", "kept")
		_ = writer.Close()
	}()
	resp, err := (&http.Client{Transport: transport, Timeout: 4 * time.Second}).Do(req)
	if err != nil {
		t.Fatal(err)
	}
	if resp.ProtoMajor != 2 || string(getBody(t, resp)) != "h2-upload" {
		t.Fatal("HTTP/2 data changed")
	}
	if resp.Header.Get("X-Request-Trailer") != "kept" || resp.Trailer.Get("X-Complete") != "yes" {
		t.Fatal("HTTP/2 trailer lost")
	}
}

func TestFullDuplexHTTPUpload(t *testing.T) {
	origin := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_ = http.NewResponseController(w).EnableFullDuplex()
		b := make([]byte, 5)
		for {
			n, err := r.Body.Read(b)
			if n > 0 {
				_, _ = w.Write(b[:n])
				w.(http.Flusher).Flush()
			}
			if err != nil {
				return
			}
		}
	}))
	t.Cleanup(origin.Close)
	p := startTestProxy(t, origin.URL)
	reader, writer := io.Pipe()
	req, _ := http.NewRequest("POST", p.url+"/duplex", reader)
	go func() { _, _ = writer.Write([]byte("first")) }()
	resp, err := client(t).Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	defer writer.Close()
	first := make([]byte, 5)
	if _, err := io.ReadFull(resp.Body, first); err != nil || string(first) != "first" {
		t.Fatalf("HTTP upload buffered: %v", err)
	}
	go func() { _, _ = writer.Write([]byte("last")); _ = writer.Close() }()
	if string(getBody(t, resp)) != "last" {
		t.Fatal("duplex response changed")
	}
}

func TestExpectContinueAndEarlyHints(t *testing.T) {
	origin := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/reject" {
			w.WriteHeader(413)
			return
		}
		w.Header().Set("Link", "</app.css>; rel=preload")
		w.WriteHeader(103)
		_, _ = io.Copy(w, r.Body)
	}))
	t.Cleanup(origin.Close)
	p := startTestProxy(t, origin.URL)
	var hints atomic.Int32
	trace := &httptrace.ClientTrace{Got1xxResponse: func(code int, header textproto.MIMEHeader) error {
		if code == 103 && header.Get("Link") != "" {
			hints.Add(1)
		}
		return nil
	}}
	ctx := httptrace.WithClientTrace(context.Background(), trace)
	req, _ := http.NewRequestWithContext(ctx, "POST", p.url+"/upload", strings.NewReader("expect-body"))
	req.Header.Set("Expect", "100-continue")
	resp, err := client(t).Do(req)
	if err != nil {
		t.Fatal(err)
	}
	if string(getBody(t, resp)) != "expect-body" || hints.Load() != 1 {
		t.Fatal("100-continue body or 103 Early Hints lost")
	}
	req, _ = http.NewRequest("POST", p.url+"/reject", strings.NewReader("should-not-be-retried"))
	req.Header.Set("Expect", "100-continue")
	resp, err = client(t).Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != 413 {
		t.Fatalf("early rejection changed: %d", resp.StatusCode)
	}
}

func TestLivePolicyOnReusedConnectionAndEncodedPath(t *testing.T) {
	origin := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { _, _ = io.WriteString(w, "ok") }))
	t.Cleanup(origin.Close)
	u, _ := url.Parse(origin.URL)
	port, _ := strconv.Atoi(u.Port())
	routes := []testRoute{
		{Host: "public.example.com", Port: port, Path: "/", Open: true},
		{Host: "public.example.com", Port: port, Path: "/admin", Open: true, Security: &testSecurity{Allowlist: []string{}, Enabled: true, Name: "X-Secret", Secret: "old"}},
	}
	p := startTestProxy(t, origin.URL, routes...)
	conn, err := net.DialTimeout("tcp", strings.TrimPrefix(p.url, "http://"), time.Second)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	_ = conn.SetDeadline(time.Now().Add(5 * time.Second))
	reader := bufio.NewReader(conn)
	request := func(path, headers string, want int) {
		t.Helper()
		_, _ = fmt.Fprintf(conn, "GET %s HTTP/1.1\r\nHost: public.example.com\r\n%s\r\n", path, headers)
		resp, err := http.ReadResponse(reader, nil)
		if err != nil {
			t.Fatal(err)
		}
		_ = getBody(t, resp)
		if resp.StatusCode != want {
			t.Fatalf("%s status %d, want %d", path, resp.StatusCode, want)
		}
	}
	request("/admin", "X-Secret: old\r\n", 200)
	request("/public", "", 200)
	request("/%61dmin", "", 403)
	request("/public/../admin", "", 403)
	routes[1].Security = &testSecurity{Allowlist: []string{"2001:db8::/32"}, Enabled: true, Name: "X-Secret", Secret: "new"}
	p.update(t, routes)
	request("/admin", "X-Secret: old\r\n", 403)
	request("/admin", "X-Secret: new\r\nCF-Connecting-IP: 2001:db8::42\r\n", 200)
	request("/admin", "X-Secret: new\r\nCF-Connecting-IP: 198.51.100.2\r\n", 403)
	request("/public", "", 200)
	routes[1].Security = &testSecurity{Allowlist: []string{}, Enabled: false, Name: "X-Secret", Secret: "new"}
	p.update(t, routes)
	request("/admin", "", 200)
}

func TestAmbiguousRequestsAreRejectedWithoutCrashing(t *testing.T) {
	var calls atomic.Int32
	origin := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { calls.Add(1); w.WriteHeader(200) }))
	t.Cleanup(origin.Close)
	p := startTestProxy(t, origin.URL)
	for _, tc := range []struct {
		headers string
		status  int
	}{
		{"Content-Length: 3\r\nContent-Length: 4\r\n", 400},
		{"Transfer-Encoding: Identity\r\n", 501},
		{"Connection: Upgrade\r\nUpgrade: h2c\r\n", 501},
		{"CF-Connecting-IP: 203.0.113.1\r\ncf-connecting-ip: 198.51.100.1\r\n", 403},
	} {
		conn, err := net.DialTimeout("tcp", strings.TrimPrefix(p.url, "http://"), time.Second)
		if err != nil {
			t.Fatal(err)
		}
		_ = conn.SetDeadline(time.Now().Add(3 * time.Second))
		_, _ = fmt.Fprintf(conn, "GET / HTTP/1.1\r\nHost: public.example.com\r\nConnection: close\r\n%s\r\n", tc.headers)
		resp, err := http.ReadResponse(bufio.NewReader(conn), nil)
		if err != nil {
			conn.Close()
			t.Fatal(err)
		}
		resp.Body.Close()
		conn.Close()
		if resp.StatusCode != tc.status {
			t.Fatalf("malformed request status %d, want %d", resp.StatusCode, tc.status)
		}
	}
	if calls.Load() != 0 {
		t.Fatal("ambiguous request reached origin")
	}
	resp, err := client(t).Get(p.url + "/health")
	if err != nil {
		t.Fatalf("proxy crashed: %v", err)
	}
	resp.Body.Close()
}

package main

import (
	"context"
	"errors"
	"fmt"
	"log"
	"mime"
	"net"
	"net/http"
	"net/http/httputil"
	"path"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

type route struct {
	Hostname   string          `json:"hostname"`
	TargetPort int             `json:"targetPort"`
	TargetPath string          `json:"targetPath"`
	Security   *securityPolicy `json:"security,omitempty"`
	IsOpen     bool            `json:"isOpen"`
}

type snapshot struct {
	routes   []route
	fallback int
	policy   securityPolicy
}

type proxy struct {
	configuration atomic.Pointer[snapshot]
	http1         *http.Transport
	http2         *http.Transport
	server        *http.Server
	listener      net.Listener
	ctx           context.Context
	cancel        context.CancelFunc
	closeOnce     sync.Once
	connections   sync.Map
	log           func(string)
}

func newProxy(logger func(string)) *proxy {
	ctx, cancel := context.WithCancel(context.Background())
	http1 := &http.Transport{
		Proxy: nil, DisableCompression: true,
		DialContext:  (&net.Dialer{Timeout: 10 * time.Second, KeepAlive: 30 * time.Second}).DialContext,
		MaxIdleConns: 100, MaxIdleConnsPerHost: 16, IdleConnTimeout: 90 * time.Second,
		ExpectContinueTimeout: time.Second, MaxResponseHeaderBytes: 1 << 20,
	}
	http2 := http1.Clone()
	http2.Protocols = new(http.Protocols)
	http2.Protocols.SetUnencryptedHTTP2(true)
	p := &proxy{ctx: ctx, cancel: cancel, http1: http1, http2: http2, log: logger}
	protocols := new(http.Protocols)
	protocols.SetHTTP1(true)
	protocols.SetUnencryptedHTTP2(true)
	p.server = &http.Server{
		Handler: p, Protocols: protocols, ReadHeaderTimeout: 10 * time.Second,
		IdleTimeout: 90 * time.Second, MaxHeaderBytes: 1 << 20,
		BaseContext: func(net.Listener) context.Context { return ctx },
		ErrorLog:    log.New(logWriter{p}, "", 0),
	}
	return p
}

func (p *proxy) configure(c command) error {
	if c.FallbackTargetPort < 1 || c.FallbackTargetPort > 65535 {
		return fmt.Errorf("invalid local target port")
	}
	seen := make(map[string]bool)
	for i := range c.Routes {
		r := &c.Routes[i]
		if r.TargetPort < 1 || r.TargetPort > 65535 {
			return fmt.Errorf("invalid route target port")
		}
		r.Hostname = strings.TrimSuffix(strings.ToLower(strings.TrimSpace(r.Hostname)), ".")
		if strings.ContainsAny(r.Hostname, "/\r\n\x00") {
			return fmt.Errorf("invalid route hostname")
		}
		if r.TargetPath == "" {
			r.TargetPath = "/"
		}
		if !strings.HasPrefix(r.TargetPath, "/") {
			r.TargetPath = "/" + r.TargetPath
		}
		r.TargetPath = path.Clean(r.TargetPath)
		key := r.Hostname + "\n" + r.TargetPath
		if seen[key] {
			return fmt.Errorf("ambiguous duplicate hostname/path route")
		}
		seen[key] = true
	}
	p.configuration.Store(&snapshot{routes: c.Routes, fallback: c.FallbackTargetPort, policy: c.DefaultPolicy})
	return nil
}

func (p *proxy) start() (int, error) {
	listener, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		return 0, fmt.Errorf("proxy loopback listener failed: %w", err)
	}
	p.listener = listener
	go func() {
		if err := p.server.Serve(&trackedListener{Listener: listener, owner: p}); err != nil && !errors.Is(err, http.ErrServerClosed) {
			p.log("Proxy listener failed: " + err.Error())
			p.cancel()
		}
	}()
	return listener.Addr().(*net.TCPAddr).Port, nil
}

func (s *snapshot) match(r *http.Request) *route {
	host := r.Host
	if name, _, err := net.SplitHostPort(host); err == nil {
		host = name
	}
	host = strings.TrimSuffix(strings.ToLower(host), ".")
	// Match decoded/canonical paths for authorization, but forward the original URL.
	requestPath := path.Clean(r.URL.Path)
	var best *route
	for i := range s.routes {
		candidate := &s.routes[i]
		if candidate.Hostname != "" && candidate.Hostname != host {
			continue
		}
		prefix := candidate.TargetPath
		if prefix != "/" && requestPath != prefix && !strings.HasPrefix(requestPath, strings.TrimSuffix(prefix, "/")+"/") {
			continue
		}
		if best == nil || (best.Hostname == "" && candidate.Hostname != "") || ((best.Hostname == "") == (candidate.Hostname == "") && len(prefix) > len(best.TargetPath)) {
			best = candidate
		}
	}
	if best == nil && len(s.routes) == 0 {
		return &route{TargetPort: s.fallback, TargetPath: "/", IsOpen: true}
	}
	return best
}

func (p *proxy) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	s := p.configuration.Load()
	if s == nil {
		http.Error(w, "Proxy is not configured", http.StatusServiceUnavailable)
		return
	}
	if r.Method == http.MethodConnect {
		http.Error(w, "CONNECT is not supported", http.StatusMethodNotAllowed)
		return
	}
	if connectionNames(r.Header, "Upgrade") && !strings.EqualFold(strings.TrimSpace(r.Header.Get("Upgrade")), "websocket") {
		http.Error(w, "Only WebSocket upgrades are supported; use HTTP/2 prior knowledge for h2c", http.StatusNotImplemented)
		return
	}
	target := s.match(r)
	if target == nil || !target.IsOpen {
		http.NotFound(w, r)
		return
	}
	policy := s.policy
	if target.Security != nil {
		policy = *target.Security
	}
	allowed, source := policy.allows(r.Header)
	if !allowed {
		p.log(fmt.Sprintf("Blocked request from %s to :%d%s", source, target.TargetPort, r.URL.EscapedPath()))
		http.Error(w, "Forbidden", http.StatusForbidden)
		return
	}
	// net/http otherwise drains an HTTP/1 request body before writing a response.
	_ = http.NewResponseController(w).EnableFullDuplex()
	transport := p.http1
	isWebSocket := connectionNames(r.Header, "Upgrade") && strings.EqualFold(r.Header.Get("Upgrade"), "websocket")
	upgraded := false
	mediaType, _, _ := mime.ParseMediaType(r.Header.Get("Content-Type"))
	if mediaType == "application/grpc" || strings.HasPrefix(mediaType, "application/grpc+") {
		transport = p.http2
	}
	reverse := &httputil.ReverseProxy{
		Transport: transport, FlushInterval: -1, BufferPool: copyBuffers,
		Rewrite: func(request *httputil.ProxyRequest) {
			request.Out.URL.Scheme = "http"
			request.Out.URL.Host = net.JoinHostPort("127.0.0.1", strconv.Itoa(target.TargetPort))
			request.Out.Host = request.In.Host
			request.Out.URL.RawQuery = request.In.URL.RawQuery
			// Trailers are populated while Body is consumed; keep that same live map.
			request.Out.Trailer = request.In.Trailer
			for _, name := range []string{"Forwarded", "X-Forwarded-For", "X-Forwarded-Host", "X-Forwarded-Proto"} {
				if !connectionNames(request.In.Header, name) {
					if values, ok := request.In.Header[name]; ok {
						request.Out.Header[name] = append([]string(nil), values...)
					}
				}
			}
		},
		ErrorLog: log.New(logWriter{p}, "", 0),
		ModifyResponse: func(response *http.Response) error {
			if isWebSocket {
				upgraded = response.StatusCode == http.StatusSwitchingProtocols
				p.log(fmt.Sprintf("WebSocket handshake returned %d from :%d%s", response.StatusCode, target.TargetPort, r.URL.EscapedPath()))
			}
			return nil
		},
		ErrorHandler: func(w http.ResponseWriter, request *http.Request, err error) {
			if request.Context().Err() != nil {
				return
			}
			p.log(fmt.Sprintf("Proxy forward failed to :%d: %s", target.TargetPort, p.redact(err.Error())))
			http.Error(w, "Bad Gateway", http.StatusBadGateway)
		},
	}
	p.log(fmt.Sprintf("Allowed request from %s to :%d%s", source, target.TargetPort, r.URL.EscapedPath()))
	reverse.ServeHTTP(w, r)
	if upgraded {
		p.log(fmt.Sprintf("WebSocket connection closed to :%d%s", target.TargetPort, r.URL.EscapedPath()))
	}
}

func connectionNames(header http.Header, name string) bool {
	for _, value := range header.Values("Connection") {
		for _, token := range strings.Split(value, ",") {
			if strings.EqualFold(strings.TrimSpace(token), name) {
				return true
			}
		}
	}
	return false
}

func (p *proxy) close() {
	p.closeOnce.Do(func() {
		p.cancel()
		_ = p.server.Close()
		p.connections.Range(func(key, _ any) bool { _ = key.(*trackedConn).Close(); return true })
		p.http1.CloseIdleConnections()
		p.http2.CloseIdleConnections()
	})
}

// Track actual accepted sockets, including HTTP/2 and hijacked WebSockets.
type trackedListener struct {
	net.Listener
	owner *proxy
}

func (l *trackedListener) Accept() (net.Conn, error) {
	conn, err := l.Listener.Accept()
	if err != nil {
		return nil, err
	}
	t := &trackedConn{Conn: conn, owner: l.owner}
	l.owner.connections.Store(t, struct{}{})
	if l.owner.ctx.Err() != nil {
		_ = t.Close()
		return nil, net.ErrClosed
	}
	return t, nil
}

type trackedConn struct {
	net.Conn
	owner *proxy
}

func (c *trackedConn) Close() error      { c.owner.connections.Delete(c); return c.Conn.Close() }
func (c *trackedConn) CloseWrite() error { return c.Conn.(*net.TCPConn).CloseWrite() }

type bufferPool struct{ sync.Pool }

func (b *bufferPool) Get() []byte      { return b.Pool.Get().([]byte) }
func (b *bufferPool) Put(value []byte) { b.Pool.Put(value) }

var copyBuffers = &bufferPool{sync.Pool{New: func() any { return make([]byte, 32*1024) }}}

type logWriter struct{ p *proxy }

func (w logWriter) Write(message []byte) (int, error) {
	w.p.log(w.p.redact(strings.TrimSpace(string(message))))
	return len(message), nil
}
func (p *proxy) redact(message string) string {
	if s := p.configuration.Load(); s != nil {
		secrets := []string{s.policy.AuthHeaderSecret}
		for _, r := range s.routes {
			if r.Security != nil {
				secrets = append(secrets, r.Security.AuthHeaderSecret)
			}
		}
		for _, secret := range secrets {
			if secret != "" {
				message = strings.ReplaceAll(message, secret, "[redacted]")
			}
		}
	}
	return message
}

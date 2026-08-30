package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"os/signal"
	"sync"
	"syscall"
)

const protocolVersion = 1

type command struct {
	Version            int            `json:"version"`
	ID                 int            `json:"id"`
	Routes             []route        `json:"routes"`
	FallbackTargetPort int            `json:"fallbackTargetPort"`
	DefaultPolicy      securityPolicy `json:"defaultPolicy"`
}

type event struct {
	Type    string `json:"type"`
	ID      int    `json:"id,omitempty"`
	Port    int    `json:"port,omitempty"`
	Message string `json:"message,omitempty"`
}

type eventWriter struct {
	mu      sync.Mutex
	encoder *json.Encoder
}

func (w *eventWriter) send(e event) { w.mu.Lock(); defer w.mu.Unlock(); _ = w.encoder.Encode(e) }

func main() {
	if err := run(os.Stdin, os.Stdout); err != nil {
		// Never print the configuration: it contains route secrets.
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

func run(input io.Reader, output io.Writer) error {
	writer := &eventWriter{encoder: json.NewEncoder(output)}
	proxy := newProxy(func(message string) { writer.send(event{Type: "log", Message: message}) })
	defer proxy.close()
	signals := make(chan os.Signal, 1)
	signal.Notify(signals, os.Interrupt, syscall.SIGTERM)
	defer signal.Stop(signals)
	scanner := bufio.NewScanner(input)
	scanner.Buffer(make([]byte, 4096), 2<<20)
	type inputLine struct {
		data []byte
		err  error
	}
	lines := make(chan inputLine)
	go func() {
		defer close(lines)
		for scanner.Scan() {
			select {
			case lines <- inputLine{data: append([]byte(nil), scanner.Bytes()...)}:
			case <-proxy.ctx.Done():
				return
			}
		}
		if scanner.Err() != nil {
			select {
			case lines <- inputLine{err: fmt.Errorf("proxy control channel failed")}:
			case <-proxy.ctx.Done():
			}
		}
	}()
	started := false
	lastID := 0
	for {
		var line inputLine
		select {
		case <-signals:
			return nil
		case <-proxy.ctx.Done():
			return fmt.Errorf("proxy listener stopped unexpectedly")
		case next, ok := <-lines:
			if !ok {
				return nil // Owner exit closes all listeners and active streams.
			}
			if next.err != nil {
				return next.err
			}
			line = next
		}
		var next command
		if err := json.Unmarshal(line.data, &next); err != nil {
			return fmt.Errorf("invalid proxy configuration JSON")
		}
		if next.Version != protocolVersion || next.ID <= lastID {
			return fmt.Errorf("unsupported proxy protocol or out-of-order configuration")
		}
		if err := proxy.configure(next); err != nil {
			writer.send(event{Type: "error", ID: next.ID, Message: err.Error()})
			return err
		}
		lastID = next.ID
		if !started {
			port, err := proxy.start()
			if err != nil {
				return err
			}
			started = true
			writer.send(event{Type: "ready", ID: next.ID, Port: port})
		} else {
			writer.send(event{Type: "applied", ID: next.ID})
		}
	}
}

package main

import (
	"bytes"
	"context"
	"io"
	"net"
	"strings"
	"testing"
	"time"

	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/credentials/insecure"
	"google.golang.org/grpc/encoding/gzip"
	pb "google.golang.org/grpc/interop/grpc_testing"
	"google.golang.org/grpc/metadata"
	"google.golang.org/grpc/status"
)

type echoRPC struct {
	pb.UnimplementedTestServiceServer
	continueStream chan struct{}
	cancelled      chan struct{}
}

func (s *echoRPC) UnaryCall(ctx context.Context, in *pb.SimpleRequest) (*pb.SimpleResponse, error) {
	if string(in.GetPayload().GetBody()) == "denied" {
		_ = grpc.SetTrailer(ctx, metadata.Pairs("x-denial", "origin"))
		return nil, status.Error(codes.PermissionDenied, "origin permission denied")
	}
	md, _ := metadata.FromIncomingContext(ctx)
	_ = grpc.SetHeader(ctx, metadata.Pairs("x-request-token", strings.Join(md.Get("authorization"), ",")))
	_ = grpc.SetTrailer(ctx, metadata.Pairs("x-trace-bin", string([]byte{0, 255, 17}), "x-tag", "one", "x-tag", "two"))
	return &pb.SimpleResponse{Payload: in.Payload}, nil
}

func (s *echoRPC) StreamingOutputCall(in *pb.StreamingOutputCallRequest, stream pb.TestService_StreamingOutputCallServer) error {
	stream.SetTrailer(metadata.Pairs("x-complete", "yes"))
	if err := stream.Send(&pb.StreamingOutputCallResponse{Payload: in.Payload}); err != nil {
		return err
	}
	select {
	case <-s.continueStream:
	case <-stream.Context().Done():
		close(s.cancelled)
		return stream.Context().Err()
	}
	return stream.Send(&pb.StreamingOutputCallResponse{Payload: in.Payload})
}

func (s *echoRPC) StreamingInputCall(stream pb.TestService_StreamingInputCallServer) error {
	var size int32
	for {
		in, err := stream.Recv()
		if err == io.EOF {
			stream.SetTrailer(metadata.Pairs("x-complete", "yes"))
			return stream.SendAndClose(&pb.StreamingInputCallResponse{AggregatedPayloadSize: size})
		}
		if err != nil {
			return err
		}
		size += int32(len(in.GetPayload().GetBody()))
	}
}

func (s *echoRPC) FullDuplexCall(stream pb.TestService_FullDuplexCallServer) error {
	stream.SetTrailer(metadata.Pairs("x-complete", "yes"))
	for {
		in, err := stream.Recv()
		if err == io.EOF {
			return nil
		}
		if err != nil {
			return err
		}
		if err := stream.Send(&pb.StreamingOutputCallResponse{Payload: in.Payload}); err != nil {
			return err
		}
	}
}

func TestGRPCUnaryStreamingMetadataAndStatus(t *testing.T) {
	listener, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	origin := grpc.NewServer()
	service := &echoRPC{continueStream: make(chan struct{}), cancelled: make(chan struct{})}
	pb.RegisterTestServiceServer(origin, service)
	go origin.Serve(listener)
	t.Cleanup(origin.Stop)
	p := startTestProxy(t, "http://"+listener.Addr().String())
	conn, err := grpc.NewClient(strings.TrimPrefix(p.url, "http://"), grpc.WithTransportCredentials(insecure.NewCredentials()))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { conn.Close() })
	rpc := pb.NewTestServiceClient(conn)
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	ctx = metadata.NewOutgoingContext(ctx, metadata.Pairs("authorization", "Bearer client-token"))
	var header, trailer metadata.MD
	want := bytes.Repeat([]byte("grpc-data\x00\xff"), 50_000)
	response, err := rpc.UnaryCall(ctx, &pb.SimpleRequest{Payload: &pb.Payload{Body: want}}, grpc.Header(&header), grpc.Trailer(&trailer), grpc.UseCompressor(gzip.Name))
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(response.Payload.Body, want) {
		t.Fatal("gRPC payload changed")
	}
	if got := header.Get("x-request-token"); len(got) != 1 || got[0] != "Bearer client-token" {
		t.Fatalf("gRPC request metadata lost: %v", header)
	}
	if got := trailer.Get("x-trace-bin"); len(got) != 1 || got[0] != string([]byte{0, 255, 17}) {
		t.Fatalf("binary trailer lost: %v", trailer)
	}
	if len(trailer.Get("x-tag")) != 2 {
		t.Fatalf("duplicate metadata lost: %v", trailer)
	}

	stream, err := rpc.StreamingOutputCall(ctx, &pb.StreamingOutputCallRequest{Payload: &pb.Payload{Body: []byte("first")}})
	if err != nil {
		t.Fatal(err)
	}
	if message, err := stream.Recv(); err != nil || string(message.GetPayload().GetBody()) != "first" {
		t.Fatalf("server stream buffered: %v", err)
	}
	close(service.continueStream)
	if _, err := stream.Recv(); err != nil {
		t.Fatal(err)
	}
	if _, err := stream.Recv(); err != io.EOF {
		t.Fatalf("expected stream end: %v", err)
	}
	if got := stream.Trailer().Get("x-complete"); len(got) != 1 || got[0] != "yes" {
		t.Fatal("server stream trailer lost")
	}

	upload, err := rpc.StreamingInputCall(ctx, grpc.UseCompressor(gzip.Name))
	if err != nil {
		t.Fatal(err)
	}
	for i := 0; i < 3; i++ {
		if err := upload.Send(&pb.StreamingInputCallRequest{Payload: &pb.Payload{Body: want}}); err != nil {
			t.Fatal(err)
		}
	}
	summary, err := upload.CloseAndRecv()
	if err != nil {
		t.Fatal(err)
	}
	if summary.AggregatedPayloadSize != int32(len(want)*3) {
		t.Fatal("client stream truncated")
	}

	duplex, err := rpc.FullDuplexCall(ctx)
	if err != nil {
		t.Fatal(err)
	}
	for i := 0; i < 3; i++ {
		if err := duplex.Send(&pb.StreamingOutputCallRequest{Payload: &pb.Payload{Body: want}}); err != nil {
			t.Fatal(err)
		}
		out, err := duplex.Recv() // Must arrive before sending the next message or closing.
		if err != nil {
			t.Fatal(err)
		}
		if !bytes.Equal(out.Payload.Body, want) {
			t.Fatal("bidirectional stream data changed")
		}
	}
	if err := duplex.CloseSend(); err != nil {
		t.Fatal(err)
	}
	if _, err := duplex.Recv(); err != io.EOF {
		t.Fatalf("bidirectional stream end: %v", err)
	}
	if len(duplex.Trailer().Get("x-complete")) != 1 {
		t.Fatal("bidirectional stream trailer lost")
	}

	_, err = rpc.UnaryCall(ctx, &pb.SimpleRequest{Payload: &pb.Payload{Body: []byte("denied")}}, grpc.Trailer(&trailer))
	if status.Code(err) != codes.PermissionDenied || status.Convert(err).Message() != "origin permission denied" {
		t.Fatalf("origin status changed: %v", err)
	}
	if got := trailer.Get("x-denial"); len(got) != 1 || got[0] != "origin" {
		t.Fatal("non-OK trailer lost")
	}
}

func TestGRPCCancellationAndConcurrentStreams(t *testing.T) {
	listener, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	origin := grpc.NewServer()
	service := &echoRPC{continueStream: make(chan struct{}), cancelled: make(chan struct{})}
	pb.RegisterTestServiceServer(origin, service)
	go origin.Serve(listener)
	t.Cleanup(origin.Stop)
	p := startTestProxy(t, "http://"+listener.Addr().String())
	conn, err := grpc.NewClient(strings.TrimPrefix(p.url, "http://"), grpc.WithTransportCredentials(insecure.NewCredentials()))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { conn.Close() })
	rpc := pb.NewTestServiceClient(conn)
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	stream, err := rpc.StreamingOutputCall(ctx, &pb.StreamingOutputCallRequest{Payload: &pb.Payload{Body: []byte("ready")}})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := stream.Recv(); err != nil {
		t.Fatal(err)
	}
	results := make(chan error, 8)
	for i := 0; i < 8; i++ {
		go func() { _, err := rpc.UnaryCall(ctx, &pb.SimpleRequest{}); results <- err }()
	}
	for i := 0; i < 8; i++ {
		if err := <-results; err != nil {
			t.Fatal(err)
		}
	}
	cancel()
	select {
	case <-service.cancelled:
	case <-time.After(2 * time.Second):
		t.Fatal("gRPC cancellation did not reach origin")
	}
}

package main

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"sync/atomic"

	stefgrpc "github.com/splunk/stef/go/grpc"
	"github.com/splunk/stef/go/grpc/stef_proto"
	"github.com/splunk/stef/go/otel/otelstef"
	"github.com/splunk/stef/go/pkg"
	colmetricspb "go.opentelemetry.io/proto/otlp/collector/metrics/v1"
	"google.golang.org/grpc"
	"google.golang.org/grpc/stats"
)

// bytesCounter tracks cumulative wire bytes using atomic operations.
type bytesCounter struct {
	total atomic.Int64
}

func (c *bytesCounter) Add(n int64)         { c.total.Add(n) }
func (c *bytesCounter) ReadAndReset() int64 { return c.total.Swap(0) }

// --- gRPC nop server ---

type nopMetricsGRPCServer struct {
	colmetricspb.UnimplementedMetricsServiceServer
}

func (s *nopMetricsGRPCServer) Export(_ context.Context, _ *colmetricspb.ExportMetricsServiceRequest) (*colmetricspb.ExportMetricsServiceResponse, error) {
	return &colmetricspb.ExportMetricsServiceResponse{}, nil
}

// grpcBytesHandler is a gRPC stats handler that tracks wire bytes received.
type grpcBytesHandler struct {
	counter *bytesCounter
}

func (h *grpcBytesHandler) TagRPC(ctx context.Context, _ *stats.RPCTagInfo) context.Context {
	return ctx
}
func (h *grpcBytesHandler) HandleRPC(_ context.Context, s stats.RPCStats) {
	if in, ok := s.(*stats.InPayload); ok {
		h.counter.Add(int64(in.WireLength))
	}
}
func (h *grpcBytesHandler) TagConn(ctx context.Context, _ *stats.ConnTagInfo) context.Context {
	return ctx
}
func (h *grpcBytesHandler) HandleConn(_ context.Context, _ stats.ConnStats) {}

type grpcServer struct {
	server  *grpc.Server
	lis     net.Listener
	Counter *bytesCounter
}

func startGRPCServer() (*grpcServer, error) {
	lis, err := net.Listen("tcp", "localhost:0")
	if err != nil {
		return nil, fmt.Errorf("listen: %w", err)
	}

	counter := &bytesCounter{}
	srv := grpc.NewServer(grpc.StatsHandler(&grpcBytesHandler{counter: counter}))
	colmetricspb.RegisterMetricsServiceServer(srv, &nopMetricsGRPCServer{})

	go srv.Serve(lis)

	return &grpcServer{
		server:  srv,
		lis:     lis,
		Counter: counter,
	}, nil
}

func (s *grpcServer) Endpoint() string { return s.lis.Addr().String() }
func (s *grpcServer) Stop()            { s.server.GracefulStop() }

// --- HTTP nop server ---

type httpServer struct {
	server  *http.Server
	lis     net.Listener
	Counter *bytesCounter
}

func startHTTPServer() (*httpServer, error) {
	lis, err := net.Listen("tcp", "localhost:0")
	if err != nil {
		return nil, fmt.Errorf("listen: %w", err)
	}

	counter := &bytesCounter{}
	mux := http.NewServeMux()
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		n, _ := io.Copy(io.Discard, r.Body)
		counter.Add(n)
		w.WriteHeader(http.StatusOK)
	})

	srv := &http.Server{Handler: mux}
	go srv.Serve(lis)

	return &httpServer{
		server:  srv,
		lis:     lis,
		Counter: counter,
	}, nil
}

func (s *httpServer) Endpoint() string { return "http://" + s.lis.Addr().String() }
func (s *httpServer) Stop()            { s.server.Shutdown(context.Background()) }

// --- STEF nop server ---
// Models the stefexporter test server: accepts STEF streams, reads records, sends ACKs.

type stefServer struct {
	grpcSrv *grpc.Server
	lis     net.Listener
	Counter *bytesCounter
}

func startSTEFServer() (*stefServer, error) {
	lis, err := net.Listen("tcp", "localhost:0")
	if err != nil {
		return nil, fmt.Errorf("listen: %w", err)
	}

	counter := &bytesCounter{}
	grpcSrv := grpc.NewServer(grpc.StatsHandler(&grpcBytesHandler{counter: counter}))

	schema, err := otelstef.MetricsWireSchema()
	if err != nil {
		return nil, fmt.Errorf("metrics wire schema: %w", err)
	}

	settings := stefgrpc.ServerSettings{
		ServerSchema: &schema,
		Callbacks: stefgrpc.Callbacks{
			OnStream: func(reader stefgrpc.GrpcReader, stream stefgrpc.STEFStream) error {
				mr, err := otelstef.NewMetricsReader(reader)
				if err != nil {
					return err
				}
				for {
					if err := mr.Read(pkg.ReadOptions{}); err != nil {
						return err
					}
					if err := stream.SendDataResponse(&stef_proto.STEFDataResponse{
						AckRecordId: mr.RecordCount(),
					}); err != nil {
						return err
					}
				}
			},
		},
	}
	stef_proto.RegisterSTEFDestinationServer(grpcSrv, stefgrpc.NewStreamServer(settings))

	go func() {
		if err := grpcSrv.Serve(lis); err != nil && !errors.Is(err, grpc.ErrServerStopped) {
			fmt.Fprintf(os.Stderr, "STEF server error: %v\n", err)
		}
	}()

	return &stefServer{
		grpcSrv: grpcSrv,
		lis:     lis,
		Counter: counter,
	}, nil
}

func (s *stefServer) Endpoint() string { return s.lis.Addr().String() }
func (s *stefServer) Stop()            { s.grpcSrv.GracefulStop() }

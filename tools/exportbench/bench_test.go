package main

import (
	"context"
	"fmt"
	"os"
	"testing"
	"time"

	"go.opentelemetry.io/collector/component/componenttest"
	"go.opentelemetry.io/collector/config/configcompression"
	"go.opentelemetry.io/collector/config/configoptional"
	"go.opentelemetry.io/collector/config/configretry"
	"go.opentelemetry.io/collector/config/configtls"
	"go.opentelemetry.io/collector/exporter"
	"go.opentelemetry.io/collector/exporter/exporterhelper"
	"go.opentelemetry.io/collector/exporter/exportertest"
	"go.opentelemetry.io/collector/exporter/otlpexporter"
	"go.opentelemetry.io/collector/exporter/otlphttpexporter"

	"github.com/open-telemetry/opentelemetry-collector-contrib/exporter/stefexporter"
)

var (
	testPayloads      []payload
	testTotalRawBytes int64
	testGRPCServer    *grpcServer
	testHTTPServer    *httpServer
	testSTEFServer    *stefServer
)

func TestMain(m *testing.M) {
	dir := os.Getenv("EXPORTBENCH_INPUT_DIR")
	if dir == "" {
		fmt.Fprintln(os.Stderr, "EXPORTBENCH_INPUT_DIR not set, skipping benchmarks")
		os.Exit(0)
	}

	var err error
	testPayloads, testTotalRawBytes, err = loadPayloads(dir)
	if err != nil {
		fmt.Fprintf(os.Stderr, "failed to load payloads: %v\n", err)
		os.Exit(1)
	}

	testGRPCServer, err = startGRPCServer()
	if err != nil {
		fmt.Fprintf(os.Stderr, "failed to start gRPC server: %v\n", err)
		os.Exit(1)
	}

	testHTTPServer, err = startHTTPServer()
	if err != nil {
		fmt.Fprintf(os.Stderr, "failed to start HTTP server: %v\n", err)
		os.Exit(1)
	}

	testSTEFServer, err = startSTEFServer()
	if err != nil {
		fmt.Fprintf(os.Stderr, "failed to start STEF server: %v\n", err)
		os.Exit(1)
	}

	code := m.Run()

	testGRPCServer.Stop()
	testHTTPServer.Stop()
	testSTEFServer.Stop()

	os.Exit(code)
}

func benchmarkExporter(b *testing.B, exp exporter.Metrics, counter *bytesCounter) {
	b.Helper()
	b.SetBytes(testTotalRawBytes)
	b.ReportAllocs()
	ctx := context.Background()

	// Warmup and discard initial bytes.
	for _, p := range testPayloads {
		if err := exp.ConsumeMetrics(ctx, p.req.Metrics()); err != nil {
			b.Fatal(err)
		}
	}
	counter.ReadAndReset()

	for b.Loop() {
		for _, p := range testPayloads {
			if err := exp.ConsumeMetrics(ctx, p.req.Metrics()); err != nil {
				b.Fatal(err)
			}
		}
	}

	wireBytes := counter.ReadAndReset()
	if b.N > 0 {
		bytesPerOp := float64(wireBytes) / float64(b.N)
		ratio := float64(testTotalRawBytes) / bytesPerOp
		b.ReportMetric(bytesPerOp, "wire-B/op")
		b.ReportMetric(ratio, "compress-ratio")
	}
}

func newGRPCExporter(b *testing.B, compression configcompression.Type) exporter.Metrics {
	b.Helper()
	factory := otlpexporter.NewFactory()
	cfg := factory.CreateDefaultConfig().(*otlpexporter.Config)
	cfg.ClientConfig.Endpoint = testGRPCServer.Endpoint()
	cfg.ClientConfig.TLS = configtls.ClientConfig{Insecure: true}
	cfg.ClientConfig.Compression = compression
	cfg.RetryConfig = configretry.BackOffConfig{Enabled: false}
	cfg.QueueConfig = configoptional.None[exporterhelper.QueueBatchConfig]()

	ctx := context.Background()
	exp, err := factory.CreateMetrics(ctx, exportertest.NewNopSettings(factory.Type()), cfg)
	if err != nil {
		b.Fatal(err)
	}
	if err := exp.Start(ctx, componenttest.NewNopHost()); err != nil {
		b.Fatal(err)
	}
	b.Cleanup(func() { exp.Shutdown(ctx) })
	return exp
}

func newHTTPExporter(b *testing.B, encoding otlphttpexporter.EncodingType, compression configcompression.Type) exporter.Metrics {
	b.Helper()
	factory := otlphttpexporter.NewFactory()
	cfg := factory.CreateDefaultConfig().(*otlphttpexporter.Config)
	cfg.ClientConfig.Endpoint = testHTTPServer.Endpoint()
	cfg.ClientConfig.Compression = compression
	cfg.Encoding = encoding
	cfg.RetryConfig = configretry.BackOffConfig{Enabled: false}
	cfg.QueueConfig = configoptional.None[exporterhelper.QueueBatchConfig]()

	ctx := context.Background()
	exp, err := factory.CreateMetrics(ctx, exportertest.NewNopSettings(factory.Type()), cfg)
	if err != nil {
		b.Fatal(err)
	}
	if err := exp.Start(ctx, componenttest.NewNopHost()); err != nil {
		b.Fatal(err)
	}
	b.Cleanup(func() { exp.Shutdown(ctx) })
	return exp
}

func BenchmarkOTLPgRPC(b *testing.B) {
	if len(testPayloads) == 0 {
		b.Skip("no test payloads")
	}
	benchmarkExporter(b, newGRPCExporter(b, ""), testGRPCServer.Counter)
}

func BenchmarkOTLPgRPC_Zstd(b *testing.B) {
	if len(testPayloads) == 0 {
		b.Skip("no test payloads")
	}
	benchmarkExporter(b, newGRPCExporter(b, configcompression.TypeZstd), testGRPCServer.Counter)
}

func BenchmarkOTLPHTTP_Proto(b *testing.B) {
	if len(testPayloads) == 0 {
		b.Skip("no test payloads")
	}
	benchmarkExporter(b, newHTTPExporter(b, otlphttpexporter.EncodingProto, ""), testHTTPServer.Counter)
}

func BenchmarkOTLPHTTP_Proto_Zstd(b *testing.B) {
	if len(testPayloads) == 0 {
		b.Skip("no test payloads")
	}
	benchmarkExporter(b, newHTTPExporter(b, otlphttpexporter.EncodingProto, configcompression.TypeZstd), testHTTPServer.Counter)
}

func BenchmarkOTLPHTTP_JSON(b *testing.B) {
	if len(testPayloads) == 0 {
		b.Skip("no test payloads")
	}
	benchmarkExporter(b, newHTTPExporter(b, otlphttpexporter.EncodingJSON, ""), testHTTPServer.Counter)
}

func BenchmarkOTLPHTTP_JSON_Zstd(b *testing.B) {
	if len(testPayloads) == 0 {
		b.Skip("no test payloads")
	}
	benchmarkExporter(b, newHTTPExporter(b, otlphttpexporter.EncodingJSON, configcompression.TypeZstd), testHTTPServer.Counter)
}

func newSTEFExporter(b *testing.B, compression configcompression.Type) exporter.Metrics {
	b.Helper()
	factory := stefexporter.NewFactory()
	cfg := factory.CreateDefaultConfig().(*stefexporter.Config)
	cfg.ClientConfig.Endpoint = testSTEFServer.Endpoint()
	cfg.ClientConfig.TLS = configtls.ClientConfig{Insecure: true}
	cfg.ClientConfig.Compression = compression
	cfg.TimeoutConfig = exporterhelper.TimeoutConfig{Timeout: 2 * time.Minute}
	cfg.RetryConfig = configretry.BackOffConfig{Enabled: false}
	qCfg := exporterhelper.NewDefaultQueueConfig()
	qCfg.QueueSize = 50000
	cfg.QueueConfig = configoptional.Some(qCfg)

	ctx := context.Background()
	exp, err := factory.CreateMetrics(ctx, exportertest.NewNopSettings(factory.Type()), cfg)
	if err != nil {
		b.Fatal(err)
	}
	if err := exp.Start(ctx, componenttest.NewNopHost()); err != nil {
		b.Fatal(err)
	}
	b.Cleanup(func() { exp.Shutdown(ctx) })
	return exp
}

func BenchmarkSTEF(b *testing.B) {
	if len(testPayloads) == 0 {
		b.Skip("no test payloads")
	}
	benchmarkExporter(b, newSTEFExporter(b, ""), testSTEFServer.Counter)
}

func BenchmarkSTEF_Zstd(b *testing.B) {
	if len(testPayloads) == 0 {
		b.Skip("no test payloads")
	}
	benchmarkExporter(b, newSTEFExporter(b, configcompression.TypeZstd), testSTEFServer.Counter)
}

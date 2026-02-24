package main

import (
	"context"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"sort"
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
	"go.opentelemetry.io/collector/pdata/pmetric/pmetricotlp"

	"github.com/open-telemetry/opentelemetry-collector-contrib/exporter/stefexporter"
)

type payload struct {
	filename string
	raw      []byte
	req      pmetricotlp.ExportRequest
}

type formatResult struct {
	name          string
	totalBytes    int64
	serializeTime time.Duration
	allocBytes    int64
	numAllocs     int64
}

type benchFormat struct {
	name    string
	setup   func() error
	export  func([]payload) error
	size    func() int64
	cleanup func()
}

func main() {
	inputDir := flag.String("input-dir", "", "directory containing .pb files (required)")
	iterations := flag.Int("iterations", 10, "number of iterations for timing")
	flag.Parse()

	if *inputDir == "" {
		fmt.Fprintf(os.Stderr, "error: --input-dir is required\n")
		flag.Usage()
		os.Exit(1)
	}

	payloads, totalRawBytes, err := loadPayloads(*inputDir)
	if err != nil {
		fmt.Fprintf(os.Stderr, "error loading payloads: %v\n", err)
		os.Exit(1)
	}

	totalDataPoints := 0
	for _, p := range payloads {
		totalDataPoints += p.req.Metrics().DataPointCount()
	}

	fmt.Println("## Dataset")
	fmt.Printf("- Files: %d\n", len(payloads))
	fmt.Printf("- Total raw protobuf: %.1f MB\n", float64(totalRawBytes)/1024/1024)
	fmt.Printf("- Total data points: %d\n", totalDataPoints)
	fmt.Println()

	// Start nop servers for exporters to send to.
	grpcSrv, err := startGRPCServer()
	if err != nil {
		fmt.Fprintf(os.Stderr, "error starting gRPC server: %v\n", err)
		os.Exit(1)
	}
	defer grpcSrv.Stop()

	httpSrv, err := startHTTPServer()
	if err != nil {
		fmt.Fprintf(os.Stderr, "error starting HTTP server: %v\n", err)
		os.Exit(1)
	}
	defer httpSrv.Stop()

	stefSrv, err := startSTEFServer()
	if err != nil {
		fmt.Fprintf(os.Stderr, "error starting STEF server: %v\n", err)
		os.Exit(1)
	}
	defer stefSrv.Stop()

	formats := []benchFormat{
		newGRPCFormat("OTLP gRPC", grpcSrv, ""),
		newGRPCFormat("OTLP gRPC + zstd", grpcSrv, configcompression.TypeZstd),
		newHTTPFormat("OTLP HTTP proto", httpSrv, otlphttpexporter.EncodingProto, ""),
		newHTTPFormat("OTLP HTTP proto+zstd", httpSrv, otlphttpexporter.EncodingProto, configcompression.TypeZstd),
		newHTTPFormat("OTLP HTTP JSON", httpSrv, otlphttpexporter.EncodingJSON, ""),
		newHTTPFormat("OTLP HTTP JSON+zstd", httpSrv, otlphttpexporter.EncodingJSON, configcompression.TypeZstd),
		newSTEFExporterFormat("STEF (none)", stefSrv, ""),
		newSTEFExporterFormat("STEF (zstd)", stefSrv, configcompression.TypeZstd),
	}

	results := make([]formatResult, 0, len(formats))
	for _, f := range formats {
		fmt.Fprintf(os.Stderr, "benchmarking: %s ...\n", f.name)

		if err := f.setup(); err != nil {
			fmt.Fprintf(os.Stderr, "error setting up %s: %v\n", f.name, err)
			os.Exit(1)
		}

		// Warmup.
		if err := f.export(payloads); err != nil {
			fmt.Fprintf(os.Stderr, "error in %s warmup: %v\n", f.name, err)
			os.Exit(1)
		}
		f.size() // discard warmup bytes

		// Measure size from one iteration.
		if err := f.export(payloads); err != nil {
			fmt.Fprintf(os.Stderr, "error in %s: %v\n", f.name, err)
			os.Exit(1)
		}
		size := f.size()

		// Timed iterations with memory tracking.
		runtime.GC()
		var memBefore runtime.MemStats
		runtime.ReadMemStats(&memBefore)

		start := time.Now()
		for i := 0; i < *iterations; i++ {
			if err := f.export(payloads); err != nil {
				fmt.Fprintf(os.Stderr, "error in %s iteration %d: %v\n", f.name, i, err)
				os.Exit(1)
			}
		}
		elapsed := time.Since(start)

		var memAfter runtime.MemStats
		runtime.ReadMemStats(&memAfter)

		f.size() // discard timed bytes
		f.cleanup()

		allocBytes := int64(memAfter.TotalAlloc-memBefore.TotalAlloc) / int64(*iterations)
		numAllocs := int64(memAfter.Mallocs-memBefore.Mallocs) / int64(*iterations)

		results = append(results, formatResult{
			name:          f.name,
			totalBytes:    size,
			serializeTime: elapsed / time.Duration(*iterations),
			allocBytes:    allocBytes,
			numAllocs:     numAllocs,
		})
	}

	fmt.Printf("## Results (avg over %d iterations)\n\n", *iterations)
	fmt.Println("| Format | Total Size | Ratio vs Raw | Serialize Time | Allocs/op | Bytes/op |")
	fmt.Println("|--------|-----------|--------------|----------------|-----------|----------|")
	for _, r := range results {
		ratio := float64(totalRawBytes) / float64(r.totalBytes)
		fmt.Printf("| %-22s | %8.1f MB | %10.2fx | %12s | %9d | %8.1f MB |\n",
			r.name,
			float64(r.totalBytes)/1024/1024,
			ratio,
			r.serializeTime.Round(time.Microsecond),
			r.numAllocs,
			float64(r.allocBytes)/1024/1024,
		)
	}
}

func newGRPCFormat(name string, srv *grpcServer, compression configcompression.Type) benchFormat {
	var exp exporter.Metrics

	return benchFormat{
		name: name,
		setup: func() error {
			factory := otlpexporter.NewFactory()
			cfg := factory.CreateDefaultConfig().(*otlpexporter.Config)
			cfg.ClientConfig.Endpoint = srv.Endpoint()
			cfg.ClientConfig.TLS = configtls.ClientConfig{Insecure: true}
			cfg.ClientConfig.Compression = compression
			cfg.RetryConfig = configretry.BackOffConfig{Enabled: false}
			cfg.QueueConfig = configoptional.None[exporterhelper.QueueBatchConfig]()

			ctx := context.Background()
			var err error
			exp, err = factory.CreateMetrics(ctx, exportertest.NewNopSettings(factory.Type()), cfg)
			if err != nil {
				return fmt.Errorf("create exporter: %w", err)
			}
			return exp.Start(ctx, componenttest.NewNopHost())
		},
		export: func(ps []payload) error {
			ctx := context.Background()
			for _, p := range ps {
				if err := exp.ConsumeMetrics(ctx, p.req.Metrics()); err != nil {
					return err
				}
			}
			return nil
		},
		size:    func() int64 { return srv.Counter.ReadAndReset() },
		cleanup: func() { exp.Shutdown(context.Background()) },
	}
}

func newHTTPFormat(name string, srv *httpServer, encoding otlphttpexporter.EncodingType, compression configcompression.Type) benchFormat {
	var exp exporter.Metrics

	return benchFormat{
		name: name,
		setup: func() error {
			factory := otlphttpexporter.NewFactory()
			cfg := factory.CreateDefaultConfig().(*otlphttpexporter.Config)
			cfg.ClientConfig.Endpoint = srv.Endpoint()
			cfg.ClientConfig.Compression = compression
			cfg.Encoding = encoding
			cfg.RetryConfig = configretry.BackOffConfig{Enabled: false}
			cfg.QueueConfig = configoptional.None[exporterhelper.QueueBatchConfig]()

			ctx := context.Background()
			var err error
			exp, err = factory.CreateMetrics(ctx, exportertest.NewNopSettings(factory.Type()), cfg)
			if err != nil {
				return fmt.Errorf("create exporter: %w", err)
			}
			return exp.Start(ctx, componenttest.NewNopHost())
		},
		export: func(ps []payload) error {
			ctx := context.Background()
			for _, p := range ps {
				if err := exp.ConsumeMetrics(ctx, p.req.Metrics()); err != nil {
					return err
				}
			}
			return nil
		},
		size:    func() int64 { return srv.Counter.ReadAndReset() },
		cleanup: func() { exp.Shutdown(context.Background()) },
	}
}

func newSTEFExporterFormat(name string, srv *stefServer, compression configcompression.Type) benchFormat {
	var exp exporter.Metrics

	return benchFormat{
		name: name,
		setup: func() error {
			factory := stefexporter.NewFactory()
			cfg := factory.CreateDefaultConfig().(*stefexporter.Config)
			cfg.ClientConfig.Endpoint = srv.Endpoint()
			cfg.ClientConfig.TLS = configtls.ClientConfig{Insecure: true}
			cfg.ClientConfig.Compression = compression
			cfg.TimeoutConfig = exporterhelper.TimeoutConfig{Timeout: 2 * time.Minute}
			cfg.RetryConfig = configretry.BackOffConfig{Enabled: false}
			qCfg := exporterhelper.NewDefaultQueueConfig()
			qCfg.QueueSize = 50000
			cfg.QueueConfig = configoptional.Some(qCfg)

			ctx := context.Background()
			var err error
			exp, err = factory.CreateMetrics(ctx, exportertest.NewNopSettings(factory.Type()), cfg)
			if err != nil {
				return fmt.Errorf("create exporter: %w", err)
			}
			return exp.Start(ctx, componenttest.NewNopHost())
		},
		export: func(ps []payload) error {
			ctx := context.Background()
			for _, p := range ps {
				if err := exp.ConsumeMetrics(ctx, p.req.Metrics()); err != nil {
					return err
				}
			}
			return nil
		},
		size:    func() int64 { return srv.Counter.ReadAndReset() },
		cleanup: func() { exp.Shutdown(context.Background()) },
	}
}

func loadPayloads(dir string) ([]payload, int64, error) {
	matches, err := filepath.Glob(filepath.Join(dir, "*.pb"))
	if err != nil {
		return nil, 0, fmt.Errorf("globbing %s: %w", dir, err)
	}
	if len(matches) == 0 {
		return nil, 0, fmt.Errorf("no .pb files found in %s", dir)
	}
	sort.Strings(matches)

	var payloads []payload
	var totalRawBytes int64

	for _, path := range matches {
		data, err := os.ReadFile(path)
		if err != nil {
			return nil, 0, fmt.Errorf("reading %s: %w", path, err)
		}

		req := pmetricotlp.NewExportRequest()
		if err := req.UnmarshalProto(data); err != nil {
			return nil, 0, fmt.Errorf("unmarshaling %s: %w", path, err)
		}

		payloads = append(payloads, payload{
			filename: filepath.Base(path),
			raw:      data,
			req:      req,
		})
		totalRawBytes += int64(len(data))
	}

	return payloads, totalRawBytes, nil
}

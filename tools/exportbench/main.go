package main

import (
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"sort"
	"time"

	"go.opentelemetry.io/collector/pdata/pmetric/pmetricotlp"
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

	type formatDef struct {
		name string
		fn   func([]payload) (int64, error)
	}

	formats := []formatDef{
		{"OTLP HTTP JSON", func(ps []payload) (int64, error) {
			var total int64
			for _, p := range ps {
				b, err := marshalJSON(p.req)
				if err != nil {
					return 0, err
				}
				total += int64(len(b))
			}
			return total, nil
		}},
		{"OTLP HTTP Protobuf", func(ps []payload) (int64, error) {
			var total int64
			for _, p := range ps {
				b, err := marshalProto(p.req)
				if err != nil {
					return 0, err
				}
				total += int64(len(b))
			}
			return total, nil
		}},
		{"OTLP gRPC (no compression)", func(ps []payload) (int64, error) {
			var total int64
			for _, p := range ps {
				b, err := marshalProto(p.req)
				if err != nil {
					return 0, err
				}
				// gRPC adds a 5-byte frame header per message
				total += int64(len(b)) + 5
			}
			return total, nil
		}},
		{"STEF (none)", func(ps []payload) (int64, error) {
			var total int64
			for _, p := range ps {
				b, err := marshalSTEFNoCompression(p.req.Metrics())
				if err != nil {
					return 0, err
				}
				total += int64(len(b))
			}
			return total, nil
		}},
		{"STEF (zstd)", func(ps []payload) (int64, error) {
			var total int64
			for _, p := range ps {
				b, err := marshalSTEF(p.req.Metrics())
				if err != nil {
					return 0, err
				}
				total += int64(len(b))
			}
			return total, nil
		}},
		{"OTLP/HTTP JSON + zstd", func(ps []payload) (int64, error) {
			var total int64
			for _, p := range ps {
				b, err := marshalJSON(p.req)
				if err != nil {
					return 0, err
				}
				c, err := compressZstdHTTP(b)
				if err != nil {
					return 0, err
				}
				total += int64(len(c))
			}
			return total, nil
		}},
		{"OTLP/HTTP Proto + zstd", func(ps []payload) (int64, error) {
			var total int64
			for _, p := range ps {
				b, err := marshalProto(p.req)
				if err != nil {
					return 0, err
				}
				c, err := compressZstdHTTP(b)
				if err != nil {
					return 0, err
				}
				total += int64(len(c))
			}
			return total, nil
		}},
		{"OTLP/gRPC + zstd", func(ps []payload) (int64, error) {
			var total int64
			for _, p := range ps {
				b, err := marshalProto(p.req)
				if err != nil {
					return 0, err
				}
				c, err := compressZstdGRPC(b)
				if err != nil {
					return 0, err
				}
				// gRPC adds a 5-byte frame header per message
				total += int64(len(c)) + 5
			}
			return total, nil
		}},
	}

	results := make([]formatResult, 0, len(formats))
	for _, f := range formats {
		fmt.Fprintf(os.Stderr, "benchmarking: %s ...\n", f.name)

		// Warmup
		if _, err := f.fn(payloads); err != nil {
			fmt.Fprintf(os.Stderr, "error in %s: %v\n", f.name, err)
			os.Exit(1)
		}

		// Measure size from first iteration
		size, err := f.fn(payloads)
		if err != nil {
			fmt.Fprintf(os.Stderr, "error in %s: %v\n", f.name, err)
			os.Exit(1)
		}

		// Timed iterations with memory tracking
		runtime.GC()
		var memBefore runtime.MemStats
		runtime.ReadMemStats(&memBefore)

		start := time.Now()
		for i := 0; i < *iterations; i++ {
			if _, err := f.fn(payloads); err != nil {
				fmt.Fprintf(os.Stderr, "error in %s iteration %d: %v\n", f.name, i, err)
				os.Exit(1)
			}
		}
		elapsed := time.Since(start)

		var memAfter runtime.MemStats
		runtime.ReadMemStats(&memAfter)

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
		fmt.Printf("| %-20s | %8.1f MB | %10.2fx | %12s | %9d | %8.1f MB |\n",
			r.name,
			float64(r.totalBytes)/1024/1024,
			ratio,
			r.serializeTime.Round(time.Microsecond),
			r.numAllocs,
			float64(r.allocBytes)/1024/1024,
		)
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

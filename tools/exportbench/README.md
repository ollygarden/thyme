# exportbench

Benchmark tool for comparing metric export formats. Uses real OTel Collector exporter components (`otlpexporter`, `otlphttpexporter`, `stefexporter`) sending to local nop servers, measuring payload size, throughput, wire bytes, compression ratio, and memory allocations.

## Context

Evaluates which wire format to use for downstream export/storage of metric payloads by benchmarking real exporter pipelines with protobuf-encoded `ExportMetricsServiceRequest` messages.

## Formats Tested

| Format | Exporter Component |
|--------|-------------------|
| OTLP gRPC | `otlpexporter` (no compression) |
| OTLP gRPC + zstd | `otlpexporter` (zstd) |
| OTLP HTTP proto | `otlphttpexporter` (protobuf encoding) |
| OTLP HTTP proto + zstd | `otlphttpexporter` (protobuf + zstd) |
| OTLP HTTP JSON | `otlphttpexporter` (JSON encoding) |
| OTLP HTTP JSON + zstd | `otlphttpexporter` (JSON + zstd) |
| STEF | `stefexporter` (no compression) |
| STEF + zstd | `stefexporter` (zstd) |

## Prerequisites

A directory of `.pb` files containing protobuf-encoded `ExportMetricsServiceRequest` payloads (output of `pmetricotlp.ExportRequest.MarshalProto()`).

## Usage

### CLI benchmark

```bash
# Build
cd tools/exportbench
go build -o ../../bin/exportbench ./...

# Run against payload directory
../../bin/exportbench --input-dir /path/to/payload-dir/

# Custom iteration count
../../bin/exportbench --input-dir /path/to/raw/ --iterations 20
```

Output is a markdown table to stdout with per-format size, compression ratio, timing, and allocation stats.

### Go benchmarks

```bash
# Set payload directory
export EXPORTBENCH_INPUT_DIR=/path/to/payload-dir/

# Run all benchmarks
go test -bench=. -benchmem -count=3

# Run only STEF benchmarks
go test -bench='BenchmarkSTEF' -benchmem -count=3

# Run only OTLP gRPC benchmarks
go test -bench='BenchmarkOTLPgRPC' -benchmem -count=3
```

If `EXPORTBENCH_INPUT_DIR` is not set, benchmarks are skipped.

Benchmark output includes custom metrics: `wire-B/op` (wire bytes per iteration) and `compress-ratio` (raw protobuf size / wire bytes).

## Results

Dataset: 106 files, 63.8 MB raw protobuf, 353,698 data points.

### CLI benchmark (avg over 10 iterations)

| Format | Total Size | Ratio vs Raw | Serialize Time | Allocs/op | Bytes/op |
|--------|-----------|--------------|----------------|-----------|----------|
| OTLP gRPC              |     63.8 MB |       1.00x |    738.073ms |   6933915 |    311.6 MB |
| OTLP gRPC + zstd       |      5.1 MB |      12.58x |    1.001461s |   6934279 |    428.4 MB |
| OTLP HTTP proto        |     63.8 MB |       1.00x |    114.297ms |     14026 |     68.8 MB |
| OTLP HTTP proto+zstd   |      5.2 MB |      12.24x |    245.918ms |     15773 |     89.8 MB |
| OTLP HTTP JSON         |    125.5 MB |       0.51x |    379.618ms |    789524 |    205.9 MB |
| OTLP HTTP JSON+zstd    |      5.8 MB |      11.08x |    535.332ms |    791367 |    227.4 MB |
| STEF (none)            |      0.6 MB |     112.03x |     26.271ms |    205949 |     15.9 MB |
| STEF (zstd)            |      0.1 MB |     483.39x |     27.168ms |    229830 |     17.4 MB |

### Go benchmarks

```
goos: linux
goarch: amd64
cpu: 11th Gen Intel(R) Core(TM) i7-11800H @ 2.30GHz

BenchmarkOTLPgRPC-16               2     759563585 ns/op    88.10 MB/s     1.000 compress-ratio    66920687 wire-B/op   306808964 B/op   6933561 allocs/op
BenchmarkOTLPgRPC_Zstd-16          1    1102810687 ns/op    60.68 MB/s    12.58  compress-ratio     5320883 wire-B/op   497153704 B/op   6935270 allocs/op
BenchmarkOTLPHTTP_Proto-16        10     113119937 ns/op   591.59 MB/s     1.000 compress-ratio    66920157 wire-B/op    72199840 B/op     14042 allocs/op
BenchmarkOTLPHTTP_Proto_Zstd-16    4     266785750 ns/op   250.84 MB/s    12.24  compress-ratio     5469169 wire-B/op    92323304 B/op     15763 allocs/op
BenchmarkOTLPHTTP_JSON-16          3     369138323 ns/op   181.29 MB/s     0.508 compress-ratio   131630545 wire-B/op   211492069 B/op    789492 allocs/op
BenchmarkOTLPHTTP_JSON_Zstd-16     2     515336072 ns/op   129.86 MB/s    11.08  compress-ratio     6037916 wire-B/op   241065708 B/op    791392 allocs/op
BenchmarkSTEF-16                  48      25358978 ns/op  2638.91 MB/s   263.2   compress-ratio      254238 wire-B/op    19256771 B/op    225418 allocs/op
BenchmarkSTEF_Zstd-16             40      27972012 ns/op  2392.40 MB/s   643.2   compress-ratio      104050 wire-B/op    19152801 B/op    218023 allocs/op
```

### Key Takeaways

- **STEF is dramatically faster**: 25ms vs 114ms (best OTLP) — ~4.5x faster throughput
- **STEF compresses far better**: 0.1 MB (zstd) vs 5.1 MB (best OTLP+zstd) — ~50x smaller wire size
- **STEF allocates less memory**: 19 MB vs 69 MB (best OTLP) per iteration
- **zstd adds minimal overhead to STEF**: only ~2ms penalty for massive compression gains
- **OTLP HTTP proto is the fastest OTLP variant**: 6.5x faster than gRPC due to avoiding per-message gRPC framing overhead
- **JSON doubles wire size** without compression (125 MB vs 64 MB) but compresses to similar levels as proto+zstd

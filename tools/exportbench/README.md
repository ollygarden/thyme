# exportbench

Benchmark tool for comparing metric serialization formats. Measures payload size, serialization time, memory allocations, and compression ratio across OTLP (JSON/Protobuf) and STEF formats.

## Context

We receive metric payloads from customers via Raincatcher as protobuf-encoded `ExportMetricsServiceRequest` messages. This tool helps evaluate which wire format to use for downstream export/storage by benchmarking against real production payloads.

## Formats Tested

| Format | Description |
|--------|-------------|
| OTLP HTTP JSON | `ExportRequest.MarshalJSON()` |
| OTLP HTTP Protobuf | `ExportRequest.MarshalProto()` |
| OTLP gRPC | Same as Protobuf + 5-byte gRPC frame header |
| STEF (none) | Columnar encoding, no compression |
| STEF (zstd) | Columnar encoding + built-in zstd |
| JSON + zstd | JSON serialization + zstd compression |
| Protobuf + zstd | Protobuf serialization + zstd compression |

## Prerequisites

A directory of `.pb` files containing protobuf-encoded `ExportMetricsServiceRequest` payloads. These are produced by Raincatcher's ingester (see `raincatcher/internal/app/ingester_processor.go`).

## Usage

### CLI benchmark

```bash
# Build
cd tools/exportbench
go build -o ../../bin/exportbench ./...

# Run against payload directory
../../bin/exportbench --input-dir /path/to/raincatcher/local/raw/

# Custom iteration count
../../bin/exportbench --input-dir /path/to/raw/ --iterations 20
```

Output is a markdown table to stdout with per-format size, compression ratio, timing, and allocation stats.

### Go benchmarks

```bash
# Set payload directory
export EXPORTBENCH_INPUT_DIR=/path/to/raincatcher/local/raw/

# Run all benchmarks
go test -bench=. -benchmem -count=3

# Run only STEF benchmarks
go test -bench='BenchmarkMarshalSTEF' -benchmem -count=3
```

If `EXPORTBENCH_INPUT_DIR` is not set, defaults to `../../raincatcher/local/raw/`. Benchmarks are skipped if no `.pb` files are found.

## Results

See `local/tasks/E-1531/results.md` for full benchmark results and analysis.

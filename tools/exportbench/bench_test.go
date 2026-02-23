package main

import (
	"fmt"
	"os"
	"path/filepath"
	"testing"
)

var testPayloads []payload
var testTotalRawBytes int64

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

	os.Exit(m.Run())
}

func BenchmarkMarshalJSON(b *testing.B) {
	if len(testPayloads) == 0 {
		b.Skip("no test payloads")
	}
	b.SetBytes(testTotalRawBytes)
	b.ReportAllocs()
	for b.Loop() {
		for _, p := range testPayloads {
			if _, err := marshalJSON(p.req); err != nil {
				b.Fatal(err)
			}
		}
	}
}

func BenchmarkMarshalProto(b *testing.B) {
	if len(testPayloads) == 0 {
		b.Skip("no test payloads")
	}
	b.SetBytes(testTotalRawBytes)
	b.ReportAllocs()
	for b.Loop() {
		for _, p := range testPayloads {
			if _, err := marshalProto(p.req); err != nil {
				b.Fatal(err)
			}
		}
	}
}

func BenchmarkMarshalSTEF_None(b *testing.B) {
	if len(testPayloads) == 0 {
		b.Skip("no test payloads")
	}
	b.SetBytes(testTotalRawBytes)
	b.ReportAllocs()
	for b.Loop() {
		for _, p := range testPayloads {
			if _, err := marshalSTEFNoCompression(p.req.Metrics()); err != nil {
				b.Fatal(err)
			}
		}
	}
}

func BenchmarkMarshalSTEF(b *testing.B) {
	if len(testPayloads) == 0 {
		b.Skip("no test payloads")
	}
	b.SetBytes(testTotalRawBytes)
	b.ReportAllocs()
	for b.Loop() {
		for _, p := range testPayloads {
			if _, err := marshalSTEF(p.req.Metrics()); err != nil {
				b.Fatal(err)
			}
		}
	}
}

func BenchmarkMarshalJSON_Zstd(b *testing.B) {
	if len(testPayloads) == 0 {
		b.Skip("no test payloads")
	}
	b.SetBytes(testTotalRawBytes)
	b.ReportAllocs()
	for b.Loop() {
		for _, p := range testPayloads {
			data, err := marshalJSON(p.req)
			if err != nil {
				b.Fatal(err)
			}
			if _, err := compressZstd(data); err != nil {
				b.Fatal(err)
			}
		}
	}
}

func BenchmarkMarshalProto_Zstd(b *testing.B) {
	if len(testPayloads) == 0 {
		b.Skip("no test payloads")
	}
	b.SetBytes(testTotalRawBytes)
	b.ReportAllocs()
	for b.Loop() {
		for _, p := range testPayloads {
			data, err := marshalProto(p.req)
			if err != nil {
				b.Fatal(err)
			}
			if _, err := compressZstd(data); err != nil {
				b.Fatal(err)
			}
		}
	}
}

func BenchmarkIndividualPayloadSTEF(b *testing.B) {
	if len(testPayloads) == 0 {
		b.Skip("no test payloads")
	}
	// Benchmark a few representative payloads by size
	type sized struct {
		label string
		idx   int
	}
	// Find smallest, median, and largest
	smallest, largest := 0, 0
	for i, p := range testPayloads {
		if len(p.raw) < len(testPayloads[smallest].raw) {
			smallest = i
		}
		if len(p.raw) > len(testPayloads[largest].raw) {
			largest = i
		}
	}
	median := len(testPayloads) / 2

	cases := []sized{
		{"smallest", smallest},
		{"median", median},
		{"largest", largest},
	}

	for _, tc := range cases {
		p := testPayloads[tc.idx]
		b.Run(tc.label+"-"+filepath.Base(p.filename), func(b *testing.B) {
			b.SetBytes(int64(len(p.raw)))
			b.ReportAllocs()
			for b.Loop() {
				if _, err := marshalSTEF(p.req.Metrics()); err != nil {
					b.Fatal(err)
				}
			}
		})
	}
}

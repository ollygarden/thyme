package main

import (
	"bytes"
	"sync"

	"github.com/klauspost/compress/zstd"
	"github.com/splunk/stef/go/otel/otelstef"
	stefpdatametrics "github.com/splunk/stef/go/pdata/metrics"
	"github.com/splunk/stef/go/pkg"
	"go.opentelemetry.io/collector/pdata/pmetric"
	"go.opentelemetry.io/collector/pdata/pmetric/pmetricotlp"
)

func marshalJSON(req pmetricotlp.ExportRequest) ([]byte, error) {
	return req.MarshalJSON()
}

func marshalProto(req pmetricotlp.ExportRequest) ([]byte, error) {
	return req.MarshalProto()
}

func marshalSTEFNoCompression(metrics pmetric.Metrics) ([]byte, error) {
	return marshalSTEFWith(metrics, pkg.CompressionNone)
}

func marshalSTEF(metrics pmetric.Metrics) ([]byte, error) {
	return marshalSTEFWith(metrics, pkg.CompressionZstd)
}

func marshalSTEFWith(metrics pmetric.Metrics, compression pkg.Compression) ([]byte, error) {
	buf := &pkg.MemChunkWriter{}
	writer, err := otelstef.NewMetricsWriter(buf, pkg.WriterOptions{
		Compression: compression,
	})
	if err != nil {
		return nil, err
	}

	converter := &stefpdatametrics.OtlpToStefUnsorted{}
	if err := converter.Convert(metrics, writer); err != nil {
		return nil, err
	}

	if err := writer.Flush(); err != nil {
		return nil, err
	}

	return buf.Bytes(), nil
}

// compressZstdHTTP mirrors confighttp's compressor: sync.Pool of encoders
// with WithEncoderConcurrency(1), default 8MB window, streaming write.
// See: go.opentelemetry.io/collector/config/confighttp/compressor.go
var httpZstdPool = sync.Pool{
	New: func() any {
		w, _ := zstd.NewWriter(nil, zstd.WithEncoderConcurrency(1))
		return w
	},
}

func compressZstdHTTP(data []byte) ([]byte, error) {
	enc := httpZstdPool.Get().(*zstd.Encoder)
	defer httpZstdPool.Put(enc)

	var buf bytes.Buffer
	enc.Reset(&buf)
	if _, err := enc.Write(data); err != nil {
		return nil, err
	}
	if err := enc.Close(); err != nil {
		return nil, err
	}
	return buf.Bytes(), nil
}

// compressZstdGRPC mirrors go-grpc-compression's zstd codec: single shared
// encoder with 512KB window, EncodeAll() batch encoding.
// See: github.com/mostynb/go-grpc-compression/internal/zstd/zstd.go
var grpcZstdEncoder, _ = zstd.NewWriter(nil,
	zstd.WithEncoderConcurrency(1),
	zstd.WithWindowSize(512*1024),
)

func compressZstdGRPC(data []byte) ([]byte, error) {
	return grpcZstdEncoder.EncodeAll(data, nil), nil
}

package main

import (
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

func compressZstd(data []byte) ([]byte, error) {
	enc, err := zstd.NewWriter(nil, zstd.WithEncoderLevel(zstd.SpeedDefault))
	if err != nil {
		return nil, err
	}
	defer enc.Close()
	return enc.EncodeAll(data, nil), nil
}

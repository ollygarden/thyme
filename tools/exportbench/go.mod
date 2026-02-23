module go.olly.garden/thyme/tools/exportbench

go 1.25.0

require (
	github.com/klauspost/compress v1.18.4
	github.com/splunk/stef/go/otel v0.1.1
	github.com/splunk/stef/go/pdata v0.1.1
	github.com/splunk/stef/go/pkg v0.1.1
	go.opentelemetry.io/collector/pdata v1.52.0
)

require (
	github.com/hashicorp/go-version v1.8.0 // indirect
	github.com/json-iterator/go v1.1.12 // indirect
	github.com/modern-go/concurrent v0.0.0-20180306012644-bacd9c7ef1dd // indirect
	github.com/modern-go/reflect2 v1.0.3-0.20250322232337-35a7c28c31ee // indirect
	go.opentelemetry.io/collector/featuregate v1.52.0 // indirect
	go.uber.org/multierr v1.11.0 // indirect
	golang.org/x/net v0.48.0 // indirect
	golang.org/x/sys v0.39.0 // indirect
	golang.org/x/text v0.32.0 // indirect
	google.golang.org/genproto/googleapis/rpc v0.0.0-20251222181119-0a764e51fe1b // indirect
	google.golang.org/grpc v1.79.1 // indirect
	google.golang.org/protobuf v1.36.11 // indirect
	modernc.org/b/v2 v2.1.10 // indirect
)

// Temporary: use fork with panic-to-error fix until splunk/stef#371 is merged and released.
replace github.com/splunk/stef/go/pdata => github.com/jpkrohling/stef/go/pdata v0.0.0-20260222100847-1f92bd111b31

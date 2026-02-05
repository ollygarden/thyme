# Benchmarking Guide

This guide walks through running performance benchmarks for the Thyme collector.

## Test Scenario

**Configuration:**
- 20 log generator pods
- 2,500 lines/second per pod
- Total: 50,000 log lines/second
- Log size: 100-1000 bytes per line (random)
- Duration: 10 minutes

**Architecture:**
```
20× log-generator → /var/log/pods
    ↓ (filelog receiver)
thyme DaemonSet
    ↓ (parse + k8s enrichment + batch + OTLP)
nop-collector
    ↓ (nop exporter - discard)

Both collectors → internal telemetry → LGTM
```

## Prerequisites

- k3d installed
- kubectl configured
- Docker running
- At least 4GB RAM available

## Running the Benchmark

### 1. Setup Environment

```bash
# Create k3d cluster
k3d cluster create thyme --agents 2

# Build and load Thyme image
cd /path/to/thyme
make k3d-load K3D_CLUSTER=thyme
```

### 2. Deploy Stack

```bash
# Deploy all components (thyme-benchmark + LGTM stack)
kubectl apply -k deployment/kubernetes/
```

### 3. Wait for Ready

```bash
# Wait for LGTM
kubectl wait --for=condition=ready pod -l app=lgtm -n lgtm --timeout=120s

# Wait for collectors
kubectl wait --for=condition=ready pod -l app=nop-collector -n thyme-benchmark --timeout=120s

# Verify all pods are running
kubectl get pods -n thyme-benchmark
kubectl get pods -n lgtm
```

### 4. Start Monitoring

Open Grafana in your browser:

**For k3d (Local Development):**
```bash
# Via NodePort
open http://localhost:30000
# Login: admin/admin
```

**For Production Clusters:**
```bash
# Via port-forward
kubectl port-forward -n lgtm service/grafana 3000:3000
open http://localhost:3000
# Login: admin/admin
```

Navigate to **Explore** → **Prometheus** datasource.

### 5. Key Metrics to Monitor

Add these queries to track performance:

#### Throughput
```promql
# Logs received by nop-collector (should be ~50,000/sec)
rate(otelcol_receiver_accepted_log_records_total{service_name="nop-collector"}[1m])

# Logs sent by thyme (should match received)
rate(otelcol_exporter_sent_log_records_total{service_name="thyme"}[1m])
```

#### Resource Usage (Thyme DaemonSet)
```promql
# CPU usage (cores)
rate(otelcol_process_cpu_seconds_total{service_name="thyme"}[1m])

# Memory usage (MB)
otelcol_process_runtime_heap_alloc_bytes{service_name="thyme"} / 1024 / 1024
```

#### Pipeline Health
```promql
# Batch processor average batch size
otelcol_processor_batch_batch_send_size_sum{service_name="thyme"} /
otelcol_processor_batch_batch_send_size_count{service_name="thyme"}

# Memory limiter refusals (should be 0)
rate(otelcol_processor_refused_log_records_total{service_name="thyme"}[1m])

# Export failures (should be 0)
rate(otelcol_exporter_send_failed_log_records_total{service_name="thyme"}[1m])
```

### 6. Let Test Run

Let the test run for **10 minutes** to collect steady-state metrics.

Monitor via terminal:
```bash
# Watch log accumulation
watch -n 5 'kubectl exec -n thyme-benchmark daemonset/thyme -- sh -c "wc -l /var/log/pods/thyme-benchmark_log-generator*/app/0.log 2>/dev/null | tail -1"'

# Watch pod status
kubectl get pods -n thyme-benchmark -w
```

### 7. Collect Results

After 10 minutes:

**Via kubectl:**
```bash
# Total logs generated
TOTAL=$(kubectl exec -n thyme-benchmark daemonset/thyme -- sh -c \
  'wc -l /var/log/pods/thyme-benchmark_log-generator*/app/0.log 2>/dev/null | tail -1 | awk "{print \$1}"')
echo "Total logs: $TOTAL"
echo "Expected: ~6,000,000 (10min × 60sec × 10k/sec)"

# Average throughput
echo "Average throughput: $(echo "scale=2; $TOTAL / 600" | bc) logs/sec"
```

**Via Grafana:**
1. Set time range: "Last 10 minutes"
2. Run all queries from step 5
3. For each query:
   - Click **Inspector** → **Data** → **Download CSV**
   - Save as: `thyme-benchmark-{metric-name}.csv`

**Via zpages:**
```bash
# Thyme detailed stats
kubectl port-forward -n thyme-benchmark daemonset/thyme 55679:55679 &
curl http://localhost:55679/debug/servicez > thyme-servicez.html
open thyme-servicez.html

# nop-collector stats
kubectl port-forward -n thyme-benchmark deployment/nop-collector 55680:55679 &
curl http://localhost:55680/debug/servicez > nop-collector-servicez.html
open nop-collector-servicez.html
```

## Expected Results

### Throughput
- **Target**: 50,000 logs/sec
- **Actual**: Should be within 5% (47,500 - 52,500 logs/sec)
- **Total over 10 min**: ~30,000,000 logs

### Resource Usage (Thyme DaemonSet per node)
- **CPU**: < 1 core (typically 0.5-0.8 cores)
- **Memory**: < 500 MB (typically 200-400 MB)

### Pipeline Health
- **Batch size**: 10,000 logs (configured)
- **Memory refusals**: 0
- **Export failures**: 0
- **Queue depth**: Stable (not growing)

## Adjusting Test Parameters

### Increase Throughput

Edit `deployment/kubernetes/loggen-deployment.yaml`:

```yaml
# Option 1: More lines per pod
args:
  - --lines-per-second=5000  # 100k total (20 pods × 5k)

# Option 2: More pods
replicas: 40  # 100k total (40 pods × 2.5k)
```

Apply changes:
```bash
kubectl apply -f deployment/kubernetes/loggen-deployment.yaml
```

### Increase Thyme Resources

Edit `deployment/kubernetes/thyme-daemonset.yaml`:

```yaml
resources:
  limits:
    cpu: 4000m
    memory: 4Gi
```

Apply and restart:
```bash
kubectl apply -f deployment/kubernetes/thyme-daemonset.yaml
kubectl rollout restart daemonset/thyme -n thyme-benchmark
```

### Adjust Batch Size

Edit `deployment/kubernetes/thyme-configmap.yaml`:

```yaml
processors:
  batch:
    send_batch_size: 5000      # Smaller batches
    send_batch_max_size: 6000
    timeout: 5s                # More frequent flushes
```

Apply:
```bash
kubectl delete configmap thyme-config -n thyme-benchmark
kubectl apply -f deployment/kubernetes/thyme-configmap.yaml
kubectl rollout restart daemonset/thyme -n thyme-benchmark
```

## Troubleshooting

### Low Throughput

Check if logs are being generated:
```bash
kubectl logs -n thyme-benchmark -l app=log-generator --tail=10
```

Check if thyme is reading logs:
```bash
kubectl logs -n thyme-benchmark daemonset/thyme --tail=50 | grep -i "file\|read"
```

### High Memory Usage

Check memory limiter configuration:
```bash
kubectl logs -n thyme-benchmark daemonset/thyme --tail=100 | grep -i "memory"
```

If seeing refusals, increase memory limits or batch size.

### Export Failures

Check nop-collector connectivity:
```bash
kubectl logs -n thyme-benchmark daemonset/thyme --tail=100 | grep -i "error\|fail"
```

Verify nop-collector is ready:
```bash
kubectl get pods -n thyme-benchmark -l app=nop-collector
```

## Cleanup

### Remove Resources (Keep Cluster)

```bash
# Delete all resources deployed by kustomize
kubectl delete -k deployment/kubernetes/

# Or delete namespaces directly (also removes all resources)
kubectl delete namespace thyme-benchmark lgtm
```

### Remove k3d Cluster (Local Dev Only)

```bash
# Delete the entire k3d cluster
k3d cluster delete thyme
```

## Comparing Results

To compare different configurations:

1. Save Grafana dashboards for each test
2. Export metrics as CSV for each test
3. Compare key metrics:
   - Throughput (logs/sec)
   - CPU efficiency (logs/sec per CPU core)
   - Memory efficiency (logs/sec per MB)
   - Latency (p95, p99 from batch processor metrics)

Example comparison table:

| Config | Throughput | CPU | Memory | CPU Efficiency |
|--------|-----------|-----|---------|----------------|
| Baseline (50k/s) | 50,000 | 1.5 | 800 MB | 33,333 logs/core |
| 2× throughput | 100,000 | 2.8 | 1.5 GB | 35,714 logs/core |
| 4× batch size | 50,000 | 1.2 | 900 MB | 41,667 logs/core |

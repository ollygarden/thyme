# Kubernetes Deployment

This directory contains Kubernetes manifests for deploying Thyme in a benchmarking configuration.

## Architecture

```
┌──────────────┐
│  log-generator│  10 replicas @ 10,000 lines/sec each = 100k lines/sec total
└──────┬────────┘
       │ stdout (captured by kubelet)
       ↓
  /var/log/pods/*/*/*.log
       │
       ↓ (filelog receiver)
┌──────────────┐
│    thyme     │  DaemonSet (one per node)
│  (filelog →  │  - Reads pod logs from host
│   k8sattrs → │  - Enriches with K8s metadata
│   batch →    │  - Batches and exports
│   OTLP)      │
└──────┬────────┘
       │ OTLP gRPC :4317
       ↓
┌──────────────┐
│nop-collector │  Deployment (1 replica)
│  (OTLP →     │  - Receives from all thyme DaemonSet pods
│   batch →    │  - Processes and discards
│   nop)       │
└──────────────┘
```

Both collectors send internal telemetry (metrics, traces) to your observability backend via the configured endpoints.

## Components

- **thyme**: DaemonSet that reads logs from `/var/log/pods` on each node
- **nop-collector**: Deployment that receives OTLP and exports to nop (discard)
- **log-generator**: Deployment with 10 replicas generating 10,000 lines/sec each (100-1000 byte lines)

## Prerequisites

- Kubernetes cluster (1.24+)
- kubectl configured
- Docker for building images

## Building and Loading Images

### For Local k3d Development

If you're using k3d for local development, use the provided script to build and load the image:

```bash
# Build and load into thyme-test cluster
./deployment/kubernetes/build-and-load.sh thyme-test

# Or specify a different cluster name
./deployment/kubernetes/build-and-load.sh my-cluster
```

This script:
1. Builds the Docker image from the repository root
2. Imports it directly into the k3d cluster (no registry push needed)
3. Makes it available for deployment

Verify the image is loaded:
```bash
docker exec k3d-thyme-test-server-0 crictl images | grep thyme
```

### For Production/Remote Clusters

Build and push to GitHub Container Registry:

```bash
# Build the image
docker build -t ghcr.io/ollygarden/thyme:latest .

# Tag with version
docker tag ghcr.io/ollygarden/thyme:latest ghcr.io/ollygarden/thyme:v0.144.0

# Login to GHCR (requires GitHub PAT with write:packages scope)
echo $GITHUB_TOKEN | docker login ghcr.io -u USERNAME --password-stdin

# Push images
docker push ghcr.io/ollygarden/thyme:latest
docker push ghcr.io/ollygarden/thyme:v0.144.0
```

### Using a Different Registry

To use a different registry, update the image references in:
- `thyme-daemonset.yaml`
- `nop-collector-deployment.yaml`

Replace `ghcr.io/ollygarden/thyme:latest` with your registry URL.

## Quick Start (k3d)

1. **Create a k3d cluster** (if you don't have one):
   ```bash
   k3d cluster create thyme-test --agents 2
   ```

2. **Build and load the image**:
   ```bash
   ./deployment/kubernetes/build-and-load.sh thyme-test
   ```

3. **Deploy**:
   ```bash
   # Deploys both thyme-benchmark and LGTM stack
   kubectl apply -k deployment/kubernetes/
   ```

4. **Verify**:
   ```bash
   kubectl get all -n thyme-benchmark
   ```

## Deployment

Deploy all resources (thyme-benchmark + LGTM observability stack) using Kustomize:

```bash
kubectl apply -k deployment/kubernetes/
```

This single command deploys:
- **thyme-benchmark namespace**: DaemonSet, nop-collector, log-generators
- **lgtm namespace**: Grafana/LGTM observability stack

Or apply individual files if needed:

```bash
# thyme-benchmark resources
kubectl apply -f deployment/kubernetes/namespace.yaml
kubectl apply -f deployment/kubernetes/serviceaccount.yaml
kubectl apply -f deployment/kubernetes/thyme-configmap.yaml
kubectl apply -f deployment/kubernetes/nop-collector-configmap.yaml
kubectl apply -f deployment/kubernetes/nop-collector-deployment.yaml
kubectl apply -f deployment/kubernetes/nop-collector-service.yaml
kubectl apply -f deployment/kubernetes/thyme-daemonset.yaml
kubectl apply -f deployment/kubernetes/loggen-deployment.yaml

# LGTM observability stack
kubectl apply -f deployment/kubernetes/lgtm-namespace.yaml
kubectl apply -f deployment/kubernetes/lgtm-deployment.yaml
kubectl apply -f deployment/kubernetes/lgtm-service.yaml
```

## Verify Deployment

Check that all components are running:

```bash
kubectl get all -n thyme-benchmark
```

Expected output:
- DaemonSet `thyme` with one pod per node
- Deployment `nop-collector` with 1 replica
- Deployment `log-generator` with 10 replicas

## Access Metrics and Observability

### Grafana (LGTM Stack)

Access Grafana to view collector internal telemetry:

```bash
# Via port-forward (recommended for all clusters)
kubectl port-forward -n lgtm service/grafana 3000:3000
open http://localhost:3000

# Or via NodePort (k3d local development only)
open http://localhost:30000
```

**Default credentials**: admin/admin

**Note**: Port-forward is recommended for production clusters. The NodePort service is configured for k3d local development convenience.

Navigate to **Explore** and select:
- **Prometheus** datasource for metrics (collector internal metrics)
- **Tempo** datasource for traces (collector internal traces)

Example queries:
```promql
# Logs received by nop-collector
otelcol_receiver_accepted_log_records_total{service_name="nop-collector"}

# Logs exported by thyme
otelcol_exporter_sent_log_records_total{service_name="thyme"}

# Memory usage (bytes)
otelcol_process_runtime_heap_alloc_bytes{service_namespace="ollygarden"}
```

### Collector Debug Interfaces

Port-forward to access collector debug interfaces:

```bash
# Thyme zpages
kubectl port-forward -n thyme-benchmark daemonset/thyme 55679:55679

# nop-collector zpages
kubectl port-forward -n thyme-benchmark deployment/nop-collector 55679:55679

# Thyme pprof
kubectl port-forward -n thyme-benchmark daemonset/thyme 1777:1777

# nop-collector pprof
kubectl port-forward -n thyme-benchmark deployment/nop-collector 1777:1777
```

## Running Performance Tests

### 10-Minute Benchmark Test

The default configuration generates 100,000 log lines/second (10 pods × 10,000 lines/sec).

**1. Verify all components are running:**
```bash
kubectl get pods -n thyme-benchmark
kubectl get pods -n lgtm
```

**2. Access Grafana:**
```bash
# Via port-forward (recommended)
kubectl port-forward -n lgtm service/grafana 3000:3000 &
open http://localhost:3000

# Or via NodePort (k3d only)
open http://localhost:30000

# Credentials: admin/admin
```

**3. Monitor throughput in Grafana:**

Navigate to **Explore** → **Prometheus** and run:

```promql
# Logs received by nop-collector (logs/sec)
rate(otelcol_receiver_accepted_log_records_total{service_name="nop-collector"}[1m])

# Logs sent by thyme (logs/sec)
rate(otelcol_exporter_sent_log_records_total{service_name="thyme"}[1m])

# Thyme CPU usage (cores)
rate(otelcol_process_cpu_seconds_total{service_name="thyme"}[1m])

# Thyme memory usage (MB)
otelcol_process_runtime_heap_alloc_bytes{service_name="thyme"} / 1024 / 1024
```

**4. Expected Results (10 minutes):**
- **Total logs**: ~60,000,000 (10 min × 60 sec × 100k logs/sec)
- **Throughput**: ~100,000 logs/sec
- **CPU (thyme)**: ~2-3 cores
- **Memory (thyme)**: < 1.5 GB

**5. Collect Results:**

Via kubectl:
```bash
# Total log lines generated
kubectl exec -n thyme-benchmark daemonset/thyme -- sh -c \
  'wc -l /var/log/pods/thyme-benchmark_log-generator*/app/0.log 2>/dev/null | tail -1'

# Log file sizes
kubectl exec -n thyme-benchmark daemonset/thyme -- sh -c \
  'du -sh /var/log/pods/thyme-benchmark_log-generator*/app/ 2>/dev/null | head -5'
```

Via Grafana:
1. Set time range to "Last 10 minutes"
2. Run the queries above
3. Click **Inspector** → **Data** → **Download CSV** to export metrics

**6. View detailed collector stats:**
```bash
# Thyme zpages (service metrics and pipeline stats)
kubectl port-forward -n thyme-benchmark daemonset/thyme 55679:55679
open http://localhost:55679/debug/servicez

# nop-collector zpages
kubectl port-forward -n thyme-benchmark deployment/nop-collector 55680:55679
open http://localhost:55680/debug/servicez
```

### Adjusting Load

To test different throughput levels, edit `loggen-deployment.yaml`:

```yaml
# Change lines-per-second per pod
--lines-per-second=5000  # 50k logs/sec total (10 pods × 5k)

# Change number of replicas
replicas: 20  # 200k logs/sec total (20 × 10k)
```

Then reapply:
```bash
kubectl apply -f deployment/kubernetes/loggen-deployment.yaml
```

## Cleanup

### Remove Resources (Keep Cluster)

Remove all deployed resources without deleting the cluster:

```bash
# Delete everything deployed by kustomize (recommended)
kubectl delete -k deployment/kubernetes/
```

Alternative - delete namespaces directly (also removes all resources):

```bash
kubectl delete namespace thyme-benchmark lgtm
```

### Remove k3d Cluster (Local Dev Only)

If you're using k3d and want to remove the entire cluster:

```bash
k3d cluster delete thyme-test
```

## Configuration

### Adjusting Log Generation Rate

Edit `loggen-deployment.yaml` and modify:
- `--lines-per-second=10000` - Lines per second per replica
- `replicas: 10` - Number of generator pods

Total throughput = replicas × lines-per-second (default: 10 × 10,000 = 100k logs/sec)

### Adjusting Collector Resources

Edit resource limits in:
- `thyme-daemonset.yaml` - DaemonSet resource limits
- `nop-collector-deployment.yaml` - Deployment resource limits

### Batch Configuration

Edit batch processor settings in ConfigMaps:
- `thyme-configmap.yaml`
- `nop-collector-configmap.yaml`

Adjust `send_batch_size`, `send_batch_max_size`, and `timeout` based on your performance requirements.

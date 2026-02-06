# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Thyme is a **downstream distribution of Tulip** (OllyGarden's OpenTelemetry Collector), specialized for high-throughput log collection benchmarking. It is NOT a production collector - it's a performance testing tool that validates collector performance at 50-100k+ logs/sec.

**Relationship to Tulip**: Thyme is built using the same OCB (OpenTelemetry Collector Builder) approach as Tulip but with a focused component set optimized for log ingestion benchmarking.

## Build System Architecture

### Two-Level Build Structure

The project uses a **two-level Makefile structure**:

1. **Root Makefile** (`./Makefile`) - Entry point that delegates to distribution
2. **Distribution Makefile** (`distributions/thyme/Makefile`) - Actual build logic

All build commands at the root simply forward to `distributions/thyme/`.

### OpenTelemetry Collector Builder (OCB)

Thyme is built using **OCB v0.144.0**, which:
- Downloads automatically on first build to `distributions/thyme/bin/builder`
- Reads `distributions/thyme/manifest.yaml` to know which OTel components to include
- Generates Go source code in `distributions/thyme/build/`
- Compiles to `distributions/thyme/build/thyme` binary

**Key principle**: The manifest.yaml defines the distribution. To add/remove components, edit the manifest and rebuild.

## Build Commands

```bash
# Build the collector binary
make build

# Run locally with config.yaml
make run

# Validate configuration without running
make validate

# Clean all build artifacts
make clean

# Build Docker image
make docker-build

# Build and load into k3d cluster
make k3d-load K3D_CLUSTER=thyme-test
```

## Configuration Files

Two configurations exist in `distributions/thyme/`:

- **`config.yaml`** - Production config with filelog receiver + k8sattributes processor (for DaemonSet deployments)
- **`config-local.yaml`** - Local testing config with only OTLP receiver (simpler, no K8s dependencies)

When modifying configurations, remember:
- Extensions must bind to `0.0.0.0` not `localhost` (for K8s health checks)
- Batch processor `send_batch_size: 10000` creates ~4.6MB messages
- gRPC receivers need `max_recv_msg_size_mib: 16` to handle large batches
- Internal telemetry sends to LGTM via `http://lgtm.lgtm.svc.cluster.local:4318`

## Deployment Architecture

### Two-Stage Benchmarking Pipeline

```
log-generator pods (100 × 1,000 lines/sec = 100k logs/sec)
    ↓
/var/log/pods/* (Kubernetes host filesystem)
    ↓
thyme DaemonSet (filelog receiver → k8sattributes → batch → OTLP exporter)
    ↓
nop-collector Deployment (OTLP receiver → batch → nop exporter)
    ↓
[discarded]

Both collectors export internal telemetry to LGTM stack
```

**Why two stages?**: This simulates realistic edge collection (DaemonSet) → aggregation (Deployment) patterns while isolating performance of the edge collector.

### Deployment Modes

1. **Docker Compose** (`deployment/compose/`) - Local development, single-host testing
2. **Kubernetes with k3d** (`deployment/kubernetes/`) - Local Kubernetes testing with k3d
3. **AWS EKS** (`deployment/aws/` + `infrastructure/aws/`) - Production-scale cloud benchmarking

### Kubernetes Deployment Structure

All Kubernetes resources deploy via `kubectl apply -k deployment/kubernetes/`, which includes:

- **thyme-benchmark namespace**: Contains thyme DaemonSet, nop-collector, log-generators
- **lgtm namespace**: Grafana LGTM stack for observability (Prometheus, Loki, Tempo)

Resources use **kustomize** with `labels` (not deprecated `commonLabels`).

## Performance Metrics

When querying metrics in Grafana, use these **correct metric names** (v0.144.0+):

### Counter Metrics (require `_total` suffix)
- `otelcol_receiver_accepted_log_records_total` - Logs received
- `otelcol_exporter_sent_log_records_total` - Logs exported
- `otelcol_exporter_send_failed_log_records_total` - Export failures
- `otelcol_processor_refused_log_records_total` - Memory limiter refusals

### Gauge Metrics
- `otelcol_process_cpu_seconds_total` - CPU usage (rate this for cores)
- `otelcol_process_runtime_heap_alloc_bytes` - Memory usage
- `otelcol_processor_batch_batch_send_size_*` - Batch size stats

**Important**: Process metrics have `otelcol_` prefix. Go runtime metrics like `process_runtime_go_goroutines` are NOT exported.

## Version Management

When updating OTel Collector versions:

1. Update `distributions/thyme/manifest.yaml`:
   - Collector version: `dist.version` and all component versions (e.g., `v0.144.0`)
   - Provider versions: `providers[*].gomod` (e.g., `v1.50.0`)

2. Update `distributions/thyme/Makefile`:
   - `OCB_VERSION` variable

3. Update `Dockerfile`:
   - `ARG OCB_VERSION=...`

4. Rebuild: `make clean && make build`

## Common Issues

### gRPC Message Size Errors
**Symptom**: `grpc: received message larger than max (4630191 vs. 4194304)`

**Fix**: Increase `max_recv_msg_size_mib` on the receiving collector's OTLP receiver:
```yaml
receivers:
  otlp:
    protocols:
      grpc:
        max_recv_msg_size_mib: 16
```

### Health Check Failures in Kubernetes
**Symptom**: Readiness probes fail with "connection refused"

**Fix**: Extensions must bind to `0.0.0.0`, not `localhost`:
```yaml
extensions:
  health_check:
    endpoint: 0.0.0.0:13133
```

### Log Parsing Failures
Filelog receiver parses containerd/docker/cri-o formats. Simplify operators with `on_error: drop` to avoid pipeline failures on malformed logs.

## Local Testing Workflow (k3d)

For local development and quick testing:

1. **Build and load into k3d**:
   ```bash
   k3d cluster create thyme-test --agents 2
   make k3d-load K3D_CLUSTER=thyme-test
   ```

2. **Deploy everything**:
   ```bash
   kubectl apply -k deployment/kubernetes/
   kubectl wait --for=condition=ready pod -l app=lgtm -n lgtm --timeout=120s
   ```

3. **Access Grafana**:
   ```bash
   kubectl port-forward -n lgtm service/grafana 3000:3000
   ```

4. **Monitor throughput** (Explore → Prometheus):
   ```promql
   rate(otelcol_receiver_accepted_log_records_total{service_name="nop-collector"}[1m])
   ```

5. **Cleanup**:
   ```bash
   kubectl delete -k deployment/kubernetes/
   k3d cluster delete thyme-test
   ```

## AWS Benchmarking

Thyme supports **production-scale benchmarking on AWS EKS** with automated infrastructure provisioning, deployment, and teardown.

### Quick Start: Automated Benchmark

The easiest way to run an AWS benchmark:

```bash
# Full automated benchmark (provision → deploy → run → collect → cleanup)
./scripts/run-benchmark-aws.sh

# Custom active duration (default 30 minutes)
./scripts/run-benchmark-aws.sh 60

# Keep infrastructure running after benchmark
AUTO_CLEANUP=false ./scripts/run-benchmark-aws.sh
```

**What the script does:**
1. Provisions EKS cluster with OpenTofu (~15 min)
2. Deploys thyme + LGTM stack (~5 min)
3. Runs benchmark with 3 phases:
   - Ramp-up: 5 minutes (system stabilization)
   - Active: 30 minutes (performance measurement)
   - Cool-down: 10 minutes (tail behavior observation)
4. Collects metrics via LoadBalancer
5. Generates comprehensive report in `local/reports/YYYY-MM-DD-NN-aws/`
6. Destroys infrastructure (~10 min, optional)

**Total runtime**: ~75 minutes for default 30-minute active benchmark
**Estimated cost**: ~$2.50/hour (~$3.00 for full run)

### Manual AWS Setup

For interactive testing or development:

#### 1. Provision Infrastructure

```bash
cd infrastructure/aws

# Initialize OpenTofu (first time only)
tofu init

# Provision EKS cluster (~15 minutes)
tofu apply
```

**Infrastructure includes:**
- EKS cluster (Kubernetes 1.34)
- 3× m6i.2xlarge nodes (8 vCPU, 32GB RAM each)
- VPC with public/private subnets across 3 AZs
- NAT gateway for private subnet egress
- ECR repository (optional)
- IAM roles and security groups

#### 2. Configure kubectl

```bash
aws eks update-kubeconfig --region eu-central-1 --name thyme-benchmark-<timestamp>

# Verify nodes ready
kubectl wait --for=condition=ready node --all --timeout=300s
kubectl get nodes
```

#### 3. Deploy Workload

```bash
# Deploy thyme + LGTM stack
kubectl apply -k deployment/aws/

# Wait for LGTM
kubectl wait --for=condition=ready pod -l app=lgtm -n lgtm --timeout=180s

# Wait for collectors
kubectl wait --for=condition=ready pod -l app=thyme -n thyme-benchmark --timeout=120s
kubectl wait --for=condition=ready pod -l app=nop-collector -n thyme-benchmark --timeout=120s

# Wait for log generators (co-located on single node)
kubectl wait --for=condition=ready pod -l app=log-generator -n thyme-benchmark --timeout=180s
```

#### 4. Access Grafana

```bash
# Get LoadBalancer URL (takes ~2-3 minutes to provision)
LB_URL=$(kubectl get svc grafana -n lgtm -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
echo "Grafana: http://$LB_URL:3000"

# Login: admin / admin
```

#### 5. Monitor Performance

Query throughput in Grafana (Explore → Prometheus):

```promql
# Throughput (logs/sec)
rate(otelcol_receiver_accepted_log_records_total{service_name="nop-collector"}[1m])

# CPU usage per thyme pod
rate(otelcol_process_cpu_seconds_total{service_name="thyme"}[1m])

# Memory usage
otelcol_process_runtime_heap_alloc_bytes{service_name="thyme"} / 1024 / 1024
```

#### 6. Cleanup

**IMPORTANT**: Always delete Kubernetes resources first, then wait before destroying infrastructure to avoid 15-20 minute hangs.

```bash
# Delete Kubernetes resources
kubectl delete -k deployment/aws/

# Wait for LoadBalancer deletion (critical!)
sleep 180

# Destroy infrastructure
cd infrastructure/aws
tofu destroy
```

### AWS vs k3d Differences

| Aspect | k3d | AWS EKS |
|--------|-----|---------|
| **Infrastructure** | Local Docker | Real cloud VMs |
| **Grafana Access** | NodePort 30000 | LoadBalancer (NLB) |
| **Log-Gen Placement** | Distributed | Co-located (single node) |
| **Setup Time** | ~5 minutes | ~20 minutes |
| **Cost** | Free | ~$2.50/hour |
| **Use Case** | Development, quick tests | Production-scale validation |

**Why co-locate log generators on AWS?** Tests thyme DaemonSet at maximum single-node capacity (100k logs/sec from one node), simulating realistic "hot node" scenarios.

### AWS Configuration

Infrastructure configuration: `infrastructure/aws/terraform.tfvars`

```hcl
cluster_name           = "thyme-benchmark-<timestamp>"
aws_region             = "eu-central-1"
kubernetes_version     = "1.34"
node_instance_type     = "m6i.2xlarge"
node_desired_capacity  = 3

# Cost optimization
enable_cluster_logging = false
enable_nat_gateway_ha  = false
```

**Customization options:**
- Instance types: `m6i.xlarge` (cheaper), `m6i.4xlarge` (more capacity)
- Node count: Scale up for higher throughput tests
- Spot instances: Set in `eks-node-group.tf` for 70% cost savings

### Troubleshooting AWS Deployments

**LoadBalancer stuck in `<pending>`:**
- Check subnet tags: `aws ec2 describe-subnets --filters "Name=tag:Name,Values=*thyme-benchmark*"`
- Verify subnets have `kubernetes.io/role/elb` tag
- Check events: `kubectl get events -n lgtm --sort-by='.lastTimestamp'`

**Pods not co-locating:**
- Verify: `kubectl get pods -n thyme-benchmark -l app=log-generator -o wide`
- All 100 log-gen pods should be on the same node
- If spread: increase instance type or reduce replicas

**tofu destroy hangs:**
- You deleted K8s resources first: ✓
- You waited 3+ minutes after deletion: ✓
- If still hanging: manually delete LoadBalancer in AWS console

### Cost Tracking

```bash
# Real-time cost estimate
aws ce get-cost-and-usage \
  --time-period Start=2026-02-04,End=2026-02-05 \
  --granularity HOURLY \
  --metrics UnblendedCost \
  --filter file://<(echo '{"Tags":{"Key":"Project","Values":["Thyme"]}}')
```

**Hourly breakdown:**
- EKS control plane: $0.10/hour
- 3× m6i.2xlarge: $1.152/hour
- EBS + NAT + NLB + transfer: ~$0.25/hour
- **Total: ~$2.50/hour**

### Further Reading

See detailed AWS documentation:
- **Deployment guide**: `deployment/aws/README.md` (400+ lines)
- **Infrastructure overview**: `infrastructure/aws/README.md`
- **Automated script**: `scripts/run-benchmark-aws.sh` (670+ lines)

## File Locations

- **Manifest**: `distributions/thyme/manifest.yaml` - Component definitions
- **Configs**: `distributions/thyme/config*.yaml` - Collector configurations
- **K8s Manifests**: `deployment/kubernetes/` - k3d Kubernetes resources
- **AWS Manifests**: `deployment/aws/` - EKS-specific overlays (LoadBalancer, affinity)
- **AWS Infrastructure**: `infrastructure/aws/` - OpenTofu/Terraform for EKS provisioning
- **Benchmark Script**: `scripts/run-benchmark-aws.sh` - Automated AWS benchmarking
- **Kustomization**: `deployment/kubernetes/kustomization.yaml` - Includes both thyme-benchmark and LGTM
- **Binary Output**: `distributions/thyme/build/thyme`
- **Generated Source**: `distributions/thyme/build/*.go` (gitignored)
- **Benchmark Reports**: `local/reports/YYYY-MM-DD-NN-aws/` - Generated after AWS runs

## Design Principles

1. **No production use** - Thyme is for benchmarking only; use Tulip for production
2. **Realistic simulation** - Two-stage architecture mimics real edge collection patterns
3. **Observable** - Both collectors export internal telemetry to LGTM for performance analysis
4. **Multi-environment** - Supports local development (k3d) and production-scale validation (AWS EKS)
5. **High throughput** - Configured for 50k-100k logs/sec with large batches (10k records)
6. **Automated** - Full benchmark lifecycle (provision → run → report → cleanup) via single script

## Performance Tuning Learnings

### Batch Processor Timeout is Critical

**Problem:** Default batch timeout of 10s caused massive throughput issues.

**Solution:** Use 200ms (the OTel default). At 50k+ logs/sec with batch size 10000, batches fill in ~200ms anyway. Long timeouts create unnecessary pipeline stalls.

```yaml
batch:
  send_batch_size: 10000
  timeout: 200ms  # NOT 10s
```

### k8sattributes Processor Adds Significant Overhead

**Problem:** k8sattributes processor queries Kubernetes API and maintains in-memory caches, adding CPU overhead even when metadata is already extracted from file paths.

**Solution:** For pure throughput benchmarks, remove k8sattributes if you're already extracting namespace/pod/container from file paths via filelog operators. Only use k8sattributes when you need owner references (deployment, statefulset names) or pod labels.

### Filelog poll_interval Affects Throughput

**Finding:** Reducing `poll_interval` from 200ms to 100ms improved throughput for high-volume scenarios. For 100k+ logs/sec, consider 50-100ms polling.

**Trade-off:** Lower intervals = higher CPU usage for file polling.

### Disk Pressure Kills Benchmarks

**Problem:** 100GB disks filled within 30 minutes at 100k logs/sec (~50MB/sec of log data). Kubernetes applies `disk-pressure` taint, evicting pods.

**Solutions:**
1. Use 500GB+ disks for extended benchmarks
2. Add toleration for `node.kubernetes.io/disk-pressure` on log generators
3. Clean up old log files between runs

### start_at: beginning Creates Backlog

**Problem:** With `start_at: beginning`, thyme reads ALL accumulated log files on startup, not just new data. This makes throughput measurements unreliable during catch-up.

**Solution:** For steady-state benchmarking:
- Use `start_at: end` to only read new logs
- Or wait for backlog processing to complete before measuring
- Watch for throughput to stabilize at expected input rate

### Many Small Pods Better Simulate Real Workloads

**Approach:** 100 pods × 1,000 lines/sec (co-located on one node via pod affinity) simulates a busy node with many workloads writing to `/var/log/pods/`. This stresses the filelog receiver's ability to watch many files simultaneously, which is more realistic than a few high-throughput pods.

**Constraint:** EKS max pods per node is ~110 (m6i.2xlarge with VPC CNI prefix delegation). With ~10 system pods, ~100 log-gen pods is the practical maximum per node.

### Pod Affinity + Node Taints = Scheduling Deadlock

**Problem:** Hardcoded `nodeSelector` for co-locating log generators failed when that node got a disk-pressure taint.

**Solution:** Use tolerations instead of (or in addition to) nodeSelector:
```yaml
tolerations:
  - key: node.kubernetes.io/disk-pressure
    operator: Exists
    effect: NoSchedule
```

### ECR Repository Cleanup

**Problem:** `tofu destroy` fails if ECR repository has images.

**Solution:** Force delete before destroy:
```bash
aws ecr delete-repository --repository-name thyme --force --region eu-central-1
```

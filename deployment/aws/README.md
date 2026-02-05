# Thyme AWS Deployment

AWS-specific Kubernetes deployment overlay for Thyme high-throughput log collection benchmarks on EKS.

## Overview

This directory contains Kustomize overlays that adapt the base Kubernetes deployment for AWS EKS:

1. **Grafana LoadBalancer**: Exposes Grafana via AWS Network Load Balancer
2. **Log-Generator Pod Affinity**: Co-locates all 20 log-gen pods on a single node

## Differences from Base Deployment

| Component | Base (k3d) | AWS Overlay |
|-----------|------------|-------------|
| Grafana Access | NodePort (30000) | LoadBalancer (NLB) |
| Log-Gen Placement | Distributed | Co-located on single node |
| Image Registry | Local or GHCR | GHCR (or ECR) |

## Prerequisites

1. **EKS cluster provisioned** via `infrastructure/aws/`
2. **kubectl configured** to access cluster:
   ```bash
   aws eks update-kubeconfig --region eu-central-1 --name thyme-benchmark
   ```
3. **Thyme image pushed** to GHCR or ECR:
   ```bash
   make docker-build
   make docker-push  # Requires GHCR authentication
   ```

## Deployment

### Deploy All Resources

```bash
# From repository root
kubectl apply -k deployment/aws/
```

This creates:
- **thyme-benchmark** namespace with thyme DaemonSet, nop-collector, log-generators
- **lgtm** namespace with Grafana LGTM stack
- LoadBalancer service for Grafana
- Pod affinity rules for log-generators

### Verify Deployment

```bash
# Check all pods running
kubectl get pods -n thyme-benchmark
kubectl get pods -n lgtm

# Verify log-generator pod co-location (all should be on same node)
kubectl get pods -n thyme-benchmark -l app=log-generator -o wide

# Check services
kubectl get svc -n lgtm grafana
```

Expected output for log-generator pods:
```
NAME                             READY   STATUS    NODE
log-generator-xxxxxxxxxx-xxxxx   1/1     Running   ip-10-0-11-123.eu-central-1.compute.internal
log-generator-xxxxxxxxxx-xxxxx   1/1     Running   ip-10-0-11-123.eu-central-1.compute.internal
log-generator-xxxxxxxxxx-xxxxx   1/1     Running   ip-10-0-11-123.eu-central-1.compute.internal
...
(All 20 pods on the SAME node)
```

### Access Grafana

```bash
# Get LoadBalancer URL
LB_URL=$(kubectl get svc grafana -n lgtm -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
echo "Grafana: http://$LB_URL:3000"

# Open in browser (takes ~2-3 minutes for DNS propagation)
# Login: admin / admin
```

**Note**: LoadBalancer provisioning takes 2-3 minutes. Check status with:
```bash
kubectl describe svc grafana -n lgtm
```

## Configuration

### Using ECR Instead of GHCR

If using AWS ECR (uncommented in `infrastructure/aws/ecr.tf`):

1. **Get ECR repository URL**:
   ```bash
   cd infrastructure/aws
   tofu output ecr_repository_url
   ```

2. **Update kustomization.yaml**:
   ```yaml
   images:
   - name: ghcr.io/ollygarden/thyme
     newName: YOUR_ACCOUNT_ID.dkr.ecr.eu-central-1.amazonaws.com/thyme
     newTag: latest
   ```

3. **Authenticate and push**:
   ```bash
   aws ecr get-login-password --region eu-central-1 | \
     docker login --username AWS --password-stdin \
     $(aws sts get-caller-identity --query Account --output text).dkr.ecr.eu-central-1.amazonaws.com

   make docker-build
   docker tag ghcr.io/ollygarden/thyme:latest YOUR_ACCOUNT_ID.dkr.ecr.eu-central-1.amazonaws.com/thyme:latest
   docker push YOUR_ACCOUNT_ID.dkr.ecr.eu-central-1.amazonaws.com/thyme:latest
   ```

### Restricting Grafana Access

To limit LoadBalancer access to specific IPs:

1. **Edit grafana-loadbalancer.yaml**:
   ```yaml
   spec:
     loadBalancerSourceRanges:
       - 1.2.3.4/32  # Your office IP
       - 5.6.7.8/32  # VPN IP
   ```

2. **Reapply**:
   ```bash
   kubectl apply -k deployment/aws/
   ```

## Pod Affinity Explained

### Why Co-locate Log Generators?

The log-generator pod affinity ensures all 20 log-gen pods run on a **single node**:

- **Reason**: Test thyme DaemonSet at maximum node capacity (50k logs/sec)
- **Strategy**: First pod schedules freely, subsequent pods must co-locate with it
- **Result**: One "hot" node with 20 log-gens + thyme DaemonSet pod

### Affinity Rule Breakdown

```yaml
podAffinity:
  requiredDuringSchedulingIgnoredDuringExecution:
    - labelSelector:
        matchExpressions:
          - key: app
            operator: In
            values:
              - log-generator
      topologyKey: kubernetes.io/hostname
```

- **requiredDuringScheduling**: Hard constraint, pod won't schedule if violated
- **IgnoredDuringExecution**: If node fails, pods can move elsewhere
- **topologyKey: kubernetes.io/hostname**: Pods must share same hostname (node)

### Verifying Co-location

```bash
# Should show all pods on same node
kubectl get pods -n thyme-benchmark -l app=log-generator -o custom-columns=NAME:.metadata.name,NODE:.spec.nodeName

# Count pods per node (should be 20 on one node, 0 on others)
kubectl get pods -n thyme-benchmark -l app=log-generator -o json | \
  jq -r '.items[].spec.nodeName' | sort | uniq -c
```

## Monitoring

### Prometheus Queries for Benchmarking

Access Grafana at LoadBalancer URL, then use Explore → Prometheus:

**Throughput (logs/sec)**:
```promql
rate(otelcol_receiver_accepted_log_records_total{service_name="nop-collector"}[1m])
```

**Export Failures**:
```promql
rate(otelcol_exporter_send_failed_log_records_total[1m])
```

**CPU Usage per Node**:
```promql
sum by (instance) (rate(otelcol_process_cpu_seconds_total[1m]))
```

**Memory Usage**:
```promql
otelcol_process_runtime_heap_alloc_bytes
```

### Log Analysis

**Thyme logs (DaemonSet)**:
```bash
kubectl logs -n thyme-benchmark -l app=thyme --tail=100
```

**Nop-collector logs**:
```bash
kubectl logs -n thyme-benchmark -l app=nop-collector --tail=100
```

**Log-generator logs** (verify 2,500 logs/sec per pod):
```bash
kubectl logs -n thyme-benchmark -l app=log-generator --tail=20
```

## Troubleshooting

### Pods Not Co-locating

**Symptom**: Log-gen pods spread across multiple nodes

**Diagnosis**:
```bash
kubectl get pods -n thyme-benchmark -l app=log-generator -o wide
```

**Cause**: Insufficient resources on single node for 20 pods

**Solution**:
1. Check node capacity: `kubectl describe nodes | grep -A5 "Allocated resources"`
2. Reduce log-gen replicas or resource requests
3. Use larger instance type (e.g., m6i.4xlarge)

### LoadBalancer Stuck in Pending

**Symptom**: `kubectl get svc grafana -n lgtm` shows `<pending>`

**Diagnosis**:
```bash
kubectl describe svc grafana -n lgtm
```

**Common causes**:
- Subnets missing `kubernetes.io/role/elb` tag (check `infrastructure/aws/vpc.tf`)
- Service quotas exceeded (check AWS Service Quotas)
- Security groups blocking traffic

**Solution**:
```bash
# Verify subnet tags
aws ec2 describe-subnets --filters "Name=tag:Name,Values=*thyme-benchmark*" \
  --query 'Subnets[*].[SubnetId,Tags[?Key==`kubernetes.io/role/elb`].Value]'

# Check events
kubectl get events -n lgtm --sort-by='.lastTimestamp'
```

### High Export Failure Rate

**Symptom**: `otelcol_exporter_send_failed_log_records_total` increasing

**Diagnosis**:
```bash
kubectl logs -n thyme-benchmark -l app=thyme | grep -i error
kubectl logs -n thyme-benchmark -l app=nop-collector | grep -i error
```

**Common causes**:
- Nop-collector overwhelmed (increase resources)
- Network issues between nodes
- gRPC message size limit (check `max_recv_msg_size_mib`)

### Node Running Out of Resources

**Symptom**: Pods stuck in Pending, node showing high utilization

**Diagnosis**:
```bash
kubectl describe node <node-with-log-gens>
kubectl top node
kubectl top pod -n thyme-benchmark
```

**Solution**:
- Reduce log-gen replicas: `kubectl scale deployment log-generator -n thyme-benchmark --replicas=15`
- Increase node size in `infrastructure/aws/variables.tf` and reapply

## Cleanup

### Automated Cleanup (Recommended)

The `run-benchmark-aws.sh` script handles cleanup automatically:

```bash
# Auto-cleanup enabled by default
./scripts/run-benchmark-aws.sh

# Disable auto-cleanup to keep infrastructure running
AUTO_CLEANUP=false ./scripts/run-benchmark-aws.sh
```

**What the automated cleanup does:**
1. Deletes all Kubernetes resources
2. Waits for LoadBalancer deletion (3 minutes)
3. Deletes ECR images (if ECR is used)
4. Destroys all infrastructure

Total cleanup time: ~10 minutes

### Manual Cleanup

If you need to manually clean up:

```bash
# Step 1: Delete Kubernetes resources
kubectl delete -k deployment/aws/

# Step 2: Wait for LoadBalancer deletion
sleep 180

# Step 3: Destroy infrastructure
cd infrastructure/aws
tofu destroy
```

**Important:** Always delete Kubernetes resources first and wait 3 minutes. This prevents `tofu destroy` from hanging for 15-20 minutes while AWS cleans up the LoadBalancer.

### Manual ECR Cleanup (If Using ECR)

The automated script handles this, but for manual cleanup:

```bash
aws ecr list-images --repository-name thyme --region eu-central-1 \
  --query 'imageIds[*]' --output json | \
  jq -r '.[] | @json' | \
  xargs -I {} aws ecr batch-delete-image \
  --repository-name thyme --region eu-central-1 --image-ids '{}'
```

### Cleanup Verification

```bash
# Verify all resources destroyed
cd infrastructure/aws && tofu show

# Check for orphaned resources
aws elbv2 describe-load-balancers --region eu-central-1 \
  --query 'LoadBalancers[?contains(Tags[?Key==`Project`].Value, `Thyme`)]'
```

## Automated Benchmarking

Use the automated script for complete benchmark workflow:

```bash
# From repository root
./scripts/run-benchmark-aws.sh [active_duration_minutes] [cluster_name]

# Examples:
./scripts/run-benchmark-aws.sh                    # 30-min active, auto-cleanup
./scripts/run-benchmark-aws.sh 60                 # 60-min active, auto-cleanup
AUTO_CLEANUP=false ./scripts/run-benchmark-aws.sh # Keep cluster after
```

The script handles:
- Infrastructure provisioning (15 min)
- Deployment (5 min)
- Ramp-up phase (5 min)
- Active benchmark (configurable, default 30 min)
- Cool-down phase (10 min)
- Metrics collection via LoadBalancer
- Report generation
- Infrastructure cleanup (optional, 10 min)

**Total runtime**: ~45 minutes for default 30-minute active benchmark

## Cost Tracking

Monitor costs during benchmarks:

```bash
# Real-time cost estimate
aws ce get-cost-and-usage \
  --time-period Start=2026-02-04,End=2026-02-05 \
  --granularity HOURLY \
  --metrics UnblendedCost \
  --filter file://<(echo '{"Tags":{"Key":"Project","Values":["Thyme"]}}')
```

Expected: ~$2.50/hour during benchmark

## References

- [Base Kubernetes Deployment](../kubernetes/README.md)
- [AWS Infrastructure Guide](../../infrastructure/aws/README.md)
- [Kustomize Documentation](https://kustomize.io/)
- [AWS EKS Best Practices](https://aws.github.io/aws-eks-best-practices/)

#!/bin/bash
set -e

# Run Thyme benchmark on AWS EKS and generate report
# Usage: ./scripts/run-benchmark-aws.sh [active_duration_minutes] [cluster_name]
#
# Benchmark phases:
# - Ramp-up: 5 minutes (system stabilization)
# - Active benchmark: 30 minutes (default, configurable)
# - Cool-down: 10 minutes (observe tail behavior)
# Total default runtime: 45 minutes

ACTIVE_DURATION_MINUTES=${1:-30}
RAMPUP_MINUTES=${RAMPUP_MINUTES:-5}
COOLDOWN_MINUTES=${COOLDOWN_MINUTES:-10}
TOTAL_DURATION=$((RAMPUP_MINUTES + ACTIVE_DURATION_MINUTES + COOLDOWN_MINUTES))
CLUSTER_NAME=${2:-thyme-benchmark-$(date +%s)}
AWS_REGION=${AWS_REGION:-eu-central-1}
AUTO_CLEANUP=${AUTO_CLEANUP:-true}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
INFRA_DIR="$PROJECT_ROOT/infrastructure/aws"

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_phase() {
    echo -e "${BLUE}[PHASE]${NC} $1"
}

# Generate report directory with sequential run number
generate_report_dir() {
    local date=$(date +%Y-%m-%d)
    local base_dir="$PROJECT_ROOT/local/reports"
    mkdir -p "$base_dir"

    # Find next run number for today
    local run_num=1
    while [[ -d "$base_dir/${date}-$(printf "%02d" $run_num)-aws" ]]; do
        run_num=$((run_num + 1))
    done

    local report_dir="$base_dir/${date}-$(printf "%02d" $run_num)-aws"
    mkdir -p "$report_dir"
    echo "$report_dir"
}

# Check prerequisites
check_prereqs() {
    log_info "Checking prerequisites..."

    if ! command -v tofu &> /dev/null && ! command -v terraform &> /dev/null; then
        log_error "OpenTofu or Terraform not found. Please install one of them."
        exit 1
    fi

    # Prefer tofu over terraform
    if command -v tofu &> /dev/null; then
        TF_CMD="tofu"
    else
        TF_CMD="terraform"
    fi

    if ! command -v aws &> /dev/null; then
        log_error "AWS CLI not found. Please install aws-cli."
        exit 1
    fi

    if ! command -v kubectl &> /dev/null; then
        log_error "kubectl not found. Please install kubectl."
        exit 1
    fi

    # Check AWS credentials
    if ! aws sts get-caller-identity &> /dev/null; then
        log_error "AWS credentials not configured. Run 'aws configure'."
        exit 1
    fi

    log_info "Using ${TF_CMD} for infrastructure provisioning"
}

# Provision infrastructure
provision_infrastructure() {
    log_info "Provisioning EKS infrastructure in ${AWS_REGION}..."
    cd "$INFRA_DIR"

    # Create terraform.tfvars if it doesn't exist, or read existing cluster name
    if [[ ! -f terraform.tfvars ]]; then
        log_info "Creating terraform.tfvars from example..."
        cp terraform.tfvars.example terraform.tfvars
        sed -i.bak "s/cluster_name.*/cluster_name = \"${CLUSTER_NAME}\"/" terraform.tfvars
        rm -f terraform.tfvars.bak
    else
        # Read existing cluster name from terraform.tfvars
        local existing_cluster=$(grep "cluster_name" terraform.tfvars | cut -d'"' -f2)
        if [[ -n "$existing_cluster" ]]; then
            CLUSTER_NAME="$existing_cluster"
            log_info "Using existing cluster name from terraform.tfvars: $CLUSTER_NAME"
        fi
    fi

    # Initialize
    log_info "Initializing ${TF_CMD}..."
    $TF_CMD init

    # Apply
    log_info "Creating EKS cluster (this takes ~15 minutes)..."
    $TF_CMD apply -auto-approve

    cd "$PROJECT_ROOT"
}

# Configure kubectl
configure_kubectl() {
    log_info "Configuring kubectl..."
    aws eks update-kubeconfig --region "$AWS_REGION" --name "$CLUSTER_NAME"

    # Wait for cluster to be fully ready
    log_info "Waiting for nodes to be ready..."
    kubectl wait --for=condition=ready node --all --timeout=300s

    log_info "Cluster nodes:"
    kubectl get nodes
}

# Build and push Docker image to ECR
build_and_push_image() {
    log_info "Building and pushing Docker image to ECR..."

    # Get AWS account ID
    local aws_account_id=$(aws sts get-caller-identity --query Account --output text)
    local ecr_repo="${aws_account_id}.dkr.ecr.${AWS_REGION}.amazonaws.com/thyme"

    # Authenticate with ECR
    log_info "Authenticating with ECR..."
    aws ecr get-login-password --region "$AWS_REGION" | \
        docker login --username AWS --password-stdin "${aws_account_id}.dkr.ecr.${AWS_REGION}.amazonaws.com"

    # Build image
    log_info "Building Docker image..."
    cd "$PROJECT_ROOT"
    make docker-build

    # Tag and push to ECR
    log_info "Pushing image to ECR: $ecr_repo"
    docker tag ghcr.io/ollygarden/thyme:latest "$ecr_repo:latest"
    docker push "$ecr_repo:latest"

    log_info "Image pushed to ECR successfully"
    cd "$PROJECT_ROOT"
}

# Deploy stack
deploy_stack() {
    log_info "Deploying Thyme and LGTM stack..."
    cd "$PROJECT_ROOT"

    kubectl apply -k deployment/aws/

    log_info "Waiting for LGTM to be ready..."
    kubectl wait --for=condition=ready pod -l app=lgtm -n lgtm --timeout=180s

    log_info "Waiting for nop-collector to be ready..."
    kubectl wait --for=condition=ready pod -l app=nop-collector -n thyme-benchmark --timeout=120s

    log_info "Waiting for thyme DaemonSet to be ready..."
    kubectl wait --for=condition=ready pod -l app=thyme -n thyme-benchmark --timeout=120s

    log_info "Waiting for log-generator pods to be ready..."
    kubectl wait --for=condition=ready pod -l app=log-generator -n thyme-benchmark --timeout=180s

    # Verify log-gen pod co-location
    log_info "Verifying log-generator pod co-location..."
    kubectl get pods -n thyme-benchmark -l app=log-generator -o wide

    # Verify all 40 pods are on same node
    local node_count=$(kubectl get pods -n thyme-benchmark -l app=log-generator -o wide | \
        awk 'NR>1 {print $7}' | sort -u | wc -l)
    if [[ "$node_count" -ne 1 ]]; then
        log_error "Expected all 40 log-gen pods on 1 node, but found $node_count nodes"
        log_error "Pod distribution:"
        kubectl get pods -n thyme-benchmark -l app=log-generator -o wide | \
            awk 'NR>1 {print $7}' | sort | uniq -c
        exit 1
    fi
    log_info "✓ All 40 log-generator pods co-located on single node"

    # Give LoadBalancer time to provision
    log_info "Waiting for Grafana LoadBalancer to be ready..."
    sleep 30

    local lb_url=$(kubectl get svc grafana -n lgtm -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "pending")
    if [[ "$lb_url" != "pending" ]]; then
        log_info "Grafana available at: http://${lb_url}:3000"
    else
        log_warn "LoadBalancer still provisioning (this can take 2-3 minutes)"
    fi
}

# Wait for ramp-up phase
wait_for_rampup() {
    local duration=$1
    local report_dir=$2

    log_phase "RAMP-UP PHASE (${duration} minutes) - System stabilization"

    local start_time=$(date +%s)
    local end_time=$((start_time + duration * 60))

    local health_log="$report_dir/health-rampup.log"
    echo "Phase,Timestamp,ThymePods,NopPods,LGTMPods,LogGenerators" > "$health_log"

    while [[ $(date +%s) -lt $end_time ]]; do
        local now=$(date +%s)
        local remaining=$((end_time - now))

        # Check pod health
        local thyme_ready=$(kubectl get pods -n thyme-benchmark -l app=thyme --no-headers 2>/dev/null | grep -c "Running" || echo "0")
        local nop_ready=$(kubectl get pods -n thyme-benchmark -l app=nop-collector --no-headers 2>/dev/null | grep -c "Running" || echo "0")
        local lgtm_ready=$(kubectl get pods -n lgtm -l app=lgtm --no-headers 2>/dev/null | grep -c "Running" || echo "0")
        local loggen_ready=$(kubectl get pods -n thyme-benchmark -l app=log-generator --no-headers 2>/dev/null | grep -c "Running" || echo "0")

        echo "RAMP-UP,$(date -Iseconds),$thyme_ready,$nop_ready,$lgtm_ready,$loggen_ready" >> "$health_log"

        log_info "[RAMP-UP] Remaining: $((remaining / 60))m | Pods: thyme=$thyme_ready nop=$nop_ready lgtm=$lgtm_ready loggen=$loggen_ready"

        sleep 30
    done

    log_info "Ramp-up phase completed!"
}

# Monitor active benchmark phase
monitor_active_benchmark() {
    local duration=$1
    local report_dir=$2

    log_phase "ACTIVE BENCHMARK PHASE (${duration} minutes) - Performance measurement"

    local start_time=$(date +%s)
    local end_time=$((start_time + duration * 60))

    local health_log="$report_dir/health-active.log"
    echo "Phase,Timestamp,ThymePods,NopPods,LGTMPods,LogGenerators" > "$health_log"

    while [[ $(date +%s) -lt $end_time ]]; do
        local now=$(date +%s)
        local elapsed=$((now - start_time))
        local remaining=$((end_time - now))

        # Check pod health
        local thyme_ready=$(kubectl get pods -n thyme-benchmark -l app=thyme --no-headers 2>/dev/null | grep -c "Running" || echo "0")
        local nop_ready=$(kubectl get pods -n thyme-benchmark -l app=nop-collector --no-headers 2>/dev/null | grep -c "Running" || echo "0")
        local lgtm_ready=$(kubectl get pods -n lgtm -l app=lgtm --no-headers 2>/dev/null | grep -c "Running" || echo "0")
        local loggen_ready=$(kubectl get pods -n thyme-benchmark -l app=log-generator --no-headers 2>/dev/null | grep -c "Running" || echo "0")

        echo "ACTIVE,$(date -Iseconds),$thyme_ready,$nop_ready,$lgtm_ready,$loggen_ready" >> "$health_log"

        log_info "[ACTIVE] Elapsed: ${elapsed}s / ${duration}m | Remaining: $((remaining / 60))m | Pods: thyme=$thyme_ready nop=$nop_ready lgtm=$lgtm_ready loggen=$loggen_ready"

        sleep 30
    done

    log_info "Active benchmark phase completed!"
}

# Monitor cool-down phase
monitor_cooldown() {
    local duration=$1
    local report_dir=$2

    log_phase "COOL-DOWN PHASE (${duration} minutes) - Observing tail behavior"

    local start_time=$(date +%s)
    local end_time=$((start_time + duration * 60))

    local health_log="$report_dir/health-cooldown.log"
    echo "Phase,Timestamp,ThymePods,NopPods,LGTMPods,LogGenerators" > "$health_log"

    while [[ $(date +%s) -lt $end_time ]]; do
        local now=$(date +%s)
        local remaining=$((end_time - now))

        # Check pod health
        local thyme_ready=$(kubectl get pods -n thyme-benchmark -l app=thyme --no-headers 2>/dev/null | grep -c "Running" || echo "0")
        local nop_ready=$(kubectl get pods -n thyme-benchmark -l app=nop-collector --no-headers 2>/dev/null | grep -c "Running" || echo "0")
        local lgtm_ready=$(kubectl get pods -n lgtm -l app=lgtm --no-headers 2>/dev/null | grep -c "Running" || echo "0")
        local loggen_ready=$(kubectl get pods -n thyme-benchmark -l app=log-generator --no-headers 2>/dev/null | grep -c "Running" || echo "0")

        echo "COOL-DOWN,$(date -Iseconds),$thyme_ready,$nop_ready,$lgtm_ready,$loggen_ready" >> "$health_log"

        log_info "[COOL-DOWN] Remaining: $((remaining / 60))m | Pods: thyme=$thyme_ready nop=$nop_ready lgtm=$lgtm_ready loggen=$loggen_ready"

        sleep 30
    done

    log_info "Cool-down phase completed!"
}

# Collect metrics from Prometheus via LoadBalancer
collect_metrics() {
    local report_dir=$1
    local active_duration=$2
    local benchmark_start=$3
    local benchmark_end=$4

    log_info "Collecting metrics from Prometheus..."

    # Get LoadBalancer URL
    local lb_url=$(kubectl get svc grafana -n lgtm -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")

    if [[ -z "$lb_url" ]]; then
        log_warn "LoadBalancer URL not available, using port-forward..."
        kubectl port-forward -n lgtm service/lgtm 9090:9090 >/dev/null 2>&1 &
        local pf_pid=$!
        sleep 5
        local prometheus_url="http://localhost:9090"
    else
        local prometheus_url="http://${lb_url}:9090"
    fi

    local metrics_file="$report_dir/metrics.json"
    local queries_file="$report_dir/queries.txt"

    # Define queries
    cat > "$queries_file" <<'EOF'
# Throughput metrics
rate(otelcol_receiver_accepted_log_records_total{service_name="nop-collector"}[5m])
rate(otelcol_exporter_sent_log_records_total{service_name="thyme"}[5m])

# Resource usage
rate(otelcol_process_cpu_seconds_total{service_name="thyme"}[5m])
otelcol_process_runtime_heap_alloc_bytes{service_name="thyme"}

# Pipeline health
rate(otelcol_exporter_send_failed_log_records_total{service_name="thyme"}[5m])
rate(otelcol_processor_refused_log_records_total{service_name="thyme"}[5m])
otelcol_processor_batch_batch_send_size_sum{service_name="thyme"} / otelcol_processor_batch_batch_send_size_count{service_name="thyme"}
EOF

    # Execute queries and save results
    echo "{" > "$metrics_file"
    local first=true

    while IFS= read -r query; do
        [[ "$query" =~ ^# ]] && continue  # Skip comments
        [[ -z "$query" ]] && continue     # Skip empty lines

        local safe_name=$(echo "$query" | sed 's/[^a-zA-Z0-9_]/_/g' | cut -c1-50)
        local encoded_query=$(echo "$query" | jq -sRr @uri)
        local result=$(curl -s "${prometheus_url}/api/v1/query?query=${encoded_query}" 2>/dev/null || echo '{"status":"error"}')

        if [[ "$first" == "true" ]]; then
            first=false
        else
            echo "," >> "$metrics_file"
        fi

        echo "  \"$safe_name\": $result" >> "$metrics_file"
    done < "$queries_file"

    echo "}" >> "$metrics_file"

    # Stop port-forward if used
    if [[ -n "${pf_pid:-}" ]]; then
        kill $pf_pid 2>/dev/null || true
    fi

    log_info "Metrics saved to: $metrics_file"
}

# Collect pod logs
collect_logs() {
    local report_dir=$1

    log_info "Collecting pod logs..."

    local logs_dir="$report_dir/logs"
    mkdir -p "$logs_dir"

    # Thyme logs
    kubectl logs -n thyme-benchmark daemonset/thyme --tail=500 > "$logs_dir/thyme.log" 2>&1 || true

    # Nop-collector logs
    kubectl logs -n thyme-benchmark deployment/nop-collector --tail=500 > "$logs_dir/nop-collector.log" 2>&1 || true

    # LGTM logs
    kubectl logs -n lgtm deployment/lgtm --tail=500 > "$logs_dir/lgtm.log" 2>&1 || true

    # Log generator sample
    kubectl logs -n thyme-benchmark -l app=log-generator --tail=100 | head -100 > "$logs_dir/log-generator-sample.log" 2>&1 || true

    # Pod placement
    kubectl get pods -n thyme-benchmark -o wide > "$logs_dir/pod-placement.txt" 2>&1 || true
}

# Generate report
generate_report() {
    local report_dir=$1
    local active_duration=$2
    local overall_start=$3
    local overall_end=$4
    local benchmark_start=$5
    local benchmark_end=$6

    log_info "Generating report..."

    local report_file="$report_dir/REPORT.md"
    local overall_duration=$(((overall_end - overall_start) / 60))
    local benchmark_duration=$(((benchmark_end - benchmark_start) / 60))

    # Get LoadBalancer URL
    local lb_url=$(kubectl get svc grafana -n lgtm -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "not-provisioned")

    cat > "$report_file" <<EOF
# Thyme AWS EKS Benchmark Report

**Date**: $(date -d @$overall_start '+%Y-%m-%d %H:%M:%S') to $(date -d @$overall_end '+%Y-%m-%d %H:%M:%S')
**Total Duration**: ${overall_duration} minutes (including ramp-up and cool-down)
**Active Benchmark**: ${active_duration} minutes
**Cluster**: $CLUSTER_NAME
**Region**: $AWS_REGION

## Test Phases

| Phase | Duration | Purpose |
|-------|----------|---------|
| Ramp-up | ${RAMPUP_MINUTES} minutes | System stabilization |
| Active Benchmark | ${active_duration} minutes | Performance measurement |
| Cool-down | ${COOLDOWN_MINUTES} minutes | Observe tail behavior |
| **Total** | **${TOTAL_DURATION} minutes** | - |

**Active Benchmark Period**: $(date -d @$benchmark_start '+%Y-%m-%d %H:%M:%S') to $(date -d @$benchmark_end '+%Y-%m-%d %H:%M:%S')

## Test Configuration

- **Log generators**: 40 pods × 2,500 lines/sec = 100,000 logs/sec
- **Pod co-location**: All log-gen pods on single node (hot node scenario - see pod-placement.txt)
- **Collector**: Thyme DaemonSet with k8sattributes processor
- **Pipeline**: filelog → thyme → nop-collector
- **Batch size**: 10,000 records
- **Infrastructure**: 3× m6i.2xlarge nodes (8 vCPU, 32GB RAM each)
- **Memory limits**: Thyme 16Gi (85% limiter = 13.9GB usable), Nop-Collector 4Gi

## Results Summary

### Expected Results (Active Phase)
- Total logs: ~$(echo "$active_duration * 60 * 100000" | bc) logs
- Throughput: ~100,000 logs/sec (all on single "hot" node)
- CPU (thyme on hot node): ~4 cores
- Memory (thyme on hot node): ~12-14 GB

### Actual Results

See \`metrics.json\` for detailed time-series data from Prometheus.

**Key metrics** (query during active phase timeframe):

\`\`\`promql
# Throughput (logs/sec)
rate(otelcol_receiver_accepted_log_records_total{service_name="nop-collector"}[5m])

# CPU usage (cores)
rate(otelcol_process_cpu_seconds_total{service_name="thyme"}[5m])

# Memory (MB)
otelcol_process_runtime_heap_alloc_bytes{service_name="thyme"} / 1024 / 1024

# Average batch size
otelcol_processor_batch_batch_send_size_sum{service_name="thyme"} / otelcol_processor_batch_batch_send_size_count{service_name="thyme"}
\`\`\`

## Files Generated

- \`REPORT.md\` - This report
- \`metrics.json\` - Prometheus query results
- \`queries.txt\` - PromQL queries used
- \`health-rampup.log\` - Pod health during ramp-up phase
- \`health-active.log\` - Pod health during active benchmark
- \`health-cooldown.log\` - Pod health during cool-down phase
- \`start_time.txt\` - Overall start timestamp
- \`benchmark_start.txt\` - Active benchmark start timestamp
- \`benchmark_end.txt\` - Active benchmark end timestamp
- \`end_time.txt\` - Overall end timestamp
- \`logs/\` - Pod logs from end of test
  - \`thyme.log\`
  - \`nop-collector.log\`
  - \`lgtm.log\`
  - \`log-generator-sample.log\`
  - \`pod-placement.txt\` - Pod to node mapping

## Infrastructure Details

### EKS Cluster
\`\`\`
Cluster Name: $CLUSTER_NAME
Region: $AWS_REGION
Kubernetes Version: $(kubectl version --short 2>/dev/null | grep Server || echo "unknown")
\`\`\`

### Nodes
\`\`\`
$(kubectl get nodes -o wide)
\`\`\`

### Pods (thyme-benchmark namespace)
\`\`\`
$(kubectl get pods -n thyme-benchmark -o wide)
\`\`\`

### Pods (lgtm namespace)
\`\`\`
$(kubectl get pods -n lgtm -o wide)
\`\`\`

## Access Grafana

**LoadBalancer URL**: http://${lb_url}:3000

Login: admin / admin

Navigate to **Explore** → **Prometheus** and use the queries from \`queries.txt\`.

## Cost Information

**Estimated cost for this benchmark**:
- Runtime: ~${overall_duration} minutes (~$(echo "scale=2; $overall_duration / 60" | bc) hours)
- Hourly rate: ~\$2.50/hour
- Total cost: ~\$$(echo "scale=2; $overall_duration / 60 * 2.5" | bc)

**Components**:
- EKS Control Plane: \$0.10/hour
- 3× m6i.2xlarge nodes: \$1.152/hour
- EBS, NAT, NLB, data transfer: ~\$0.25/hour

## Cleanup Status

Auto-cleanup: ${AUTO_CLEANUP}

EOF

    if [[ "$AUTO_CLEANUP" == "true" ]]; then
        cat >> "$report_file" <<EOF
Infrastructure has been automatically destroyed after benchmark completion.
EOF
    else
        cat >> "$report_file" <<EOF
Infrastructure is still running. To destroy manually:
\`\`\`bash
cd infrastructure/aws
tofu destroy
\`\`\`
EOF
    fi

    cat >> "$report_file" <<EOF

---

Generated by: \`scripts/run-benchmark-aws.sh\`
EOF

    log_info "Report generated: $report_file"
}

# Cleanup infrastructure
cleanup_infrastructure() {
    log_info "Starting cleanup process..."

    # Step 1: Delete Kubernetes resources (CRITICAL: must be done first!)
    log_info "Deleting Kubernetes resources..."
    kubectl delete -k "$PROJECT_ROOT/deployment/aws/" --wait=false 2>&1 || log_warn "Some resources may have already been deleted"

    # Step 2: Wait for LoadBalancer deletion (CRITICAL: prevents subnet deletion hang)
    log_info "Waiting for AWS to delete LoadBalancer (2-3 minutes)..."
    log_info "This prevents subnet deletion from hanging for 15-20 minutes..."

    # Monitor LoadBalancer deletion
    local wait_seconds=180
    local elapsed=0
    while [[ $elapsed -lt $wait_seconds ]]; do
        if ! kubectl get svc grafana -n lgtm &>/dev/null; then
            log_info "LoadBalancer service deleted successfully"
            break
        fi
        sleep 10
        elapsed=$((elapsed + 10))
        if [[ $((elapsed % 30)) -eq 0 ]]; then
            log_info "Still waiting for LoadBalancer deletion... (${elapsed}s elapsed)"
        fi
    done

    # Additional safety wait for AWS to clean up ENIs
    log_info "Waiting additional 30s for AWS to clean up network interfaces..."
    sleep 30

    # Step 3: Delete ECR images if ECR is being used
    log_info "Checking for ECR images to delete..."
    local ecr_repo="thyme"
    local image_count=$(aws ecr list-images --repository-name "$ecr_repo" --region "$AWS_REGION" --query 'length(imageIds)' --output text 2>/dev/null || echo "0")

    if [[ "$image_count" -gt 0 ]]; then
        log_info "Found $image_count images in ECR. Deleting..."
        aws ecr list-images --repository-name "$ecr_repo" --region "$AWS_REGION" \
            --query 'imageIds[*]' --output json 2>/dev/null | \
            jq -r '.[] | @json' | \
            xargs -I {} aws ecr batch-delete-image \
                --repository-name "$ecr_repo" --region "$AWS_REGION" --image-ids '{}' 2>&1 || true
        log_info "ECR images deleted"
    else
        log_info "No ECR images to delete (or ECR not configured)"
    fi

    # Step 4: Destroy infrastructure
    log_info "Destroying AWS infrastructure (this takes 5-10 minutes)..."
    cd "$INFRA_DIR"

    $TF_CMD destroy -auto-approve

    log_info "Infrastructure destroyed successfully"
    cd "$PROJECT_ROOT"
}

# Main execution
main() {
    local overall_start=$(date +%s)

    check_prereqs

    local report_dir=$(generate_report_dir)
    log_info "Report directory: $report_dir"
    log_info "Cluster: $CLUSTER_NAME"
    log_info "Benchmark phases: Ramp-up ${RAMPUP_MINUTES}m | Active ${ACTIVE_DURATION_MINUTES}m | Cool-down ${COOLDOWN_MINUTES}m | Total ${TOTAL_DURATION}m"
    log_info "Auto-cleanup: ${AUTO_CLEANUP}"

    # Provision infrastructure
    provision_infrastructure
    configure_kubectl

    # Build and push Docker image before deployment
    build_and_push_image

    deploy_stack

    # Record overall start time
    echo "$(date -Iseconds)" > "$report_dir/start_time.txt"

    # Phase 1: Ramp-up (skip if 0 minutes)
    if [[ "$RAMPUP_MINUTES" -gt 0 ]]; then
        wait_for_rampup "$RAMPUP_MINUTES" "$report_dir"
    else
        log_info "Skipping ramp-up phase (0 minutes)"
    fi

    # Phase 2: Active benchmark
    local benchmark_start=$(date +%s)
    echo "$(date -Iseconds)" > "$report_dir/benchmark_start.txt"
    monitor_active_benchmark "$ACTIVE_DURATION_MINUTES" "$report_dir"
    local benchmark_end=$(date +%s)
    echo "$(date -Iseconds)" > "$report_dir/benchmark_end.txt"

    # Phase 3: Cool-down (skip if 0 minutes)
    if [[ "$COOLDOWN_MINUTES" -gt 0 ]]; then
        monitor_cooldown "$COOLDOWN_MINUTES" "$report_dir"
    else
        log_info "Skipping cool-down phase (0 minutes)"
    fi

    # Record overall end time
    local overall_end=$(date +%s)
    echo "$(date -Iseconds)" > "$report_dir/end_time.txt"

    # Collect metrics and logs
    collect_metrics "$report_dir" "$ACTIVE_DURATION_MINUTES" "$benchmark_start" "$benchmark_end"
    collect_logs "$report_dir"
    generate_report "$report_dir" "$ACTIVE_DURATION_MINUTES" "$overall_start" "$overall_end" "$benchmark_start" "$benchmark_end"

    log_info "Benchmark complete!"
    log_info "Report location: $report_dir"

    # Auto-cleanup
    if [[ "${AUTO_CLEANUP}" == "true" ]]; then
        log_info "Auto-cleanup enabled. Destroying infrastructure..."
        cleanup_infrastructure
        log_info "Cleanup complete!"
    else
        log_warn "Auto-cleanup disabled. Cluster preserved."
        log_info "To cleanup manually: cd infrastructure/aws && tofu destroy"
    fi

    log_info ""
    log_info "Next steps:"
    log_info "  1. Review report: cat $report_dir/REPORT.md"
    log_info "  2. Analyze metrics: cat $report_dir/metrics.json | jq"
    if [[ "${AUTO_CLEANUP}" != "true" ]]; then
        log_info "  3. Access Grafana: kubectl port-forward -n lgtm service/grafana 3000:3000"
        log_info "  4. Cleanup: cd infrastructure/aws && tofu destroy"
    fi
}

main "$@"

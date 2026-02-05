#!/bin/bash
set -e

# Run Thyme benchmark and generate report
# Usage: ./scripts/run-benchmark.sh [duration_minutes]

DURATION_MINUTES=${1:-60}
CLUSTER_NAME="thyme-benchmark"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
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

# Generate report directory with sequential run number
generate_report_dir() {
    local date=$(date +%Y-%m-%d)
    local base_dir="$PROJECT_ROOT/local/reports"
    mkdir -p "$base_dir"

    # Find next run number for today
    local run_num=1
    while [[ -d "$base_dir/${date}-$(printf "%02d" $run_num)" ]]; do
        run_num=$((run_num + 1))
    done

    local report_dir="$base_dir/${date}-$(printf "%02d" $run_num)"
    mkdir -p "$report_dir"
    echo "$report_dir"
}

# Check prerequisites
check_prereqs() {
    log_info "Checking prerequisites..."

    if ! command -v k3d &> /dev/null; then
        log_error "k3d not found. Please install k3d."
        exit 1
    fi

    if ! command -v kubectl &> /dev/null; then
        log_error "kubectl not found. Please install kubectl."
        exit 1
    fi

    if ! command -v docker &> /dev/null; then
        log_error "docker not found. Please install docker."
        exit 1
    fi
}

# Setup k3d cluster
setup_cluster() {
    log_info "Setting up k3d cluster: $CLUSTER_NAME..."

    # Check if cluster exists
    if k3d cluster list | grep -q "^${CLUSTER_NAME}"; then
        log_warn "Cluster $CLUSTER_NAME already exists. Deleting..."
        k3d cluster delete "$CLUSTER_NAME"
    fi

    # Create cluster with 2 agents
    k3d cluster create "$CLUSTER_NAME" --agents 2

    # Wait for cluster to be ready
    kubectl wait --for=condition=ready node --all --timeout=120s
}

# Build and deploy
deploy_stack() {
    log_info "Building and loading Thyme image..."
    cd "$PROJECT_ROOT"
    make k3d-load K3D_CLUSTER="$CLUSTER_NAME"

    log_info "Deploying Thyme and LGTM stack..."
    kubectl apply -k deployment/kubernetes/

    log_info "Waiting for LGTM to be ready..."
    kubectl wait --for=condition=ready pod -l app=lgtm -n lgtm --timeout=180s

    log_info "Waiting for nop-collector to be ready..."
    kubectl wait --for=condition=ready pod -l app=nop-collector -n thyme-benchmark --timeout=120s

    log_info "Waiting for thyme DaemonSet to be ready..."
    kubectl wait --for=condition=ready pod -l app=thyme -n thyme-benchmark --timeout=120s

    # Give it a moment to stabilize
    sleep 10
}

# Monitor health during benchmark
monitor_health() {
    local duration=$1
    local report_dir=$2
    local start_time=$(date +%s)
    local end_time=$((start_time + duration * 60))

    log_info "Starting $duration minute benchmark (until $(date -d @$end_time '+%Y-%m-%d %H:%M:%S'))..."

    # Create health log
    local health_log="$report_dir/health.log"
    echo "Timestamp,ThymePods,NopPods,LGTMPods,LogGenerators" > "$health_log"

    while [[ $(date +%s) -lt $end_time ]]; do
        local now=$(date +%s)
        local elapsed=$((now - start_time))
        local remaining=$((end_time - now))

        # Check pod health
        local thyme_ready=$(kubectl get pods -n thyme-benchmark -l app=thyme --no-headers 2>/dev/null | grep -c "Running" || echo "0")
        local nop_ready=$(kubectl get pods -n thyme-benchmark -l app=nop-collector --no-headers 2>/dev/null | grep -c "Running" || echo "0")
        local lgtm_ready=$(kubectl get pods -n lgtm -l app=lgtm --no-headers 2>/dev/null | grep -c "Running" || echo "0")
        local loggen_ready=$(kubectl get pods -n thyme-benchmark -l app=log-generator --no-headers 2>/dev/null | grep -c "Running" || echo "0")

        # Log health
        echo "$(date -Iseconds),$thyme_ready,$nop_ready,$lgtm_ready,$loggen_ready" >> "$health_log"

        log_info "Elapsed: ${elapsed}s / ${duration}m | Remaining: $((remaining / 60))m | Pods: thyme=$thyme_ready nop=$nop_ready lgtm=$lgtm_ready loggen=$loggen_ready"

        sleep 30
    done

    log_info "Benchmark duration completed!"
}

# Collect metrics from Prometheus
collect_metrics() {
    local report_dir=$1
    local duration=$2

    log_info "Collecting metrics from Prometheus..."

    # Start port-forward in background
    kubectl port-forward -n lgtm service/lgtm 9090:9090 >/dev/null 2>&1 &
    local pf_pid=$!
    sleep 5

    # Query Prometheus for key metrics
    local metrics_file="$report_dir/metrics.json"
    local queries_file="$report_dir/queries.txt"

    # Define queries
    cat > "$queries_file" <<EOF
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
        local result=$(curl -s "http://localhost:9090/api/v1/query?query=$(echo "$query" | jq -sRr @uri)" 2>/dev/null || echo '{"status":"error"}')

        if [[ "$first" == "true" ]]; then
            first=false
        else
            echo "," >> "$metrics_file"
        fi

        echo "  \"$safe_name\": $result" >> "$metrics_file"
    done < "$queries_file"

    echo "}" >> "$metrics_file"

    # Stop port-forward
    kill $pf_pid 2>/dev/null || true

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
}

# Generate report
generate_report() {
    local report_dir=$1
    local duration=$2
    local start_time=$3
    local end_time=$4

    log_info "Generating report..."

    local report_file="$report_dir/REPORT.md"

    cat > "$report_file" <<EOF
# Thyme Benchmark Report

**Date**: $(date -d @$start_time '+%Y-%m-%d %H:%M:%S') to $(date -d @$end_time '+%Y-%m-%d %H:%M:%S')
**Duration**: ${duration} minutes
**Cluster**: $CLUSTER_NAME

## Test Configuration

- **Log generators**: 20 pods × 2,500 lines/sec = 50,000 logs/sec
- **Collector**: Thyme DaemonSet with k8sattributes processor
- **Pipeline**: filelog → thyme → nop-collector
- **Batch size**: 10,000 records

## Results Summary

### Expected Results
- Total logs: ~$(echo "$duration * 60 * 50000" | bc) logs
- Throughput: ~50,000 logs/sec
- CPU (thyme): ~1.5 cores
- Memory (thyme): < 1 GB

### Actual Results

See \`metrics.json\` for detailed time-series data.

Key metrics queries:
\`\`\`promql
# Throughput
rate(otelcol_receiver_accepted_log_records_total{service_name="nop-collector"}[5m])

# CPU usage
rate(otelcol_process_cpu_seconds_total{service_name="thyme"}[5m])

# Memory
otelcol_process_runtime_heap_alloc_bytes{service_name="thyme"} / 1024 / 1024
\`\`\`

## Files Generated

- \`REPORT.md\` - This report
- \`metrics.json\` - Prometheus query results
- \`queries.txt\` - PromQL queries used
- \`health.log\` - Pod health monitoring during test
- \`logs/\` - Pod logs from end of test
  - \`thyme.log\`
  - \`nop-collector.log\`
  - \`lgtm.log\`
  - \`log-generator-sample.log\`

## Cluster Information

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

## How to Access Grafana

\`\`\`bash
kubectl port-forward -n lgtm service/grafana 3000:3000
open http://localhost:3000  # admin/admin
\`\`\`

Navigate to **Explore** → **Prometheus** and use the queries from \`queries.txt\`.

## Cleanup

To remove the benchmark cluster:
\`\`\`bash
k3d cluster delete $CLUSTER_NAME
\`\`\`

---

Generated by: \`scripts/run-benchmark.sh\`
EOF

    log_info "Report generated: $report_file"
}

# Main execution
main() {
    local start_time=$(date +%s)

    check_prereqs

    local report_dir=$(generate_report_dir)
    log_info "Report directory: $report_dir"

    setup_cluster
    deploy_stack

    # Record start time
    echo "$(date -Iseconds)" > "$report_dir/start_time.txt"

    monitor_health "$DURATION_MINUTES" "$report_dir"

    # Record end time
    local end_time=$(date +%s)
    echo "$(date -Iseconds)" > "$report_dir/end_time.txt"

    collect_metrics "$report_dir" "$DURATION_MINUTES"
    collect_logs "$report_dir"
    generate_report "$report_dir" "$DURATION_MINUTES" "$start_time" "$end_time"

    log_info "Benchmark complete!"
    log_info "Report location: $report_dir"
    log_info ""
    log_info "Next steps:"
    log_info "  1. Review report: cat $report_dir/REPORT.md"
    log_info "  2. Analyze metrics: cat $report_dir/metrics.json | jq"
    log_info "  3. Access Grafana: kubectl port-forward -n lgtm service/grafana 3000:3000"
    log_info "  4. Cleanup: k3d cluster delete $CLUSTER_NAME"
}

main "$@"

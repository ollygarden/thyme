# Scripts

Automation scripts for Thyme benchmarking and testing.

## run-benchmark.sh

Automated benchmark execution script that sets up a k3d cluster, runs Thyme for a specified duration, and generates a comprehensive report.

### Usage

```bash
./scripts/run-benchmark.sh [duration_minutes]
```

**Parameters:**
- `duration_minutes` - How long to run the benchmark (default: 60)

**Example:**
```bash
# Run a 60-minute benchmark (default)
./scripts/run-benchmark.sh

# Run a 10-minute benchmark
./scripts/run-benchmark.sh 10

# Run a 5-minute quick test
./scripts/run-benchmark.sh 5
```

### What It Does

1. **Prerequisites Check**: Verifies k3d, kubectl, and docker are installed
2. **Cluster Setup**: Creates k3d cluster `thyme-benchmark` with 2 agent nodes
3. **Build & Deploy**: Builds Thyme image and deploys full stack
4. **Monitoring**: Monitors pod health every 30 seconds during the test
5. **Metrics Collection**: Queries Prometheus for key performance metrics
6. **Log Collection**: Gathers pod logs from all components
7. **Report Generation**: Creates comprehensive markdown report

### Output

Reports are saved to `./local/reports/YYYY-MM-DD-NN/` where:
- `YYYY-MM-DD` is the current date
- `NN` is a sequential run number (01, 02, 03...) for same-day runs

Each report directory contains:
- `REPORT.md` - Main report with summary and cluster info
- `metrics.json` - Prometheus query results
- `queries.txt` - PromQL queries used
- `health.log` - CSV log of pod health during test
- `logs/` - Pod logs directory
  - `thyme.log`
  - `nop-collector.log`
  - `lgtm.log`
  - `log-generator-sample.log`

### Prerequisites

- **k3d** - For local Kubernetes cluster
- **kubectl** - For Kubernetes operations
- **docker** - For container operations
- **jq** (optional) - For JSON processing of metrics
- **curl** - For Prometheus queries

### Cluster Cleanup

The script does NOT automatically delete the cluster. To clean up:

```bash
k3d cluster delete thyme-benchmark
```

This allows you to:
- Access Grafana after the test completes
- Manually inspect the cluster state
- Run additional queries or tests

### Troubleshooting

**Port conflicts**: If port-forward fails, check if ports 9090 or 3000 are already in use.

**Cluster already exists**: Script will automatically delete and recreate the cluster.

**Metrics collection fails**: Ensure Prometheus is accessible. Try manually:
```bash
kubectl port-forward -n lgtm service/lgtm 9090:9090
curl http://localhost:9090/api/v1/query?query=up
```

### Integration with Claude

This script is designed to be called by the `/benchmark` Claude skill:

```
User: "Run a benchmark"
Claude: [Executes ./scripts/run-benchmark.sh 60]
```

See `.claude/skills/benchmark.md` for skill documentation.

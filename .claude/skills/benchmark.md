# Benchmark Skill

Run a complete Thyme benchmarking test with automated report generation.

## Trigger

Use this skill when the user asks to:
- "Run a benchmark"
- "Run the benchmark"
- "Do a benchmark test"
- "Run performance tests"
- "Benchmark thyme"
- "Test thyme performance"

## What This Skill Does

1. **Setup**: Creates a k3d cluster named `thyme-benchmark` with 2 agent nodes
2. **Build & Deploy**: Builds Thyme image and deploys the full stack (thyme-benchmark + LGTM)
3. **Monitor**: Runs the benchmark while monitoring pod health every 30 seconds
4. **Collect**: Gathers metrics from Prometheus and pod logs
5. **Report**: Generates a comprehensive markdown report in `./local/reports/YYYY-MM-DD-NN/`

## Implementation

When this skill is invoked:

1. **Ask for duration** if not specified:
   ```
   How long should the benchmark run? (default: 60 minutes)
   ```

2. **Execute the benchmark script**:
   ```bash
   ./scripts/run-benchmark.sh [duration_minutes]
   ```

3. **Monitor progress**: The script will output progress every 30 seconds. Show this to the user.

4. **Report completion**: When done, inform the user:
   ```
   Benchmark complete! Report saved to: ./local/reports/YYYY-MM-DD-NN/

   Next steps:
   - Review report: cat ./local/reports/YYYY-MM-DD-NN/REPORT.md
   - Analyze metrics: cat ./local/reports/YYYY-MM-DD-NN/metrics.json | jq
   - Access Grafana: kubectl port-forward -n lgtm service/grafana 3000:3000
   - Cleanup cluster: k3d cluster delete thyme-benchmark
   ```

## Report Contents

The generated report directory contains:

- **REPORT.md** - Comprehensive markdown report with summary and cluster info
- **metrics.json** - Prometheus query results (time-series data)
- **queries.txt** - PromQL queries used for metrics collection
- **health.log** - CSV log of pod health checks during test
- **logs/** - Directory containing:
  - `thyme.log` - Thyme DaemonSet logs (last 500 lines)
  - `nop-collector.log` - Nop-collector logs (last 500 lines)
  - `lgtm.log` - LGTM stack logs (last 500 lines)
  - `log-generator-sample.log` - Sample log generator output

## Notes

- The script is idempotent - it will delete and recreate the cluster if it exists
- Progress is logged every 30 seconds with pod health status
- The cluster is NOT automatically deleted - user must clean up manually
- Report directory uses sequential numbering (01, 02, 03...) for same-day runs
- Default duration is 60 minutes if not specified

## Examples

**Example 1: Default 60-minute benchmark**
```
User: "Run a benchmark"
Assistant: "I'll run a 60-minute Thyme benchmark. This will take about an hour..."
[Executes ./scripts/run-benchmark.sh 60]
```

**Example 2: Custom duration**
```
User: "Run a 10-minute benchmark"
Assistant: "I'll run a 10-minute Thyme benchmark..."
[Executes ./scripts/run-benchmark.sh 10]
```

**Example 3: Quick test**
```
User: "Do a quick performance test"
Assistant: "I'll run a 5-minute benchmark for quick validation..."
[Executes ./scripts/run-benchmark.sh 5]
```
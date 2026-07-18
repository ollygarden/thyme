# Benchmark Skill

Run Thyme benchmarking tests with automated report generation.

## Trigger

Use this skill when the user asks to:
- "Run a benchmark"
- "Run the benchmark"
- "Do a benchmark test"
- "Run performance tests"
- "Benchmark thyme"
- "Test thyme performance"
- "Run AWS benchmark"
- "Benchmark on EKS"

## Environment Options

### Local (k3d) - Default
- **Cost**: No cloud infrastructure charge
- **Setup time**: ~5 minutes
- **Use case**: Development, quick validation
- **Infrastructure**: Local Docker with k3d cluster
- **Throughput**: 100k logs/sec (100 pods × 1,000 lines/sec)

### AWS (EKS)
- **Historical cost estimate**: ~$2.50/hour (~$3 for full 75-min run); verify current prices
- **Setup time**: ~20 minutes (infrastructure provisioning)
- **Use case**: Production-scale validation
- **Infrastructure**: 3× m6i.2xlarge nodes (8 vCPU, 32GB each)
- **Throughput**: 100k logs/sec (100 pods × 1,000 lines/sec on a single "hot" node)

## Implementation

### Step 1: Ask for Environment

If the user doesn't specify, ask:

```
Which environment should I run the benchmark on?

1. **Local (k3d)** - Free, ~5 min setup, good for development
2. **AWS (EKS)** - ~$2.50/hour, ~20 min setup, production-scale testing
```

### Step 2: Ask for Duration

**For Local (k3d)**:
```
How long should the benchmark run? (default: 60 minutes)
```

**For AWS (EKS)**:
```
How long should the ACTIVE benchmark phase run? (default: 30 minutes)

Note: Total time includes ramp-up (5 min) + active + cool-down (10 min)
So 30 min active = 45 min benchmark + ~20 min setup + ~10 min cleanup = ~75 min total
```

### Step 3: Confirm Authorization and Target

Do not run either script until the user explicitly approves the exact target
and expected side effects.

**For Local (k3d)**:
- State that the target cluster is `thyme-benchmark`.
- Warn that an existing cluster with that name will be deleted and replaced.
- Ask the user to approve that replacement before continuing.

**For AWS (EKS)**:
- Run `aws sts get-caller-identity` and report the exact AWS account and caller.
- Confirm the intended cluster name and region.
- Check the current infrastructure resources and current AWS prices; treat the
  estimates below as historical guidance, not a quote.
- State the expected benchmark duration and estimated cost for the approved
  resources.
- Confirm whether automatic cleanup will remain enabled.
- Ask the user to explicitly approve the account, cluster, cost, and cleanup
  plan before continuing.

If approval is absent or ambiguous, stop before executing the benchmark.

### Step 4: Execute

**For Local (k3d)**:
```bash
./scripts/run-benchmark.sh [duration_minutes]
```

**For AWS (EKS)**:
```bash
# Default: auto-cleanup enabled
./scripts/run-benchmark-aws.sh [active_duration_minutes]

# To keep infrastructure running after benchmark:
AUTO_CLEANUP=false ./scripts/run-benchmark-aws.sh [active_duration_minutes]
```

### Step 5: Monitor and Report

Both scripts output progress. When done, inform the user:

**For Local**:
```
Benchmark complete! Report saved to: ./local/reports/YYYY-MM-DD-NN/

Next steps:
- Review report: cat ./local/reports/YYYY-MM-DD-NN/REPORT.md
- Analyze metrics: cat ./local/reports/YYYY-MM-DD-NN/metrics.json | jq
- Access Grafana: kubectl port-forward -n lgtm service/grafana 3000:3000
- Cleanup cluster: k3d cluster delete thyme-benchmark
```

**For AWS**:
```
Benchmark complete! Report saved to: ./local/reports/YYYY-MM-DD-NN-aws/

Next steps:
- Review report: cat ./local/reports/YYYY-MM-DD-NN-aws/REPORT.md
- Analyze metrics: cat ./local/reports/YYYY-MM-DD-NN-aws/metrics.json | jq
```

If AUTO_CLEANUP=false was used:
```
Infrastructure is still running!
- Access Grafana: http://<LoadBalancer-URL>:3000
- Cleanup: cd infrastructure/aws && tofu destroy
```

After either benchmark, report the actual target and cleanup outcome. If
cleanup fails or AWS resources remain, say so prominently and provide the exact
remaining resources and cleanup command.

## AWS-Specific Details

### Prerequisites
- AWS CLI configured (`aws configure`)
- OpenTofu or Terraform installed
- Docker (for building/pushing to ECR)

### Benchmark Phases
1. **Ramp-up** (5 min): System stabilization
2. **Active** (configurable, default 30 min): Performance measurement
3. **Cool-down** (10 min): Observe tail behavior

### Environment Variables
- `AWS_REGION` - AWS region (default: eu-central-1)
- `AUTO_CLEANUP` - Destroy infrastructure after benchmark (default: true)
- `RAMPUP_MINUTES` - Ramp-up duration (default: 5)
- `COOLDOWN_MINUTES` - Cool-down duration (default: 10)

### Cost Breakdown
- EKS control plane: $0.10/hour
- 3× m6i.2xlarge nodes: $1.152/hour
- EBS, NAT, NLB, data transfer: ~$0.25/hour
- **Total: ~$2.50/hour**

## Report Contents

Both environments generate similar reports in `./local/reports/`:

- **REPORT.md** - Comprehensive markdown report
- **metrics.json** - Prometheus query results
- **queries.txt** - PromQL queries used
- **health*.log** - Pod health checks during test
- **logs/** - Pod logs from collectors and generators

## Examples

**Example 1: Quick local test**
```
User: "Run a quick benchmark"
Assistant: "This will delete and replace the local k3d cluster thyme-benchmark.
May I run a 10-minute benchmark against that target?"
User: "Yes."
[Executes ./scripts/run-benchmark.sh 10]
```

**Example 2: Production-scale AWS test**
```
User: "Run a benchmark on AWS"
Assistant: [Checks the AWS caller identity and current prices, then reports the
account, cluster, region, ~75-minute duration, estimated cost, and automatic
cleanup plan and asks for approval]
User: "I approve that target, cost, and cleanup plan."
[Executes ./scripts/run-benchmark-aws.sh 30]
```

**Example 3: AWS with custom duration, keep infrastructure**
```
User: "Run an hour-long AWS benchmark and keep the cluster running"
Assistant: [Checks the AWS caller identity and current prices, then reports the
account, cluster, region, duration, estimated cost, and that resources will
remain running and asks for approval]
User: "I approve that target, cost, and no-cleanup plan."
[Executes AUTO_CLEANUP=false ./scripts/run-benchmark-aws.sh 60]
```

**Example 4: User specifies local explicitly**
```
User: "Run a local benchmark for 30 minutes"
Assistant: "This will delete and replace the local k3d cluster thyme-benchmark.
May I proceed with that target?"
User: "Yes."
[Executes ./scripts/run-benchmark.sh 30]
```

## Notes

- Local k3d cluster is NOT automatically deleted after benchmark
- AWS infrastructure IS automatically deleted by default (AUTO_CLEANUP=true)
- Report directories use `-aws` suffix for AWS runs
- Sequential numbering (01, 02, 03...) prevents overwriting same-day runs
- The deployment manifests are the source of truth for generator topology:
  both current Kustomize overlays render 100 replicas at 1,000 lines/sec. The
  benchmark scripts' generated report templates still contain older 20/40 ×
  2,500 topology text; do not present that pre-existing report text as the
  executed topology.

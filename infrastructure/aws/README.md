# Thyme AWS EKS Infrastructure

OpenTofu/Terraform infrastructure-as-code for deploying an AWS EKS cluster optimized for Thyme high-throughput log collection benchmarks (50k logs/sec target).

## Architecture Overview

### Infrastructure Components

- **EKS Cluster**: Kubernetes 1.34 cluster in eu-central-1
- **Node Group**: 3× m6i.2xlarge instances (8 vCPU, 32GB RAM each)
- **VPC**: 10.0.0.0/16 with 3 public and 3 private subnets across availability zones
- **NAT Gateway**: Single NAT (cost optimized) or 3× NAT (high availability)
- **Security**: KMS encryption for secrets, security groups, IMDSv2 required

### Resource Capacity

- **Total Cluster**: ~22 vCPU, ~16GB RAM required
- **Node 1**: 20 log-generator pods + thyme DaemonSet (~12 CPU, ~4GB RAM)
- **Node 2-3**: nop-collector, LGTM, thyme DaemonSet (~5 CPU, ~6GB RAM each)

## Cost Estimate

| Component | Cost |
|-----------|------|
| EKS Control Plane | $0.10/hour |
| 3× m6i.2xlarge nodes | $1.152/hour |
| EBS volumes (3× 100GB gp3) | ~$0.10/hour |
| NAT Gateway (single AZ) | ~$0.045/hour |
| Network Load Balancer | ~$0.025/hour |
| Data transfer | ~$0.09/hour |
| **Total** | **~$2.50/hour (~$60/day)** |

### Cost Optimization Tips

1. **Use single NAT gateway** (default): Saves ~$0.09/hour vs. HA setup
2. **Disable control plane logging** (default): Saves ~$0.50/day per log type
3. **Destroy cluster after benchmarks**: Use `AUTO_CLEANUP=true` in run-benchmark-aws.sh
4. **Use GHCR over ECR**: No additional registry costs
5. **Schedule benchmarks**: Only run when needed, destroy immediately after

## Prerequisites

### Required Tools

```bash
# OpenTofu (Terraform alternative)
brew install opentofu  # macOS
# OR
sudo snap install opentofu --classic  # Linux

# AWS CLI
brew install awscli  # macOS
# OR
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip awscliv2.zip && sudo ./aws/install

# kubectl
brew install kubectl  # macOS
# OR
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
```

### AWS Credentials

Configure AWS credentials with permissions to create:
- EKS clusters
- EC2 instances, VPCs, subnets, security groups
- IAM roles and policies
- KMS keys
- EBS volumes

```bash
aws configure
# AWS Access Key ID [None]: YOUR_ACCESS_KEY
# AWS Secret Access Key [None]: YOUR_SECRET_KEY
# Default region name [None]: eu-central-1
# Default output format [None]: json
```

## Quick Start

### 1. Deploy Infrastructure

```bash
cd infrastructure/aws

# Initialize OpenTofu
tofu init

# Review planned changes
tofu plan

# Create infrastructure (takes ~15 minutes)
tofu apply

# Configure kubectl
aws eks update-kubeconfig --region eu-central-1 --name thyme-benchmark

# Verify cluster access
kubectl get nodes
```

### 2. Deploy Thyme Benchmark Stack

```bash
cd ../../  # Back to repository root

# Build and push image to GHCR (if not already done)
make docker-build
make docker-push  # Requires GHCR authentication

# Deploy all resources
kubectl apply -k deployment/aws/

# Wait for all pods to be ready
kubectl wait --for=condition=ready pod -l app=lgtm -n lgtm --timeout=120s
kubectl wait --for=condition=ready pod -l app=thyme -n thyme-benchmark --timeout=120s
```

### 3. Access Grafana

```bash
# Get LoadBalancer URL
LB_URL=$(kubectl get svc grafana -n lgtm -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
echo "Grafana: http://$LB_URL:3000"

# Login: admin / admin
```

### 4. Run Benchmark

```bash
# Automated benchmark with default 30-minute active phase
./scripts/run-benchmark-aws.sh

# Custom duration (60 minutes active phase)
./scripts/run-benchmark-aws.sh 60

# Custom cluster name
./scripts/run-benchmark-aws.sh 30 my-test-cluster

# Disable auto-cleanup (keep cluster after benchmark)
AUTO_CLEANUP=false ./scripts/run-benchmark-aws.sh
```

### 5. Cleanup

```bash
# Delete Kubernetes resources
kubectl delete -k deployment/aws/

# Destroy infrastructure
cd infrastructure/aws
tofu destroy  # Takes ~10 minutes
```

## Configuration

### Customizing Variables

Copy the example file and customize:

```bash
cd infrastructure/aws
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars with your preferences
```

Key variables:

```hcl
cluster_name           = "thyme-benchmark"
aws_region             = "eu-central-1"
node_instance_type     = "m6i.2xlarge"
node_desired_capacity  = 3
enable_cluster_logging = false  # Set true for debugging ($0.50/day per log type)
enable_nat_gateway_ha  = false  # Set true for HA ($0.09/hour additional)
```

### Remote State Backend (Optional)

For production use, configure S3 backend for state management:

```bash
# 1. Create S3 bucket and DynamoDB table
aws s3 mb s3://your-terraform-state-bucket --region eu-central-1
aws s3api put-bucket-versioning \
  --bucket your-terraform-state-bucket \
  --versioning-configuration Status=Enabled

aws dynamodb create-table \
  --table-name terraform-state-locks \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST \
  --region eu-central-1

# 2. Copy backend configuration
cp backend.tf.example backend.tf
# Edit backend.tf with your bucket name

# 3. Migrate state
tofu init -migrate-state
```

## Using ECR Instead of GHCR

To use AWS ECR instead of GitHub Container Registry:

1. **Uncomment ECR configuration** in `ecr.tf`
2. **Apply infrastructure**:
   ```bash
   tofu apply
   ```
3. **Authenticate Docker**:
   ```bash
   aws ecr get-login-password --region eu-central-1 | \
     docker login --username AWS --password-stdin \
     $(aws sts get-caller-identity --query Account --output text).dkr.ecr.eu-central-1.amazonaws.com
   ```
4. **Update image references** in `deployment/aws/kustomization.yaml`:
   ```yaml
   images:
   - name: ghcr.io/ollygarden/thyme
     newName: YOUR_ACCOUNT_ID.dkr.ecr.eu-central-1.amazonaws.com/thyme
     newTag: latest
   ```

## Architecture Details

### VPC Layout

```
10.0.0.0/16 (VPC)
├── Public Subnets (IGW → Internet)
│   ├── 10.0.1.0/24 (eu-central-1a)
│   ├── 10.0.2.0/24 (eu-central-1b)
│   └── 10.0.3.0/24 (eu-central-1c)
└── Private Subnets (NAT → IGW → Internet)
    ├── 10.0.11.0/24 (eu-central-1a) [EKS nodes]
    ├── 10.0.12.0/24 (eu-central-1b) [EKS nodes]
    └── 10.0.13.0/24 (eu-central-1c) [EKS nodes]
```

### Security Groups

- **Cluster Security Group**: Auto-created by EKS for cluster-to-node communication
- **Node Additional Security Group**: Node-to-node communication, optional SSH access
- **LoadBalancer Security Groups**: Auto-created for NLB

### IAM Roles

- **Cluster Role**: Manages EKS control plane
- **Node Role**: Grants nodes permissions for ECR, CloudWatch, EKS

## Troubleshooting

### Cluster Creation Fails

**Error**: "Error creating EKS Cluster: LimitExceededException"

**Solution**: Check AWS service quotas:
```bash
aws service-quotas get-service-quota \
  --service-code eks \
  --quota-code L-1194D53C  # Clusters per region
```

### Nodes Not Joining Cluster

**Check node status**:
```bash
kubectl get nodes
aws eks describe-nodegroup --cluster-name thyme-benchmark --nodegroup-name thyme-benchmark-nodes
```

**Common causes**:
- IAM role misconfiguration
- Security group blocking cluster communication
- Insufficient capacity in availability zones

### LoadBalancer Not Provisioning

**Check service**:
```bash
kubectl describe svc grafana -n lgtm
```

**Common causes**:
- Subnets missing `kubernetes.io/role/elb` tag
- AWS Load Balancer Controller not functioning (uses built-in in-tree controller)
- Security groups blocking health checks

### High Costs

**Check current spend**:
```bash
aws ce get-cost-and-usage \
  --time-period Start=2026-02-04,End=2026-02-05 \
  --granularity DAILY \
  --metrics UnblendedCost \
  --group-by Type=TAG,Key=Project
```

**Ensure cleanup**:
```bash
# Verify all resources destroyed
tofu show  # Should show no resources

# Check for orphaned resources
aws ec2 describe-instances --filters "Name=tag:Project,Values=Thyme" --query 'Reservations[*].Instances[*].[InstanceId,State.Name]'
aws elb describe-load-balancers --query 'LoadBalancerDescriptions[?contains(Tags[?Key==`Project`].Value, `Thyme`)]'
```

## Verification Checklist

After deployment, verify:

- [ ] `kubectl get nodes` shows 3 nodes in Ready state
- [ ] `kubectl get pods -A` shows all pods Running
- [ ] Grafana accessible via LoadBalancer URL
- [ ] Prometheus metrics available in Grafana
- [ ] Log-generator pods co-located on single node: `kubectl get pods -n thyme-benchmark -l app=log-generator -o wide`
- [ ] Thyme DaemonSet has 3 pods (one per node)

## Important Notes

### Cleanup Process

**The automated benchmark script handles cleanup properly**, but if you're manually destroying infrastructure:

1. **Always delete Kubernetes resources first**: `kubectl delete -k deployment/aws/`
2. **Wait 3 minutes** for LoadBalancer deletion before running `tofu destroy`
3. **If using ECR**: Images are auto-deleted by the cleanup script, but for manual cleanup see commands in deployment/aws/README.md

**Why this matters:** LoadBalancers created by Kubernetes hold network interfaces in subnets. If not deleted first, `tofu destroy` will wait 15-20 minutes for AWS to clean them up.

The `run-benchmark-aws.sh` script automates all of this for you.

### Benchmark Timeline

**Typical end-to-end benchmark:**

```
Infrastructure provisioning: ~15 minutes
Deployment: ~5 minutes
Benchmark phases: 25-75 minutes (5 min ramp + 10-60 min active + 10 min cool-down)
Cleanup: ~10 minutes (automated)

Total: 55-105 minutes for complete cycle
```

**Quick 10-minute test:** `RAMPUP_MINUTES=0 COOLDOWN_MINUTES=0 ./scripts/run-benchmark-aws.sh 10` (~35 min total)

## Security Considerations

1. **EKS-managed Security**: Node configuration managed by EKS with secure defaults
2. **Secrets Encryption**: KMS encryption enabled for Kubernetes secrets
3. **Private Nodes**: All EKS nodes in private subnets
4. **Security Groups**: Minimal ingress rules, explicit egress
5. **LoadBalancer Access**: Configure `grafana_allowed_cidrs` to restrict access

## Maintenance

### Updating Kubernetes Version

1. Update `kubernetes_version` in `variables.tf`
2. Update add-on versions in `eks.tf` (check compatibility)
3. Apply changes:
   ```bash
   tofu plan
   tofu apply  # EKS will perform rolling update
   ```

### Scaling Node Group

```bash
# Temporary scaling via kubectl
kubectl scale deployment log-generator -n thyme-benchmark --replicas=30

# Permanent scaling via Terraform
# Edit terraform.tfvars: node_desired_capacity = 4
tofu apply
```

## References

- [AWS EKS Best Practices](https://aws.github.io/aws-eks-best-practices/)
- [OpenTofu Documentation](https://opentofu.org/docs/)
- [EKS Pricing Calculator](https://calculator.aws/#/addService/EKS)
- [Thyme Deployment Guide](../../deployment/aws/README.md)

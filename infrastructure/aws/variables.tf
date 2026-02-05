variable "cluster_name" {
  description = "Name of the EKS cluster"
  type        = string
  default     = "thyme-benchmark"
}

variable "aws_region" {
  description = "AWS region to deploy resources"
  type        = string
  default     = "eu-central-1"
}

variable "vpc_cidr" {
  description = "CIDR block for VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "kubernetes_version" {
  description = "Kubernetes version for EKS cluster"
  type        = string
  default     = "1.34"
}

variable "node_instance_type" {
  description = "EC2 instance type for worker nodes"
  type        = string
  default     = "m6i.2xlarge"
}

variable "node_desired_capacity" {
  description = "Desired number of worker nodes"
  type        = number
  default     = 3
}

variable "node_min_size" {
  description = "Minimum number of worker nodes"
  type        = number
  default     = 3
}

variable "node_max_size" {
  description = "Maximum number of worker nodes"
  type        = number
  default     = 5
}

variable "node_disk_size" {
  description = "Disk size in GB for worker nodes"
  type        = number
  default     = 100
}

variable "common_tags" {
  description = "Common tags to apply to all resources"
  type        = map(string)
  default = {
    Project     = "Thyme"
    ManagedBy   = "OpenTofu"
    Environment = "Benchmark"
  }
}

variable "enable_cluster_logging" {
  description = "Enable EKS control plane logging (audit, api, authenticator)"
  type        = bool
  default     = false
}

variable "enable_nat_gateway_ha" {
  description = "Enable high availability NAT gateways (one per AZ, increases cost)"
  type        = bool
  default     = false
}

variable "allowed_ssh_cidr" {
  description = "CIDR blocks allowed to SSH to nodes (empty = no SSH access)"
  type        = list(string)
  default     = []
}

variable "grafana_allowed_cidrs" {
  description = "CIDR blocks allowed to access Grafana LoadBalancer (empty = allow all)"
  type        = list(string)
  default     = []
}

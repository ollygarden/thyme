# EKS Managed Node Group
#
# CRITICAL: This uses a SIMPLIFIED approach without custom launch templates.
# DO NOT add launch_template configuration here - it causes node join failures.
#
# Lessons learned from production testing (2026-02-04):
# - Custom launch templates with user_data caused MIME multipart format errors
# - Custom IMDSv2 settings prevented nodes from joining cluster (29+ min hang)
# - EKS-managed defaults provide adequate security and faster provisioning (1m17s)
#
# If you need custom configuration:
# - Use node_group labels (already configured below)
# - Use IAM roles (already configured in iam.tf)
# - Use security groups (already configured in security-groups.tf)
# - DO NOT use launch templates unless absolutely necessary
#
resource "aws_eks_node_group" "main" {
  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "${local.cluster_name}-nodes"
  node_role_arn   = aws_iam_role.node.arn
  subnet_ids      = aws_subnet.private[*].id

  scaling_config {
    desired_size = var.node_desired_capacity
    max_size     = var.node_max_size
    min_size     = var.node_min_size
  }

  update_config {
    max_unavailable_percentage = 33
  }

  # Disk configuration - EKS native support
  disk_size = var.node_disk_size

  instance_types = [var.node_instance_type]

  labels = {
    role = "worker"
  }

  tags = merge(
    var.common_tags,
    {
      Name = "${local.cluster_name}-node-group"
    }
  )

  depends_on = [
    aws_iam_role_policy_attachment.node_worker_policy,
    aws_iam_role_policy_attachment.node_cni_policy,
    aws_iam_role_policy_attachment.node_registry_policy,
    aws_iam_role_policy_attachment.node_cloudwatch_policy,
    aws_eks_addon.vpc_cni,
  ]

  lifecycle {
    create_before_destroy = true
    ignore_changes        = [scaling_config[0].desired_size]
  }
}

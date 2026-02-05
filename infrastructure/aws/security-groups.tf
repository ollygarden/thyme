# EKS Cluster Security Group
# Note: EKS automatically creates a security group for cluster-to-node communication
# This is an additional security group for node-to-node communication

resource "aws_security_group" "node_additional" {
  name_prefix = "${local.cluster_name}-node-additional-"
  description = "Additional security group for EKS nodes"
  vpc_id      = aws_vpc.main.id

  tags = merge(
    var.common_tags,
    {
      Name = "${local.cluster_name}-node-additional-sg"
    }
  )
}

# Allow nodes to communicate with each other
resource "aws_security_group_rule" "node_to_node" {
  description              = "Allow nodes to communicate with each other"
  type                     = "ingress"
  from_port                = 0
  to_port                  = 65535
  protocol                 = "-1"
  security_group_id        = aws_security_group.node_additional.id
  source_security_group_id = aws_security_group.node_additional.id
}

# Allow SSH access (if configured)
resource "aws_security_group_rule" "node_ssh" {
  count             = length(var.allowed_ssh_cidr) > 0 ? 1 : 0
  description       = "Allow SSH access from specific CIDRs"
  type              = "ingress"
  from_port         = 22
  to_port           = 22
  protocol          = "tcp"
  cidr_blocks       = var.allowed_ssh_cidr
  security_group_id = aws_security_group.node_additional.id
}

# Allow all outbound traffic
resource "aws_security_group_rule" "node_egress" {
  description       = "Allow all outbound traffic"
  type              = "egress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.node_additional.id
}

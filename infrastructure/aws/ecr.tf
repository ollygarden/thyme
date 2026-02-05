# ECR Repository
resource "aws_ecr_repository" "thyme" {
  name                 = "thyme"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }

  tags = merge(
    var.common_tags,
    {
      Name = "${local.cluster_name}-ecr"
    }
  )
}

# Lifecycle policy to retain last 10 images
resource "aws_ecr_lifecycle_policy" "thyme" {
  repository = aws_ecr_repository.thyme.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep last 10 images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 10
      }
      action = {
        type = "expire"
      }
    }]
  })
}

output "ecr_repository_url" {
  description = "ECR repository URL"
  value       = aws_ecr_repository.thyme.repository_url
}

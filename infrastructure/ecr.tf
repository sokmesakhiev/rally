# ── ECR Repository ────────────────────────────────────────────────────────────

resource "aws_ecr_repository" "app" {
  name                 = "${local.prefix}-api"
  image_tag_mutability = "MUTABLE" # allows :latest tag to be overwritten

  image_scanning_configuration {
    scan_on_push = true # free basic vulnerability scan on every push
  }

  tags = { Name = "${local.prefix}-api" }
}

# Keep the 10 most recent images; delete everything older.
# This prevents unbounded storage costs.
resource "aws_ecr_lifecycle_policy" "app" {
  repository = aws_ecr_repository.app.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep last 10 images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 10
      }
      action = { type = "expire" }
    }]
  })
}

# ── Active Storage uploads ─────────────────────────────────────────────────
#
# Its own bucket, never production's. Staging exercises the same code paths
# (`Certificates::SweepPreviews` deletes objects; `User#discard!` purges
# attachments), and a staging run pointed at the production bucket would be
# deleting customers' certificates.
resource "aws_s3_bucket" "uploads" {
  bucket = "${local.prefix}-uploads"
}

resource "aws_s3_bucket_public_access_block" "uploads" {
  bucket = aws_s3_bucket.uploads.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "uploads" {
  bucket = aws_s3_bucket.uploads.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Staging uploads are test data by definition. Nothing here is worth paying to
# keep, and without this the bucket grows forever — `SweepPreviews` only
# removes what it knows about.
resource "aws_s3_bucket_lifecycle_configuration" "uploads" {
  bucket = aws_s3_bucket.uploads.id

  rule {
    id     = "expire-staging-uploads"
    status = "Enabled"

    filter {}

    expiration {
      days = 30
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

# ── Container registry ─────────────────────────────────────────────────────
#
# **A separate repository from production's, and this one is not a
# preference.**
#
# Kamal pushes a `latest` tag alongside the versioned one on every deploy.
# Production's ECS task definitions point at `:latest` by design
# (`var.rails_image_tag`, see ../ecs.tf) and a production deploy is just
# "force ECS to re-pull it". Sharing one repository would therefore mean every
# staging deploy silently re-points production at a staging image, and the
# next production deploy — or any task replacement, or a scale-up — would roll
# it out. That is a production outage caused by merging to `staging`, with
# nothing in either pipeline looking wrong.
#
# Verify before trusting this comment: `kamal build push -d staging --verbose`
# prints the tags it pushes.
resource "aws_ecr_repository" "api" {
  name                 = "${local.prefix}-api"
  image_tag_mutability = "MUTABLE" # `latest` has to be movable

  image_scanning_configuration {
    scan_on_push = true
  }
}

# Kamal keeps the previous version on the box for `kamal rollback`, so the
# repository needs to hold more than the current image — but not the whole
# history of a branch that gets pushed many times a day.
resource "aws_ecr_lifecycle_policy" "api" {
  repository = aws_ecr_repository.api.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep the last 10 images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 10
      }
      action = { type = "expire" }
    }]
  })
}

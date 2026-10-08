# ── The staging box ────────────────────────────────────────────────────────

resource "aws_key_pair" "deploy" {
  key_name   = "${local.prefix}-deploy"
  public_key = var.ssh_public_key
}

resource "aws_security_group" "app" {
  name        = "${local.prefix}-app"
  description = "Staging app box: SSH for Kamal, HTTP/HTTPS for the proxy"
  vpc_id      = data.aws_vpc.default.id

  # Nothing opens Postgres. The database is a container on this instance
  # published to 127.0.0.1 only, so it is reachable from the app container
  # over Kamal's Docker network and from an SSH session, and from nowhere
  # else. A staging database is still full of real-shaped data.
  ingress {
    description = "SSH, for Kamal"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = var.ssh_allowed_cidrs
  }

  ingress {
    description = "HTTP — Let's Encrypt HTTP-01 validation and the redirect to HTTPS"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTPS"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${local.prefix}-app" }
}

# ── Instance profile ───────────────────────────────────────────────────────
#
# Production reaches S3 through the ECS *task* role and holds no access keys.
# An EC2 instance profile is the same mechanism — the AWS SDK finds both over
# IMDS — so staging keeps that property: there are no AWS credentials in
# Kamal's env, in GitHub secrets for the app, or on the box.
#
# ECR pull is here too, so `docker pull` on the box works without a long-lived
# registry password. Kamal still needs a registry login for the *push* from
# CI, which uses the deploy workflow's own OIDC/secret credentials.
resource "aws_iam_role" "app" {
  name = "${local.prefix}-app"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "app_uploads" {
  name = "${local.prefix}-uploads"
  role = aws_iam_role.app.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject",
          "s3:GetObjectAcl",
          "s3:PutObjectAcl",
        ]
        Resource = "${aws_s3_bucket.uploads.arn}/*"
      },
      {
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
        Resource = aws_s3_bucket.uploads.arn
      },
    ]
  })
}

resource "aws_iam_role_policy_attachment" "app_ecr" {
  role       = aws_iam_role.app.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

resource "aws_iam_instance_profile" "app" {
  name = "${local.prefix}-app"
  role = aws_iam_role.app.name
}

resource "aws_instance" "app" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.instance_type
  subnet_id              = data.aws_subnets.default.ids[0]
  vpc_security_group_ids = [aws_security_group.app.id]
  key_name               = aws_key_pair.deploy.key_name
  iam_instance_profile   = aws_iam_instance_profile.app.name

  root_block_device {
    volume_size = var.root_volume_gb
    volume_type = "gp3"
    encrypted   = true
  }

  # Kamal bootstraps Docker itself on first `kamal setup`, so this is not
  # strictly required — but two things here are worth doing before Kamal
  # arrives. The swap file is load-bearing on a 2 GiB box: a LibreOffice
  # conversion peaks near 180 MB, and with Postgres, two Rails containers and
  # the proxy resident, an unlucky overlap is an OOM kill rather than a slow
  # request. And a box that is already bootstrapped makes the first deploy a
  # deploy rather than a provisioning run.
  user_data = <<-BASH
    #!/bin/bash
    set -euo pipefail

    apt-get update -y
    apt-get install -y docker.io curl
    systemctl enable --now docker
    usermod -aG docker ubuntu

    if [ ! -f /swapfile ]; then
      fallocate -l 2G /swapfile
      chmod 600 /swapfile
      mkswap /swapfile
      swapon /swapfile
      echo '/swapfile none swap sw 0 0' >> /etc/fstab
    fi
  BASH

  # Changing user_data would otherwise replace the instance, taking the
  # Postgres volume with it. Edit the script and the box keeps running; to
  # actually apply a change, re-run it over SSH or taint the instance
  # deliberately, having decided what happens to the database.
  lifecycle {
    ignore_changes = [user_data, ami]
  }

  tags = { Name = "${local.prefix}-app" }
}

# A stable address, so the DNS record survives rebuilding the box — and so
# Let's Encrypt doesn't re-validate against a new IP on every replacement.
resource "aws_eip" "app" {
  domain   = "vpc"
  instance = aws_instance.app.id
  tags     = { Name = "${local.prefix}-app" }
}

resource "aws_route53_record" "api" {
  count = local.use_route53_for_api ? 1 : 0

  zone_id = var.route53_zone_id
  name    = var.api_domain
  type    = "A"
  ttl     = 300
  records = [aws_eip.app.public_ip]
}

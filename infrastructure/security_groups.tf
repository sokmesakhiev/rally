# ── ALB security group ────────────────────────────────────────────────────────
# Accepts HTTP/HTTPS from anywhere; forwards to ECS.

resource "aws_security_group" "alb" {
  name        = "${local.prefix}-alb-sg"
  description = "ALB: accept HTTP/HTTPS from internet"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "HTTP"
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
    description = "Allow all outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${local.prefix}-alb-sg" }
}

# ── ECS security group ────────────────────────────────────────────────────────
# Only the ALB can reach the Rails app port; ECS can reach the internet (for ECR, Secrets Manager).

resource "aws_security_group" "ecs" {
  name        = "${local.prefix}-ecs-sg"
  description = "ECS Fargate tasks: accept traffic from ALB only"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "Rails app port from ALB"
    from_port       = local.app_port
    to_port         = local.app_port
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  egress {
    description = "Allow all outbound (ECR pull, Secrets Manager, RDS, internet)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${local.prefix}-ecs-sg" }
}

# ── RDS security group ────────────────────────────────────────────────────────
# Only ECS tasks can reach PostgreSQL.

resource "aws_security_group" "rds" {
  name        = "${local.prefix}-rds-sg"
  description = "RDS: accept PostgreSQL connections from ECS only"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "PostgreSQL from ECS"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.ecs.id]
  }

  egress {
    description = "Allow all outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${local.prefix}-rds-sg" }
}

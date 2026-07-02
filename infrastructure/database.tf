# ── DB Subnet Group ───────────────────────────────────────────────────────────
# RDS must be placed in at least 2 AZs even if Multi-AZ is disabled.

resource "aws_db_subnet_group" "main" {
  name       = "${local.prefix}-db-subnet-group"
  subnet_ids = aws_subnet.private[*].id

  tags = { Name = "${local.prefix}-db-subnet-group" }
}

# ── RDS PostgreSQL Instance ───────────────────────────────────────────────────

resource "aws_db_instance" "main" {
  identifier = "${local.prefix}-postgres"

  # Engine
  engine         = "postgres"
  engine_version = "16.3"
  instance_class = var.db_instance_class

  # Credentials
  db_name  = var.db_name
  username = var.db_username
  password = random_password.db_password.result

  # Storage
  storage_type          = "gp3"
  allocated_storage     = var.db_allocated_storage
  max_allocated_storage = var.db_max_allocated_storage
  storage_encrypted     = true

  # Network — private, not publicly accessible
  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.rds.id]
  publicly_accessible    = false

  # Availability — set to true for production critical apps (doubles cost)
  multi_az = false

  # Backups — 7-day retention, automated daily backup
  backup_retention_period   = 7
  backup_window             = "03:00-04:00" # UTC
  maintenance_window        = "Mon:04:00-Mon:05:00" # UTC, after backup window
  delete_automated_backups  = false

  # Protect from accidental deletion
  deletion_protection = true
  skip_final_snapshot = false
  final_snapshot_identifier = "${local.prefix}-final-snapshot"

  # Performance Insights — free for db.t3/t4g classes
  performance_insights_enabled = true

  # Automatic minor version upgrades during the maintenance window
  auto_minor_version_upgrade = true

  tags = { Name = "${local.prefix}-postgres" }
}

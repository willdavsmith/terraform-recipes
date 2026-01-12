terraform {
  required_version = ">= 1.11.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

// -----RADIUS RECIPE CONTEXT----- //

variable "context" {
  description = "Radius-provided object containing information about the resource calling the Recipe."
  type        = any
}

// -----RADIUS ENVIRONMENT CONFIGURATION----- //

variable "vpc_id" {
  description = "The AWS VPC ID"
  type        = string
}

data "aws_subnets" "this" {
  filter {
    name   = "vpc-id"
    values = [var.vpc_id]
  }
}

data "aws_security_groups" "all_in_vpc" {
  filter {
    name   = "vpc-id"
    values = [var.vpc_id]
  }
}

// VARIABLES

resource "random_id" "resource" {
  byte_length = 4
}

locals {
  unique_name = "mycompany-pg-${random_id.resource.hex}"
  db_name = "postgres"
  db_username = "adminuser"
}


# --- Networking ---
resource "aws_db_subnet_group" "subnet_group" {
  name       = "${local.unique_name}-subnet-group"
  subnet_ids = data.aws_subnets.this.ids
  tags = {
    owner = "willsmith"
  }
}



// ===== RDS ===== //

resource "aws_db_instance" "db" {
  identifier             = local.unique_name
  engine                 = "postgres"
  instance_class         = "db.t4g.micro"
  allocated_storage      = 20
  db_name                = local.db_name
  db_subnet_group_name   = aws_db_subnet_group.subnet_group.name
  vpc_security_group_ids = data.aws_security_groups.all_in_vpc.ids
  tags = {
    owner = "willsmith"
  }

  username = local.db_username

  // Write-only password. Must update password_wo_version when password is updated.
  password_wo         = var.context.resource.properties.password
  password_wo_version = 1

  publicly_accessible = false
  skip_final_snapshot = true
  deletion_protection = false
}

// ===== SECRETS MANAGER ===== //

# ephemeral "random_password" "db_password" {
#   length           = 20
#   special          = true
#   override_special = "!#$%&*()-_=+[]{}<>:?"
# }

resource "aws_secretsmanager_secret" "db" {
  name = "${local.unique_name}-credentials"
  tags = {
    owner = "willsmith"
  }
}

resource "aws_secretsmanager_secret_version" "db" {
  secret_id = aws_secretsmanager_secret.db.id

  secret_string_wo = jsonencode({
    username = local.db_username
    password = var.context.resource.properties.password
  })

  secret_string_wo_version = 1
}

output "result" {
  value = {
    values = {
      database = aws_db_instance.db.db_name
      host     = aws_db_instance.db.address
      port     = aws_db_instance.db.port
      username = local.db_username
    }
  }
}

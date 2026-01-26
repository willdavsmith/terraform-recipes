terraform {
  required_version = ">= 1.11.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

// -----RADIUS RECIPE CONTEXT----- //

variable "context" {
  description = "Radius-provided object containing information about the resource calling the Recipe."
  type        = any
}

locals {
  secret_name = var.context.resource.name
  secret_data = {
    for k, v in var.context.resource.properties.data : k => v.value
  }
  tags = {
    "radius-resource-name" = var.context.resource.name
    "radius-resource-type" = var.context.resource.type
    "radius-application"   = var.context.application != null ? var.context.application.name : ""
    "radius-environment"   = try(var.context.resource.properties.environment, "")
  }
}

resource "aws_secretsmanager_secret" "secret" {
  name = local.secret_name
  tags = local.tags
}

resource "aws_secretsmanager_secret_version" "secret" {
  secret_id     = aws_secretsmanager_secret.secret.id
  secret_string = jsonencode(local.secret_data)
}

output "result" {
  value = {
    values = {
      secretName = aws_secretsmanager_secret.secret.name
      secretArn  = aws_secretsmanager_secret.secret.arn
    }
  }
}

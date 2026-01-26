terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = ">= 2.37.1"
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
  namespace   = var.context.runtime.kubernetes.namespace
  secret_kind = try(var.context.resource.properties.kind, "generic")
  secret_type = (
    local.secret_kind == "certificate-pem" ? "kubernetes.io/tls" :
    local.secret_kind == "basicAuthentication" ? "kubernetes.io/basic-auth" :
    "Opaque"
  )
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

resource "kubernetes_manifest" "external_secret" {
  manifest = {
    apiVersion = "external-secrets.io/v1beta1"
    kind       = "ExternalSecret"
    metadata = {
      name      = local.secret_name
      namespace = local.namespace
      labels = {
        resource = var.context.resource.name
        app      = var.context.application != null ? var.context.application.name : ""
      }
    }
    spec = {
      refreshInterval = "1h"
      secretStoreRef = {
        name = "aws-secretsmanager"
        kind = "ClusterSecretStore"
      }
      target = {
        name           = local.secret_name
        creationPolicy = "Owner"
        template = {
          type = local.secret_type
        }
      }
      dataFrom = [
        {
          extract = {
            key = aws_secretsmanager_secret.secret.name
          }
        }
      ]
    }
  }

  depends_on = [aws_secretsmanager_secret_version.secret]
}

output "result" {
  value = {
    values = {
      secretName          = aws_secretsmanager_secret.secret.name
      secretArn           = aws_secretsmanager_secret.secret.arn
      kubernetesSecretName = local.secret_name
    }
  }
}

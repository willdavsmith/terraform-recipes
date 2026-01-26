#!/usr/bin/env bash
set -euo pipefail

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

log() {
  echo "==> $*"
}

require_cmd rad

GROUP_NAME="${GROUP_NAME:-default}"
ENV_NAME="${ENV_NAME:-default}"
WORKSPACE_NAME="${WORKSPACE_NAME:-default}"
ENV_REGION="${ENV_REGION:-}"
ENV_ACCOUNT_ID="${ENV_ACCOUNT_ID:-}"

SECRETS_RECIPE_PATH="${SECRETS_RECIPE_PATH:-git::https://github.com/willdavsmith/terraform-recipes.git//resource-catalog/Radius/Security/secrets/recipes/kubernetes/terraform-eso}"

REGISTER_AWS_POSTGRES="${REGISTER_AWS_POSTGRES:-false}"
VPC_ID="${VPC_ID:-}"

log "Creating group and environment"
log "Installing Radius control plane (kubernetes)"
rad install kubernetes

rad group create "$GROUP_NAME"
rad env create "$ENV_NAME" -g "$GROUP_NAME"

if [[ -n "$ENV_REGION" || -n "$ENV_ACCOUNT_ID" ]]; then
  log "Updating environment cloud settings"
  ENV_UPDATE_ARGS=()
  [[ -n "$ENV_REGION" ]] && ENV_UPDATE_ARGS+=(--aws-region "$ENV_REGION")
  [[ -n "$ENV_ACCOUNT_ID" ]] && ENV_UPDATE_ARGS+=(--aws-account-id "$ENV_ACCOUNT_ID")
  rad env update "$ENV_NAME" -g "$GROUP_NAME" "${ENV_UPDATE_ARGS[@]}"
fi

log "Creating Kubernetes workspace"
rad workspace create kubernetes "$WORKSPACE_NAME" -g "$GROUP_NAME" -e "$ENV_NAME" --force

log "Registering resource types"
rad resource-type create containers -f resource-catalog/Radius/Compute/containers/containers.yaml
rad resource-type create postgreSqlDatabases -f resource-catalog/Radius/Data/postgreSqlDatabases/postgreSqlDatabases.yaml
rad resource-type create secrets -f resource-catalog/Radius/Security/secrets/secrets.yaml

log "Registering recipes"
rad recipe register default \
  --environment "$ENV_NAME" \
  --resource-type Radius.Compute/containers \
  --template-kind bicep \
  --template-path ghcr.io/willdavsmith/radius/recipes/kubernetes/containers:latest

rad recipe register default \
  --environment "$ENV_NAME" \
  --resource-type Radius.Data/postgreSqlDatabases \
  --template-kind bicep \
  --template-path ghcr.io/willdavsmith/radius/recipes/kubernetes/postgresql:latest

rad recipe register default \
  --environment "$ENV_NAME" \
  --resource-type Radius.Security/secrets \
  --template-kind terraform \
  --template-path "$SECRETS_RECIPE_PATH"

if [[ "$REGISTER_AWS_POSTGRES" == "true" ]]; then
  if [[ -z "$VPC_ID" ]]; then
    echo "REGISTER_AWS_POSTGRES=true requires VPC_ID to be set." >&2
    exit 1
  fi
  log "Registering AWS PostgreSQL recipe"
  rad recipe register default \
    --environment "$ENV_NAME" \
    --resource-type Radius.Data/postgreSqlDatabases \
    --template-kind terraform \
    --template-path resource-catalog/Radius/Data/postgreSqlDatabases/recipes/aws \
    --parameters vpc_id="$VPC_ID"
fi

log "Done"

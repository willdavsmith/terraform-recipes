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

require_cmd aws
require_cmd eksctl
require_cmd kubectl
require_cmd helm

CLUSTER_NAME="${CLUSTER_NAME:-ue-eks-cluster}"
REGION="${AWS_REGION:-us-west-2}"

ESO_NAMESPACE="${ESO_NAMESPACE:-external-secrets}"
ESO_SERVICE_ACCOUNT="${ESO_SERVICE_ACCOUNT:-external-secrets}"

APP_NAMESPACE="${APP_NAMESPACE:-default}"
AWS_SECRET_NAME="${AWS_SECRET_NAME:-credentials}"
K8S_SECRET_NAME="${K8S_SECRET_NAME:-$AWS_SECRET_NAME}"

POLICY_NAME="${POLICY_NAME:-${CLUSTER_NAME}-eso-secretsmanager}"
POLICY_ARN="${POLICY_ARN:-}"

DELETE_CLUSTER="${DELETE_CLUSTER:-true}"
DELETE_SECRET="${DELETE_SECRET:-false}"

log "Updating kubeconfig (if cluster exists)"
aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$REGION" >/dev/null 2>&1 || true

log "Deleting ExternalSecret (if present)"
kubectl -n "$APP_NAMESPACE" delete externalsecret "$K8S_SECRET_NAME" >/dev/null 2>&1 || true

log "Deleting ClusterSecretStore (if present)"
kubectl delete clustersecretstore aws-secretsmanager >/dev/null 2>&1 || true

log "Uninstalling External Secrets Operator (helm release external-secrets)"
helm -n "$ESO_NAMESPACE" uninstall external-secrets >/dev/null 2>&1 || true

log "Deleting ESO namespace (if present)"
kubectl delete namespace "$ESO_NAMESPACE" >/dev/null 2>&1 || true

log "Deleting IAM service account (if present)"
eksctl delete iamserviceaccount \
  --cluster "$CLUSTER_NAME" \
  --region "$REGION" \
  --namespace "$ESO_NAMESPACE" \
  --name "$ESO_SERVICE_ACCOUNT" >/dev/null 2>&1 || true

if [[ "$DELETE_SECRET" == "true" ]]; then
  log "Deleting Secrets Manager secret $AWS_SECRET_NAME"
  aws secretsmanager delete-secret --secret-id "$AWS_SECRET_NAME" --force-delete-without-recovery --region "$REGION" >/dev/null 2>&1 || true
else
  log "Skipping Secrets Manager secret deletion (set DELETE_SECRET=true to delete)"
fi

if [[ -z "$POLICY_ARN" ]]; then
  POLICY_ARN="$(aws iam list-policies --scope Local --query "Policies[?PolicyName=='$POLICY_NAME'].Arn | [0]" --output text 2>/dev/null || true)"
  if [[ "$POLICY_ARN" == "None" ]]; then
    POLICY_ARN=""
  fi
fi

if [[ -n "$POLICY_ARN" ]]; then
  log "Attempting to delete IAM policy $POLICY_ARN"
  ROLE_ARNS="$(aws iam list-entities-for-policy --policy-arn "$POLICY_ARN" --query 'PolicyRoles[].RoleName' --output text 2>/dev/null || true)"
  for role in $ROLE_ARNS; do
    [[ -z "$role" ]] && continue
    aws iam detach-role-policy --role-name "$role" --policy-arn "$POLICY_ARN" >/dev/null 2>&1 || true
  done
  VERSIONS="$(aws iam list-policy-versions --policy-arn "$POLICY_ARN" --query 'Versions[?IsDefaultVersion==`false`].VersionId' --output text 2>/dev/null || true)"
  for version in $VERSIONS; do
    [[ -z "$version" ]] && continue
    aws iam delete-policy-version --policy-arn "$POLICY_ARN" --version-id "$version" >/dev/null 2>&1 || true
  done
  aws iam delete-policy --policy-arn "$POLICY_ARN" >/dev/null 2>&1 || true
else
  log "No IAM policy ARN found; skipping policy deletion"
fi

if [[ "$DELETE_CLUSTER" == "true" ]]; then
  log "Deleting EKS cluster $CLUSTER_NAME"
  eksctl delete cluster --name "$CLUSTER_NAME" --region "$REGION"
else
  log "Skipping EKS cluster deletion (set DELETE_CLUSTER=true to delete)"
fi

log "Done"

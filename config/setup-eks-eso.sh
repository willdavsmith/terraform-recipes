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
require_cmd jq

CLUSTER_NAME="${CLUSTER_NAME:-willsmith-126262-ue-eks-cluster}"
REGION="${AWS_REGION:-us-west-2}"
NODEGROUP_NAME="${NODEGROUP_NAME:-ng-default}"
NODE_TYPE="${NODE_TYPE:-t3.medium}"
NODE_COUNT="${NODE_COUNT:-1}"
OWNER_TAG="${OWNER_TAG:-willsmith}"

ESO_NAMESPACE="${ESO_NAMESPACE:-external-secrets}"
ESO_SERVICE_ACCOUNT="${ESO_SERVICE_ACCOUNT:-external-secrets}"

APP_NAMESPACE="${APP_NAMESPACE:-default}"
AWS_SECRET_NAME="${AWS_SECRET_NAME:-credentials}"
K8S_SECRET_NAME="${K8S_SECRET_NAME:-$AWS_SECRET_NAME}"
DB_USERNAME="${DB_USERNAME:-admin}"
DB_PASSWORD="${DB_PASSWORD:-}"

if [[ -z "$DB_PASSWORD" ]]; then
  log "DB_PASSWORD not set; skipping Secrets Manager seed and ExternalSecret creation."
  SEED_SECRET="false"
else
  SEED_SECRET="true"
fi

if ! eksctl get cluster --name "$CLUSTER_NAME" --region "$REGION" >/dev/null 2>&1; then
  log "Creating EKS cluster $CLUSTER_NAME in $REGION"
  eksctl create cluster \
    --name "$CLUSTER_NAME" \
    --region "$REGION" \
    --nodegroup-name "$NODEGROUP_NAME" \
    --node-type "$NODE_TYPE" \
    --nodes "$NODE_COUNT" \
    --managed \
    --tags "owner=$OWNER_TAG"
else
  log "EKS cluster $CLUSTER_NAME already exists"
fi

log "Updating kubeconfig"
aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$REGION"

log "Ensuring namespaces exist"
kubectl create namespace "$ESO_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace "$APP_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

if [[ "$SEED_SECRET" == "true" ]]; then
  log "Creating or updating AWS Secrets Manager secret"
  SECRET_JSON="$(jq -nc --arg u "$DB_USERNAME" --arg p "$DB_PASSWORD" '{username:$u,password:$p}')"
  if ! aws secretsmanager describe-secret --secret-id "$AWS_SECRET_NAME" --region "$REGION" >/dev/null 2>&1; then
    aws secretsmanager create-secret \
      --name "$AWS_SECRET_NAME" \
      --secret-string "$SECRET_JSON" \
      --tags Key=radius-resource-type,Value=Radius.Security/secrets \
      --region "$REGION" >/dev/null
  else
    aws secretsmanager put-secret-value \
      --secret-id "$AWS_SECRET_NAME" \
      --secret-string "$SECRET_JSON" \
      --region "$REGION" >/dev/null
    aws secretsmanager tag-resource \
      --secret-id "$AWS_SECRET_NAME" \
      --tags Key=radius-resource-type,Value=Radius.Security/secrets \
      --region "$REGION" >/dev/null
  fi
fi

POLICY_NAME="${POLICY_NAME:-${CLUSTER_NAME}-eso-secretsmanager}"
POLICY_DOC="$(mktemp)"
cat >"$POLICY_DOC" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "secretsmanager:GetSecretValue",
        "secretsmanager:DescribeSecret"
      ],
      "Resource": "*",
      "Condition": {
        "StringEquals": {
          "secretsmanager:ResourceTag/radius-resource-type": "Radius.Security/secrets"
        }
      }
    }
  ]
}
EOF

if [[ -n "${POLICY_ARN:-}" ]]; then
  log "Using existing IAM policy ARN from POLICY_ARN"
else
  POLICY_ARN="$(aws iam list-policies --scope Local --query "Policies[?PolicyName=='$POLICY_NAME'].Arn | [0]" --output text)"
  if [[ -z "$POLICY_ARN" || "$POLICY_ARN" == "None" ]]; then
    if ! POLICY_ARN="$(aws iam create-policy --policy-name "$POLICY_NAME" --policy-document file://"$POLICY_DOC" --query Policy.Arn --output text)"; then
      rm -f "$POLICY_DOC"
      echo "Failed to create IAM policy. Ensure your IAM user can create policies or set POLICY_ARN to an existing policy." >&2
      exit 1
    fi
  else
    if ! aws iam create-policy-version --policy-arn "$POLICY_ARN" --policy-document file://"$POLICY_DOC" --set-as-default >/dev/null; then
      log "Warning: failed to update IAM policy. Continuing with existing policy. Ensure it allows Secrets Manager access."
    fi
  fi
fi
rm -f "$POLICY_DOC"

log "Associating OIDC provider"
eksctl utils associate-iam-oidc-provider --cluster "$CLUSTER_NAME" --region "$REGION" --approve

log "Creating IAM service account for External Secrets Operator"
eksctl create iamserviceaccount \
  --cluster "$CLUSTER_NAME" \
  --region "$REGION" \
  --namespace "$ESO_NAMESPACE" \
  --name "$ESO_SERVICE_ACCOUNT" \
  --attach-policy-arn "$POLICY_ARN" \
  --approve \
  --override-existing-serviceaccounts

log "Installing External Secrets Operator"
helm repo add external-secrets https://charts.external-secrets.io >/dev/null
helm repo update >/dev/null
helm upgrade --install external-secrets external-secrets/external-secrets \
  --namespace "$ESO_NAMESPACE" \
  --set installCRDs=true \
  --set serviceAccount.create=false \
  --set serviceAccount.name="$ESO_SERVICE_ACCOUNT" \
  --wait \
  --timeout 5m

wait_for_crd() {
  local crd_name="$1"
  local timeout_seconds="${2:-120}"
  local elapsed=0
  while [[ $elapsed -lt $timeout_seconds ]]; do
    if kubectl get crd "$crd_name" >/dev/null 2>&1; then
      kubectl wait --for=condition=Established --timeout=60s "crd/$crd_name" >/dev/null
      return 0
    fi
    sleep 2
    elapsed=$((elapsed + 2))
  done
  echo "CRD $crd_name not found after ${timeout_seconds}s. Check ESO installation." >&2
  return 1
}

log "Waiting for External Secrets CRDs"
wait_for_crd "clustersecretstores.external-secrets.io" 180
wait_for_crd "externalsecrets.external-secrets.io" 180
wait_for_crd "secretstores.external-secrets.io" 180

ESO_API_VERSION=""
SERVED_VERSIONS="$(kubectl get crd clustersecretstores.external-secrets.io -o json | jq -r '.spec.versions[] | select(.served==true) | .name')"
if echo "$SERVED_VERSIONS" | grep -Eq '^v1beta1$'; then
  ESO_API_VERSION="external-secrets.io/v1beta1"
elif echo "$SERVED_VERSIONS" | grep -Eq '^v1alpha1$'; then
  ESO_API_VERSION="external-secrets.io/v1alpha1"
elif [[ -n "$SERVED_VERSIONS" ]]; then
  ESO_API_VERSION="external-secrets.io/$(echo "$SERVED_VERSIONS" | head -n 1)"
else
  echo "No served versions found for clustersecretstores.external-secrets.io; check ESO installation." >&2
  exit 1
fi
log "Using External Secrets API version: $ESO_API_VERSION"

log "Creating ClusterSecretStore"
kubectl apply -f - <<EOF
apiVersion: $ESO_API_VERSION
kind: ClusterSecretStore
metadata:
  name: aws-secretsmanager
spec:
  provider:
    aws:
      service: SecretsManager
      region: $REGION
      auth:
        jwt:
          serviceAccountRef:
            name: $ESO_SERVICE_ACCOUNT
            namespace: $ESO_NAMESPACE
EOF

if [[ "$SEED_SECRET" == "true" ]]; then
  log "Creating ExternalSecret for seeded secret"
  kubectl apply -f - <<EOF
apiVersion: $ESO_API_VERSION
kind: ExternalSecret
metadata:
  name: $K8S_SECRET_NAME
  namespace: $APP_NAMESPACE
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: aws-secretsmanager
    kind: ClusterSecretStore
  target:
    name: $K8S_SECRET_NAME
    creationPolicy: Owner
  data:
    - secretKey: username
      remoteRef:
        key: $AWS_SECRET_NAME
        property: username
    - secretKey: password
      remoteRef:
        key: $AWS_SECRET_NAME
        property: password
EOF
  log "Done. Kubernetes Secret '$K8S_SECRET_NAME' will be synced into namespace '$APP_NAMESPACE'."
else
  log "Skipping ExternalSecret creation; secrets will be created by Radius.Security/secrets via ESO."
fi

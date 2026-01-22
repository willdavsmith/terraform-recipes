#!/usr/bin/env bash
set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-willsmith-ue-cluster-15261}"
AWS_REGION="${AWS_REGION:-us-west-2}"
K8S_VERSION="${K8S_VERSION:-1.32}"
NODEGROUP_NAME="${NODEGROUP_NAME:-ng-default}"
NODE_TYPE="${NODE_TYPE:-t3.medium}"
NODES="${NODES:-1}"
NAMESPACE="${NAMESPACE:-default}"
SERVICE_ACCOUNT="${SERVICE_ACCOUNT:-secrets-sync}"
ROLE_NAME="${ROLE_NAME:-secrets-sync-role}"

echo "Creating cluster ${CLUSTER_NAME} in ${AWS_REGION}..."
eksctl create cluster \
  --name "${CLUSTER_NAME}" \
  --region "${AWS_REGION}" \
  --version "${K8S_VERSION}" \
  --nodegroup-name "${NODEGROUP_NAME}" \
  --node-type "${NODE_TYPE}" \
  --nodes "${NODES}" \
  --managed \
  --tags \
    owner=willsmith

echo "Installing EKS Pod Identity Agent..."
eksctl create addon \
  --name eks-pod-identity-agent \
  --cluster "${CLUSTER_NAME}" \
  --region "${AWS_REGION}"

echo "Installing Secrets Store CSI Driver + AWS provider..."
helm repo add secrets-store-csi-driver https://kubernetes-sigs.github.io/secrets-store-csi-driver/charts
helm repo add aws-secrets-manager https://aws.github.io/secrets-store-csi-driver-provider-aws
helm repo update

helm upgrade --install csi-secrets-store secrets-store-csi-driver/secrets-store-csi-driver \
  --namespace kube-system \
  --set syncSecret.enabled=true

helm upgrade --install secrets-provider-aws aws-secrets-manager/secrets-store-csi-driver-provider-aws \
  --namespace kube-system

echo "Creating service account and pod identity association..."
kubectl create serviceaccount "${SERVICE_ACCOUNT}" -n "${NAMESPACE}" || true

eksctl create podidentityassociation \
  --cluster "${CLUSTER_NAME}" \
  --namespace "${NAMESPACE}" \
  --service-account-name "${SERVICE_ACCOUNT}" \
  --permission-policy-arns arn:aws:iam::aws:policy/SecretsManagerReadWrite

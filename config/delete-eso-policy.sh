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

CLUSTER_NAME="${CLUSTER_NAME:-}"
POLICY_NAME="${POLICY_NAME:-}"
POLICY_ARN="${POLICY_ARN:-}"

if [[ -z "$POLICY_ARN" ]]; then
  if [[ -z "$POLICY_NAME" ]]; then
    if [[ -n "$CLUSTER_NAME" ]]; then
      POLICY_NAME="${CLUSTER_NAME}-eso-secretsmanager"
    else
      echo "Set POLICY_ARN, POLICY_NAME, or CLUSTER_NAME." >&2
      exit 1
    fi
  fi

  POLICY_ARN="$(aws iam list-policies --scope Local --query "Policies[?PolicyName=='$POLICY_NAME'].Arn | [0]" --output text)"
  if [[ -z "$POLICY_ARN" || "$POLICY_ARN" == "None" ]]; then
    echo "Policy '$POLICY_NAME' not found." >&2
    exit 1
  fi
fi

log "Using policy ARN: $POLICY_ARN"

ROLE_ARNS="$(aws iam list-entities-for-policy --policy-arn "$POLICY_ARN" --query 'PolicyRoles[].RoleName' --output text)"
USER_ARNS="$(aws iam list-entities-for-policy --policy-arn "$POLICY_ARN" --query 'PolicyUsers[].UserName' --output text)"
GROUP_ARNS="$(aws iam list-entities-for-policy --policy-arn "$POLICY_ARN" --query 'PolicyGroups[].GroupName' --output text)"

for role in $ROLE_ARNS; do
  log "Detaching from role: $role"
  aws iam detach-role-policy --role-name "$role" --policy-arn "$POLICY_ARN"
done

for user in $USER_ARNS; do
  log "Detaching from user: $user"
  aws iam detach-user-policy --user-name "$user" --policy-arn "$POLICY_ARN"
done

for group in $GROUP_ARNS; do
  log "Detaching from group: $group"
  aws iam detach-group-policy --group-name "$group" --policy-arn "$POLICY_ARN"
done

VERSIONS="$(aws iam list-policy-versions --policy-arn "$POLICY_ARN" --query 'Versions[?IsDefaultVersion==`false`].VersionId' --output text)"
for version in $VERSIONS; do
  log "Deleting non-default policy version: $version"
  aws iam delete-policy-version --policy-arn "$POLICY_ARN" --version-id "$version"
done

log "Deleting policy"
aws iam delete-policy --policy-arn "$POLICY_ARN"
log "Done"

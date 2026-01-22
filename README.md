# User Empathy Demo

This repo demonstrates a Radius recipe-backed PostgreSQL database that exposes a Kubernetes Secret for app consumption. The goal is to keep developer experience simple and push auth/secret plumbing into the platform layer.

## App Developer Flow

- Deploy the app and database via Radius.
- Read the Kubernetes Secret using the outputs from `MyCompany.Databases/postgreSqlDatabases`.
- No IAM, CSI, or pod identity setup required by app teams.

Example Bicep usage: `apps/todolist/deploy/todolist.bicep`.

## Platform Engineer Setup

One-time (per cluster or per namespace):

1) Install the Secrets Store CSI driver + AWS provider with secret sync enabled.
2) Install the EKS Pod Identity Agent add-on.
3) Create a namespace ServiceAccount (e.g., `secrets-sync`) and associate it to an IAM role with `secretsmanager:GetSecretValue`.

Recipe wiring:

- `secret_sync_service_account` defaults to `default`, but should be set to your platform-managed SA.
- The recipe creates a `SecretProviderClass` and a short-lived Job that mounts the CSI volume to trigger sync.

## Secrets Ownership Model

Common production pattern is a shared, platform-managed Secrets Manager service per environment (dev/stage/prod), with app teams owning their individual secret entries. The platform defines IAM boundaries and standard access patterns; developers only create and rotate their app secrets within those boundaries.

## Radius Changes Needed

Update the `dynamic-rp` ClusterRole with these rules (cluster-scoped):

```yaml
- apiGroups:
  - apiextensions.k8s.io
  resources:
  - customresourcedefinitions
  verbs:
  - get
  - list
  - watch
- apiGroups:
  - secrets-store.csi.x-k8s.io
  resources:
  - secretproviderclasses
  verbs:
  - get
  - list
  - watch
  - create
  - update
  - patch
- apiGroups:
  - batch
  resources:
  - jobs
  verbs:
  - get
  - list
  - watch
  - create
  - update
  - patch
  - delete
```

## Useful Scripts

- Recipe registration: `.scripts/recipes-and-types.sh`

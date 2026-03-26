# Integration Points

How this chart integrates with surrounding infrastructure.

## ArgoCD Consumption (multi-source pattern)

The Helm chart will be pushed to Harbor as an OCI chart. ArgoCD applications in both homelab and AnkiMCP infra reference it:

```yaml
spec:
  sources:
    - repoURL: https://github.com/anatoly314/<infra-repo>.git
      targetRevision: HEAD
      ref: values
    - repoURL: harbor.anatoly.dev/helm-charts
      chart: discourse
      targetRevision: <version>
      helm:
        valueFiles:
          - $values/apps/<path>/values.yaml
```

## Secrets Management

- **Homelab:** VaultStaticSecret resources synced via Vault Secrets Operator
- **AnkiMCP infra:** ESO (External Secrets Operator) syncing from Vault

Secrets needed in Vault:
- `discourse/db-password`
- `discourse/secret-key-base` (generate: `openssl rand -hex 64`)
- `discourse/smtp-password`
- `discourse/oidc-client-secret` (Keycloak client secret)

## Jenkins Pipeline

Build the custom Docker image with plugins baked in, push to Harbor. Trigger on changes to `docker/` directory or manually for Discourse version upgrades.

## Target Environments

| Environment | Cluster | GitOps | PostgreSQL | Secrets |
|-------------|---------|--------|------------|---------|
| AnkiMCP (prod) | Managed K8s | ArgoCD | CNPG shared cluster | ESO + Vault |
| Homelab (test) | k3s | ArgoCD | CNPG | VSO + Vault |

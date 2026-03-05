#!/usr/bin/env bash
# Configure Vault after initialization:
#   - Enable KV-v2 secrets engine at applications/
#   - Enable and configure Kubernetes auth method
#   - Create External Secrets Operator policy and role
#   - Write local development secrets to applications/local/api
#
# Requires: kubectl, jq
# Usage: VAULT_NAMESPACE=vault ./bin/setup-cluster/steps/vault-configure.sh
# Run after bin/setup-cluster/steps/vault-init-unseal.sh (or manually after unsealing).
set -eu

# @formatter:off
fatal() {
  [ "${TERM:-}" != "dumb" ] \
    && tput colors >/dev/null 2>&1 \
    && printf "\033[31m[[FAT]] %s\033[0m\n" "${1}" \
    || printf "[[FAT]] %s\n" "${1}"
}
info() {
  [ "${TERM:-}" != "dumb" ] \
    && tput colors >/dev/null 2>&1 \
    && printf "\033[34m[[INF]] %s\033[0m\n" "${1}" \
    || printf "[[INF]] %s\n" "${1}"
}
# @formatter:on

VAULT_NAMESPACE="${VAULT_NAMESPACE:-vault}"

if ! command -v jq &>/dev/null; then
  fatal "jq is required. Install from https://stedolan.github.io/jq/"
  exit 1
fi

pod=$(kubectl get pods -n "${VAULT_NAMESPACE}" -l app.kubernetes.io/name=vault \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
pod="${pod:-vault-0}"

if ! kubectl get pod -n "${VAULT_NAMESPACE}" "${pod}" &>/dev/null; then
  fatal "Pod ${pod} not found in namespace ${VAULT_NAMESPACE}"
  exit 1
fi

# Require Vault to be unsealed before proceeding
if kubectl exec -n "${VAULT_NAMESPACE}" "${pod}" -- vault status -format=json 2>/dev/null \
    | grep -q '"sealed":true'; then
  fatal "Vault is sealed. Run bin/setup-cluster/steps/vault-init-unseal.sh first."
  exit 1
fi

# Read root token from init-keys.json written by vault-init-unseal.sh
ROOT_TOKEN=$(kubectl exec -n "${VAULT_NAMESPACE}" "${pod}" -- \
  cat /vault/data/init-keys.json | jq -r .root_token)

if [[ -z "${ROOT_TOKEN}" || "${ROOT_TOKEN}" == "null" ]]; then
  fatal "Could not read root token from /vault/data/init-keys.json in pod ${pod}"
  exit 1
fi

# Helper: run vault CLI inside the pod with the root token
vault_exec() {
  kubectl exec -n "${VAULT_NAMESPACE}" "${pod}" -- \
    env VAULT_TOKEN="${ROOT_TOKEN}" vault "$@"
}

# 1. Enable KV-v2 secrets engine at applications/ if not already enabled
info "Checking KV-v2 secrets engine..."
if ! vault_exec secrets list -format=json 2>/dev/null | grep -q '"applications/"'; then
  info "Enabling KV-v2 at applications/..."
  vault_exec secrets enable -path=applications kv-v2
else
  info "KV-v2 already enabled at applications/"
fi

# 2. Enable Kubernetes auth method if not already enabled
info "Checking Kubernetes auth method..."
if ! vault_exec auth list -format=json 2>/dev/null | grep -q '"kubernetes/"'; then
  info "Enabling Kubernetes auth method..."
  vault_exec auth enable kubernetes
else
  info "Kubernetes auth already enabled"
fi

# 3. Configure Kubernetes auth to use the in-cluster API server
info "Configuring Kubernetes auth..."
vault_exec write auth/kubernetes/config \
  kubernetes_host="https://kubernetes.default.svc"

# 4. Create policy for External Secrets Operator
info "Writing external-secrets policy..."
kubectl exec -n "${VAULT_NAMESPACE}" "${pod}" -- \
  env VAULT_TOKEN="${ROOT_TOKEN}" \
  sh -c 'vault policy write external-secrets - <<EOF
path "applications/data/local/*" {
  capabilities = ["read"]
}
path "applications/metadata/local/*" {
  capabilities = ["list", "read"]
}
EOF'

# 5. Create Kubernetes auth role for the ESO service account
info "Creating external-secrets role..."
vault_exec write auth/kubernetes/role/external-secrets \
  bound_service_account_names=external-secrets \
  bound_service_account_namespaces=external-secrets \
  policies=external-secrets \
  ttl=24h

info "Vault configuration complete."
info "Next: verify the ClusterSecretStore is ready:"
info "  kubectl get clustersecretstore vault-backend"

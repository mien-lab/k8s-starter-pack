#!/usr/bin/env bash
# Initialize and unseal Vault for local development.
# - Waits for vault-0 to be running and the Vault API to respond.
# - If not yet initialized: runs vault operator init, writes JSON output to
#   /vault/data/init-keys.json on the pod's PV, then unseals.
# - If already initialized but sealed: reads /vault/data/init-keys.json and unseals.
# - If already initialized and unsealed: no-op.
#
# Requires: kubectl, jq
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
VAULT_POD="vault-0"

if ! command -v jq &>/dev/null; then
  fatal "jq is required. Install from https://stedolan.github.io/jq/"
  exit 1
fi

# Wait for vault-0 pod to be created by ArgoCD/Helm
info "Waiting for ${VAULT_POD} pod..."
until kubectl get pod -n "${VAULT_NAMESPACE}" "${VAULT_POD}" &>/dev/null; do
  sleep 5
done

# Wait for the pod phase to be Running (containers started, even before ready)
info "Waiting for ${VAULT_POD} to be Running..."
until [[ "$(kubectl get pod -n "${VAULT_NAMESPACE}" "${VAULT_POD}" \
    -o jsonpath='{.status.phase}' 2>/dev/null)" == "Running" ]]; do
  sleep 5
done

# Wait for Vault API to respond (exit 0 = active, exit 2 = sealed but alive)
info "Waiting for Vault API..."
until kubectl exec -n "${VAULT_NAMESPACE}" "${VAULT_POD}" -- \
    vault status > /dev/null 2>&1 || [ $? -eq 2 ]; do
  sleep 3
done

vault_status() {
  kubectl exec -n "${VAULT_NAMESPACE}" "${VAULT_POD}" -- \
    vault status -format=json 2>/dev/null
}

is_initialized() { vault_status | grep -q '"initialized":true'; }
is_sealed()      { vault_status | grep -q '"sealed":true'; }

if is_initialized; then
  info "Vault is already initialized."
  if ! is_sealed; then
    info "Vault is already unsealed. Nothing to do."
    exit 0
  fi

  info "Vault is sealed. Reading unseal key from init-keys.json..."
  if ! kubectl exec -n "${VAULT_NAMESPACE}" "${VAULT_POD}" -- \
      sh -c '[ -s /vault/data/init-keys.json ]' 2>/dev/null; then
    fatal "init-keys.json is missing or empty."
    fatal "Cannot unseal. Delete the PVC (data-${VAULT_POD} in ns ${VAULT_NAMESPACE}) and rerun setup."
    exit 1
  fi

  UNSEAL_KEY=$(kubectl exec -n "${VAULT_NAMESPACE}" "${VAULT_POD}" -- \
    cat /vault/data/init-keys.json | jq -r '.unseal_keys_b64[0]')

  info "Unsealing Vault..."
  kubectl exec -n "${VAULT_NAMESPACE}" "${VAULT_POD}" -- \
    vault operator unseal "${UNSEAL_KEY}"
  info "Vault unsealed."
  exit 0
fi

# Vault is not initialized — initialize it
info "Initializing Vault..."
INIT_JSON=$(kubectl exec -n "${VAULT_NAMESPACE}" "${VAULT_POD}" -- \
  vault operator init -key-shares=1 -key-threshold=1 -format=json)

if [[ -z "${INIT_JSON}" ]]; then
  fatal "vault operator init returned no output"
  exit 1
fi

# Write init JSON to the pod's PV so vault-configure.sh can read the root token
echo "${INIT_JSON}" | kubectl exec -i -n "${VAULT_NAMESPACE}" "${VAULT_POD}" -- \
  sh -c "cat > /vault/data/init-keys.json"
info "Init keys written to /vault/data/init-keys.json on the pod PV."

UNSEAL_KEY=$(echo "${INIT_JSON}" | jq -r '.unseal_keys_b64[0]')
if [[ -z "${UNSEAL_KEY}" || "${UNSEAL_KEY}" == "null" ]]; then
  fatal "Could not parse unseal key from vault init output"
  exit 1
fi

info "Unsealing Vault..."
kubectl exec -n "${VAULT_NAMESPACE}" "${VAULT_POD}" -- \
  vault operator unseal "${UNSEAL_KEY}"

info "Vault initialized and unsealed."

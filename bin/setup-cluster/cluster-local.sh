#!/usr/bin/env bash
set -eu

# @formatter:off
fatal() {
  [ "${TERM:-}" != "dumb" ] \
    && tput colors >/dev/null 2>&1 \
    && printf "\033[31m[[FAT]] %s\033[0m\n" "${1}" \
    || printf "[[FAT]] %s\n" "${1}"
}
error() {
  [ "${TERM:-}" != "dumb" ] \
    && tput colors >/dev/null 2>&1 \
    && printf "\033[38;5;208m[[ERR]] %s\033[0m\n" "${1}" \
    || printf "[[ERR]] %s\n" "${1}"
}
warn() {
  [ "${TERM:-}" != "dumb" ] \
    && tput colors >/dev/null 2>&1 \
    && printf "\033[33m[[WRN]] %s\033[0m\n" "${1}" \
    || printf "[[WRN]] %s\n" "${1}"
}
info() {
  [ "${TERM:-}" != "dumb" ] \
    && tput colors >/dev/null 2>&1 \
    && printf "\033[34m[[INF]] %s\033[0m\n" "${1}" \
    || printf "[[INF]] %s\n" "${1}"
}
debug() {
  [ "${TERM:-}" != "dumb" ] \
    && tput colors >/dev/null 2>&1 \
    && printf "\033[37m[[DBG]] %s\033[0m\n" "${1}" \
    || printf "[[DBG]] %s\n" "${1}"
}
# @formatter:on

readonly DEFAULT_CLUSTER_NAME="mien-lab-starter-pack"
readonly ARGOCD_LOCAL_PORT="8089"

usage() {
  echo "Usage: $0 [--cluster-name NAME]"
  echo "  -c, --cluster-name  k3d cluster name (default: $DEFAULT_CLUSTER_NAME)"
  echo "  -h, --help          Show this help"
  exit 0
}

parse_args() {
  local cluster_name="$DEFAULT_CLUSTER_NAME"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -c|--cluster-name) cluster_name="${2:?Missing value for $1}"; shift 2 ;;
      -h|--help) usage ;;
      *) fatal "Unknown option: $1"; exit 1 ;;
    esac
  done
  echo "$cluster_name"
}

main() {
  local script_dir cluster_name k3d_context
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  cluster_name="$(parse_args "$@")"
  k3d_context="k3d-$cluster_name"

  if ! command -v k3d &>/dev/null; then
    fatal "k3d is not installed. Install from https://k3d.io/"
    exit 1
  fi

  if k3d cluster list 2>/dev/null | grep -q "^${cluster_name} "; then
    info "Cluster $cluster_name already exists."
  else
    info "Creating k3d cluster $cluster_name"
    k3d cluster create "$cluster_name" \
      --servers 1 \
      --agents 2 \
      --k3s-arg "--disable=traefik@server:0"
  fi

  k3d kubeconfig merge "$cluster_name" --kubeconfig-switch-context

  "$script_dir/cluster-any.sh" --cluster-name "$k3d_context" --env local
  "$script_dir/steps/argocd-repo-secret.sh"

  # Bootstrap: apply root app-of-apps so ArgoCD starts syncing all child Applications
  repo_root="$(cd "$script_dir/../.." && pwd)"
  kubectl apply -f "$repo_root/environments/bootstrap/local.yaml"

  "$script_dir/steps/vault-init-unseal.sh"
  "$script_dir/steps/vault-configure.sh"
}

main "$@"

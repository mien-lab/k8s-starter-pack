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

readonly ARGOCD_NAMESPACE="argocd"
readonly VALUES_PATH="charts/argocd/values-local.yaml"

usage() {
  echo "Usage: $0 [--ssh-key PATH]"
  echo "  Patches each argocd-repo-<key> Secret (from Helm configs.repositories in"
  echo "  $VALUES_PATH) to set data.sshPrivateKey. Secrets must already exist."
  echo "  -s, --ssh-key   Path to SSH private key (default: ~/.ssh/id_ed25519 or id_rsa)"
  echo "  -h, --help      Show this help"
  exit 0
}

parse_args() {
  local ssh_key_path=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -s|--ssh-key) ssh_key_path="${2:?Missing value for $1}"; shift 2 ;;
      -h|--help) usage ;;
      *) fatal "Unknown option: $1"; exit 1 ;;
    esac
  done
  echo "$ssh_key_path"
}

main() {
  local script_dir repo_root values_file ssh_key_path
  local ssh_key_b64 repo_keys key secret_name
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  repo_root="$(cd "$script_dir/../../.." && pwd)"
  values_file="$repo_root/$VALUES_PATH"

  if ! command -v yq &>/dev/null; then
    fatal "yq is required. Install from https://github.com/mikefarah/yq"
    exit 1
  fi

  if [[ ! -f "$values_file" ]]; then
    fatal "Values file not found: $values_file"
    exit 1
  fi

  ssh_key_path="$(parse_args "$@")"
  if [[ -z "$ssh_key_path" ]]; then
    for candidate in ~/.ssh/id_ed25519 ~/.ssh/id_rsa; do
      if [[ -f "$candidate" ]] && [[ -r "$candidate" ]]; then
        ssh_key_path="$candidate"
        break
      fi
    done
  fi
  if [[ -z "$ssh_key_path" ]]; then
    fatal "No readable SSH key found (~/.ssh/id_ed25519 or ~/.ssh/id_rsa)."
    exit 1
  fi
  if [[ ! -f "$ssh_key_path" ]] || [[ ! -r "$ssh_key_path" ]]; then
    fatal "SSH key not readable: $ssh_key_path"
    exit 1
  fi

  repo_keys=$(yq eval '.argo-cd.configs.repositories | to_entries[] | .key' "$values_file" 2>/dev/null || true)
  if [[ -z "$repo_keys" ]]; then
    warn "No repositories found in $VALUES_PATH under argo-cd.configs.repositories"
    exit 0
  fi

  ssh_key_b64=$(base64 -w 0 < "$ssh_key_path" 2>/dev/null || base64 < "$ssh_key_path" | tr -d '\n')

  while IFS= read -r key; do
    [[ -z "$key" ]] && continue
    secret_name="argocd-repo-$key"
    info "Patching secret $secret_name (data.sshPrivateKey)"
    kubectl patch secret "$secret_name" -n "$ARGOCD_NAMESPACE" --type=merge \
      -p "{\"data\":{\"sshPrivateKey\":\"$ssh_key_b64\"}}"
  done <<< "$repo_keys"

  info "Repository secrets patched from $ssh_key_path."

  info "Rolling restarts in namespace $ARGOCD_NAMESPACE (deployments, statefulsets, daemonsets)"
  for kind in deployment statefulset daemonset; do
    if kubectl get "$kind" -n "$ARGOCD_NAMESPACE" --no-headers 2>/dev/null | grep -q .; then
      kubectl rollout restart "$kind" -n "$ARGOCD_NAMESPACE"
    fi
  done
}

main "$@"

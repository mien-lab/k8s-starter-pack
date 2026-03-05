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

readonly NAMESPACE="argocd"

usage() {
  echo "Usage: $0 --cluster-name NAME [--env ENV]"
  echo "  -c, --cluster-name  Kubernetes context / cluster name (required)"
  echo "  -e, --env           Environment for values (default: local)"
  echo "  -h, --help          Show this help"
  exit 0
}

parse_args() {
  local cluster_name=""
  local env="local"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -c|--cluster-name) cluster_name="${2:?Missing value for $1}"; shift 2 ;;
      -e|--env) env="${2:?Missing value for $1}"; shift 2 ;;
      -h|--help) usage ;;
      *) fatal "Unknown option: $1"; exit 1 ;;
    esac
  done
  if [[ -z "${cluster_name:-}" ]]; then
    fatal "Missing required option: --cluster-name"
    exit 1
  fi
  echo "${cluster_name}|${env}"
}

main() {
  local script_dir repo_root argocd_chart values_file cluster_name env parsed
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  repo_root="$(cd "$script_dir/../.." && pwd)"
  argocd_chart="$repo_root/charts/argocd"

  parsed="$(parse_args "$@")"
  cluster_name="${parsed%%|*}"
  env="${parsed#*|}"

  kubectl config use-context "$cluster_name"

  if ! kubectl get ns "$NAMESPACE" &>/dev/null; then
    info "Creating namespace $NAMESPACE..."
    kubectl create namespace "$NAMESPACE"
  fi

  values_file="$argocd_chart/values.yaml"
  if [[ "$env" == "local" ]] && [[ -f "$argocd_chart/values-local.yaml" ]]; then
    values_file="$argocd_chart/values-local.yaml"
  fi

  info "Installing Argo CD via Helm (env=$env)..."
  helm dependency build "$argocd_chart"
  # Server-side apply avoids "metadata.annotations: Too long" on large CRDs
  helm template argocd "$argocd_chart" \
    -n "$NAMESPACE" \
    -f "$values_file" \
    | kubectl apply --server-side --force-conflicts -n "$NAMESPACE" -f -

  kubectl wait --for=condition=available deployment/argocd-server \
    -n "$NAMESPACE" --timeout=300s

  info "Argo CD is up. For local: kubectl port-forward -n $NAMESPACE svc/argocd-server 8080:443"
  info "Then open http://localhost:8080 (values-local: server.insecure). Admin: kubectl -n $NAMESPACE get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"
}

main "$@"

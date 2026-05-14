#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<EOF
Usage: $0 enable|disable

This script toggles the "values-minimal.yaml" file into ArgoCD umbrella Applications
so the umbrella Helm chart for dev/staging will deploy with the minimal services set.

Requires: kubectl configured to the cluster with access to ArgoCD namespace (argocd).

Examples:
  $0 enable   # enable minimal values (adds values-minimal.yaml)
  $0 disable  # remove minimal values (revert to values-dev / values-staging)
EOF
}

if [ $# -ne 1 ]; then
  usage
  exit 2
fi

CMD=$1

enable_minimal() {
  echo "Patching yas-dev to include values-minimal.yaml..."
  kubectl patch application yas-dev -n argocd --type=merge -p '{"spec":{"source":{"helm":{"valueFiles":["values.yaml","values-dev.yaml","values-minimal.yaml"]}}}}'

  echo "Patching yas-staging to include values-minimal.yaml..."
  kubectl patch application yas-staging -n argocd --type=merge -p '{"spec":{"source":{"helm":{"valueFiles":["values.yaml","values-staging.yaml","values-minimal.yaml"]}}}}'

  echo "Optional: force sync via argocd CLI if available (argocd app sync yas-dev yas-staging)"
  if command -v argocd >/dev/null 2>&1; then
    argocd app sync yas-dev || true
    argocd app sync yas-staging || true
  fi

  echo "Enabled minimal values. ArgoCD should reconcile and scale pods accordingly."
}

disable_minimal() {
  echo "Reverting yas-dev to values-dev.yaml (removing values-minimal.yaml)..."
  kubectl patch application yas-dev -n argocd --type=merge -p '{"spec":{"source":{"helm":{"valueFiles":["values.yaml","values-dev.yaml"]}}}}'

  echo "Reverting yas-staging to values-staging.yaml (removing values-minimal.yaml)..."
  kubectl patch application yas-staging -n argocd --type=merge -p '{"spec":{"source":{"helm":{"valueFiles":["values.yaml","values-staging.yaml"]}}}}'

  if command -v argocd >/dev/null 2>&1; then
    argocd app sync yas-dev || true
    argocd app sync yas-staging || true
  fi

  echo "Disabled minimal values. ArgoCD should reconcile and restore previous replicas."
}

case "$CMD" in
  enable) enable_minimal ;; 
  disable) disable_minimal ;;
  *) usage; exit 2 ;;
esac

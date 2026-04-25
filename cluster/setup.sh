#!/usr/bin/env bash
set -euo pipefail

CLUSTER_NAME=${CLUSTER_NAME:-podinfo}
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

install_brew_package() {
  local cmd=$1 pkg=${2:-$1}
  if ! command -v "$cmd" &>/dev/null; then
    echo "==> Installing $pkg..."
    brew install "$pkg"
  else
    echo "==> $cmd already installed ($(${cmd} version --short 2>/dev/null || true))"
  fi
}

# Docker Desktop must be installed and running before kind can work
if ! command -v docker &>/dev/null; then
  echo "==> Installing Docker Desktop..."
  brew install --cask docker
  echo ""
  echo "Docker Desktop installed. Please:"
  echo "  1. Open Docker Desktop from Applications"
  echo "  2. Wait for it to fully start (whale icon stops animating)"
  echo "  3. Re-run this script"
  exit 0
fi

if ! docker info &>/dev/null 2>&1; then
  echo "Error: Docker is installed but not running."
  echo "Start Docker Desktop and re-run this script."
  exit 1
fi

install_brew_package kind
install_brew_package kubectl kubernetes-cli
install_brew_package helm

if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
  echo "==> Cluster '${CLUSTER_NAME}' already exists, skipping creation"
else
  echo "==> Creating kind cluster '${CLUSTER_NAME}'..."
  kind create cluster --name "$CLUSTER_NAME" --config "${SCRIPT_DIR}/kind-config.yaml"
fi

kubectl cluster-info --context "kind-${CLUSTER_NAME}"
echo ""
echo "Cluster ready. Context: kind-${CLUSTER_NAME}"

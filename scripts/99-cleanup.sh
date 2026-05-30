#!/usr/bin/env bash
# =============================================================================
# 99-cleanup.sh — Tear down everything
# =============================================================================
set -euo pipefail

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

CLUSTER_NAME="ai-demo"

echo -e "${YELLOW}${BOLD}This will delete the k3d cluster '${CLUSTER_NAME}' and ALL its data.${RESET}"
echo -e "${YELLOW}Press ENTER to confirm, or Ctrl+C to cancel.${RESET}"
read -r

echo -e "${CYAN}Deleting k3d cluster...${RESET}"
k3d cluster delete "$CLUSTER_NAME" 2>/dev/null || true

echo -e "${CYAN}Cleaning up local Docker images (optional)...${RESET}"
docker rmi agent-orchestrator:latest ai-worker:latest 2>/dev/null || true

echo -e "${GREEN}${BOLD}Cleanup complete. 'kubectl get nodes' should now fail.${RESET}"

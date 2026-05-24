#!/usr/bin/env bash
set -euo pipefail

STACK_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
PODMAN_ROOT="${STACK_DIR}/.podman/root"
PODMAN_RUNROOT="${STACK_DIR}/.podman/runroot"
COMPOSE_FILE_PATH="${STACK_DIR}/.generated/compose.dynamic.yaml"

if [[ ! -f "${COMPOSE_FILE_PATH}" ]]; then
  echo "Rendered compose file not found: ${COMPOSE_FILE_PATH}" >&2
  echo "Run 'llama render' first, then retry." >&2
  exit 1
fi

mkdir -p \
  "${PODMAN_ROOT}" \
  "${PODMAN_RUNROOT}" \
  "${STACK_DIR}/data/open-webui"

exec podman-compose \
  --project-name local-llm-stack \
  --file "${COMPOSE_FILE_PATH}" \
  --env-file "${STACK_DIR}/.env" \
  --podman-args="--root ${PODMAN_ROOT} --runroot ${PODMAN_RUNROOT} --storage-driver=vfs" \
  "$@"


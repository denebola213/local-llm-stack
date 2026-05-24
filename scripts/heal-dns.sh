#!/usr/bin/env bash
set -euo pipefail

STACK_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
PODMAN_ROOT="${STACK_DIR}/.podman/root"
PODMAN_RUNROOT="${STACK_DIR}/.podman/runroot"
AARDVARK_DIR="${PODMAN_RUNROOT}/networks/aardvark-dns"

podman_local() {
  podman \
    --root "${PODMAN_ROOT}" \
    --runroot "${PODMAN_RUNROOT}" \
    --storage-driver=vfs \
    "$@"
}

echo "[heal-dns] Stopping project containers..."
container_ids="$(podman_local ps -aq || true)"
if [[ -n "${container_ids}" ]]; then
  podman_local stop ${container_ids} >/dev/null 2>&1 || true
fi

echo "[heal-dns] Killing aardvark-dns for project runroot..."
pids="$(pgrep -f "[a]ardvark-dns.*${PODMAN_RUNROOT}" || true)"
if [[ -n "${pids}" ]]; then
  kill ${pids} >/dev/null 2>&1 || true
  pids="$(pgrep -f "[a]ardvark-dns.*${PODMAN_RUNROOT}" || true)"
  if [[ -n "${pids}" ]]; then
    kill -9 ${pids} >/dev/null 2>&1 || true
  fi
fi

echo "[heal-dns] Removing ${AARDVARK_DIR}"
rm -rf -- "${AARDVARK_DIR}"

echo "[heal-dns] Done. Run ./scripts/up.sh to start services again."

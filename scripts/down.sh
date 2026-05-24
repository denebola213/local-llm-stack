#!/usr/bin/env bash
set -euo pipefail

STACK_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

"${STACK_DIR}/scripts/llama" down "$@"


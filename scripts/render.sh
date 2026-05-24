#!/usr/bin/env bash
set -euo pipefail

STACK_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${STACK_DIR}/.env"
GENERATED_DIR="${STACK_DIR}/.generated"
GENERATED_FILE="${GENERATED_DIR}/compose.dynamic.yaml"
GENERATED_PRESET_FILE="${GENERATED_DIR}/models.preset.ini"
DEFAULT_MODELS_FILE="${STACK_DIR}/models"

load_env_file() {
  local line key value

  while IFS= read -r line || [[ -n "${line}" ]]; do
    line="${line%$'\r'}"
    [[ -z "${line//[[:space:]]/}" ]] && continue
    [[ "${line}" =~ ^[[:space:]]*# ]] && continue

    line="${line#${line%%[![:space:]]*}}"
    if [[ "${line}" == export* ]]; then
      line="${line#export}"
      line="${line#${line%%[![:space:]]*}}"
    fi

    [[ "${line}" == *=* ]] || continue

    key="${line%%=*}"
    value="${line#*=}"

    key="${key%${key##*[![:space:]]}}"
    key="${key#${key%%[![:space:]]*}}"

    if [[ ! "${key}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
      continue
    fi

    if [[ "${value}" =~ ^\".*\"$ ]]; then
      value="${value:1:${#value}-2}"
    elif [[ "${value}" =~ ^\'.*\'$ ]]; then
      value="${value:1:${#value}-2}"
    fi

    export "${key}=${value}"
  done < "${ENV_FILE}"
}

if [[ -f "${ENV_FILE}" ]]; then
  load_env_file
fi

trim() {
  local value="$1"
  value="${value#${value%%[![:space:]]*}}"
  value="${value%${value##*[![:space:]]}}"
  printf '%s' "${value}"
}

yaml_escape() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  printf '%s' "${value}"
}

mkdir -p "${GENERATED_DIR}" "${STACK_DIR}/data/open-webui"

base_port="${LLAMA_BASE_PORT:-8080}"
context="${LLAMA_CONTEXT:-32768}"
predict="${LLAMA_PREDICT:-4096}"
threads="${LLAMA_THREADS:-16}"
parallel="${LLAMA_PARALLEL:-2}"
gpu_layers="${LLAMA_GPU_LAYERS:-99}"

specs=()

parse_models_ini() {
  local models_file="$1"
  local line alias repo

  while IFS= read -r line || [[ -n "${line}" ]]; do
    line="${line%$'\r'}"
    line="$(trim "${line}")"
    [[ -z "${line}" ]] && continue
    case "${line}" in
      \#*|\;*) continue ;;
    esac

    [[ "${line}" == *=* ]] || continue

    alias="$(trim "${line%%=*}")"
    repo="$(trim "${line#*=}")"

    # Treat # and ; as trailing comments only when they are preceded by whitespace.
    repo="${repo%%[[:space:]]#*}"
    repo="${repo%%[[:space:]];*}"
    repo="$(trim "${repo}")"

    if [[ -z "${alias}" || -z "${repo}" ]]; then
      echo "Invalid model entry in ${models_file}: ${line}" >&2
      exit 1
    fi

    specs+=("${alias}=${repo}")
  done < "${models_file}"
}

models_file="${MODELS_FILE:-${DEFAULT_MODELS_FILE}}"
if [[ "${models_file}" != /* ]]; then
  models_file="${STACK_DIR}/${models_file}"
fi

if [[ -f "${models_file}" ]]; then
  parse_models_ini "${models_file}"
fi

if [[ ${#specs[@]} -eq 0 ]]; then
  echo "No model entries found. Define models in: ${models_file}" >&2
  exit 1
fi

service_count=0
openai_urls=""

hf_token_escaped="$(yaml_escape "${HF_TOKEN:-}")"
open_webui_port="${OPEN_WEBUI_PORT:-3000}"
openai_api_key_escaped="$(yaml_escape "${OPENAI_API_KEY:-sk-local}")"
webui_secret_key_escaped="$(yaml_escape "${WEBUI_SECRET_KEY:-replace-this-secret}")"

{
  echo "version = 1"
  echo
  echo "[*]"
  echo "ctx-size = ${context}"
  echo "n-predict = ${predict}"
  echo "threads = ${threads}"
  echo "parallel = ${parallel}"
  echo "n-gpu-layers = ${gpu_layers}"
  echo "flash-attn = auto"
  echo "cache-type-k = q8_0"
  echo "cache-type-v = q8_0"
  echo "jinja = true"
  echo "metrics = true"

  for raw_spec in "${specs[@]}"; do
    model_alias="$(trim "${raw_spec%%=*}")"
    model_repo="$(trim "${raw_spec#*=}")"

    echo
    echo "[${model_alias}]"
    echo "hf-repo = ${model_repo}"
    echo "load-on-startup = false"
  done
} > "${GENERATED_PRESET_FILE}"

{
  echo "services:"

  service_name="llama-server-1"
  service_data_dir="${STACK_DIR}/data/${service_name}"
  mkdir -p "${service_data_dir}"

  port="${base_port}"
  service_count=1
  openai_urls="http://${service_name}:8080/v1"

  cat <<EOF
  ${service_name}:
    image: ghcr.io/ggml-org/llama.cpp:server-vulkan
    restart: unless-stopped
    environment:
      LD_LIBRARY_PATH: "/app"
      HF_TOKEN: "${hf_token_escaped}"
      XDG_CACHE_HOME: "/data/.cache"
    ports:
      - "${port}:8080"
    devices:
      - /dev/dri:/dev/dri
    volumes:
      - ${STACK_DIR}/data/${service_name}:/data
      - ${GENERATED_DIR}:/generated:ro
    security_opt:
      - label=disable
    command:
      - --host
      - 0.0.0.0
      - --port
      - "8080"
      - --models-preset
      - /generated/models.preset.ini
      - --models-max
      - "0"
    healthcheck:
      test: ["CMD-SHELL", "grep -q ':1F90 ' /proc/net/tcp || grep -q ':1F90 ' /proc/net/tcp6"]
      interval: 15s
      timeout: 5s
      retries: 20
      start_period: 120s

EOF

  if [[ ${service_count} -eq 0 ]]; then
    echo "No valid model entries found in ${models_file}" >&2
    exit 1
  fi

  echo "  open-webui:"
  echo "    image: ghcr.io/open-webui/open-webui:main"
  echo "    restart: unless-stopped"
  echo "    depends_on:"
  echo "      ${service_name}:"
  echo "        condition: service_healthy"
  echo "    ports:"
  echo "      - \"${open_webui_port}:8080\""
  echo "    volumes:"
  echo "      - ${STACK_DIR}/data/open-webui:/app/backend/data"
  echo "    environment:"
  echo "      ENABLE_OLLAMA_API: \"False\""
  echo "      ENABLE_OPENAI_API: \"True\""
  echo "      OPENAI_API_BASE_URLS: \"$(yaml_escape "${openai_urls}")\""
  echo "      OPENAI_API_KEYS: \"${openai_api_key_escaped}\""
  echo "      WEBUI_SECRET_KEY: \"${webui_secret_key_escaped}\""
  echo "    healthcheck:"
  echo "      test: [\"CMD-SHELL\", \"grep -q ':1F90 ' /proc/net/tcp || grep -q ':1F90 ' /proc/net/tcp6\"]"
  echo "      interval: 15s"
  echo "      timeout: 5s"
  echo "      retries: 10"
  echo "      start_period: 20s"
} > "${GENERATED_FILE}"

echo "${GENERATED_FILE}"

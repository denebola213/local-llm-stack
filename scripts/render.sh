#!/usr/bin/env bash
set -euo pipefail

STACK_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${STACK_DIR}/.env"
GENERATED_DIR="${STACK_DIR}/.generated"
GENERATED_FILE="${GENERATED_DIR}/compose.dynamic.yaml"
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
    line="${line%%#*}"
    line="${line%%;*}"
    line="$(trim "${line}")"
    [[ -z "${line}" ]] && continue

    [[ "${line}" == *=* ]] || continue

    alias="$(trim "${line%%=*}")"
    repo="$(trim "${line#*=}")"

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
service_names=()

hf_token_escaped="$(yaml_escape "${HF_TOKEN:-}")"
open_webui_port="${OPEN_WEBUI_PORT:-3000}"
openai_api_key_escaped="$(yaml_escape "${OPENAI_API_KEY:-sk-local}")"
webui_secret_key_escaped="$(yaml_escape "${WEBUI_SECRET_KEY:-replace-this-secret}")"

{
  echo "services:"

  for i in "${!specs[@]}"; do
    raw_spec="$(trim "${specs[i]}")"
    if [[ -z "${raw_spec}" ]]; then
      continue
    fi

    service_count=$((service_count + 1))
    service_name="llama-server-${service_count}"
    service_data_dir="${STACK_DIR}/data/${service_name}"
    mkdir -p "${service_data_dir}"

    model_alias=""
    model_repo=""

    if [[ "${raw_spec}" == *"="* ]]; then
      model_alias="$(trim "${raw_spec%%=*}")"
      model_repo="$(trim "${raw_spec#*=}")"
    else
      model_alias="model-${service_count}"
      model_repo="${raw_spec}"
    fi

    if [[ -z "${model_alias}" || -z "${model_repo}" ]]; then
      echo "Invalid model spec entry: ${raw_spec}" >&2
      exit 1
    fi

    port=$((base_port + service_count - 1))

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
      - ./data/${service_name}:/data
    security_opt:
      - label=disable
    command:
      - --host
      - 0.0.0.0
      - --port
      - "8080"
      - --hf-repo
      - "$(yaml_escape "${model_repo}")"
      - --alias
      - "$(yaml_escape "${model_alias}")"
      - --jinja
      - --ctx-size
      - "${context}"
      - --n-predict
      - "${predict}"
      - --threads
      - "${threads}"
      - --parallel
      - "${parallel}"
      - --n-gpu-layers
      - "${gpu_layers}"
      - --flash-attn
      - auto
      - --metrics
      - --cache-type-k
      - q8_0
      - --cache-type-v
      - q8_0

EOF

    service_names+=("${service_name}")
    if [[ -n "${openai_urls}" ]]; then
      openai_urls+=";"
    fi
    openai_urls+="http://${service_name}:8080/v1"
  done

  if [[ ${service_count} -eq 0 ]]; then
    echo "No valid model entries found in ${models_file}" >&2
    exit 1
  fi

  echo "  open-webui:"
  echo "    image: ghcr.io/open-webui/open-webui:main"
  echo "    restart: unless-stopped"
  echo "    depends_on:"
  for service_name in "${service_names[@]}"; do
    echo "      - ${service_name}"
  done
  echo "    ports:"
  echo "      - \"${open_webui_port}:8080\""
  echo "    volumes:"
  echo "      - ./data/open-webui:/app/backend/data"
  echo "    environment:"
  echo "      ENABLE_OLLAMA_API: \"False\""
  echo "      ENABLE_OPENAI_API: \"True\""
  echo "      OPENAI_API_BASE_URLS: \"$(yaml_escape "${openai_urls}")\""
  echo "      OPENAI_API_KEYS: \"${openai_api_key_escaped}\""
  echo "      WEBUI_SECRET_KEY: \"${webui_secret_key_escaped}\""
} > "${GENERATED_FILE}"

echo "${GENERATED_FILE}"

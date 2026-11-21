#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
CONFIG_DIR="${MODEL_CONFIG_DIR:-${REPO_ROOT}/config/models}"
LLM_ROOT="${LLM_ROOT:-/data/llm}"
VLLM_ENV="${VLLM_ENV:-${LLM_ROOT}/envs/vllm-xpu-0.33.0}"
LOCK_FILE="${LOCK_FILE:-${LLM_ROOT}/locks/vllm-xpu.lock}"
LOG_DIR="${LOG_DIR:-${LLM_ROOT}/logs/models}"
API_KEY_FILE="${API_KEY_FILE:-${LLM_ROOT}/secrets/vllm-api-key}"

usage() {
  cat <<'EOF'
Usage: serve-model.sh <profile>
       serve-model.sh --check <profile>
       serve-model.sh --list
       serve-model.sh --help

Profiles are loaded from config/models/<profile>.env.
Starting a profile loads the model into the Arc Pro B60.
EOF
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then usage; exit 0; fi
CHECK_ONLY=0
if [[ "${1:-}" == "--check" ]]; then CHECK_ONLY=1; shift; fi
if [[ "${1:-}" == "--list" ]]; then
  for profile_file in "${CONFIG_DIR}"/*.env; do
    [[ -f "${profile_file}" ]] || continue
    basename "${profile_file}" .env
  done | sort
  exit 0
fi
[[ $# -eq 1 ]] || { usage >&2; exit 2; }
PROFILE="$1"
[[ "${PROFILE}" =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]*$ ]] || { echo "Invalid profile name: ${PROFILE}" >&2; exit 2; }
PROFILE_FILE="${CONFIG_DIR}/${PROFILE}.env"
[[ -r "${PROFILE_FILE}" ]] || { echo "Profile not found: ${PROFILE_FILE}" >&2; exit 2; }
# shellcheck disable=SC1090
source "${PROFILE_FILE}"

MODEL_ID="${MODEL_ID:-${PROFILE}}"
MODEL_PATH="${MODEL_PATH:-}"
SERVED_MODEL_NAME="${SERVED_MODEL_NAME:-${MODEL_ID}}"
HOST="${HOST:-127.0.0.1}"
PORT="${PORT:-8000}"
MAX_MODEL_LEN="${MAX_MODEL_LEN:-8192}"
MAX_NUM_SEQS="${MAX_NUM_SEQS:-1}"
MAX_NUM_BATCHED_TOKENS="${MAX_NUM_BATCHED_TOKENS:-}"
GPU_MEMORY_UTILIZATION="${GPU_MEMORY_UTILIZATION:-0.90}"
DTYPE="${DTYPE:-auto}"
QUANTIZATION="${QUANTIZATION:-}"
CPU_OFFLOAD_GB="${CPU_OFFLOAD_GB:-0}"
MIN_AVAILABLE_GIB="${MIN_AVAILABLE_GIB:-24}"
RUNNER="${RUNNER:-auto}"
CONVERT="${CONVERT:-}"
HF_OVERRIDES_JSON="${HF_OVERRIDES_JSON:-}"
CHAT_TEMPLATE="${CHAT_TEMPLATE:-}"
LANGUAGE_MODEL_ONLY="${LANGUAGE_MODEL_ONLY:-0}"
ENFORCE_EAGER="${ENFORCE_EAGER:-0}"
ENABLE_AUTO_TOOL_CHOICE="${ENABLE_AUTO_TOOL_CHOICE:-0}"
TOOL_CALL_PARSER="${TOOL_CALL_PARSER:-}"
EXPECTED_VLLM_VERSION="${EXPECTED_VLLM_VERSION:-0.33.0}"

fail() { printf 'ERROR [%s]: %s\n' "${PROFILE}" "$*" >&2; exit 1; }

if [[ "${CHECK_ONLY}" == 0 ]]; then
  mkdir -p "${LOG_DIR}"
  [[ -w "${LOG_DIR}" ]] || fail "log directory is not writable: ${LOG_DIR}"
  exec >>"${LOG_DIR}/vllm-${PROFILE}.log" 2>&1
fi

[[ -n "${MODEL_PATH}" && -d "${MODEL_PATH}" ]] || fail "model directory missing: ${MODEL_PATH:-<unset>}"
[[ -x "${VLLM_ENV}/bin/vllm" && -x "${VLLM_ENV}/bin/python" ]] || fail "vLLM environment missing under ${VLLM_ENV}"
[[ -x /usr/bin/flock ]] || fail "util-linux flock is required at /usr/bin/flock"
[[ "${PORT}" =~ ^[0-9]+$ ]] && ((PORT >= 1 && PORT <= 65535)) || fail "PORT must be 1..65535"
[[ "${MAX_MODEL_LEN}" =~ ^[0-9]+$ ]] && ((MAX_MODEL_LEN > 0)) || fail "MAX_MODEL_LEN must be a positive integer"
[[ "${MAX_NUM_SEQS}" =~ ^[0-9]+$ ]] && ((MAX_NUM_SEQS > 0)) || fail "MAX_NUM_SEQS must be a positive integer"
if [[ -n "${MAX_NUM_BATCHED_TOKENS}" ]]; then
  [[ "${MAX_NUM_BATCHED_TOKENS}" =~ ^[0-9]+$ ]] && ((MAX_NUM_BATCHED_TOKENS > 0)) || fail "MAX_NUM_BATCHED_TOKENS must be empty or a positive integer"
fi
[[ "${CPU_OFFLOAD_GB}" =~ ^[0-9]+$ ]] || fail "CPU_OFFLOAD_GB must be a non-negative integer"
[[ "${MIN_AVAILABLE_GIB}" =~ ^[0-9]+$ ]] || fail "MIN_AVAILABLE_GIB must be a non-negative integer"
[[ "${GPU_MEMORY_UTILIZATION}" =~ ^(0(\.[0-9]+)?|1(\.0+)?)$ ]] || fail "GPU_MEMORY_UTILIZATION must be between 0 and 1"
[[ "${LANGUAGE_MODEL_ONLY}" == 0 || "${LANGUAGE_MODEL_ONLY}" == 1 ]] || fail "LANGUAGE_MODEL_ONLY must be 0 or 1"
[[ "${ENFORCE_EAGER}" == 0 || "${ENFORCE_EAGER}" == 1 ]] || fail "ENFORCE_EAGER must be 0 or 1"
[[ "${ENABLE_AUTO_TOOL_CHOICE}" == 0 || "${ENABLE_AUTO_TOOL_CHOICE}" == 1 ]] || fail "ENABLE_AUTO_TOOL_CHOICE must be 0 or 1"
if [[ "${ENABLE_AUTO_TOOL_CHOICE}" == 1 && -z "${TOOL_CALL_PARSER}" ]]; then
  fail "TOOL_CALL_PARSER is required when ENABLE_AUTO_TOOL_CHOICE=1"
fi
[[ -z "${CHAT_TEMPLATE}" || -r "${CHAT_TEMPLATE}" ]] || fail "chat template is missing or unreadable: ${CHAT_TEMPLATE}"
[[ -r "${API_KEY_FILE}" ]] || fail "API key file is missing or unreadable: ${API_KEY_FILE}"
VLLM_API_KEY="$(<"${API_KEY_FILE}")"
[[ ${#VLLM_API_KEY} -ge 32 ]] || fail "API key must contain at least 32 characters"

available_kib="$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo)"
required_kib="$((MIN_AVAILABLE_GIB * 1024 * 1024))"
((available_kib >= required_kib)) || fail "MemAvailable is below ${MIN_AVAILABLE_GIB} GiB; refusing to start"

"${VLLM_ENV}/bin/python" - "${MODEL_PATH}" "${EXPECTED_VLLM_VERSION}" "${QUANTIZATION}" <<'PY'
import json
import re
import sys
from pathlib import Path

root = Path(sys.argv[1])
expected_version = sys.argv[2]
quantization_override = sys.argv[3]
try:
    import torch
    import vllm
except Exception as exc:
    print(f"ERROR: failed to import PyTorch/vLLM: {exc}", file=sys.stderr)
    raise SystemExit(1)

if vllm.__version__ != expected_version:
    print(f"ERROR: expected vLLM {expected_version}, found {vllm.__version__}", file=sys.stderr)
    raise SystemExit(1)
if not torch.xpu.is_available():
    print("ERROR: PyTorch XPU is unavailable", file=sys.stderr)
    raise SystemExit(1)
names = [torch.xpu.get_device_name(i) for i in range(torch.xpu.device_count())]
print(f"vLLM {vllm.__version__}; XPU devices: {'; '.join(names)}")
if not any(re.search(r"Arc(?:\(TM\))?\s+Pro\s+B60", name, re.IGNORECASE) for name in names):
    print("ERROR: Intel Arc Pro B60 was not found among XPU devices", file=sys.stderr)
    raise SystemExit(1)

config_path = root / "config.json"
if config_path.is_file():
    try:
        quant_method = (json.loads(config_path.read_text()).get("quantization_config") or {}).get("quant_method")
    except Exception as exc:
        print(f"ERROR: invalid model config {config_path}: {exc}", file=sys.stderr)
        raise SystemExit(1)
    selected_method = quantization_override or quant_method
    if selected_method:
        try:
            from vllm.model_executor.layers.quantization import get_quantization_config
            get_quantization_config(selected_method)
        except Exception as exc:
            print(
                f"ERROR: selected quantization method {selected_method!r} is not registered in vLLM {vllm.__version__}: {exc}. "
                "This upstream environment cannot launch this checkpoint; use a compatible backend or a supported model format.",
                file=sys.stderr,
            )
            raise SystemExit(1)
        if quantization_override and quant_method and quantization_override != quant_method:
            print(f"Quantization override: checkpoint={quant_method}; runtime={quantization_override}")

weights = list(root.rglob("*.safetensors")) + list(root.rglob("pytorch_model*.bin"))
if not weights:
    print("ERROR: no complete model weight files found", file=sys.stderr)
    raise SystemExit(1)
for index_name in ("model.safetensors.index.json", "pytorch_model.bin.index.json"):
    index_path = root / index_name
    if index_path.is_file():
        try:
            weight_map = json.loads(index_path.read_text())["weight_map"]
            missing = sorted(set(weight_map.values()) - {path.name for path in weights})
        except Exception as exc:
            print(f"ERROR: invalid shard index {index_path}: {exc}", file=sys.stderr)
            raise SystemExit(1)
        if missing:
            print(f"ERROR: model shard(s) missing: {', '.join(missing[:5])}", file=sys.stderr)
            raise SystemExit(1)
has_weight_index = any((root / index_name).is_file() for index_name in ("model.safetensors.index.json", "pytorch_model.bin.index.json"))
if not has_weight_index and any("-of-" in path.name for path in weights):
    print("ERROR: sharded model weights are present but the safetensors index is missing", file=sys.stderr)
    raise SystemExit(1)
print(f"Model files present: {len(weights)} weight file(s)")
PY

if [[ "${CHECK_ONLY}" == 1 ]]; then
  echo "Profile ${PROFILE} preflight passed; model was not started."
  exit 0
fi

export HF_HOME="${HF_HOME:-${LLM_ROOT}/cache/huggingface}"
export HF_HUB_OFFLINE="${HF_HUB_OFFLINE:-1}"
export TRANSFORMERS_OFFLINE="${TRANSFORMERS_OFFLINE:-1}"
export HF_HUB_DISABLE_TELEMETRY=1
export VLLM_API_KEY
export PYTHONPATH="${SCRIPT_DIR}${PYTHONPATH:+:${PYTHONPATH}}"
export ZE_AFFINITY_MASK="${ZE_AFFINITY_MASK:-0}"
export VLLM_WORKER_MULTIPROC_METHOD="${VLLM_WORKER_MULTIPROC_METHOD:-spawn}"
# oneCCL loads its OpenMP transport plugin dynamically. That plugin depends on
# libraries shipped in the vLLM environment root, which systemd does not add
# to the loader path automatically.
export LD_LIBRARY_PATH="${VLLM_ENV}/lib${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"
if [[ -n "${VLLM_XPU_INC_WNA16_BACKEND:-}" ]]; then
  export VLLM_XPU_INC_WNA16_BACKEND
fi
export XDG_CACHE_HOME="${XDG_CACHE_HOME:-${LLM_ROOT}/cache/xdg}"
export TORCHINDUCTOR_CACHE_DIR="${TORCHINDUCTOR_CACHE_DIR:-${LLM_ROOT}/cache/torchinductor}"
export TRITON_CACHE_DIR="${TRITON_CACHE_DIR:-${LLM_ROOT}/cache/triton}"

mkdir -p "$(dirname -- "${LOCK_FILE}")"
args=(serve "${MODEL_PATH}"
  --middleware api_key_auth.RequireApiKey
  --served-model-name "${SERVED_MODEL_NAME}"
  --host "${HOST}"
  --port "${PORT}"
  --dtype "${DTYPE}"
  --runner "${RUNNER}"
  --max-model-len "${MAX_MODEL_LEN}"
  --max-num-seqs "${MAX_NUM_SEQS}"
  --gpu-memory-utilization "${GPU_MEMORY_UTILIZATION}"
)
[[ -z "${QUANTIZATION}" ]] || args+=(--quantization "${QUANTIZATION}")
[[ -z "${MAX_NUM_BATCHED_TOKENS}" ]] || args+=(--max-num-batched-tokens "${MAX_NUM_BATCHED_TOKENS}")
((CPU_OFFLOAD_GB == 0)) || args+=(--cpu-offload-gb "${CPU_OFFLOAD_GB}")
[[ -z "${CONVERT}" ]] || args+=(--convert "${CONVERT}")
[[ -z "${HF_OVERRIDES_JSON}" ]] || args+=(--hf-overrides "${HF_OVERRIDES_JSON}")
[[ -z "${CHAT_TEMPLATE}" ]] || args+=(--chat-template "${CHAT_TEMPLATE}")
if [[ "${LANGUAGE_MODEL_ONLY}" == 1 ]]; then args+=(--language-model-only); fi
if [[ "${ENFORCE_EAGER}" == 1 ]]; then args+=(--enforce-eager); fi
if [[ "${ENABLE_AUTO_TOOL_CHOICE}" == 1 ]]; then
  args+=(--enable-auto-tool-choice --tool-call-parser "${TOOL_CALL_PARSER}")
fi

printf 'Starting profile=%s model=%s port=%s max_len=%s max_num_seqs=%s gpu_mem_util=%s\n' \
  "${PROFILE}" "${MODEL_ID}" "${PORT}" "${MAX_MODEL_LEN}" "${MAX_NUM_SEQS}" "${GPU_MEMORY_UTILIZATION}"
exec /usr/bin/flock --nonblock --no-fork "${LOCK_FILE}" "${VLLM_ENV}/bin/vllm" "${args[@]}"

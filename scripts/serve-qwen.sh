#!/usr/bin/env bash
set -Eeuo pipefail

LLM_ROOT="${LLM_ROOT:-/data/llm}"
VLLM_ENV="${VLLM_ENV:-${LLM_ROOT}/envs/vllm-xpu-0.33.0}"
MODEL_PATH="${MODEL_PATH:-${LLM_ROOT}/models/Qwen3.6-27B-int4-AutoRound}"
SERVED_MODEL_NAME="${SERVED_MODEL_NAME:-qwen3.6-27b}"
HOST="${HOST:-127.0.0.1}"
PORT="${PORT:-8000}"
MAX_MODEL_LEN="${MAX_MODEL_LEN:-8192}"
MAX_NUM_SEQS="${MAX_NUM_SEQS:-2}"
GPU_MEMORY_UTILIZATION="${GPU_MEMORY_UTILIZATION:-0.90}"
MIN_AVAILABLE_GIB="${MIN_AVAILABLE_GIB:-24}"

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

[[ -x "${VLLM_ENV}/bin/vllm" ]] || fail "vLLM executable missing: ${VLLM_ENV}/bin/vllm"
[[ -x "${VLLM_ENV}/bin/python" ]] || fail "Python executable missing: ${VLLM_ENV}/bin/python"
[[ -d "${MODEL_PATH}" ]] || fail "model directory missing: ${MODEL_PATH}"
[[ "${PORT}" =~ ^[0-9]+$ ]] && ((PORT >= 1 && PORT <= 65535)) || fail "PORT must be 1..65535"
[[ "${MAX_MODEL_LEN}" =~ ^[0-9]+$ ]] && ((MAX_MODEL_LEN > 0)) || fail "MAX_MODEL_LEN must be a positive integer"
[[ "${MAX_NUM_SEQS}" =~ ^[0-9]+$ ]] && ((MAX_NUM_SEQS > 0)) || fail "MAX_NUM_SEQS must be a positive integer"
[[ "${MIN_AVAILABLE_GIB}" =~ ^[0-9]+$ ]] || fail "MIN_AVAILABLE_GIB must be a non-negative integer"

available_kib="$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo)"
required_kib="$((MIN_AVAILABLE_GIB * 1024 * 1024))"
((available_kib >= required_kib)) || fail "MemAvailable is below ${MIN_AVAILABLE_GIB} GiB; refusing to start"

"${VLLM_ENV}/bin/python" - <<'PY'
import sys
try:
    import torch
except Exception as exc:
    print(f"ERROR: failed to import PyTorch: {exc}", file=sys.stderr)
    raise SystemExit(1)
if not torch.xpu.is_available():
    print("ERROR: PyTorch XPU is unavailable", file=sys.stderr)
    raise SystemExit(1)
names = [torch.xpu.get_device_name(i) for i in range(torch.xpu.device_count())]
print("XPU devices: " + "; ".join(names))
if not any("Arc Pro B60" in name for name in names):
    print("ERROR: Intel Arc Pro B60 was not found among XPU devices", file=sys.stderr)
    raise SystemExit(1)
PY

export HF_HOME="${HF_HOME:-${LLM_ROOT}/cache/huggingface}"
export HF_HUB_OFFLINE="${HF_HUB_OFFLINE:-1}"
export TRANSFORMERS_OFFLINE="${TRANSFORMERS_OFFLINE:-1}"
export HF_HUB_DISABLE_TELEMETRY="1"
export ZE_AFFINITY_MASK="${ZE_AFFINITY_MASK:-0}"

exec "${VLLM_ENV}/bin/vllm" serve "${MODEL_PATH}" \
  --served-model-name "${SERVED_MODEL_NAME}" \
  --host "${HOST}" \
  --port "${PORT}" \
  --dtype auto \
  --max-model-len "${MAX_MODEL_LEN}" \
  --max-num-seqs "${MAX_NUM_SEQS}" \
  --gpu-memory-utilization "${GPU_MEMORY_UTILIZATION}"

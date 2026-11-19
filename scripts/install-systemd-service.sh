#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
unit_src="${repo_root}/systemd/llm-vllm@.service"
unit_dst="/etc/systemd/system/llm-vllm@.service"
backup_suffix="pre-a3950x-run-llm.$(date +%Y%m%d%H%M%S)"

[[ "${EUID}" -eq 0 ]] || { echo "Run with sudo: sudo $0" >&2; exit 1; }
[[ "${repo_root}" == /data/llm/a3950x-run-llm ]] || {
  echo "Expected repository at /data/llm/a3950x-run-llm; found ${repo_root}" >&2
  exit 1
}
[[ -f "${unit_src}" && -x "${repo_root}/scripts/serve-model.sh" ]] || {
  echo "Template unit or generic launcher is missing" >&2
  exit 1
}
[[ -x /data/llm/envs/vllm-xpu-0.33.0/bin/vllm ]] || {
  echo "Expected vLLM environment not found under /data/llm/envs/vllm-xpu-0.33.0" >&2
  exit 1
}
[[ -x /usr/bin/flock ]] || { echo "util-linux flock is required" >&2; exit 1; }

for directory in /data/llm/logs /data/llm/locks /data/llm/cache /data/llm/cache/huggingface /data/llm/cache/xdg /data/llm/cache/torchinductor /data/llm/cache/triton; do
  if [[ ! -d "${directory}" ]]; then
    install -d -o wendaoji -g wendaoji -m 0750 "${directory}"
  elif ! runuser -u wendaoji -- test -w "${directory}"; then
    echo "Existing directory is not writable by wendaoji: ${directory}" >&2
    exit 1
  fi
done

if [[ -e "${unit_dst}" ]]; then
  cp -a -- "${unit_dst}" "${unit_dst}.${backup_suffix}"
  echo "Backed up existing unit to ${unit_dst}.${backup_suffix}"
fi
install -D -o root -g root -m 0644 "${unit_src}" "${unit_dst}"
systemctl daemon-reload
echo "Installed template unit and reloaded systemd. No model was enabled or started."

#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
unit_src="${repo_root}/systemd/llm-vllm.service"
unit_dst="/etc/systemd/system/llm-vllm.service"
script_src="${repo_root}/scripts/serve-qwen.sh"
script_dst="/data/llm/scripts/serve-qwen.sh"
env_example="${repo_root}/config/serve-qwen.env.example"
env_dst="/data/llm/config/serve-qwen.env"
backup_suffix="pre-a3950x-run-llm.$(date +%Y%m%d%H%M%S)"

[[ "${EUID}" -eq 0 ]] || { echo "Run with sudo: sudo $0" >&2; exit 1; }
[[ -f "${unit_src}" && -f "${script_src}" ]] || { echo "Run this from a complete project checkout" >&2; exit 1; }
[[ -x /data/llm/envs/vllm-xpu-0.33.0/bin/vllm ]] || {
  echo "Expected vLLM environment not found under /data/llm/envs/vllm-xpu-0.33.0" >&2
  exit 1
}
[[ -d /data/llm/models/Qwen3.6-27B-int4-AutoRound ]] || {
  echo "Expected Qwen3.6-27B model directory not found" >&2
  exit 1
}

for directory in /data/llm/config /data/llm/logs /data/llm/cache /data/llm/cache/huggingface; do
  if [[ ! -d "${directory}" ]]; then
    install -d -o wendaoji -g wendaoji -m 0750 "${directory}"
  elif ! runuser -u wendaoji -- test -w "${directory}"; then
    echo "Existing directory is not writable by wendaoji: ${directory}" >&2
    exit 1
  fi
done
if [[ -e "${env_dst}" ]] && ! runuser -u wendaoji -- test -r "${env_dst}"; then
  echo "Existing environment file is not readable by wendaoji: ${env_dst}" >&2
  exit 1
fi

for destination in "${unit_dst}" "${script_dst}"; do
  if [[ -e "${destination}" ]]; then
    cp -a -- "${destination}" "${destination}.${backup_suffix}"
    echo "Backed up existing file to ${destination}.${backup_suffix}"
  fi
done

install -D -o root -g root -m 0644 "${unit_src}" "${unit_dst}"
install -D -o wendaoji -g wendaoji -m 0755 "${script_src}" "${script_dst}"
if [[ ! -e "${env_dst}" ]]; then
  install -o wendaoji -g wendaoji -m 0640 "${env_example}" "${env_dst}"
  echo "Created ${env_dst}; review it before starting the service."
else
  echo "Preserved existing ${env_dst}."
fi
systemctl daemon-reload
echo "Installed unit and reloaded systemd. The service was NOT enabled or started."

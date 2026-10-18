#!/usr/bin/env bash
set -euo pipefail
name="${1:-main}"
case "${name}" in main|vision) ;; *) echo "usage: agent-log [main|vision]" >&2; exit 2 ;; esac
log="${AGENT_LAB_HOME:-/workspace/agent-lab}/logs/llama-${name}.log"
[[ -f "${log}" ]] || { echo "No log yet: ${log}" >&2; exit 1; }
exec tail -n 100 -f "${log}"

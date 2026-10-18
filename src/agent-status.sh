#!/usr/bin/env bash
set -euo pipefail
STATE_ROOT="${AGENT_LAB_HOME:-/workspace/agent-lab}"
PROFILE="${AGENT_PROFILE:-glm47-l40s}"
PROFILE_FILE="/opt/agent-lab/profiles/${PROFILE}.env"
[[ -f "${PROFILE_FILE}" ]] && source "${PROFILE_FILE}"

echo "Profile: ${PROFILE}"
echo
nvidia-smi --query-gpu=name,memory.total,memory.used,utilization.gpu --format=csv,noheader 2>/dev/null || true
echo
for spec in "main:${MAIN_PORT:-8000}" "vision:${VISION_PORT:-8001}"; do
  name="${spec%%:*}"; port="${spec##*:}"
  pidfile="${STATE_ROOT}/run/${name}.pid"
  pid="$(cat "${pidfile}" 2>/dev/null || true)"
  if [[ -n "${pid}" ]] && kill -0 "${pid}" 2>/dev/null; then
    if curl -fsS "http://127.0.0.1:${port}/health" >/dev/null 2>&1; then
      printf '%-7s pid=%-8s port=%-5s healthy\n' "${name}" "${pid}" "${port}"
    else
      printf '%-7s pid=%-8s port=%-5s starting/unhealthy\n' "${name}" "${pid}" "${port}"
    fi
  else
    printf '%-7s not running\n' "${name}"
  fi
done

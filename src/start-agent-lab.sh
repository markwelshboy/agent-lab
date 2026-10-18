#!/usr/bin/env bash
set -euo pipefail

IMAGE_ROOT="${AGENT_LAB_IMAGE_ROOT:-/opt/agent-lab}"
STATE_ROOT="${AGENT_LAB_HOME:-/workspace/agent-lab}"
PROFILE="${AGENT_PROFILE:-glm47-l40s}"
PROFILE_FILE="${IMAGE_ROOT}/profiles/${PROFILE}.env"
LOG_DIR="${STATE_ROOT}/logs"
PID_DIR="${STATE_ROOT}/run"
PROJECTS_DIR="${PROJECTS_DIR:-/workspace/projects}"
HF_HOME="${HF_HOME:-/workspace/hf-cache}"
START_TIMEOUT="${AGENT_SERVER_START_TIMEOUT:-1800}"

log() { printf '[agent-lab] %s\n' "$*"; }
die() { printf '[agent-lab] ERROR: %s\n' "$*" >&2; exit 1; }

[[ -f "${PROFILE_FILE}" ]] || {
  echo "Available profiles:" >&2
  find "${IMAGE_ROOT}/profiles" -maxdepth 1 -type f -name '*.env' -printf '  %f\n' | sed 's/\.env$//' >&2
  die "Unknown AGENT_PROFILE=${PROFILE}"
}

# shellcheck disable=SC1090
source "${PROFILE_FILE}"

: "${MAIN_MODEL_HF:?profile must set MAIN_MODEL_HF}"
: "${MAIN_MODEL_ALIAS:=agent-main}"
: "${MAIN_CONTEXT:=65536}"
: "${MAIN_MAX_TOKENS:=16384}"
: "${MAIN_INPUT:=text}"
: "${MAIN_PORT:=8000}"
: "${VISION_ENABLED:=false}"
: "${VISION_MODEL_ALIAS:=agent-vision}"
: "${VISION_CONTEXT:=16384}"
: "${VISION_MAX_TOKENS:=8192}"
: "${VISION_PORT:=8001}"

mkdir -p "${LOG_DIR}" "${PID_DIR}" "${PROJECTS_DIR}" "${HF_HOME}" \
  "${STATE_ROOT}/omp/agent" "${STATE_ROOT}/shared-skills" "${STATE_ROOT}/hermes"

export HF_HOME
export HUGGINGFACE_HUB_CACHE="${HUGGINGFACE_HUB_CACHE:-${HF_HOME}/hub}"
export HOME=/root

# Hermes' checkout/venv remains image-owned. HERMES_HOME is fixed in the image
# and ~/.hermes points at it too, so SSH sessions, docker exec, and processes
# launched by the entrypoint all resolve exactly the same state root.
HERMES_IMAGE_HOME=/opt/hermes-home
export HERMES_HOME="${HERMES_IMAGE_HOME}"
rm -rf /root/.hermes
ln -sfn "${HERMES_IMAGE_HOME}" /root/.hermes

# OMP is a standalone binary, so its complete mutable state can live on the volume.
if [[ -e /root/.omp && ! -L /root/.omp ]]; then
  if [[ -d /root/.omp && -z "$(find /root/.omp -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]]; then
    rmdir /root/.omp
  else
    mv /root/.omp "/root/.omp.image-backup.$(date +%s)"
  fi
fi
ln -sfn "${STATE_ROOT}/omp" /root/.omp

# Persist Hermes' mutable user state individually so /workspace can be mounted
# independently while the source checkout and venv stay immutable under /opt.
persist_hermes_file() {
  local name="$1" seed_mode="${2:-empty}"
  local source="${HERMES_IMAGE_HOME}/${name}"
  local target="${STATE_ROOT}/hermes/${name}"

  if [[ ! -e "${target}" && ! -L "${target}" ]]; then
    if [[ -f "${source}" && ! -L "${source}" ]]; then
      cp -a "${source}" "${target}"
    elif [[ "${seed_mode}" == "yaml" ]]; then
      printf '{}\n' > "${target}"
    elif [[ "${seed_mode}" == "empty" ]]; then
      : > "${target}"
    fi
  fi
  rm -f "${source}"
  ln -sfn "${target}" "${source}"
}

persist_hermes_dir() {
  local name="$1"
  local source="${HERMES_IMAGE_HOME}/${name}"
  local target="${STATE_ROOT}/hermes/${name}"

  if [[ ! -d "${target}" ]]; then
    mkdir -p "${target}"
    if [[ -d "${source}" && ! -L "${source}" ]]; then
      cp -a "${source}/." "${target}/" 2>/dev/null || true
    fi
  fi
  rm -rf "${source}"
  ln -sfn "${target}" "${source}"
}

persist_hermes_file config.yaml yaml
persist_hermes_file .env empty
persist_hermes_file SOUL.md empty
# These are optional. Leave the target absent until Hermes creates it, but keep
# the image path linked to the persistent location from the first invocation.
persist_hermes_file auth.json absent
persist_hermes_file state.db absent
for name in memories cron sessions logs profiles; do
  persist_hermes_dir "${name}"
done

# Seed portable skills exactly once. Users can edit the persistent copies.
if [[ -d "${IMAGE_ROOT}/skills" ]]; then
  cp -an "${IMAGE_ROOT}/skills/." "${STATE_ROOT}/shared-skills/" 2>/dev/null || true
fi
# OMP can discover Agent Skills from ~/.agents/skills; Hermes uses $HERMES_HOME/skills.
mkdir -p /root/.agents
rm -rf /root/.agents/skills
ln -sfn "${STATE_ROOT}/shared-skills" /root/.agents/skills
rm -rf "${HERMES_IMAGE_HOME}/skills"
ln -sfn "${STATE_ROOT}/shared-skills" "${HERMES_IMAGE_HOME}/skills"

setup_ssh() {
  mkdir -p /root/.ssh /run/sshd
  chmod 700 /root/.ssh
  local key="${PUBLIC_KEY:-${SSH_PUBLIC_KEY:-}}"
  if [[ -n "${key}" ]]; then
    printf '%s\n' "${key}" > /root/.ssh/authorized_keys
    chmod 600 /root/.ssh/authorized_keys
  fi
  ssh-keygen -A >/dev/null 2>&1 || true
  /usr/sbin/sshd
}

write_omp_config() {
  local main_input_yaml='[text]'
  local vision_selector="agent-local/${MAIN_MODEL_ALIAS}"
  [[ "${MAIN_INPUT}" == *image* ]] && main_input_yaml='[text, image]'

  cat > "${STATE_ROOT}/omp/agent/models.yml" <<EOF_MODELS
providers:
  agent-local:
    baseUrl: http://127.0.0.1:${MAIN_PORT}/v1
    api: openai-completions
    auth: none
    models:
      - id: ${MAIN_MODEL_ALIAS}
        name: ${PROFILE} main
        input: ${main_input_yaml}
        contextWindow: ${MAIN_CONTEXT}
        maxTokens: ${MAIN_MAX_TOKENS}
EOF_MODELS

  if [[ "${VISION_ENABLED}" == "true" ]]; then
    vision_selector="agent-vision/${VISION_MODEL_ALIAS}"
    cat >> "${STATE_ROOT}/omp/agent/models.yml" <<EOF_MODELS
  agent-vision:
    baseUrl: http://127.0.0.1:${VISION_PORT}/v1
    api: openai-completions
    auth: none
    models:
      - id: ${VISION_MODEL_ALIAS}
        name: ${PROFILE} vision
        input: [text, image]
        contextWindow: ${VISION_CONTEXT}
        maxTokens: ${VISION_MAX_TOKENS}
EOF_MODELS
  fi

  # Seed once, then use OMP's own config writer so changing AGENT_PROFILE does
  # not destroy unrelated user settings on the persistent volume.
  if [[ ! -s "${STATE_ROOT}/omp/agent/config.yml" ]]; then
    printf '{}\n' > "${STATE_ROOT}/omp/agent/config.yml"
  fi
  omp config set modelRoles.default "agent-local/${MAIN_MODEL_ALIAS}" >/dev/null
  omp config set modelRoles.slow '@default' >/dev/null
  omp config set modelRoles.plan '@default' >/dev/null
  omp config set modelRoles.advisor '@default' >/dev/null
  omp config set modelRoles.vision "${vision_selector}" >/dev/null
}

write_hermes_config() {
  local cfg="${STATE_ROOT}/hermes/config.yaml"
  [[ -s "${cfg}" ]] || printf '{}\n' > "${cfg}"

  # Same principle as OMP: update only the profile-owned model routes and leave
  # the rest of the persistent Hermes configuration untouched.
  hermes config set model.provider custom >/dev/null
  hermes config set model.default "${MAIN_MODEL_ALIAS}" >/dev/null
  hermes config set model.base_url "http://127.0.0.1:${MAIN_PORT}/v1" >/dev/null
  hermes config set model.api_key local >/dev/null
  hermes config set model.context_length "${MAIN_CONTEXT}" >/dev/null
  hermes config set model.api_mode chat_completions >/dev/null
  hermes config set auxiliary.vision.model "$(if [[ "${VISION_ENABLED}" == "true" ]]; then printf '%s' "${VISION_MODEL_ALIAS}"; else printf '%s' "${MAIN_MODEL_ALIAS}"; fi)" >/dev/null
  hermes config set auxiliary.vision.timeout 120 >/dev/null

  if [[ "${VISION_ENABLED}" == "true" ]]; then
    hermes config set auxiliary.vision.provider custom >/dev/null
    hermes config set auxiliary.vision.base_url "http://127.0.0.1:${VISION_PORT}/v1" >/dev/null
    hermes config set auxiliary.vision.api_key local >/dev/null
  else
    hermes config set auxiliary.vision.provider main >/dev/null
    hermes config set auxiliary.vision.base_url '' >/dev/null
    hermes config set auxiliary.vision.api_key '' >/dev/null
  fi
}

wait_for_server() {
  local name="$1" port="$2" pid="$3"
  local deadline=$((SECONDS + START_TIMEOUT))
  while (( SECONDS < deadline )); do
    if ! kill -0 "${pid}" 2>/dev/null; then
      tail -n 80 "${LOG_DIR}/llama-${name}.log" >&2 || true
      die "${name} llama-server exited during startup"
    fi
    if curl -fsS "http://127.0.0.1:${port}/health" >/dev/null 2>&1; then
      log "${name} server ready on 127.0.0.1:${port}"
      return 0
    fi
    sleep 2
  done
  die "Timed out waiting ${START_TIMEOUT}s for ${name} server; see ${LOG_DIR}/llama-${name}.log"
}

launch_server() {
  local name="$1" hf="$2" alias="$3" context="$4" port="$5"
  local logfile="${LOG_DIR}/llama-${name}.log"
  : > "${logfile}"
  log "Starting ${name}: ${hf} (ctx=${context}, port=${port})"
  nohup llama-server \
    -hf "${hf}" \
    --alias "${alias}" \
    --host 127.0.0.1 \
    --port "${port}" \
    --ctx-size "${context}" \
    --n-gpu-layers 999 \
    --flash-attn on \
    --cache-type-k q8_0 \
    --cache-type-v q8_0 \
    --jinja \
    >"${logfile}" 2>&1 &
  local pid=$!
  printf '%s\n' "${pid}" > "${PID_DIR}/${name}.pid"
  wait_for_server "${name}" "${port}" "${pid}"
}

cleanup() {
  for f in "${PID_DIR}"/*.pid; do
    [[ -e "${f}" ]] || continue
    pid="$(cat "${f}" 2>/dev/null || true)"
    [[ -n "${pid}" ]] && kill "${pid}" 2>/dev/null || true
  done
}
trap cleanup EXIT INT TERM

setup_ssh
write_omp_config
write_hermes_config

log "Profile: ${PROFILE}"
log "${PROFILE_DESCRIPTION:-}"
if command -v nvidia-smi >/dev/null 2>&1; then
  nvidia-smi --query-gpu=name,memory.total,driver_version --format=csv,noheader || true
fi

launch_server main "${MAIN_MODEL_HF}" "${MAIN_MODEL_ALIAS}" "${MAIN_CONTEXT}" "${MAIN_PORT}"
if [[ "${VISION_ENABLED}" == "true" ]]; then
  : "${VISION_MODEL_HF:?VISION_ENABLED=true but VISION_MODEL_HF is empty}"
  launch_server vision "${VISION_MODEL_HF}" "${VISION_MODEL_ALIAS}" "${VISION_CONTEXT}" "${VISION_PORT}"
else
  log "Separate vision server disabled; ${MAIN_MODEL_ALIAS} is used for vision."
fi

cat <<EOF_READY

================================================================================
 agent-lab ready
================================================================================
 Profile : ${PROFILE}
 Main    : http://127.0.0.1:${MAIN_PORT}/v1  (${MAIN_MODEL_HF})
 Vision  : $(if [[ "${VISION_ENABLED}" == "true" ]]; then printf 'http://127.0.0.1:%s/v1  (%s)' "${VISION_PORT}" "${VISION_MODEL_HF}"; else printf 'main model'; fi)
 Projects: ${PROJECTS_DIR}
 Skills  : ${STATE_ROOT}/shared-skills
 Logs    : ${LOG_DIR}

 Try:
   cd ${PROJECTS_DIR}
   hermes
   omp

 Status/log helpers:
   agent-status
   agent-log main
   agent-log vision

 Hermes browser dashboard (recommended through an SSH tunnel):
   hermes dashboard --host 127.0.0.1 --port 9119 --no-open
================================================================================
EOF_READY

# Keep the RunPod container alive. The inference servers and sshd run in the
# background; interactive agent sessions are intentionally operator-started.
while true; do
  sleep 3600 &
  wait $!
done

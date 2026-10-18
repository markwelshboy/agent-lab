#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  ./build_agent-lab.sh [options]

Build/output:
  --builder <name>        Buildx builder. Default: buildkit-scratch
  --no-push              Build/cache only; do not push or load into Docker
  --load                 Load into local Docker instead of pushing
  --platform <plats>     Default: linux/amd64
  --no-cache             Disable build cache
  --prune                Prune stopped containers and dangling Docker images
  --prune-hard           Aggressively prune cache from the selected Buildx builder

Tagging:
  --image <repo/name>    Default: markwelshboy/agent-lab
  --tag <tag>            Default: latest

Pinned components:
  --llama-ref <ref>      llama.cpp tag/SHA. Default: v0.7.0
  --omp-ref <ref>        Oh My Pi release. Default: v18.12.1
  --hermes-ref <ref>     Hermes Agent commit/SHA

Metadata:
  --image-version <v>    Default: 0.1.0
  --build-date <iso>     Default: current Git commit timestamp
  --vcs-ref <sha>        Default: git rev-parse --short HEAD or "unknown"

Pass-through:
  --build-arg KEY=VALUE  Repeatable
  --dockerfile <path>    Default: Dockerfile

Examples:
  ./build_agent-lab.sh
  ./build_agent-lab.sh --tag dev
  ./build_agent-lab.sh --tag dev --no-push
  ./build_agent-lab.sh --load --tag test
  ./build_agent-lab.sh --llama-ref v0.7.0 --tag llama070
USAGE
}

die() { echo "ERROR: $*" >&2; exit 1; }
have_cmd() { command -v "$1" >/dev/null 2>&1; }

IMAGE="markwelshboy/agent-lab"
TAG="latest"
DOCKERFILE="Dockerfile"
BUILDER="${BUILDX_BUILDER:-buildkit-scratch}"
PLATFORM="linux/amd64"
PUSH=true
LOAD=false
NO_CACHE=false
PRUNE=false
PRUNE_HARD=false

LLAMA_CPP_REF="v0.7.0"
OMP_REF="v18.12.1"
HERMES_REF="9e01b44dd23978f9ff40b7837467f3a9f1582130"
IMAGE_VERSION="0.1.0"
BUILD_DATE=""
VCS_REF=""
EXTRA_BUILD_ARGS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --builder) [[ -n "${2:-}" ]] || die "--builder requires a value"; BUILDER="$2"; shift 2 ;;
    --no-push) PUSH=false; shift ;;
    --load) LOAD=true; PUSH=false; shift ;;
    --platform) [[ -n "${2:-}" ]] || die "--platform requires a value"; PLATFORM="$2"; shift 2 ;;
    --no-cache) NO_CACHE=true; shift ;;
    --prune) PRUNE=true; shift ;;
    --prune-hard) PRUNE_HARD=true; shift ;;
    --image) [[ -n "${2:-}" ]] || die "--image requires a value"; IMAGE="$2"; shift 2 ;;
    --tag) [[ -n "${2:-}" ]] || die "--tag requires a value"; TAG="$2"; shift 2 ;;
    --dockerfile) [[ -n "${2:-}" ]] || die "--dockerfile requires a path"; DOCKERFILE="$2"; shift 2 ;;
    --llama-ref) [[ -n "${2:-}" ]] || die "--llama-ref requires a value"; LLAMA_CPP_REF="$2"; shift 2 ;;
    --omp-ref) [[ -n "${2:-}" ]] || die "--omp-ref requires a value"; OMP_REF="$2"; shift 2 ;;
    --hermes-ref) [[ -n "${2:-}" ]] || die "--hermes-ref requires a value"; HERMES_REF="$2"; shift 2 ;;
    --image-version) [[ -n "${2:-}" ]] || die "--image-version requires a value"; IMAGE_VERSION="$2"; shift 2 ;;
    --build-date) [[ -n "${2:-}" ]] || die "--build-date requires a value"; BUILD_DATE="$2"; shift 2 ;;
    --vcs-ref) [[ -n "${2:-}" ]] || die "--vcs-ref requires a value"; VCS_REF="$2"; shift 2 ;;
    --build-arg) [[ -n "${2:-}" ]] || die "--build-arg requires KEY=VALUE"; EXTRA_BUILD_ARGS+=(--build-arg "$2"); shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown argument: $1 (use --help)" ;;
  esac
done

have_cmd docker || die "docker not found"
docker info >/dev/null 2>&1 || die "Docker is not accessible as the current user"
docker buildx version >/dev/null 2>&1 || die "docker buildx not available"
docker buildx inspect "${BUILDER}" >/dev/null 2>&1 || die "Buildx builder '${BUILDER}' not found or unavailable"
[[ -f "${DOCKERFILE}" ]] || die "Dockerfile not found: ${DOCKERFILE}"

if $LOAD && [[ "${PLATFORM}" == *,* ]]; then
  die "--load supports a single platform only"
fi

if [[ -z "${BUILD_DATE}" ]]; then
  if have_cmd git && git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    BUILD_DATE="$(git show -s --format=%cI HEAD 2>/dev/null || true)"
  fi
  [[ -n "${BUILD_DATE}" ]] || BUILD_DATE="unknown"
fi

if [[ -z "${VCS_REF}" ]]; then
  if have_cmd git && git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    VCS_REF="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
  else
    VCS_REF="unknown"
  fi
fi

cat <<SUMMARY
== Build settings ==
Image          : ${IMAGE}:${TAG}
Builder        : ${BUILDER}
Platform       : ${PLATFORM}
Push           : ${PUSH}
Load           : ${LOAD}
No-cache       : ${NO_CACHE}
Prune          : ${PRUNE}
Prune-hard     : ${PRUNE_HARD}
Dockerfile     : ${DOCKERFILE}
llama.cpp ref  : ${LLAMA_CPP_REF}
OMP ref        : ${OMP_REF}
Hermes ref     : ${HERMES_REF}
Build date     : ${BUILD_DATE}
VCS ref        : ${VCS_REF}
Image version  : ${IMAGE_VERSION}
SUMMARY

if $PRUNE_HARD; then
  echo "== Aggressive BuildKit cache prune: ${BUILDER} =="
  docker buildx prune --builder "${BUILDER}" --all --force || true
elif $PRUNE; then
  echo "== Safe Docker Engine prune =="
  docker container prune -f || true
  docker image prune -f || true
fi

show_usage() {
  echo "== Docker Engine usage =="
  docker system df || true
  echo
  echo "== BuildKit cache: ${BUILDER} =="
  docker buildx du --builder "${BUILDER}" || true
  echo
  echo "== Filesystems =="
  df -h / /var /srv/buildkit 2>/dev/null || df -h
}

show_usage

args=(
  --builder "${BUILDER}"
  -f "${DOCKERFILE}"
  --platform "${PLATFORM}"
  --build-arg "LLAMA_CPP_REF=${LLAMA_CPP_REF}"
  --build-arg "OMP_REF=${OMP_REF}"
  --build-arg "HERMES_REF=${HERMES_REF}"
  --build-arg "BUILD_DATE=${BUILD_DATE}"
  --build-arg "VCS_REF=${VCS_REF}"
  --build-arg "IMAGE_VERSION=${IMAGE_VERSION}"
  --target final
  -t "${IMAGE}:${TAG}"
)

$NO_CACHE && args+=(--no-cache)
if $PUSH; then
  args+=(--push)
elif $LOAD; then
  args+=(--load)
fi

args+=("${EXTRA_BUILD_ARGS[@]}")
args+=(.)

echo
echo "================================================================================"
echo "== Building: ${IMAGE}:${TAG}"
echo "================================================================================"
echo

docker buildx build "${args[@]}"

echo
if $PUSH; then
  echo "Build complete and pushed: ${IMAGE}:${TAG}"
elif $LOAD; then
  echo "Build complete and loaded: ${IMAGE}:${TAG}"
else
  echo "Build complete; result remains in BuildKit cache (not pushed or loaded)."
fi

show_usage

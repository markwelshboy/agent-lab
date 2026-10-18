# syntax=docker/dockerfile:1.7

ARG CUDA_VERSION=12.8.1

# -----------------------------------------------------------------------------
# llama.cpp CUDA build
# Target the two GPU families this image is intended for:
#   sm_89  - Ada (L40S / RTX 4090 class)
#   sm_120 - Blackwell (RTX PRO 6000 Blackwell class)
# -----------------------------------------------------------------------------
FROM nvidia/cuda:${CUDA_VERSION}-devel-ubuntu24.04 AS llama-builder

ARG LLAMA_CPP_REF=v0.7.0
ARG CUDA_ARCHITECTURES="89;120"

ENV DEBIAN_FRONTEND=noninteractive

RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates git cmake ninja-build build-essential pkg-config \
      libcurl4-openssl-dev \
    && rm -rf /var/lib/apt/lists/*

RUN git clone https://github.com/ggml-org/llama.cpp.git /src/llama.cpp \
    && git -C /src/llama.cpp checkout "${LLAMA_CPP_REF}" \
    && cmake -S /src/llama.cpp -B /src/llama.cpp/build -G Ninja \
         -DCMAKE_BUILD_TYPE=Release \
         -DGGML_CUDA=ON \
         -DGGML_NATIVE=OFF \
         -DLLAMA_CURL=ON \
         -DCMAKE_CUDA_ARCHITECTURES="${CUDA_ARCHITECTURES}" \
    && cmake --build /src/llama.cpp/build --target llama-server llama-cli -j"$(nproc)"

# -----------------------------------------------------------------------------
# Runtime
# -----------------------------------------------------------------------------
FROM nvidia/cuda:${CUDA_VERSION}-runtime-ubuntu24.04 AS final

ARG LLAMA_CPP_REF=v0.7.0
ARG OMP_REF=v18.12.1
ARG HERMES_REF=9e01b44dd23978f9ff40b7837467f3a9f1582130
ARG BUILD_DATE=unknown
ARG VCS_REF=unknown
ARG IMAGE_VERSION=0.1.0

LABEL org.opencontainers.image.title="agent-lab" \
      org.opencontainers.image.description="RunPod agent harness lab: llama.cpp + Hermes Agent + Oh My Pi" \
      org.opencontainers.image.source="https://github.com/markwelshboy/agent-lab" \
      org.opencontainers.image.version="${IMAGE_VERSION}" \
      org.opencontainers.image.revision="${VCS_REF}" \
      org.opencontainers.image.created="${BUILD_DATE}" \
      io.markwelshboy.agent-lab.llama-cpp-ref="${LLAMA_CPP_REF}" \
      io.markwelshboy.agent-lab.omp-ref="${OMP_REF}" \
      io.markwelshboy.agent-lab.hermes-ref="${HERMES_REF}"

ENV DEBIAN_FRONTEND=noninteractive \
    PATH="/opt/llama.cpp/bin:/root/.local/bin:${PATH}" \
    LD_LIBRARY_PATH="/opt/llama.cpp/bin:${LD_LIBRARY_PATH}" \
    HF_HOME=/workspace/hf-cache \
    HF_HUB_CACHE=/workspace/hf-cache/hub \
    HUGGINGFACE_HUB_CACHE=/workspace/hf-cache/hub \
    AGENT_LAB_HOME=/workspace/agent-lab \
    AGENT_LAB_IMAGE_ROOT=/opt/agent-lab \
    HERMES_HOME=/opt/hermes-home

RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl git git-lfs jq \
      python3 python3-venv python3-pip \
      openssh-server openssl \
      ripgrep fd-find less vim nano tmux \
      aria2 rsync unzip wget ffmpeg \
      libcurl4 libgomp1 libstdc++6 \
    && rm -rf /var/lib/apt/lists/* \
    && mkdir -p /run/sshd /workspace /opt/agent-lab /etc/ssh/sshd_config.d \
    && printf '%s\n' 'PermitRootLogin prohibit-password' 'PasswordAuthentication no' \
         > /etc/ssh/sshd_config.d/agent-lab.conf \
    && git lfs install --system

COPY --from=llama-builder /src/llama.cpp/build/bin/ /opt/llama.cpp/bin/

# OMP: use its verified prebuilt binary installer, pinned to a release.
RUN PI_INSTALL_DIR=/usr/local/bin \
    sh -c 'curl -fsSL https://omp.sh/install | sh -s -- --binary --ref "${OMP_REF}"' \
    && omp --version

# Hermes: install a pinned source revision. Browser automation and computer-use
# are intentionally omitted from the base image; the web dashboard remains usable.
RUN HERMES_HOME=/opt/hermes-home \
    sh -c 'curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash -s -- \
      --commit "${HERMES_REF}" \
      --hermes-home /opt/hermes-home \
      --dir /opt/hermes-home/hermes-agent \
      --non-interactive \
      --skip-browser \
      --skip-computer-use' \
    && test -x /root/.local/bin/hermes \
    && ln -s /root/.local/bin/hermes /usr/local/bin/hermes \
    && HERMES_HOME=/opt/hermes-home hermes --help >/dev/null

COPY profiles/ /opt/agent-lab/profiles/
COPY skills/ /opt/agent-lab/skills/
COPY src/ /opt/agent-lab/bin/
RUN chmod +x /opt/agent-lab/bin/*.sh \
    && ln -s /opt/agent-lab/bin/start-agent-lab.sh /usr/local/bin/start-agent-lab \
    && ln -s /opt/agent-lab/bin/agent-status.sh /usr/local/bin/agent-status \
    && ln -s /opt/agent-lab/bin/agent-log.sh /usr/local/bin/agent-log

WORKDIR /workspace/projects

EXPOSE 22 8000 8001 9119
ENTRYPOINT ["/usr/local/bin/start-agent-lab"]

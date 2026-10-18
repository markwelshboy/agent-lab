# agent-lab

A small, self-contained RunPod image for experimenting with local coding/agent harnesses.
It deliberately has **no ComfyUI dependency**.

The image contains:

- CUDA-enabled `llama.cpp` with an OpenAI-compatible server
- [Hermes Agent](https://github.com/NousResearch/hermes-agent)
- [Oh My Pi (OMP)](https://github.com/can1357/oh-my-pi)
- persistent model cache, harness state, sessions and shared Agent Skills under `/workspace`
- profiles for L40S (48 GB) and RTX PRO 6000 Blackwell (96 GB)

The image does **not** bake model weights. `llama-server -hf ...` downloads them into the
persistent Hugging Face cache on first use.

## Initial profiles

| `AGENT_PROFILE` | Main model | Vision | Intended GPU |
|---|---|---|---|
| `glm47-l40s` | `ggml-org/GLM-4.7-Flash-GGUF:Q4_K` | GLM-4.6V-Flash Q8 | L40S 48 GB |
| `qwen3-coder-l40s` | Qwen3-Coder-30B-A3B Q5_K_M | GLM-4.6V-Flash Q8 | L40S 48 GB |
| `qwen3-vl-l40s` | Qwen3-VL-30B-A3B Q4_K_M | main model | L40S 48 GB |
| `qwen3-coder-next-pro6000` | Qwen3-Coder-Next Q5_K_M | GLM-4.6V-Flash Q8 | RTX PRO 6000 96 GB |

All main profiles are intentionally capped at **64K context** initially. Vision uses 16K.
The default is `glm47-l40s`.

> Model refs are ordinary profile data, not part of the image. If a quant/repository changes,
> edit the profile without changing the runtime architecture.

## Build

This follows the same Buildx workflow used by the recent inference images: the
`buildkit-scratch` builder by default, deterministic Git metadata, BuildKit cache reuse,
and explicit push/load/no-push behavior.

```bash
./build_agent-lab.sh --tag dev
```

Default image:

```text
markwelshboy/agent-lab:latest
```

Useful variants:

```bash
# Build and push dev
./build_agent-lab.sh --tag dev

# Build/cache only
./build_agent-lab.sh --tag dev --no-push

# Build and load locally
./build_agent-lab.sh --tag test --load

# Override a pinned component
./build_agent-lab.sh --llama-ref v0.7.0 --tag test
```

Current default pins are intentionally explicit:

- llama.cpp: `v0.7.0`
- OMP: `v18.12.1`
- Hermes: a specific commit SHA in `build_agent-lab.sh`

## RunPod

Create a RunPod template using the built image and attach a persistent volume at
`/workspace`.

Suggested environment for the first test:

```text
AGENT_PROFILE=glm47-l40s
HF_TOKEN=<optional, but useful for HF rate limits/private repos>
PUBLIC_KEY=<your SSH public key>
```

The image exposes:

- `22` - SSH
- `8000` - main llama.cpp API (bound to loopback by default)
- `8001` - vision llama.cpp API (bound to loopback by default)
- `9119` - Hermes dashboard if you launch it

The inference APIs intentionally bind to `127.0.0.1`; the harnesses run in the same
container and do not need them exposed publicly.

On startup the image loads the selected profile, starts the main model, waits for it
to become healthy, then starts the optional vision sidecar. First boot therefore also
performs the model downloads.

Watch model download/load progress with:

```bash
agent-log main
agent-log vision
```

Check GPU/server state with:

```bash
agent-status
```

## Use Hermes

Once startup reports `agent-lab ready`:

```bash
cd /workspace/projects
hermes
```

The image writes an initial Hermes config which points the main model at
`http://127.0.0.1:8000/v1` and, when enabled, vision at
`http://127.0.0.1:8001/v1`.

Hermes state is persisted beneath `/workspace/agent-lab/hermes` while the image-owned
Hermes installation remains under `/opt`, so mounting `/workspace` cannot hide the
application itself.

### Browser UI / image upload

Hermes has a web dashboard with an embedded Chat surface. Start it locally on the pod:

```bash
hermes dashboard --host 127.0.0.1 --port 9119 --no-open
```

Then use an SSH tunnel rather than exposing an unauthenticated dashboard directly:

```bash
ssh -L 9119:127.0.0.1:9119 root@<pod-host> -p <mapped-ssh-port>
```

Open `http://127.0.0.1:9119` locally. The dashboard is the most convenient first path
for dropping screenshots/images into a Hermes conversation.

## Use OMP

```bash
cd /workspace/projects
omp
```

At first boot the image writes:

```text
/workspace/agent-lab/omp/agent/models.yml
/workspace/agent-lab/omp/agent/config.yml
```

The generated OMP config defines the local llama.cpp endpoints as keyless custom
OpenAI-compatible providers and assigns the main and vision model roles.

## Shared skills

Portable Agent Skills live persistently at:

```text
/workspace/agent-lab/shared-skills/
```

That single directory is exposed to both harnesses. Put each skill in its own directory:

```text
/workspace/agent-lab/shared-skills/
└── pod-runtime/
    └── SKILL.md
```

This lets us grow a reusable set of skills for RunPod, Git/HF workflows, your runtime
conventions, and other tasks without coupling them to either harness.

## Persistent layout

```text
/workspace/
├── hf-cache/                  # downloaded GGUFs / HF cache
├── projects/                  # repos the agent works on
└── agent-lab/
    ├── hermes/                # Hermes mutable state/sessions/config
    ├── omp/                   # OMP config/state
    ├── shared-skills/         # portable SKILL.md trees
    ├── logs/                  # llama.cpp logs
    └── run/                   # pid files
```

Image-owned code stays under `/opt`, following the same principle as the newer Comfy
images: persistent RunPod state can replace `/workspace` without masking application code.

## Next tests

The first useful comparison is deliberately controlled:

1. L40S + `glm47-l40s` + Hermes.
2. Same pod/profile, switch only the harness to OMP.
3. Same L40S, restart with `qwen3-coder-l40s`.
4. Test `qwen3-vl-l40s` to compare a single multimodal model against a vision sidecar.
5. Rent an RTX PRO 6000 and run `qwen3-coder-next-pro6000` at the same 64K context.

That separates **harness quality**, **main-model quality**, and **vision architecture** rather
than changing all three at once.

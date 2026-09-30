# Performance Tuning

Measured on the reference machine (M4 Max MacBook Pro, 128 GB unified
memory, Ollama 0.34.4, Ollama.app launchd service). Numbers marked
measured come from this machine; anything else is a documented default
from the Ollama version cited.

Why this matters for the lab: the gate's request path spends no time on
NOVA's keyword tier (~0 ms) and the semantic tier (~15 ms, MiniLM in the
gate container), then either the LLM judge (~0.1–0.6 s) or the victim's
engine (~0.7 s per warm turn) answers over the Metal seam. Both models
run on the host. The tuning question is: how are these two made
co-resident cheaply, and what stops the host from swapping?

## Ollama

### Concurrent model residency

Two models must be resident for the proof (the judge `llama3.2:3b`, and
the victim's engine `gemma4:12b-mlx`).

**Defaults allow it.** `OLLAMA_MAX_LOADED_MODELS` defaults to 3 on a
single-GPU host, and the scheduler co-loads models when memory allows.
Measured: both models resident simultaneously, 100% GPU:

```
NAME             ID            SIZE     PROCESSOR    CONTEXT
gemma4:12b-mlx   117d0d84cf2a  7.6 GB   100% GPU     262144
llama3.2:3b      a80c4f17acd5  18 GB    100% GPU     131072
```

System free memory during co-residency: 70% (25.7 GB wired by the two
models). No memory pressure on a 128 GB machine.

**The catch — context length dominates residency.** Ollama sizes the
default context by detected VRAM; on this 128 GB host it selected 131072
for the judge and 262144 for the MLX victim engine. A 3B judge at 131k
context holds ~15 GB of KV cache against ~2 GB of weights: measured 18 GB
resident at default vs 3.1 GB resident when the request pins
`options.num_ctx = 8192`. The lab's prompts are hundreds of tokens and
the judge emits yes/no verdicts — the default context is dead weight.
The MLX model ignores `options.num_ctx`; it honours a Modelfile instead
(`ollama create` with `PARAMETER num_ctx 8192`, measured 7.7 GB vs 7.8 GB
— its grouped-query attention keeps the KV cache small either way).

**Tenable choices, cheapest-first:**

1. Leave residency alone on ≥64 GB machines (both models load, 70% free
   memory measured). No tuning. This is the lab's default posture.
2. Pin context per use-case: judge at 8k via `options.num_ctx` (single
   request line, 18 GB → 3.1 GB measured), or set the Modelfile
   `PARAMETER num_ctx` for both models if you want fixed residency
   without touching gate code.
3. Cap the server default (`OLLAMA_CONTEXT_LENGTH=8192` for the
   launchd/systemd service) when other model workloads share the host —
   measured effect is the same as (2) but applies to every model.
4. Tightest resident set (smallest hosts): judge at 8192 ctx (3.1 GB) +
   gemma4 MLX variant at 8192 (7.7 GB) ≈ 10.1 GB total measured.

Not tenable: forcing eviction of one model while keeping both "loaded"
per model name — the scheduler evicts the idle one on demand (issue
#4681 behaviour); the lab avoids depending on it by keeping keep-alive
long enough for a test run instead.

### Load latency (measured)

Cold load counts when `nbdev_test` starts a fresh Ollama or a fresh
runner slot:

| Event | Measured (M4 Max) |
|---|---|
| judge cold load + short completion | ~1.4 s |
| victim cold load + short completion | ~1.15 s |
| judge warm yes/no verdict round-trip | ~0.07–0.1 s |
| victim warm 60-token answer | ~0.7 s |
| judge, ~440-token attack prompt, cold prompt cache | ~1.6–2.1 s; warm 0.1 s |

Both models co-resident changes judge latency by nothing measurable
(0.07–0.10 s warm, identical to judge-only). The Metal GPU time-slices;
it does not contend the way CPU-bound schedulers do.

### Keep-alive

The scheduler default expires models 5 minutes after their last request
(`OLLAMA_KEEP_ALIVE`, default 5m). During a click-through run, 5 minutes
between cells is borderline: the leak-proof cell (~2 min of tool loop)
plus reading time can exceed it, forcing a reload (measured cold-load-to-first-token ≈ 1.2–1.4 s
total on this machine, so a reload inside `nbdev_test` costs about a
second — tolerable).

**Tenable:** set `OLLAMA_KEEP_ALIVE=30m` while working through notebooks
or running `nbdev_test`; drop to default for overnight idle hosts. For
automation (CI runs), `-1` (infinite) is documented but inappropriate on
shared hosts — models then never release.

### Flash attention / KV-cache quantization — not for these models

`OLLAMA_FLASH_ATTENTION=1` + `OLLAMA_KV_CACHE_TYPE=q8_0` shrink KV cache
roughly 2× on architectures that support them (gemma3, qwen3, mistral3,
gpt-oss families verified in the Ollama source; the `llama` family falls
back to f16 silently unless the env var forces it, and support depends
on head-dim divisibility and the GPU runner). For the lab's two models:

- `llama3.2:3b` (llama family): KV-cache quantization is not the lever —
  at the lab's real context (≤8k) the cache is ~1.1 GB at f16; the gain
  is small and this architecture is not on the auto-enable list.
- `gemma4:12b-mlx` runs on the MLX engine: flash attention is inherent in
  MLX Metal kernels; `OLLAMA_KV_CACHE_TYPE` does not apply to the MLX
  runner.

**Tenable:** skip both variables for this lab. They matter for larger
llama.cpp-hosted models at 32k+ context — out of the lab's envelope. If
a future model upgrade (e.g. gemma → 26B) makes KV cache the leading
term, revisit then with the `ollama ps` size delta as the test.

### iogpu.wired_limit_mb — leave at default

macOS wires ~75% of unified memory for GPU by default on this host class
(0 = system default; measured current value 0). The lab's worst case
measured residency is ~26 GB on a 128 GB machine — far below the default
cap. Raising the wired limit buys nothing here and risks starving macOS
under memory pressure. **Tenable:** system default (do nothing). This
knob belongs in the doc only to say *why it is not set*.

## VM and cluster resources (NixOS / k3s)

Everything below lives in the OrbStack VM. The two pods declare:

| Pod | requests | limits |
|---|---|---|
| nova-gate (NOVA rules + Laya on CPU) | 1 CPU / 2 Gi | 3 CPU / 5 Gi |
| atlas (HTTP shell; model on the host) | 0.5 CPU / 1 Gi | 2 CPU / 3 Gi |

The gate pod's memory goes to Laya (~808 MB checkpoint) + the MiniLM
embedding model (~90 MB, pre-baked) + uvicorn overhead — 5Gi of headroom
exists because Laya's model loader is greedy at boot. The atlas pod is
small: its LLM lives on the Mac.

- **Tenable:** keep the declared requests/limits — `tofu apply` converges
  to them; the 2–5 Gi gate envelope assumes the VM gets ≥8 GB.
- **OrbStack memory:** the VM grows dynamically (OrbStack default) — on
  the reference machine the idle-converged VM shows ~1.2 GB before the
  cluster comes up. For reproducible sizing on smaller hosts, cap it with
  `orb config aisec-lab -m 16` (k3s + both pods fit in 12–16 GiB) rather
  than letting it float.
- **Not tenable:** shrinking the gate's memory request below 2 Gi — the
  Laya preload plus tokenizers spikes past 2 Gi during first boot (~808 MB
  checkpoint load plus tokenizer load); under-requesting produces
  OOMKills that read as mystery readiness failures.
- k3s disable-agent flags and traefik/servicelb removals are already in
  `nixos/configuration.nix`; they reduce the VM's baseline footprint and
  should not be re-enabled.

## CPU-side components (what NOT to tune)

- **NOVA keyword tier:** string/regex matching; no tuning surface.
- **NOVA semantics tier:** MiniLM (~90 MB) in the gate container; first
  scan warms the model from image; no further knob. If semantics scans
  feel slow, the cause is CPU contention with Laya's predictor, not
  MiniLM itself.
- **Laya (421M, CPU):** ~40 ms per prompt on M-series CPU. If the gate
  pod is CPU-throttled at 1 core, verdicts stretch toward 100 ms; that is
  what the 1-CPU request anticipates. Laya CPU cores beyond 3 do not help.

## What the lab does not need

- Multi-replica gate deployments (the lab tests a single edge; horizontal
  scaling is a production concern).
- GPU passthrough to the VM — the one-seam design exists because
  Virtualization.framework exposes no GPU; don't chase it.
- Model quantization experiments — the shipped quantizations are part of
  the lab's declared models; changing them changes test behavior.

## Quick reference — measured residency on 128 GB

| Configuration | Resident total | Notes |
|---|---|---|
| defaults (0.34.4, VRAM auto-context) | ~25.6 GB | judge 18 GB @131k + victim 7.6 GB @262k |
| judge pinned `options.num_ctx=8192` | ~10.8 GB | 3.1 GB + 7.6 GB |
| judge options-8192 + gemma Modelfile-8192 | ~10.8 GB | 3.1 GB judge + 7.7 GB gemma variant, measured |
| memory-pressure state | 70% free | both co-resident |

## References

- Ollama concurrency envs (`OLLAMA_MAX_LOADED_MODELS`, `OLLAMA_NUM_PARALLEL`,
  `OLLAMA_MAX_QUEUE`): docs.ollama.com/faq
- Context-length behavior per VRAM tier: docs.ollama.com/context-length
- `OLLAMA_FLASH_ATTENTION` / `OLLAMA_KV_CACHE_TYPE` architecture support:
  ollama/ollama#13337 (llama family falls back to f16; MLX runner
  unaffected by these flags)
- Metal wired-limit override (not needed here): `iogpu.wired_limit_mb`,
  0 = system default

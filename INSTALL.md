# Installation

The one-time setup for the lab: an OrbStack NixOS machine, native Ollama
on the Mac, and a converged NixOS declaration. Roughly ten minutes, in
three parts, and the only imperative steps in the entire lab.

## Prerequisites

- A Mac with Apple silicon, macOS 15 or later, ≥16 GB RAM (≥8 GB free for
  the VM).
- [Homebrew](https://brew.sh).
- This repository cloned locally — OrbStack shares the Mac home into the
  VM, so the clone lives at the same path on both sides.

## Part 1 — OrbStack, the lab machine, and native Ollama

All of this runs on the Mac. It is one-time; every later step is
declarative text in the repository.

```bash
brew install orbstack ollama          # the two host-side dependencies
brew services start ollama            # serves 127.0.0.1:11434
ollama pull llama3.2:3b               # ~2 GB — the NOVA LLM-tier judge
ollama pull gemma4:12b-mlx            # ~8 GB — Atlas's engine (Metal-native MLX build)
curl -s http://127.0.0.1:11434/v1/models | head -3   # sanity: both models listed
orb create nixos aisec-lab            # ~40 s; the machine whose state the flake declares
```

**Why Ollama stays native on the Mac.** An OrbStack Linux machine runs on
Apple's Virtualization.framework, which exposes no GPU/Metal to guests —
containerized inference inside the VM is CPU-only, 3–6× slower than
native on Apple Silicon (measured publicly on 8B-class models). So the
two model workloads — the LLM-tier judge (`llama3.2:3b`) and Atlas's
engine (`gemma4:12b-mlx`) — run on the Mac at full Metal speed, and the
pods reach them over OrbStack DNS at `host.orb.internal:11434`. That
host↔VM boundary is the lab's single hybrid seam; everything else is
declared, converged, and reproducible inside the NixOS machine.

**Why the models are these models.**

| Role | Model | Size | Why this one |
|---|---|---|---|
| NOVA LLM-tier judge | `llama3.2:3b` | ~2 GB | Reads intent in ~200 ms–2 s per judgement on the Mac's GPU |
| Atlas engine | `gemma4:12b-mlx` | ~8 GB | Behaves like a real assistant (multi-turn tool loop, instruction following); MLX build = native Metal speed |
| NOVA semantics tier | `all-MiniLM-L6-v2` | ~90 MB | Automatic on first scan; pre-baked into the gate image at build time |
| Laya decision model | (bundled with `laya[serve]`) | ~808 MB | Typed injection/jailbreak/benign verdict, one CPU forward pass; loads on gate-container boot |

## Part 2 — Converge the NixOS machine (the only apply step)

The machine is declared by [`flake.nix`](flake.nix) +
[`nixos/configuration.nix`](nixos/configuration.nix): k3s (single node,
traefik + servicelb off; images are built by the flake, so no docker daemon), the hosts
entry, and `KUBECONFIG` for every shell. One rebuild converges a fresh
OrbStack machine into a working lab — no setup scripts to drift.

```bash
# from the Mac; the clone is shared into the VM at the same path:
cd /path/to/ai-sec-lab
orb -m aisec-lab sudo nixos-rebuild switch --flake "/path/to/ai-sec-lab#aisec-lab"

# then enter the pinned toolchain, inside the VM:
orb -m aisec-lab
nix develop        # kubectl, helm, tofu, python, jupyter — pinned by flake.lock + uv.lock
echo $KUBECONFIG   # /etc/rancher/k3s/k3s.yaml — picked up automatically
kubectl get nodes  # expect: one Ready node, named aisec-lab
```

`nix develop` puts you in a **pre-built** environment — no pip at entry,
no network. The venv (nbdev, laya, nova-hunting[semantic], fastapi,
jupyter) comes from `uv.lock` via uv2nix; the tools (kubectl, helm, tofu,
node) from `flake.lock`. Both locks rebuild byte-identically on any
colleague's Mac, a CI runner, or inside the VM.


## How this is declarative (for non-Nix readers)

Everything the lab builds comes from a file you can read, not a command
you run. Four artifacts carry the whole toolchain:

- `flake.lock` — pins every *tool* (kubectl, helm, tofu, node, uv) to an
  exact nixpkgs revision. `nix develop` gives those exact binaries to
  any shell on any machine.
- `pyproject.toml` + `uv.lock` — pins every *Python package* (nbdev,
  laya, nova-hunting, fastapi, torch, jupyter). `nix develop` does not
  run pip: it materialises this exact locked venv, from hashes. Renovate
  bumps it; CI re-runs the contract tests against the bump.
- `nix/images.nix` — declares both *container images*: venv layer, model
  layer (MiniLM pinned to a Hugging Face revision, per-file sha256),
  app/rules layer. Docker only ever *loads* the finished stream —
  `nix run .#load-gate` — it never assembles an image from a floating
  base. The same derivation is what CI builds, so what you run is what
  was tested.
- `terraform/.terraform.lock.hcl` — pins the tofu *provider* hashes;
  CI validates against it with `init -lockfile=readonly`, so the plan
  is reproducible too (state aside, apply remains a human decision).

Nix itself is the package manager + build language; the flake is the
repo's single entry point declaring inputs (nixpkgs revision, uv2nix
stack) and outputs (devShell, images, apps, the NixOS machine). If you
have used Terraform or Kubernetes YAML, the mental model transfers:
declarative text, reviewed as diffs, converged by a tool whose only job
is to make reality match the text. A useful side effect on this Apple
Silicon setup: the declared machine needs no docker daemon — k3s runs
containerd natively and the flake streams images straight into it.

## Part 3 — Edge access (one line)

The edge is a Gateway-API NodePort pinned to **80** on the VM, not a load
balancer. OrbStack forwards VM ports to Mac localhost automatically, so
one hosts entry makes the same URL answer on both sides:

```bash
sudo sh -c 'echo "127.0.0.1  ai-sec.lab.internal" >> /etc/hosts'   # on the Mac, once
```

Inside the VM the same mapping is already declared by
`nixos/configuration.nix` — no hosts edit needed there. The k3s NodePort
range is widened to `80-32767` in the same file, which is what makes
port 80 a legal NodePort for the NGINX Gateway Fabric service.

## Verify the toolchain (test #0)

```bash
kubectl version --client && tofu version && python -c "import laya, nova; print('laya + nova importable')"
```

## Performance

Ollama residency, context, and keep-alive tuning for the two host models is
measured and documented in [PERFORMANCE.md](PERFORMANCE.md). The default
posture (no tuning) suits the reference machine; smaller hosts pin
context per use case.

## Where the notebook runs

Start Jupyter **inside the VM** (it must run where `kubectl`/`tofu` and
`KUBECONFIG` live) and browse **from the Mac** — OrbStack forwards VM
ports to Mac localhost automatically:

```bash
orb -m aisec-lab                     # VM shell
cd /path/to/ai-sec-lab && nix develop
jupyter notebook                     # or: jupyter lab
# → open http://localhost:8888 on the Mac
```

Cells execute in the VM; outputs appear in the Mac browser. (VS Code
equivalent: attach a window to the VM — `code --remote ssh-remote+aisec-lab`
— and open the repository.)

See [USAGE.md](USAGE.md) for what to run next — the notebook run order,
the acceptance tests, and free-play operation.

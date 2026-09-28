# AI-Sec Inbound Lab

A single-node AI prompt-security lab you can run on one Apple-Silicon
MacBook: a real Kubernetes edge, a real policy gate, a real LLM
application — and a real attack that gets through when the gate is
removed, then gets stopped when it isn't.

## What this lab achieves

Security demos usually stop at "the filter blocks bad strings". This lab
proves the whole loop end to end:

1. **The vulnerability is real.** Behind the gate sits Atlas, a
   deliberately vulnerable customer-support assistant running a genuine
   LLM. Asked about order 1002, Atlas reads an attacker-controlled
   "support note" as instructions and leaks its (fake) canary API key
   into a CRM sink — on that gate-free path, the leak is proven by
   assertion against the sink's log.
2. **The defense is layered, cheap-first.** Every prompt at the edge is
   judged by NOVA's four evaluator tiers — keywords (<1 ms), semantics
   (~15 ms), an LLM judge (~200 ms–2 s), then the Laya decision model
   (~40 ms CPU) — cheap tiers short-circuiting expensive ones.
3. **The gate holds.** The same attacks through the edge all return 403,
   the CRM sink gains nothing, and every decision is attributed in the
   audit log.
4. **The gate is transparent.** Benign prompts pass with real model
   answers (HTTP 200) — a gate that blocked everything would also pass
   every attack test.

Everything is open source and declarative: the machine is a NixOS flake,
the cluster is OpenTofu, the policy is `.nov` rule files in Git, and the
lab's acceptance criteria are the notebooks themselves (`nbdev_test`).

## How a request flows

```
curl ──▶ NGINX Gateway Fabric (HTTPRoute, :80)
          └─▶ nova-gate pod
                ├─ NOVA: keywords → semantics → LLM judge   (fail closed on any hit → 403 JSON)
                └─ Laya: typed verdict (injection / jailbreak / benign)
                      └─▶ Atlas pod ──▶ real LLM answer (200)
```

Atlas is also reachable from *inside* the cluster (`atlas:8080`) without
the gate — that unprotected path is what makes the proof in
`05_attacks.ipynb` possible: first show the attack really works, then show
the gate stopping it.

![big picture](assets/mmd/big-picture.svg)

*Figure M1 — Edge, policy gate, and the vulnerable app. Everything OSS, everything on one Mac.*

## The components

| Component | What it does | Where it lives | Source in this repo |
|---|---|---|---|
| NGINX Gateway Fabric | Gateway API edge — routes inbound `/v1/*` | k3s (NGF controller) | installed by the NixOS module |
| NOVA | scans every prompt, 4 evaluator tiers, fail-closed | `nova-gate` pod | [`nova-rules/*.nov`](nova-rules/) |
| Laya | 421M open-weights decision model: injection / jailbreak / benign | `nova-gate` pod | wired in by [`gate/app.py`](gate/app.py) |
| Atlas | deliberately vulnerable support assistant — real LLM, tool loop, CRM sink | `atlas` pod | [`gate/victim_app.py`](gate/victim_app.py) |
| Ollama | hosts the models at native Metal speed; the one host↔VM seam | macOS host | nothing to configure |
| OpenTofu | declares all ten cluster objects; `apply` = converged | runs in the VM | [`terraform/main.tf`](terraform/main.tf) |
| NixOS flake | declares the machine: k3s, docker, toolchain | the VM | [`flake.nix`](flake.nix) + [`nixos/configuration.nix`](nixos/configuration.nix) |

The **NOVA evaluator tiers** in detail:

| # | Type | Matches | Cost | Needs |
|---|---|---|---|---|
| 1 | keywords | exact strings + `/regex/i` | <1 ms | nothing — core engine |
| 2 | semantics | embedding cosine vs a phrase | ~15 ms | `nova-hunting[semantic]` (MiniLM, ~90 MB, auto) |
| 3 | llm | natural-language judgement question | ~200 ms–2 s | Ollama on the Mac (above) |
| 4 | decision model | Laya classifies the whole prompt | ~40 ms CPU | ships with the gate |

One `.nov` rule per tier in [`nova-rules/`](nova-rules/) — rules are
auditable text in Git, tests are the acceptance criteria. Any tier can
block; everything fails closed.

![four tiers](assets/mmd/four-tier.svg)

*Figure M7 — Cheap tiers first; the LLM judge only sees what they let through; Laya is the backstop.*

## Repo map

```
lab-repo/
├── README.md                  ← you are here
├── flake.nix                  # nixosConfigurations.aisec-lab + the pinned devShell
├── flake.lock                 # nixpkgs pin (generated: nix flake lock)
├── nixos/
│   └── configuration.nix      # k3s + docker + tools — the machine, declared
├── notebooks/                 # nbdev notebooks — the lab IS the notebook set
│   ├── 00_core.ipynb          #   constants + cluster connectivity (the front-door test)
│   ├── 01_nova_rules.ipynb    #   the .nov policy — one rule per tier, test-scanned
│   ├── 02_gate_app.ipynb      #   the gate (NOVA + Laya) + its container image
│   ├── 03_victim.ipynb        #   Atlas — the vulnerable app and its three weaknesses
│   ├── 04_deploy.ipynb        #   OpenTofu: validate → apply → rollouts → first edge probe
│   ├── 05_attacks.ipynb       #   the two-path proof: real leak (direct), real block (edge)
│   └── index.ipynb            #   nbdev_docs landing page
├── ai_sec_lab/                # nbdev export target (generated by nbdev_export)
├── gate/
│   ├── app.py                 # FastAPI gate: NOVA (4 tiers) + Laya
│   ├── Dockerfile
│   ├── victim_app.py          # Atlas: the deliberately vulnerable support app
│   └── victim_Dockerfile
├── nova-rules/                # one .nov rule per evaluator tier
├── terraform/
│   └── main.tf                # namespace → configmap → gate → victim → Gateway → HTTPRoute
├── docs/
│   └── ai-sec-implementation.md  # the full step-by-step guide (also the PDF source)
├── assets/mmd/                # mermaid sources for every figure
└── settings.ini               # nbdev config (nbs_path = notebooks)
```

## Access: how the Mac talks to the NixOS VM

Everything **inside the repo runs in the VM** — the k3s cluster, the gate
and Atlas pods, and every notebook cell that calls `kubectl`, `tofu`, or
`curl` (they run with the VM's `KUBECONFIG` and its pinned toolchain).
Everything **user-facing stays on the Mac** — your editor, your browser,
and Ollama. The bridge between the two is OrbStack, which shares the Mac
home directory into the VM at the same path (so `/path/to/lab-repo` is
*the same files*, not a copy) and forwards VM ports to Mac localhost (the edge rides on that — below).
Three ways in:

| From the Mac… | Command | What it does |
|---|---|---|
| Get a VM shell | `orb -m aisec-lab` | lands you in the VM at the same directory (OrbStack's `-m` = machine) |
| Same thing, plain ssh | `ssh aisec-lab` | OrbStack registers each machine in the Mac's ssh config |
| Run a VM command from the Mac | `orb -m aisec-lab sudo nixos-rebuild switch --flake …` | the quickstart's rebuild step |

**Where the notebook runs:** start Jupyter **inside the VM** (it must run
where `kubectl`/`tofu` live) and browse **from the Mac** — OrbStack
forwards VM ports to Mac localhost automatically:

```bash
orb -m aisec-lab                     # VM shell
cd /path/to/lab-repo && nix develop  # pinned toolchain
jupyter notebook                     # or: jupyter lab
# → open http://localhost:8888 on the Mac
```

Cells execute in the VM; outputs show in the Mac browser. (Prefer VS
Code? Attach a window to the VM — `code --remote ssh-remote+aisec-lab` —
and open the repo; same effect.)

**Where the edge answers:** the edge is a NodePort pinned to **80**, not
a load balancer — `05_attacks.ipynb` curls `ai-sec.lab.internal`, which
`/etc/hosts` maps to `127.0.0.1`. The VM's entry is declared by
`nixos/configuration.nix`, so notebook cells need nothing. On the Mac,
one one-time line — then OrbStack's automatic port-forwarding of VM
port 80 does the rest:

```bash
sudo sh -c 'echo "127.0.0.1  ai-sec.lab.internal" >> /etc/hosts'   # on the Mac, once
```

After that the same URL answers from both sides — no tunnel, no LB. (The
k3s node-port range is widened to `80-32767` in `nixos/configuration.nix`
so port 80 is a valid NodePort for the NGF service.)

## Quickstart (the whole lab in ~8 commands)

On the Mac (one-time, imperative — the only imperative steps in the
entire lab):

```bash
brew install orbstack ollama          # if not already present
brew services start ollama && ollama pull llama3.2:3b
orb create nixos aisec-lab            # the lab machine
```

Bring the machine to the declared state (from the Mac; the repo is shared
into the VM at the same path by OrbStack):

```bash
orb -m aisec-lab sudo nixos-rebuild switch \
    --flake "/path/to/lab-repo#aisec-lab"   # the repo, as OrbStack shares it into the VM
```

Then, inside the VM shell (`orb -m aisec-lab`):

```bash
nix develop                            # pinned lab toolchain (installs jupyter too)
nbdev_test --n_workers 0               # every acceptance test, in order (serial — one shared cluster)
```

`nbdev_test` exits 0 only when: cluster reachable → all four NOVA rule
files parse and each evaluator tier catches its target → tofu validates
and applies → workloads live → benign 200 / every attack category 403 →
CRM sink unchanged through the gate → audit trail present. That is the
lab, passing.

To **click through by hand**: open the notebooks in order
(`00_core` → `01_nova_rules` → `02_gate_app` → `03_victim` → `04_deploy`
→ `05_attacks`). Every cell narrates why it exists, what it does, and
what success looks like before you run it, and each notebook ends by
pointing at the next.

**Free play.** The scripted attacks are the floor, not the ceiling. The
rules are a mounted ConfigMap, so you can fire your own undocumented
prompts at the live gate and iterate on policy without rebuilding
anything: the scratchpad cells at the end of `05_attacks.ipynb` (marked
`#| notest`, skipped by `nbdev_test`) fire free-form prompts via
`try_prompt`, report which engine/tier blocked, and the
edit-ConfigMap → `kubectl rollout restart` → re-fire loop turns your own
discoveries into committed rules.

Show-and-tell: `nbdev_docs` → browsable site of code + prose + prompts +
diagrams.

## Models (one-time, ~3 GB total)

| Tier | Model | Install | Size |
|---|---|---|---|
| keywords | none | built into the engine | — |
| semantics | `all-MiniLM-L6-v2` | automatic on first scan (pre-baked into the gate image) | ~90 MB |
| llm | `llama3.2:3b` | `brew install ollama && brew services start ollama && ollama pull llama3.2:3b` | ~2 GB |
| victim engine | `gemma4:12b-mlx` | `ollama pull gemma4:12b-mlx` (same Ollama install) | ~8 GB |
| decision | Laya | automatic on gate-container boot | ~808 MB |

## Why these choices

Every component here earned its place. The short version:

**Why Nix + NixOS.** A security lab is only convincing if the next person
reproduces it exactly. Nix pins the entire toolchain (kubectl, helm, tofu,
python, node — `flake.lock`), and the NixOS module declares the *machine*
itself: k3s (via `services.k3s`, not a GUI toggle — the cluster's
existence is reviewable text in Git like everything else), docker for
image builds, `KUBECONFIG`, the hosts entries. One `nixos-rebuild switch`
converges a fresh OrbStack VM into a working lab; the same `flake.lock`
gives any colleague or CI runner a byte-identical environment. No setup
scripts to drift, no "works on my machine".

**Why NGINX Gateway Fabric at the edge — not an EPP / InferencePool.**
Prompt screening is a security control, and a security control must fail
closed. Gateway-API inference extensions (EPP, InferencePool) are
load-balancer machinery and default to `failureMode: FailOpen` — if the
pool is unavailable, traffic flows *past* the check. Screening inside the
pool also means the prompt has already entered the cluster: flow
established, metrics exposed, session state spent. NGF at the edge blocks
with a 403 before any of that exists, and keeps policy decoupled from the
serving path's version churn — the same reason a WAF sits in front of the
app, not inside it.

![why the edge](assets/mmd/why-edge-not-epp.svg)

*Figure M4 — Fail-closed edge enforcement beats in-pool screening.*

**Why a vulnerable AI app, not a simulator.** A simulator cannot be
coaxed, so behind one the lab could only prove *screening* — that the
gate blocks strings. Atlas is a real support assistant (real LLM chat +
tool calls through the Metal seam — `03_victim.ipynb` walks its three
weaknesses), so the tests prove the leak on a direct path before proving
the gate blocks it. The attack is real; the defense then has to be.

**Why these models.** Each one is the smallest tool that does its job:

- `llama3.2:3b` — the NOVA LLM-tier judge: small enough that judging a
  prompt costs ~200 ms–2 s on the Mac's GPU, good enough to read intent.
- `gemma4:12b-mlx` — the victim's engine: big enough to behave like a
  real assistant (multi-turn tool loop, instruction following), ~8 GB so
  the whole lab still fits on one Mac; MLX build = native Metal speed.
- Laya — a 421M-parameter open-weights classifier: a typed
  injection/jailbreak/benign verdict in one cheap forward pass, catching
  shapes the rule tiers never listed.
- `all-MiniLM-L6-v2` — the ~90 MB embedding model behind the semantics
  tier; tiny, and pre-baked into the gate image so first use is warm.

Ollama stays native on macOS — the one hybrid seam (the GPU fact below).
The NixOS module stays portable to any Linux host; if GPU-in-VM ever
becomes a hard requirement, Podman + krunkit is the documented escape
hatch.

**Why notebooks / nbdev.** I closely follow Jeremy Howard and his work
and wanted to give nbdev a try after watching his ["I Like Notebooks"
talk](https://www.youtube.com/watch?v=9Q6sLbz37gk). It fits this lab
unusually well: code, tests, prompts, and prose in one place —
`nbdev_test` is the lab passing; every cell narrates why it exists before
you run it; `nbdev_docs` publishes the whole thing as a browsable site.
The notebooks are the source of truth; `gate/`, `terraform/`, and
`nova-rules/` are generated from them and committed, so artifacts and
notebooks can never drift — and the artifacts themselves stay
runtime-agnostic: moving hosts changes where they run, not what they are.

## Why this layout: the one design fact

**An OrbStack Linux VM cannot see the Apple GPU.** OrbStack runs Linux
machines on Apple's Virtualization.framework, which exposes no GPU/Metal to
guests — containerized inference in the VM is CPU-only, 3–6× slower than
native on Apple Silicon (measured publicly on 8B-class models). So the lab
is hybrid, with exactly one seam:

- **macOS host (native, Metal):** Ollama — the LLM-tier judge (`llama3.2:3b`)
  and the victim's engine (`gemma4:12b-mlx`), at full GPU speed. Nothing
  else lives on the Mac.
- **NixOS VM (`aisec-lab`):** k3s cluster, NGINX Gateway Fabric edge, the
  nova-gate pod (NOVA + Laya, CPU), the Atlas victim app, and the whole lab
  toolchain — all declared in `flake.nix` + `nixos/configuration.nix`.

The gate pod reaches native Ollama over `host.orb.internal:11434`
(OrbStack DNS, OpenAI-compatible endpoint). Everything stays on the
MacBook; no cloud keys anywhere — which is exactly the property a security
control should have.

## Honest limits

- Laya zero-shot is weak — fine-tune for production (the project ships a
  Kaggle fine-tuning notebook). Its verdicts are probabilities, not
  verdicts; benchmark the judge on your own corpus before trusting
  thresholds.
- Latency stacks by tier — keywords <1 ms, semantics ~15 ms, the LLM tier
  adds ~200 ms–2 s per judged prompt. That is why the condition logic
  short-circuits: cheap stages run first.
- The victim's canary key is fake by design, but it models the real
  failure: an assistant that carries credentials in its system prompt and
  can be steered into writing them to an integrated sink.
- Model-level resistance is probabilistic — a 12B aligned model may
  sometimes refuse the poisoned note. The gate's fail-closed verdict is
  not probabilistic; that asymmetry is the point of the lab.
- **The gate scans the prompt channel only.** Atlas's poisoned RAG note
  is an *indirect* injection — attacker-controlled text arriving in a
  tool result, not a user prompt — so prompt screening cannot see it.
  That is why the direct-path proof exists (05_attacks), and why a
  production gate must also screen tool/RAG traffic: out of scope here,
  stated so the boundary is explicit.
- Nova/Laya versions move fast — pin them in `flake.nix` /
  `requirements-dev.txt` and bump deliberately between lab runs, never
  mid-run.
- The VM's k3s runs with default sandboxing; the gate pod's 2–5Gi memory
  limits assume the VM gets ≥8 GB.

## Tear-down / re-run

```bash
cd terraform && tofu destroy -auto-approve   # removes everything it created
docker rmi ai-sec-lab/laya-gate:1.0.0 ai-sec-lab/atlas-victim:1.0.0
nix store gc                                  # reclaim the Nix store

# full teardown of the lab machine itself (from the Mac):
#   orb delete aisec-lab                         # the VM is disposable; the flake rebuilds it
```

## Status

- [x] GPU/Metal decision made and documented (hybrid, Ollama stays native)
- [x] NixOS configuration drafted (k3s single-node, tools, docker)
- [x] Proven lab artifacts: 4× .nov rules, gate app, victim app, tofu config, attack corpus
- [x] nbdev notebooks: click-through narration in every cell, run order = file order
- [ ] VM smoke test on the live `aisec-lab` machine (k3s up, image build, apply)

## License

MIT — see [LICENSE](LICENSE).
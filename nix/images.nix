# Container images built by Nix, not by Docker. Docker (and k3s/containerd)
# become pure *runners*: `nix run .#gate-image` streams the image tarball to
# stdout, `docker load` (or `k3s ctr images import`) materialises it.
#
# Layers: [venv] + [model cache] + [runtime config: app source + rules]. The
# venv layer is the big one (~700MB with torch); the model layer is ~90MB
# (MiniLM weights); app/rules land in a few KB — so a rule or app.py change
# refreshes KBs, not GBs.
{ pkgs, lib, pythonSet, workspaceDeps, gateAppSrc, victimAppSrc, rulesDir }:

let
  # ---- The semantic model, pinned to a commit ------------------------------
  # The old gate Dockerfile ran `SentenceTransformer('all-MiniLM-L6-v2')` at
  # docker-build time: whatever huggingface.co served that minute became the
  # artifact, unverified. Here every file comes from the resolve/<rev>
  # endpoint, hash-verified at build time — the lab's own supply-chain
  # discipline, applied to itself.
  miniLmRev = "1110a243fdf4706b3f48f1d95db1a4f5529b4d41";
  hubDir = "models--sentence-transformers--all-MiniLM-L6-v2";

  fetchMinilmFile = name: hash: pkgs.fetchurl {
    url = "https://huggingface.co/sentence-transformers/all-MiniLM-L6-v2/resolve/${miniLmRev}/${name}";
    inherit hash;
  };

  # The HF hub cache layout (HF_HUB_CACHE=/models/hf-cache inside the image):
  # snapshots/<rev>/<files> + refs/main, so sentence-transformers loads the
  # exact pinned revision with no hub round-trip on first scan.
  miniLmModel = pkgs.linkFarm "minilm-l6-v2-hf-cache-${builtins.substring 0 7 miniLmRev}" [
    { name = "hf-cache/hub/${hubDir}/refs/main"; path = pkgs.writeText "minilm-ref" miniLmRev; }
    { name = "hf-cache/hub/${hubDir}/snapshots/${miniLmRev}/config.json"; path = fetchMinilmFile "config.json" "sha256-lT+cDUY0hrEKaHHML9WfIjsscBhPSYFefvvKtdiQi0E="; }
    { name = "hf-cache/hub/${hubDir}/snapshots/${miniLmRev}/model.safetensors"; path = fetchMinilmFile "model.safetensors" "sha256-U6pRFy0ULInZASzOFa5NbMDKaJWJURQ3nKy0+rEo2ds="; }
    { name = "hf-cache/hub/${hubDir}/snapshots/${miniLmRev}/tokenizer.json"; path = fetchMinilmFile "tokenizer.json" "sha256-vlDDYo8r9bteOn8XsfdGEbJWGjon7qsF5aow9BFXIDc="; }
    { name = "hf-cache/hub/${hubDir}/snapshots/${miniLmRev}/tokenizer_config.json"; path = fetchMinilmFile "tokenizer_config.json" "sha256-rLknaegZWqvSm3shN6nm1uJcR2pPFapDVcIzQmxhV2s="; }
    { name = "hf-cache/hub/${hubDir}/snapshots/${miniLmRev}/vocab.txt"; path = fetchMinilmFile "vocab.txt" "sha256-B+ztN1zsFE0nyQAkHz4zlHjeyVj5L928VR8pXJkgOKM="; }
    { name = "hf-cache/hub/${hubDir}/snapshots/${miniLmRev}/special_tokens_map.json"; path = fetchMinilmFile "special_tokens_map.json" "sha256-MD30WgNgnk6tBLw9wVNtCrGbU1jbaFtvPaEj0F7CAOM="; }
    { name = "hf-cache/hub/${hubDir}/snapshots/${miniLmRev}/config_sentence_transformers.json"; path = fetchMinilmFile "config_sentence_transformers.json" "sha256-Bhyp05Zh1sbW3luif3mhzVdw6iR/jUZBKmikmNxayfM="; }
    { name = "hf-cache/hub/${hubDir}/snapshots/${miniLmRev}/modules.json"; path = fetchMinilmFile "modules.json" "sha256-hOQMjgBsmx1sEi4Cy6mwJFgSC1+wyHt0bEHgIHz2Qs8="; }
    { name = "hf-cache/hub/${hubDir}/snapshots/${miniLmRev}/1_Pooling/config.json"; path = fetchMinilmFile "1_Pooling/config.json" "sha256-S+RQ3eOwJzu5eHY3z70o/gSnumq502rEjpKxHjUP/CM="; }
  ];

  # ---- Image venv ----------------------------------------------------------
  # deps.default: same uv.lock contract, no jupyterlab — the gate/victim
  # images carry the run-time surface only (the devShell builds deps.all).
  imageVirtualenv = pythonSet.mkVirtualEnv "ai-sec-lab-venv-runtime" workspaceDeps.default;

  # ---- Common image configuration ------------------------------------------
  commonImageArgs = {
    contents = [ imageVirtualenv ];
  };

  gateImage = pkgs.dockerTools.streamLayeredImage (commonImageArgs // {
    name = "ai-sec-lab/laya-gate";
    tag = "1.1.0";
    contents = commonImageArgs.contents ++ [ miniLmModel ];
    extraCommands = ''
      # The audited .nov rules are baked into the image itself (rule
      # provenance: what you pull is what was CI-tested). At runtime k8s
      # mounts the ConfigMap at /rules and compose mounts nova-rules/ there;
      # NOVA_RULES_DIR=/rules stays the live seam (see terraform/main.tf).
      mkdir -p etc/nova-rules app
      ${lib.concatStringsSep "\n" (lib.mapAttrsToList
        (name: _type: "cp '${rulesDir}/${name}' etc/nova-rules/${name}")
        (builtins.readDir rulesDir))}
      cp ${gateAppSrc} app/app.py
    '';
    config = {
      Env = [
        "PYTHONUNBUFFERED=1"
        "LAYA_HOME=/models"
        "HF_HUB_CACHE=/models/hf-cache"
        "NOVA_RULES_DIR=/rules"
        "TRANSFORMERS_OFFLINE=0"
      ];
      Volumes = { "/models" = { }; };
      ExposedPorts = { "8000/tcp" = { }; };
      Cmd = [ "${imageVirtualenv}/bin/uvicorn" "app:app" "--host" "0.0.0.0" "--port" "8000" ];
      WorkingDir = "/app";
    };
  });

  victimImage = pkgs.dockerTools.streamLayeredImage (commonImageArgs // {
    name = "ai-sec-lab/atlas-victim";
    tag = "1.1.0";
    extraCommands = ''
      mkdir -p app
      cp ${victimAppSrc} app/victim_app.py
    '';
    config = {
      Env = [ "PYTHONUNBUFFERED=1" ];
      ExposedPorts = { "8080/tcp" = { }; };
      Cmd = [ "${imageVirtualenv}/bin/uvicorn" "victim_app:app" "--host" "0.0.0.0" "--port" "8080" ];
      WorkingDir = "/app";
    };
  });
in
{
  gate-image = gateImage;
  victim-image = victimImage;
}
terraform {
  required_version = ">= 1.7"
  required_providers {
    kubernetes = { source = "hashicorp/kubernetes", version = "~> 2.31" }
  }
}
provider "kubernetes" { config_path = "~/.kube/config" }

resource "kubernetes_namespace" "lab" {
  metadata { name = "ai-sec" }
}

resource "kubernetes_config_map" "nova_rules" {
  metadata { name = "nova-rules"; namespace = kubernetes_namespace.lab.metadata[0].name }
  data = {
    "jailbreak.nov"    = file("../nova-rules/jailbreak.nov")
    "injection.nov"    = file("../nova-rules/injection.nov")
    "exfil-llm.nov"    = file("../nova-rules/exfil-llm.nov")
    "full-spectrum.nov" = file("../nova-rules/full-spectrum.nov")
  }
}

# The gate: NOVA rules + Laya decision model. Every request from the edge
# hits this first; it forwards only clean prompts to the victim app.
resource "kubernetes_deployment" "nova_gate" {
  metadata { name = "nova-gate"; namespace = kubernetes_namespace.lab.metadata[0].name }
  spec {
    replicas = 1
    selector { match_labels = { app = "nova-gate" } }
    template {
      metadata { labels = { app = "nova-gate" } }
      spec {
        container {
          name  = "gate"
          image = "ai-sec-lab/laya-gate:1.0.0"
          port { container_port = 8000 }
          env {
            name  = "NOVA_RULES_DIR"; value = "/rules"
          }
          env {
            name  = "SIM_UPSTREAM"
            value = "http://atlas.ai-sec.svc.cluster.local:8080"   # the victim app
          }
          env {
            name  = "OLLAMA_URL"
            value = "http://host.orb.internal:11434/v1"   # Ollama native on the macOS host (OrbStack DNS)
          }
          env {
            name  = "NOVA_LLM_MODEL"
            value = "llama3.2:3b"
          }
          resources {
            requests = { cpu = "1", memory = "2Gi" }
            limits   = { cpu = "3", memory = "5Gi" }
          }
          volume_mount { name = "rules"; mount_path = "/rules"; read_only = true }
          readiness_probe {
            http_get { path = "/health"; port = 8000 }
            initial_delay_seconds = 30
          }
        }
        volume {
          name = "rules"
          config_map { name = kubernetes_config_map.nova_rules.metadata[0].name }
        }
      }
    }
  }
}

resource "kubernetes_service" "nova" {
  metadata { name = "nova-gate"; namespace = kubernetes_namespace.lab.metadata[0].name }
  spec {
    selector = { app = "nova-gate" }
    port { port = 8000; target_port = 8000 }
  }
}

# The VICTIM: a deliberately vulnerable support assistant (real LLM via the
# Metal Ollama seam). Deliberately reachable BOTH ways in the lab:
#   * edge path  — through nova-gate (protected)
#   * direct path — atlas:8080 inside the cluster (unprotected), used by
#     05_attacks.ipynb to prove the leak is real before the gate blocks it.
resource "kubernetes_deployment" "atlas" {
  metadata { name = "atlas"; namespace = kubernetes_namespace.lab.metadata[0].name }
  spec {
    replicas = 1
    selector { match_labels = { app = "atlas" } }
    template {
      metadata { labels = { app = "atlas" } }
      spec {
        container {
          name  = "atlas"
          image = "ai-sec-lab/atlas-victim:1.0.0"
          port { container_port = 8080 }
          env {
            name  = "OLLAMA_URL"
            value = "http://host.orb.internal:11434/v1"   # same Metal seam as the gate
          }
          env {
            name  = "VICTIM_MODEL"
            value = "gemma4:12b-mlx"                     # real engine; verified tool-calling
          }
          resources {
            requests = { cpu = "500m", memory = "1Gi" }
            limits   = { cpu = "2", memory = "3Gi" }
          }
          readiness_probe {
            http_get { path = "/health"; port = 8080 }
            initial_delay_seconds = 10
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "atlas" {
  metadata { name = "atlas"; namespace = kubernetes_namespace.lab.metadata[0].name }
  spec {
    selector = { app = "atlas" }
    port { port = 8080; target_port = 8080 }
  }
}

# Gateway API CRDs (if the cluster lacks them):
#   kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.1.0/standard-install.yaml
# Edge: NGINX Gateway Fabric (OSS, F5) — arm64 images, containerd runtime (no docker daemon needed):
#   kubectl apply -f https://raw.githubusercontent.com/nginx/nginx-gateway-fabric/v2.0.0/deploy/crds.yaml
#   kubectl apply -f https://raw.githubusercontent.com/nginx/nginx-gateway-fabric/v2.0.0/deploy/default/deploy.yaml
# (helm is the path that pins the port; chart = oci://ghcr.io/nginx/charts/nginx-gateway-fabric)
# Pin the edge to port 80 (k3s node-port range is widened to 80-32767 in configuration.nix):
#   helm install ngf oci://ghcr.io/nginx/charts/nginx-gateway-fabric -n nginx-gateway --create-namespace \
#     --set nginx.service.type=NodePort \
#     --set-json 'nginx.service.nodePorts=[{"port":80,"listenerPort":80}]'
# Registers gatewayClassName "nginx".
#
# Reaching the edge (no LB, no tunnel — the pinned NodePort makes it direct):
#   * in the VM (the notebooks): /etc/hosts maps ai-sec.lab.internal → 127.0.0.1
#     (declared by nixos/configuration.nix), so curl → NGF on NodePort 80.
#   * on the Mac: OrbStack forwards the VM's port 80 to Mac localhost, so the
#     same URL works from the Mac once /etc/hosts maps the name to 127.0.0.1.
#   The notebooks default to a NodePort + hosts-file access model — no LB emulation required.

resource "kubernetes_manifest" "gateway" {
  manifest = {
    apiVersion = "gateway.networking.k8s.io/v1"
    kind       = "Gateway"
    metadata = { name = "ai-sec-edge"; namespace = kubernetes_namespace.lab.metadata[0].name }
    spec = {
      gatewayClassName = "nginx"
      listeners = [{
        name = "http"; protocol = "HTTP"; port = 80
        allowedRoutes = { namespaces = { from = "Same" } }
      }]
    }
  }
}

resource "kubernetes_manifest" "route" {
  manifest = {
    apiVersion = "gateway.networking.k8s.io/v1"
    kind       = "HTTPRoute"
    metadata = { name = "ai-sec-inbound"; namespace = kubernetes_namespace.lab.metadata[0].name }
    spec = {
      parentRefs = [{ name = "ai-sec-edge" }]
      hostnames  = ["ai-sec.lab.internal"]
      rules = [{
        matches = [{ path = { type = "PathPrefix", value = "/v1" } }]
        backendRefs = [
          { name = "nova-gate", port = 8000, weight = 1 },
          { name = "atlas",     port = 8080, weight = 0 },
        ]
      }]
    }
  }
}

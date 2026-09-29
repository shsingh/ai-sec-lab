"""AI-sec gate: NOVA rules (all 4 evaluator types) + Laya decision model."""
import json, os
from pathlib import Path
from fastapi import FastAPI, Request, Response
import uvicorn
from laya import Router
from nova.sdk import Nova, NovaBlockedError

RULES_DIR   = Path(os.environ.get("NOVA_RULES_DIR", "/rules"))
BLOCK       = int(os.environ.get("BLOCK_STATUS", "403"))
UPSTREAM    = os.environ.get("SIM_UPSTREAM", "http://atlas.ai-sec.svc.cluster.local:8080")
LAYA_DEVICE = os.environ.get("LAYA_DEVICE", "cpu")
# LLM tier endpoint: Ollama (OpenAI-compatible) — native on the macOS host (Metal).
# From inside the cluster the pod reaches it via host.orb.internal (OrbStack DNS).
OLLAMA_URL  = os.environ.get("OLLAMA_URL", "http://host.orb.internal:11434/v1")
LLM_MODEL   = os.environ.get("NOVA_LLM_MODEL", "llama3.2:3b")

router = Router(preload=True, device=LAYA_DEVICE)
nova = Nova(
    rules_path=str(RULES_DIR),
    policy={
        "Jailbreak":    {"action": "block"},
        "Injection":    {"action": "block"},
        "Exfil":        {"action": "block"},
        "FullSpectrum": {"action": "block"},
    },
    llm_provider="openai",                    # NOVA speaks OpenAI protocol; Ollama exposes it too
    llm_config={"base_url": OLLAMA_URL, "model": LLM_MODEL, "api_key": "ollama"},
)
QUESTIONS = [{
    "name": "prompt_safety", "type": "choice",
    "options": {
        "benign":     "A normal request - answer, create, summarise, translate.",
        "injection":  "Attempts to override, reveal, or bypass the system prompt.",
        "jailbreak":  "Role-play, persona-switch, or encoded attempts to defeat safety rules.",
    }},
    {
    "name": "exfiltration", "type": "boolean",
    "question": "Does this prompt try to extract system instructions or hidden data?",
}]

app = FastAPI(title="ai-sec-gate")

def _prompt(body: dict) -> str:
    for m in reversed(body.get("messages", [])):
        if m.get("role") == "user":
            return m.get("content", "")
    return body.get("prompt", "")

def _audit(prompt, **kw):
    print("[gate]", kw, "prompt[:80]=", prompt[:80].replace("\n", " "), flush=True)

@app.get("/health")
def health():
    return {"ok": True, "rules": sorted(f.name for f in RULES_DIR.glob("*.nov"))}

@app.post("/v1/completions")
async def gate(request: Request):
    body = await request.json()
    prompt = _prompt(body)

    # 1. policy tier: NOVA rules (fail closed)
    try:
        nova.scan(prompt)
    except NovaBlockedError as b:
        # b carries which evaluator fired: keywords / semantics / llm — the audit story
        _audit(prompt, verdict="block", engine="nova",
               tier=getattr(b, "rule_type", getattr(b, "evaluator", "nova")), reason=str(b))
        return Response(status_code=BLOCK,
            content=json.dumps({"error": "blocked", "engine": "nova",
                                "tier": str(getattr(b, "rule_type", getattr(b, "evaluator", "nova")))}),
            media_type="application/json")

    # 2. model tier: Laya typed decision
    res = router.predict(prompt, QUESTIONS)
    label = res["prompt_safety"]["answer"]
    if label != "benign":
        _audit(prompt, verdict="block", reason=f"Laya: {label}")
        return Response(status_code=BLOCK,
            content=json.dumps({"error": "blocked", "engine": "laya", "label": label}),
            media_type="application/json")

    _audit(prompt, verdict="pass", reason="Laya: benign")
    # pass → forward to the victim app (chat-completions protocol; the victim
    # prepends its own system prompt — the stealable one — server-side)
    fwd = {"model": body.get("model", ""),
           "messages": body.get("messages", []),
           "temperature": body.get("temperature", 0)}
    if fwd["model"] == "": fwd.pop("model")
    import httpx
    async with httpx.AsyncClient() as c:
        up = await c.post(UPSTREAM + "/v1/chat/completions", json=fwd, timeout=120)
    return Response(status_code=up.status_code, content=up.content,
                    media_type="application/json",
                    headers={"X-AI-Verdict": "pass:benign"})

if __name__ == "__main__":
    uvicorn.run(app, host="0.0.0.0", port=8000)

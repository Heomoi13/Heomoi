# cli-orchestrator

Deterministic orchestration engine for **KJCLIController** gateway.

**Architecture C — observe-replan loop with injected Planner.** The engine owns the loop and all safety guardrails. Planning intelligence lives in the `Planner` object injected by the caller (Hermes or CLI). Engine never calls any LLM directly.

Delegates task steps to local AI CLIs (`claude`, `gemini`/`agy`, `openai`/`codex`) via an OpenAI-compatible gateway, preserving cross-step context in `AGENT_LOG.md`.

## Install

```bash
pip install -e ".[dev]"
```

Exposes two identical entrypoints: `cli-orchestrator` and `clio`.

## Usage

```bash
# List provider statuses
clio providers

# Run a full plan via StaticPlanner (JSON file)
clio run --workspace . --plan plan.json

# Execute exactly one step (no loop)
clio step --model claude --workspace . --prompt "Implement parser module"

# Cross-check / review mode (same prompt to multiple models)
clio review --models claude,openai --prompt "Review this approach"

# Output raw JSON (for scripting)
clio run --workspace . --plan plan.json --json
```

### Plan file format

```json
[
  {"model": "claude",  "prompt": "Design the data model"},
  {"model": "openai",  "prompt": "Implement the data model per AGENT_LOG.md"},
  {"model": "gemini",  "prompt": "Review implementation for consistency"}
]
```

## Configuration

Priority: **CLI flag > env var > config file > default**

| Key | Default | Env var |
|---|---|---|
| `base_url` | `http://127.0.0.1:8080` | `CLI_CONTROLLER_URL` |
| `token` | *(required)* | `CLI_CONTROLLER_TOKEN` |
| `default_timeout` | `120` | `CLIO_DEFAULT_TIMEOUT` |
| `gemini_timeout` | `300` | `CLIO_GEMINI_TIMEOUT` |
| `retries` | `2` | `CLIO_RETRIES` |
| `max_parallel` | `1` | `CLIO_MAX_PARALLEL` |
| `max_steps` | `12` | `CLIO_MAX_STEPS` |
| `max_delegations` | `20` | `CLIO_MAX_DELEGATIONS` |
| `oscillation_limit` | `2` | `CLIO_OSCILLATION_LIMIT` |
| `needs_info_limit` | `2` | `CLIO_NEEDS_INFO_LIMIT` |

## Library API (for Hermes skill)

```python
from cli_orchestrator import Orchestrator, StaticPlanner, Step, check_providers
from cli_orchestrator.config import load_config

config = load_config()  # reads env vars
orch = Orchestrator(workspace="/path/to/project", config=config)

# Run with StaticPlanner (fixed list of steps)
steps = [Step("claude", "Design the module"), Step("openai", "Implement it")]
result = orch.run(StaticPlanner(steps))
# result.status → "done" | "escalated"
# result.history → list[StepResult]
# result.escalation_reason → set when status == "escalated"

# Hermes provides its own ModelPlanner that calls a cheap/fast model:
class MyModelPlanner:
    def next_step(self, ledger_context: str, history: list):
        # call Groq/DeepSeek with ledger_context to decide next Step/Done/Escalate
        ...

result = orch.run(MyModelPlanner())

# Single step (no loop)
step_result = orch.run_step(model="claude", prompt="Do X")

# Provider health
statuses = check_providers(config)
```

Returns pure dataclasses; **no stdout** when used as a library.

## Architecture

```
┌─────────────────────────────────────────────────────┐
│  Hermes (caller)                                    │
│  - Natural language input                           │
│  - Provides ModelPlanner (cheap model decides steps)│
│  - Handles Escalate decisions                       │
└──────────────────┬──────────────────────────────────┘
                   │ orch.run(planner)
┌──────────────────▼──────────────────────────────────┐
│  cli-orchestrator engine (this project)             │
│  - Observe-replan loop (deterministic)              │
│  - Safety guardrails (max_steps, max_delegations,   │
│    oscillation, needs-info — all pure code)         │
│  - Calls planner.next_step() each iteration         │
│  - Delegates Step to gateway                        │
│  - Maintains AGENT_LOG.md ledger                    │
│  - NEVER calls LLM itself                           │
└──────────────────┬──────────────────────────────────┘
                   │ POST /v1/chat/completions
┌──────────────────▼──────────────────────────────────┐
│  KJCLIController gateway                            │
│  - Routes to: claude | gemini/agy | openai/codex   │
│  - Subscription quota (not token-metered)           │
└─────────────────────────────────────────────────────┘
```

## Running tests

```bash
pytest tests/ -v   # 57 tests, all deterministic (no real gateway needed)
```

## Server Deployment

### Gateway setup

1. Start KJCLIController bound to `127.0.0.1` with a strong random token:
   ```
   ./kjcli-controller --bind 127.0.0.1:8080 --token <random-strong-token>
   ```
2. Export the token:
   ```bash
   export CLI_CONTROLLER_TOKEN=<random-strong-token>
   ```

### CLI authentication (headless OAuth)

Each CLI must be authenticated **on the server** — the gateway spawns them locally:

- **Claude**: `claude auth` → copy the OAuth URL, open in local browser via SSH port-forward, paste code back.
- **Gemini / agy**: similar OAuth flow. If you installed Google's official Gemini CLI (binary name `gemini`), create a symlink so the gateway finds it:
  ```bash
  ln -s $(which gemini) ~/.local/bin/agy
  ```
  Verify flags accepted by `agy` match what KJCLIController's `gemini.rs` adapter expects. If they differ, adjust the adapter.
- **OpenAI / Codex**: `codex auth` or set `OPENAI_API_KEY`.

### Node.js requirement

Both `claude` and `gemini` CLIs require Node.js:
```bash
curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
sudo apt install -y nodejs
```

### Optional: systemd unit for gateway auto-restart

```ini
# /etc/systemd/system/kjcli-gateway.service
[Unit]
Description=KJCLIController gateway
After=network.target

[Service]
ExecStart=/usr/local/bin/kjcli-controller --bind 127.0.0.1:8080 --token-file /etc/kjcli/token
Restart=on-failure
RestartSec=5
User=kjcli

[Install]
WantedBy=multi-user.target
```

> **Note**: Do NOT create a systemd unit for `cli-orchestrator` — the engine is not a daemon. It runs one-shot and exits.

## Design principles

- **Engine never plans**: all planning intelligence lives in `Planner`. `StaticPlanner` for known tasks; inject `ModelPlanner` from Hermes for open-ended tasks.
- **Cost split**: planner uses a cheap/fast model (metered, small tokens); execution uses CLI subscription quota (heavy tokens, already paid).
- **Deterministic safety**: max_steps, max_delegations, oscillation detection, needs-info limit — all pure code, all testable without any model.
- **Zero third-party runtime deps**: stdlib only.
- **Token safety**: token never logged, never hardcoded.
- **Portable paths**: all paths in prompts and `AGENT_LOG.md` relative to workspace.

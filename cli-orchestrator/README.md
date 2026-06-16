# cli-orchestrator

Deterministic orchestration engine for **KJCLIController** gateway. Delegates task steps to local AI CLIs (`claude`, `gemini`/`agy`, `openai`/`codex`) via an OpenAI-compatible gateway, preserving cross-step context in `AGENT_LOG.md`.

## Install

```bash
pip install -e ".[dev]"
```

Exposes two identical entrypoints: `cli-orchestrator` and `clio`.

## Usage

```bash
# List provider statuses
clio providers

# Run a single step
clio step --model claude --workspace . --prompt "Implement parser module"

# Run a plan from a JSON file
clio plan --workspace . --file plan.json

# Cross-check / review mode (same prompt to multiple models)
clio review --models claude,openai --prompt "Review this approach"

# Output raw JSON (for scripting)
clio providers --json
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

Priority order: **CLI flag > env var > config file > default**

| Key | Default | Env var | CLI flag |
|---|---|---|---|
| `base_url` | `http://127.0.0.1:8080` | `CLI_CONTROLLER_URL` | `--base-url` |
| `token` | *(required)* | `CLI_CONTROLLER_TOKEN` | `--token` |
| `default_timeout` | `120` | `CLIO_DEFAULT_TIMEOUT` | — |
| `gemini_timeout` | `300` | `CLIO_GEMINI_TIMEOUT` | — |
| `retries` | `2` | `CLIO_RETRIES` | — |
| `max_parallel` | `1` | `CLIO_MAX_PARALLEL` | — |

## Library API (for Hermes skill)

```python
from cli_orchestrator import Orchestrator, check_providers
from cli_orchestrator.config import load_config

config = load_config()  # reads env vars
orch = Orchestrator(workspace="/path/to/project", config=config)

# Single step
result = orch.run_step(model="claude", prompt="Design the module")
# result.footer.status → "done" | "blocked" | "needs-info"
# result.footer.files_changed → ["src/foo.py"]
# result.footer.next → "Write tests"

# Full plan
from cli_orchestrator.orchestrator import PlanStep
steps = [PlanStep(model="claude", prompt="step 1"), PlanStep(model="openai", prompt="step 2")]
results = orch.run_plan(steps)

# Provider health
statuses = check_providers(config)
```

Returns pure dataclasses; **no stdout** when used as a library.

## Server Deployment

### Gateway setup

1. Start KJCLIController gateway bound to `127.0.0.1` with a strong random token:
   ```
   ./kjcli-controller --bind 127.0.0.1:8080 --token <random-strong-token>
   ```
2. Export the token on the same machine:
   ```bash
   export CLI_CONTROLLER_TOKEN=<random-strong-token>
   ```

### CLI authentication (headless OAuth)

Each CLI must be authenticated **on the server** — the gateway spawns them locally:

- **Claude**: `claude auth` → copy the OAuth URL, open on your local browser, complete auth, then paste the code back via SSH.
- **Gemini / agy**: similar OAuth flow. If you installed Google's official Gemini CLI (binary name `gemini`), create a symlink:
  ```bash
  ln -s $(which gemini) /usr/local/bin/agy
  ```
  Then verify the flags accepted by `agy` match what KJCLIController's `gemini.rs` adapter expects. If they differ, adjust the adapter.
- **OpenAI / Codex**: `codex auth` or set `OPENAI_API_KEY` depending on which CLI you use.

### Node.js requirement

Both `claude` and `gemini` CLIs require Node.js. Install via:
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

> **Note**: Do NOT create a systemd unit for `cli-orchestrator` — the engine is not a daemon. Run it as a one-shot command or call it from cron/git-hooks.

## Running tests

```bash
pytest tests/ -v
```

## Design notes

- **Deterministic engine**: no LLM planning inside the engine. Planning is the caller's (Hermes skill) responsibility.
- **Sequential by default**: `max_parallel=1`. Protects the server's 7.6 GB RAM.
- **Zero third-party runtime deps**: only stdlib (`urllib`, `json`, `argparse`, `pathlib`, …).
- **Token safety**: token never logged, never hardcoded.
- **Portable paths**: all paths in prompts and `AGENT_LOG.md` are relative to workspace.

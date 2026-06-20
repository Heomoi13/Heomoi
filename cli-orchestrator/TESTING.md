# Hướng dẫn test cli-orchestrator

> **Dành cho agent:** Chạy theo đúng thứ tự. Mỗi layer test độc lập — layer trước
> không cần gateway, layer sau cần gateway thật (hoặc dev_gateway).
>
> ✅ Tự động | 🔑 Cần người/auth | ⚠️ Cần gateway đang chạy

---

## Tổng quan các layer

```
Layer 1 — Unit tests          pytest (57 tests, không cần gateway, không cần CLI)
Layer 2 — Gateway health      curl / clio providers
Layer 3 — Single step         clio step (cần gateway + 1 CLI đã auth)
Layer 4 — Plan loop           clio run (cần gateway + CLI)
Layer 5 — Safety guardrails   Python script (cần gateway + CLI)
Layer 6 — Review mode         clio review (cần gateway + ≥2 CLI)
Layer 7 — Library API         Python import test (không cần gateway)
Layer 8 — End-to-end          plan thật trên workspace thật
```

---

## Layer 1 — Unit tests ✅

Không cần gateway, không cần CLI nào cả. Chạy được ngay sau `pip install -e .`.

```bash
cd ~/Heomoi/cli-orchestrator
source ~/.venv/clio/bin/activate

pytest tests/ -v
```

**Expected output:**
```
tests/test_gateway.py::TestChatCompletionRetry::test_retries_on_5xx PASSED
tests/test_ledger.py::TestAppendEntry::test_creates_file_if_missing PASSED
tests/test_orchestrator.py::TestMaxSteps::test_cap_triggers_escalate PASSED
tests/test_protocol.py::TestParseFooterFull::test_done PASSED
...
57 passed in 0.4s
```

Nếu có test fail ở layer này → lỗi code, không liên quan gateway.

### Chạy từng nhóm test riêng

```bash
# Chỉ test footer parser
pytest tests/test_protocol.py -v

# Chỉ test retry logic
pytest tests/test_gateway.py -v

# Chỉ test orchestrator loop
pytest tests/test_orchestrator.py -v

# Chỉ test ledger
pytest tests/test_ledger.py -v
```

---

## Layer 2 — Gateway health ⚠️

> Yêu cầu: gateway đang chạy (clicontroller hoặc dev_gateway.py)

### 2a. Khởi động gateway nếu chưa chạy

```bash
# Cách A: dùng systemd (nếu đã cài)
systemctl --user start kjcli-gateway
systemctl --user status kjcli-gateway

# Cách B: dev gateway (không cần Rust/clicontroller)
export CLI_CONTROLLER_TOKEN=${CLI_CONTROLLER_TOKEN:-dev-test-token}
python3 scripts/dev_gateway.py &
DEV_GW_PID=$!
```

### 2b. Test thủ công bằng curl

```bash
# Phải set token trước
echo "Token: $CLI_CONTROLLER_TOKEN"
echo "URL:   $CLI_CONTROLLER_URL"

# GET /api/providers
curl -s \
  -H "Authorization: Bearer $CLI_CONTROLLER_TOKEN" \
  "${CLI_CONTROLLER_URL:-http://127.0.0.1:8080}/api/providers" | python3 -m json.tool
```

**Expected:**
```json
[
  {"name": "claude",  "available": true,  "supports_vision": false},
  {"name": "gemini",  "available": false, "supports_vision": false},
  {"name": "openai",  "available": true,  "supports_vision": false}
]
```

`available: false` = CLI chưa auth hoặc không tìm thấy binary — bình thường ở bước này.

### 2c. Test bằng clio

```bash
clio providers
```

**Expected (khi gateway chạy):**
```
  ✓ claude
  ✗ gemini  — (not found / not auth)
  ✓ openai
```

**Expected (khi gateway không chạy):**
```
  ✗ gateway — Cannot reach gateway: ...
```
Exit code = 1 — đây là hành vi đúng, không phải lỗi code.

---

## Layer 3 — Single step ⚠️

> Yêu cầu: gateway chạy + ít nhất 1 CLI đã auth (thường là claude)

### 3a. Bước đơn với claude

```bash
WORKSPACE=$(mktemp -d)
echo "Workspace: $WORKSPACE"

clio step \
  --model claude \
  --workspace "$WORKSPACE" \
  --prompt "List numbers from 1 to 5, one per line. Then write the exact footer below:

STATUS: done
FILES_CHANGED: none
NEXT: test complete"
```

**Kiểm tra kết quả:**
```bash
# Footer phải được parse đúng (status=done)
# AGENT_LOG.md phải được tạo
cat "$WORKSPACE/AGENT_LOG.md"
```

**Expected AGENT_LOG.md:**
```markdown
# AGENT_LOG

---

## 2026-06-20 10:30 UTC — claude

**Step:** List numbers from 1 to 5...

**Reply:**

1
2
3
4
5

STATUS: done
FILES_CHANGED: none
NEXT: test complete
```

### 3b. Test JSON output (dùng trong script)

```bash
clio step \
  --model claude \
  --workspace "$WORKSPACE" \
  --prompt "Say hello. End with STATUS: done / FILES_CHANGED: none / NEXT: done" \
  --json | python3 -c "
import json, sys
r = json.load(sys.stdin)
assert r['footer']['status'] == 'done', f'Bad status: {r}'
assert r['error'] is None, f'Error: {r[\"error\"]}'
print('JSON output: OK')
print('Status:', r['footer']['status'])
"
```

### 3c. Test provider không available

```bash
# gemini chưa auth → phải báo lỗi sạch, không traceback
clio step \
  --model gemini \
  --workspace "$WORKSPACE" \
  --prompt "Hello"
# Expected: [gemini] ERROR: Provider 'gemini' not available
# Exit code: 1
echo "Exit code: $?"
```

---

## Layer 4 — Plan loop (StaticPlanner) ⚠️

### 4a. Tạo plan file

```bash
WORKSPACE=$(mktemp -d)

cat > /tmp/test-plan.json <<'EOF'
[
  {
    "model": "claude",
    "prompt": "Step 1: Write 'hello from step 1' to a file named result.txt in the workspace. End with:\nSTATUS: done\nFILES_CHANGED: result.txt\nNEXT: step 2"
  },
  {
    "model": "claude",
    "prompt": "Step 2: Read AGENT_LOG.md and confirm step 1 ran. End with:\nSTATUS: done\nFILES_CHANGED: none\nNEXT: all done"
  }
]
EOF
```

### 4b. Chạy plan

```bash
clio run --workspace "$WORKSPACE" --plan /tmp/test-plan.json
```

**Expected:**
```
[claude] status=done
  files: result.txt
  next:  step 2

[claude] status=done
  next:  all done

Done: Completed 2 step(s)
```

**Kiểm tra sau:**
```bash
# Ledger phải có 2 entries
grep -c "^##" "$WORKSPACE/AGENT_LOG.md"   # → 2

# File phải được tạo (nếu claude thực sự tạo nó)
ls -la "$WORKSPACE/"
```

### 4c. Test plan bị dừng khi blocked

```bash
cat > /tmp/blocked-plan.json <<'EOF'
[
  {
    "model": "claude",
    "prompt": "Reply with EXACTLY this footer and nothing else:\nSTATUS: blocked\nFILES_CHANGED: none\nNEXT: need clarification"
  },
  {
    "model": "claude",
    "prompt": "This step should NOT run"
  }
]
EOF

clio run --workspace "$WORKSPACE" --plan /tmp/blocked-plan.json --json | python3 -c "
import json, sys
r = json.load(sys.stdin)
assert r['status'] == 'escalated', f'Expected escalated, got: {r[\"status\"]}'
assert len(r['history']) == 1, f'Expected 1 history entry, got: {len(r[\"history\"])}'
print('Blocked plan stops correctly: OK')
"
echo "Exit code: $?"   # phải là 1
```

---

## Layer 5 — Safety guardrails ✅ (Python script, không cần CLI auth)

Test các rào an toàn của engine bằng cách mock gateway — không cần CLI thật.

```bash
python3 - <<'PYEOF'
import sys
sys.path.insert(0, ".")
from unittest.mock import patch
from cli_orchestrator.config import Config
from cli_orchestrator.orchestrator import Orchestrator
from cli_orchestrator.planner import Step, Done, Escalate
from cli_orchestrator.providers import ProviderStatus

cfg = Config(
    token="test", base_url="http://127.0.0.1:8080",
    max_steps=3, max_delegations=10,
    oscillation_limit=2, needs_info_limit=2,
    retries=0,
)

providers = [ProviderStatus("claude", available=True, supports_vision=False)]
done_reply = "done\n\nSTATUS: done\nFILES_CHANGED: none\nNEXT: ok"
needs_info_reply = "STATUS: needs-info\nFILES_CHANGED: none\nNEXT: clarify"

import tempfile, os
ws = tempfile.mkdtemp()

def run_with(decisions, reply="done"):
    reply_text = done_reply if reply == "done" else needs_info_reply
    class P:
        def __init__(self, d): self._d = list(d); self._i = 0
        def next_step(self, ctx, hist):
            if self._i >= len(self._d): return Done("exhausted")
            r = self._d[self._i]; self._i += 1; return r
    orch = Orchestrator(ws, cfg)
    with patch("cli_orchestrator.orchestrator.check_providers", return_value=providers), \
         patch("cli_orchestrator.orchestrator.is_available", return_value=True), \
         patch("cli_orchestrator.orchestrator.chat_completion", return_value=reply_text):
        return orch.run(P(decisions))

# Test 1: max_steps
r = run_with([Step("claude", f"step {i}") for i in range(10)])
assert r.status == "escalated" and "max_steps" in r.escalation_reason
assert len(r.history) == 3
print("✓ max_steps cap works")

# Test 2: oscillation
r = run_with([Step("claude", "same"), Step("claude", "same"), Step("claude", "same")])
assert r.status == "escalated" and "oscillat" in r.escalation_reason
assert len(r.history) == 1
print("✓ oscillation detection works")

# Test 3: needs-info loop
r = run_with([Step("claude", "q1"), Step("claude", "q2"), Step("claude", "q3")], reply="needs-info")
assert r.status == "escalated" and "needs-info" in r.escalation_reason
assert len(r.history) == 2
print("✓ needs-info limit works")

# Test 4: Done immediately
r = run_with([Done("finished")])
assert r.status == "done"
print("✓ Done propagates correctly")

# Test 5: Escalate from planner
r = run_with([Escalate("human needed")])
assert r.status == "escalated" and r.escalation_reason == "human needed"
print("✓ Escalate propagates correctly")

print("\nAll guardrail tests passed ✓")
PYEOF
```

---

## Layer 6 — Review mode (nhiều model) ⚠️

> Yêu cầu: gateway chạy + ≥2 CLI đã auth

```bash
WORKSPACE=$(mktemp -d)

clio review \
  --models claude,openai \
  --workspace "$WORKSPACE" \
  --prompt "Write a one-sentence summary of what a REST API is. End with STATUS: done / FILES_CHANGED: none / NEXT: done"
```

**Expected:** Hai response độc lập từ claude và openai, mỗi cái có footer riêng.

---

## Layer 7 — Library API (import test) ✅

Xác nhận engine import được và không in stdout khi dùng như thư viện.

```bash
python3 - <<'PYEOF'
import io, sys

# Capture stdout — engine không được in gì
buf = io.StringIO()
old_stdout = sys.stdout
sys.stdout = buf

from cli_orchestrator import Orchestrator, StaticPlanner, Step, check_providers
from cli_orchestrator.config import load_config

# Restore stdout
sys.stdout = old_stdout
captured = buf.getvalue()

assert captured == "", f"Engine printed to stdout during import: {captured!r}"
print("✓ No stdout on import")

# Xác nhận API surface đầy đủ
assert callable(Orchestrator)
assert callable(StaticPlanner)
assert callable(check_providers)
assert callable(load_config)
print("✓ Public API accessible")

# Xác nhận types đúng
from cli_orchestrator import RunResult, StepResult
from cli_orchestrator import Done, Escalate
from cli_orchestrator.planner import Planner

import inspect
assert hasattr(Orchestrator, "run")
assert hasattr(Orchestrator, "run_step")
print("✓ Orchestrator.run() and run_step() exist")

print("\nLibrary API test passed ✓")
PYEOF
```

---

## Layer 8 — End-to-end trên workspace thật ⚠️ 🔑

> Yêu cầu: gateway + ít nhất claude auth

Dùng chính repo này làm workspace:

```bash
WORKSPACE=~/Heomoi

cat > /tmp/e2e-plan.json <<'EOF'
[
  {
    "model": "claude",
    "prompt": "Look at the cli-orchestrator directory in this workspace. List the Python files in cli_orchestrator/ and describe in one sentence what each file does. Write your findings to AGENT_LOG.md. End with:\nSTATUS: done\nFILES_CHANGED: none\nNEXT: review complete"
  }
]
EOF

clio run --workspace "$WORKSPACE" --plan /tmp/e2e-plan.json

# Xem kết quả
echo "--- AGENT_LOG.md ---"
tail -30 "$WORKSPACE/AGENT_LOG.md"
```

---

## Chạy tất cả test tự động (không cần gateway) ✅

Script tiện lợi chạy layer 1 + layer 5 + layer 7:

```bash
#!/usr/bin/env bash
set -euo pipefail
cd ~/Heomoi/cli-orchestrator
source ~/.venv/clio/bin/activate

echo "=== Layer 1: pytest ==="
pytest tests/ -q
echo ""

echo "=== Layer 5: guardrails ==="
python3 - <<'PYEOF'
import sys; sys.path.insert(0, ".")
from unittest.mock import patch
from cli_orchestrator.config import Config
from cli_orchestrator.orchestrator import Orchestrator
from cli_orchestrator.planner import Step, Done, Escalate
from cli_orchestrator.providers import ProviderStatus
import tempfile

cfg = Config(token="t", base_url="http://x", max_steps=3,
             max_delegations=10, oscillation_limit=2, needs_info_limit=2, retries=0)
ws = tempfile.mkdtemp()
providers = [ProviderStatus("claude", available=True, supports_vision=False)]
done_r = "ok\nSTATUS: done\nFILES_CHANGED: none\nNEXT: ok"
ni_r   = "STATUS: needs-info\nFILES_CHANGED: none\nNEXT: clarify"

def run(decisions, reply=done_r):
    class P:
        def __init__(self): self._d=list(decisions); self._i=0
        def next_step(self,c,h):
            if self._i>=len(self._d): return Done("x")
            r=self._d[self._i]; self._i+=1; return r
    with patch("cli_orchestrator.orchestrator.check_providers", return_value=providers), \
         patch("cli_orchestrator.orchestrator.is_available", return_value=True), \
         patch("cli_orchestrator.orchestrator.chat_completion", return_value=reply):
        return Orchestrator(ws, cfg).run(P())

assert run([Step("claude",f"s{i}") for i in range(10)]).escalation_reason == "max_steps reached"
assert run([Step("claude","x"),Step("claude","x")]).escalation_reason == "planner oscillating"
assert run([Step("claude","a"),Step("claude","b")], ni_r).escalation_reason == "repeated needs-info"
assert run([Done("ok")]).status == "done"
assert run([Escalate("stop")]).escalation_reason == "stop"
print("Layer 5: all guardrails OK")
PYEOF

echo ""
echo "=== Layer 7: library API ==="
python3 -c "
from cli_orchestrator import Orchestrator, StaticPlanner, Step, RunResult, StepResult
from cli_orchestrator import Done, Escalate, check_providers
from cli_orchestrator.config import load_config
print('Layer 7: import OK')
"

echo ""
echo "✓ All automated tests passed"
```

---

## Checklist nhanh

```
[ ] pytest tests/ -v                          → 57 passed
[ ] clio providers                            → gateway reachable
[ ] clio step --model claude --prompt "..."   → status=done, AGENT_LOG.md tạo ra
[ ] clio run --plan plan.json                 → 2 bước chạy theo thứ tự
[ ] guardrails script                         → max_steps/oscillation/needs-info OK
[ ] python3 -c "from cli_orchestrator import Orchestrator"  → no stdout, no error
```

---

## Troubleshooting test

| Triệu chứng | Nguyên nhân | Fix |
|---|---|---|
| `57 passed` nhưng `clio providers` fail | Gateway chưa chạy | Start clicontroller hoặc dev_gateway |
| `status=blocked` thay vì `done` | CLI không theo format footer | Prompt rõ hơn, yêu cầu footer cụ thể |
| `Provider 'claude' not available` | claude chưa auth | `claude auth` |
| `token not configured` | Chưa set env | `export CLI_CONTROLLER_TOKEN=...` |
| AGENT_LOG.md không tạo | Gateway không kết nối | Kiểm tra `clio providers` trước |
| Exit code 1 sau `clio run` | Có bước escalated | Xem output, kiểm tra `escalation_reason` |

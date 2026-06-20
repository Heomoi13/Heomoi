# Hướng dẫn cài đặt cli-orchestrator lên Ubuntu Server

> **Dành cho agent:** Đọc toàn bộ file này trước. Phân biệt rõ hai loại bước:
> - ✅ **Tự động** — chạy lệnh trực tiếp được
> - 🔑 **Cần người** — yêu cầu tương tác OAuth/browser, không script được
>
> **Không có `kjcli-controller`?** Dùng `scripts/dev_gateway.py` (xem [Bước 0](#bước-0--dev-gateway-nếu-chưa-có-kjcli-controller-)).

---

## Yêu cầu

| Thứ | Phiên bản | Kiểm tra |
|-----|-----------|---------|
| Ubuntu | 20.04+ | `lsb_release -rs` |
| Python | 3.11+ | `python3 --version` |
| Node.js | 18+ | `node --version` |
| KJCLIController gateway | đang chạy trên server | `curl http://127.0.0.1:8080/api/providers` |

---

## Bước 0 — Dev gateway (nếu chưa có `kjcli-controller`) ✅

Nếu bạn chưa có binary `kjcli-controller`, dùng `scripts/dev_gateway.py` —
một gateway tối giản viết bằng Python stdlib, đủ để `clio` chạy hoàn toàn.

```bash
# Sinh token dev
export CLI_CONTROLLER_TOKEN=$(openssl rand -hex 16)
echo "Dev token: $CLI_CONTROLLER_TOKEN"

# Chạy dev gateway (terminal riêng hoặc background)
python3 scripts/dev_gateway.py
# → dev_gateway starting on http://127.0.0.1:8080
# → ✓ claude   → claude
# → ✗ gemini   → agy (not found in PATH)
# → ✓ openai   → codex
```

### Tuning lệnh CLI (nếu flag khác mặc định)

```bash
# Mặc định dev_gateway dùng: claude -p "<prompt>"
# Nếu Claude CLI của bạn dùng flag khác:
export CLIO_CLAUDE_CMD="claude --print {prompt}"

# Gemini / agy — mặc định pipe stdin
export CLIO_GEMINI_CMD="agy"

# OpenAI Codex — mặc định pipe stdin
export CLIO_OPENAI_CMD="codex -q"

python3 scripts/dev_gateway.py
```

### Chạy dev gateway như background process ✅

```bash
nohup python3 scripts/dev_gateway.py > /tmp/dev-gateway.log 2>&1 &
echo "Gateway PID: $!"

# Kiểm tra
clio providers

# Dừng khi xong
kill %1   # hoặc kill <PID>
```

> **Giới hạn của dev_gateway vs. kjcli-controller thật:**
> single-threaded, không streaming, không retry nâng cao.
> Đủ cho dev/test; thay bằng kjcli-controller khi production.

---

## Bước 1 — Chạy script cài đặt tự động ✅

```bash
# Clone repo về server (nếu chưa có)
git clone https://github.com/Heomoi13/Heomoi.git
cd Heomoi/cli-orchestrator

# Cấp quyền thực thi
chmod +x scripts/setup.sh

# Chạy (KHÔNG dùng sudo)
bash scripts/setup.sh
```

Script sẽ tự động:
- Kiểm tra Python 3.11+
- Tạo virtualenv tại `~/.venv/clio`
- Cài `cli-orchestrator` (`clio` entrypoint)
- Cài Node.js nếu thiếu (yêu cầu sudo một lần)
- Cài `claude`, `gemini`, `codex` CLI qua npm
- Tạo symlink `agy → gemini` (gateway dùng tên `agy` cho slot gemini)
- Sinh file snippet env và unit systemd mẫu

### Tuỳ chọn script

```bash
# Chỉ định thư mục virtualenv khác
bash scripts/setup.sh --venv-dir /opt/clio-venv

# Bỏ qua cài Node.js (đã có rồi)
bash scripts/setup.sh --skip-node

# Bỏ qua cài các AI CLI (đã có rồi)
bash scripts/setup.sh --skip-clis
```

---

## Bước 2 — Cấu hình token gateway ✅

```bash
# Sinh token ngẫu nhiên mạnh
CLI_CONTROLLER_TOKEN=$(openssl rand -hex 32)
echo "Token: $CLI_CONTROLLER_TOKEN"   # lưu lại chỗ an toàn

# Thêm vào ~/.bashrc (tồn tại giữa các session)
echo "export CLI_CONTROLLER_TOKEN=\"$CLI_CONTROLLER_TOKEN\"" >> ~/.bashrc
echo "export CLI_CONTROLLER_URL=\"http://127.0.0.1:8080\""  >> ~/.bashrc
echo "export PATH=\"\$HOME/.local/bin:\$HOME/.venv/clio/bin:\$PATH\"" >> ~/.bashrc

source ~/.bashrc
```

---

## Bước 3 — Cài KJCLIController gateway ✅

Gateway là Rust binary tên **`clicontroller`**, repo: https://github.com/kentjuno/KJCLIController

### Option A: Download pre-built binary (nhanh nhất)

```bash
# Xem danh sách release tại:
# https://github.com/kentjuno/KJCLIController/releases/latest
# Tải file Linux (thường tên: clicontroller-linux-x86_64 hoặc tương tự)

# Ví dụ (thay URL bằng link thật từ releases page):
mkdir -p ~/bin
curl -L -o ~/bin/clicontroller \
    https://github.com/kentjuno/KJCLIController/releases/latest/download/clicontroller-linux-x86_64
chmod +x ~/bin/clicontroller
export PATH="$HOME/bin:$PATH"

# Kiểm tra
clicontroller --version
```

### Option B: Build từ source với Cargo ✅

```bash
# 1. Cài Rust (nếu chưa có)
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
source "$HOME/.cargo/env"

# 2. Clone và build (mất ~2-5 phút lần đầu)
git clone https://github.com/kentjuno/KJCLIController.git ~/KJCLIController
cd ~/KJCLIController
cargo build --release

# 3. Copy binary vào PATH
mkdir -p ~/bin
cp target/release/clicontroller ~/bin/
export PATH="$HOME/bin:$PATH"
echo 'export PATH="$HOME/bin:$PATH"' >> ~/.bashrc

# Kiểm tra
clicontroller --version 2>/dev/null || echo "Binary tại: ~/bin/clicontroller"
```

### Cấu hình gateway (config.json)

KJCLIController **tự sinh `config.json` khi chạy lần đầu**. Quy trình:

```bash
# 1. Tạo thư mục riêng để chạy gateway
mkdir -p ~/kjcli-gateway && cd ~/kjcli-gateway

# 2. Chạy một lần để sinh config.json
clicontroller
# Ctrl+C ngay sau khi thấy "Listening on ..."

# 3. Chỉnh config.json — ĐẶT TOKEN MẠNH
cat > config.json <<EOF
{
  "token": "$(openssl rand -hex 32)",
  "port": 8080,
  "temp_dir": "./temp_uploads",
  "output_dir": "./outputs"
}
EOF

# Lưu token vào env
TOKEN=$(python3 -c "import json; print(json.load(open('config.json'))['token'])")
echo "export CLI_CONTROLLER_TOKEN=\"$TOKEN\""   >> ~/.bashrc
echo "export CLI_CONTROLLER_URL=\"http://127.0.0.1:8080\"" >> ~/.bashrc
source ~/.bashrc

# 4. Chạy gateway (từ thư mục chứa config.json)
nohup clicontroller > ~/kjcli-gateway/gateway.log 2>&1 &
echo "Gateway PID: $! — log: ~/kjcli-gateway/gateway.log"

# 5. Kiểm tra
curl -s -H "Authorization: Bearer $CLI_CONTROLLER_TOKEN" \
    http://127.0.0.1:8080/api/providers
```

### Cài gateway thành systemd service (tự khởi động lại) ✅

```bash
mkdir -p ~/.config/systemd/user
cat > ~/.config/systemd/user/kjcli-gateway.service <<EOF
[Unit]
Description=KJCLIController gateway
After=network.target

[Service]
Type=simple
WorkingDirectory=$HOME/kjcli-gateway
ExecStart=$HOME/bin/clicontroller
Restart=on-failure
RestartSec=5
Environment=HOME=$HOME
Environment=PATH=$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin

[Install]
WantedBy=default.target
EOF

systemctl --user daemon-reload
systemctl --user enable --now kjcli-gateway
systemctl --user status kjcli-gateway

# Cho phép chạy khi không login (linger)
sudo loginctl enable-linger "$USER"
```

---

## Bước 4 — Auth các AI CLI 🔑 (cần người làm một lần)

Các CLI phải được auth **ngay trên server** này. Gateway sẽ spawn chúng local.

### Claude Code

```bash
claude auth
# → In ra một URL dạng: https://claude.ai/oauth/...
# → Mở URL đó trên trình duyệt máy local của bạn
# → Đăng nhập, copy code, paste lại vào terminal server
```

SSH port-forward nếu cần mở URL:
```bash
# Từ máy local (terminal riêng):
ssh -L 9999:127.0.0.1:9999 user@your-server
```

### Gemini

```bash
gemini auth
# → Tương tự Claude — copy URL, mở trên máy local, paste code về

# Xác nhận symlink agy hoạt động
agy --version   # phải in ra phiên bản gemini
```

Nếu flag của `agy` không khớp với `gemini.rs` adapter trong gateway:
```bash
# Kiểm tra gateway log để thấy lệnh đang gọi
# Chỉnh adapter hoặc tạo wrapper script tại ~/.local/bin/agy:
cat > ~/.local/bin/agy <<'EOF'
#!/usr/bin/env bash
exec gemini "$@"
EOF
chmod +x ~/.local/bin/agy
```

### OpenAI Codex

```bash
# Cách 1: auth OAuth
codex auth

# Cách 2: dùng API key (đơn giản hơn)
echo "export OPENAI_API_KEY=\"sk-...\"" >> ~/.bashrc
source ~/.bashrc
```

---

## Bước 5 — Kiểm tra toàn bộ ✅

```bash
# Activate virtualenv (nếu chưa active)
source ~/.venv/clio/bin/activate

# Kiểm tra providers
clio providers
# Expected output:
#   ✓ claude
#   ✓ gemini
#   ✓ openai

# Chạy thử 1 bước đơn giản
clio step --model claude --workspace /tmp --prompt \
  "List files in current directory. End with STATUS: done / FILES_CHANGED: none / NEXT: done"

# Xem ledger được tạo
cat /tmp/AGENT_LOG.md
```

---

## Bước 6 — Dùng trong thực tế ✅

### Chạy plan từ file JSON

```bash
cat > /tmp/test-plan.json <<'EOF'
[
  {"model": "claude", "prompt": "Liệt kê các file trong thư mục hiện tại"},
  {"model": "openai", "prompt": "Tóm tắt những gì đã làm theo AGENT_LOG.md"}
]
EOF

clio run --workspace . --plan /tmp/test-plan.json

# Xem kết quả dạng JSON (dùng trong script)
clio run --workspace . --plan /tmp/test-plan.json --json
```

### Dùng như thư viện Python (cho Hermes skill)

```python
from cli_orchestrator import Orchestrator, StaticPlanner, Step
from cli_orchestrator.config import load_config

config = load_config()  # đọc từ env vars
orch = Orchestrator(workspace="/path/to/project", config=config)

steps = [
    Step("claude", "Phân tích codebase"),
    Step("openai", "Implement theo kế hoạch"),
]
result = orch.run(StaticPlanner(steps))

print(result.status)             # "done" hoặc "escalated"
print(result.escalation_reason)  # lý do nếu escalated
for r in result.history:
    print(r.model, r.footer.status, r.footer.files_changed)
```

### Cron job

```bash
# Chỉnh crontab
crontab -e

# Thêm dòng (chạy lúc 2AM mỗi đêm)
0 2 * * * source $HOME/.bashrc && $HOME/.venv/clio/bin/clio run \
    --workspace /path/to/project \
    --plan /path/to/nightly-plan.json \
    >> /var/log/clio-nightly.log 2>&1
```

---

## Troubleshooting

### `clio providers` báo "Cannot reach gateway"
```bash
# Kiểm tra gateway có đang chạy không
systemctl --user status kjcli-gateway
# hoặc
ps aux | grep clicontroller

# Kiểm tra port
ss -tlnp | grep 8080

# Xem log gateway
journalctl --user -u kjcli-gateway -n 50
# hoặc nếu chạy bằng nohup:
tail -f ~/kjcli-gateway/gateway.log

# Restart
systemctl --user restart kjcli-gateway
```

### Token không khớp (401 Unauthorized)
```bash
# Đảm bảo token trong env khớp với config.json
echo $CLI_CONTROLLER_TOKEN
cat ~/kjcli-gateway/config.json | python3 -c "import json,sys; print(json.load(sys.stdin)['token'])"
# Hai giá trị phải giống nhau
```

### `clicontroller: command not found`
```bash
# Kiểm tra binary
ls -la ~/bin/clicontroller
export PATH="$HOME/bin:$PATH"
# Thêm vào ~/.bashrc nếu chưa có:
echo 'export PATH="$HOME/bin:$PATH"' >> ~/.bashrc
```

### Cargo build lỗi (linker / OpenSSL)
```bash
sudo apt install -y build-essential pkg-config libssl-dev
cargo build --release
```

### `clio providers` hiện provider `available: false`
```bash
# Provider chưa auth hoặc auth hết hạn
claude auth    # re-auth claude
gemini auth    # re-auth gemini
```

### `agy: command not found`
```bash
ln -sf "$(which gemini)" "$HOME/.local/bin/agy"
export PATH="$HOME/.local/bin:$PATH"
```

### Gateway tìm không ra binary CLI
```bash
# Kiểm tra PATH mà gateway thấy
sudo systemctl show-environment   # hoặc
env | grep PATH

# Gateway cần thấy PATH chứa npm global bin
# Thêm vào [Service] section của unit file:
# Environment=PATH=/home/user/.local/bin:/usr/local/bin:/usr/bin:/bin
```

### `pip install` lỗi "No module named setuptools.backends"
```bash
pip install --upgrade pip setuptools
pip install -e .
```

---

## Cấu trúc file sau khi cài

```
~/bin/clicontroller                       # KJCLIController binary
~/KJCLIController/                        # source (nếu build từ source)
~/kjcli-gateway/
│   config.json                           # gateway config (token, port)
│   gateway.log                           # log nếu dùng nohup
~/.config/systemd/user/kjcli-gateway.service
~/.venv/clio/                             # virtualenv cho clio
~/.local/bin/agy                          # symlink → gemini
~/Heomoi/cli-orchestrator/
├── scripts/
│   ├── setup.sh                          # cài clio + AI CLIs
│   ├── dev_gateway.py                    # dev gateway (không cần Rust)
│   └── _env_snippet.sh                   # env vars (do setup.sh sinh ra)
└── <workspace>/AGENT_LOG.md             # ledger (tạo khi chạy lần đầu)
```

---

## Tổng kết

| Bước | Tự động? | Lệnh chính |
|------|----------|-----------|
| Cài Rust | ✅ | `curl ... rustup.rs \| sh` |
| Build gateway | ✅ | `cargo build --release` (hoặc download binary) |
| Cấu hình gateway | ✅ | sinh `config.json`, set `CLI_CONTROLLER_TOKEN` |
| Chạy gateway | ✅ | `systemctl --user enable --now kjcli-gateway` |
| Cài Python deps + clio | ✅ | `bash scripts/setup.sh` |
| Auth claude | 🔑 | `claude auth` (cần browser 1 lần) |
| Auth gemini | 🔑 | `gemini auth` (cần browser 1 lần) |
| Auth codex | ✅ hoặc 🔑 | `export OPENAI_API_KEY=...` hoặc `codex auth` |
| Test | ✅ | `clio providers` |

#!/usr/bin/env bash
# setup.sh — Install cli-orchestrator and its dependencies on Ubuntu server.
# Run as the user who will own the process (NOT root).
# Usage: bash scripts/setup.sh [--venv-dir <path>] [--skip-node] [--skip-clis]

set -euo pipefail

# ── Colour helpers ────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
section() { echo -e "\n${CYAN}══ $* ══${NC}"; }

# ── Argument defaults ─────────────────────────────────────────────────────────
VENV_DIR="${VENV_DIR:-$HOME/.venv/clio}"
SKIP_NODE=false
SKIP_CLIS=false

while [[ $# -gt 0 ]]; do
  case $1 in
    --venv-dir)   VENV_DIR="$2"; shift 2 ;;
    --skip-node)  SKIP_NODE=true; shift ;;
    --skip-clis)  SKIP_CLIS=true; shift ;;
    *) error "Unknown argument: $1"; exit 1 ;;
  esac
done

# Resolve project root (parent of this script's directory)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# ── Guard: must not run as root ───────────────────────────────────────────────
if [[ "$(id -u)" -eq 0 ]]; then
  error "Do not run this script as root. Run as the service user instead."
  exit 1
fi

# ═════════════════════════════════════════════════════════════════════════════
section "Step 1 — Python 3.11+"
# ═════════════════════════════════════════════════════════════════════════════

if ! command -v python3 &>/dev/null; then
  error "python3 not found. Install with: sudo apt install python3.11 python3.11-venv"
  exit 1
fi

PY_VER=$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')
PY_MAJOR=$(echo "$PY_VER" | cut -d. -f1)
PY_MINOR=$(echo "$PY_VER" | cut -d. -f2)

if [[ "$PY_MAJOR" -lt 3 || ("$PY_MAJOR" -eq 3 && "$PY_MINOR" -lt 11) ]]; then
  error "Python 3.11+ required, found $PY_VER"
  error "Install with: sudo apt install python3.11 python3.11-venv"
  exit 1
fi

success "Python $PY_VER"

# ═════════════════════════════════════════════════════════════════════════════
section "Step 2 — Virtual environment: $VENV_DIR"
# ═════════════════════════════════════════════════════════════════════════════

if [[ ! -d "$VENV_DIR" ]]; then
  info "Creating virtualenv..."
  python3 -m venv "$VENV_DIR"
fi

# Activate for the rest of this script
# shellcheck disable=SC1091
source "$VENV_DIR/bin/activate"
success "Virtualenv activated: $VENV_DIR"

pip install --upgrade pip --quiet

# ═════════════════════════════════════════════════════════════════════════════
section "Step 3 — Install cli-orchestrator"
# ═════════════════════════════════════════════════════════════════════════════

info "Installing from $PROJECT_ROOT ..."
pip install -e "$PROJECT_ROOT" --quiet
success "cli-orchestrator installed"

# Verify entrypoint
if ! command -v clio &>/dev/null; then
  error "'clio' entrypoint not found in PATH. Ensure $VENV_DIR/bin is in PATH."
  exit 1
fi
success "clio entrypoint: $(which clio)"

# ═════════════════════════════════════════════════════════════════════════════
section "Step 4 — Node.js (required for claude and gemini CLIs)"
# ═════════════════════════════════════════════════════════════════════════════

if [[ "$SKIP_NODE" == true ]]; then
  warn "Skipping Node.js check (--skip-node)"
elif command -v node &>/dev/null; then
  NODE_VER=$(node --version)
  success "Node.js $NODE_VER already installed"
else
  warn "Node.js not found. Installing via NodeSource (requires sudo)..."
  curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
  sudo apt-get install -y nodejs
  success "Node.js $(node --version) installed"
fi

# ═════════════════════════════════════════════════════════════════════════════
section "Step 5 — AI CLIs"
# ═════════════════════════════════════════════════════════════════════════════

if [[ "$SKIP_CLIS" == true ]]; then
  warn "Skipping CLI installation (--skip-clis)"
else
  # Claude Code CLI
  if command -v claude &>/dev/null; then
    success "claude CLI already installed: $(claude --version 2>/dev/null || echo 'unknown version')"
  else
    info "Installing Claude Code CLI..."
    npm install -g @anthropic-ai/claude-code
    success "claude CLI installed"
  fi

  # Gemini CLI
  if command -v gemini &>/dev/null; then
    success "gemini CLI already installed"
  else
    info "Installing Gemini CLI..."
    npm install -g @google/gemini-cli
    success "gemini CLI installed"
  fi

  # Create agy → gemini symlink (gateway looks for binary named "agy")
  LOCAL_BIN="$HOME/.local/bin"
  mkdir -p "$LOCAL_BIN"

  if [[ -L "$LOCAL_BIN/agy" ]]; then
    success "agy symlink already exists: $(readlink "$LOCAL_BIN/agy")"
  elif command -v gemini &>/dev/null; then
    ln -s "$(which gemini)" "$LOCAL_BIN/agy"
    success "Created symlink: $LOCAL_BIN/agy -> $(which gemini)"
  else
    warn "gemini not found in PATH; skipping agy symlink"
  fi

  # Ensure ~/.local/bin is on PATH
  if [[ ":$PATH:" != *":$LOCAL_BIN:"* ]]; then
    warn "$LOCAL_BIN is not in PATH. Add to ~/.bashrc:"
    echo "  export PATH=\"\$HOME/.local/bin:\$PATH\""
  fi

  # OpenAI Codex (optional)
  if command -v codex &>/dev/null; then
    success "codex CLI already installed"
  else
    info "Installing OpenAI Codex CLI..."
    npm install -g @openai/codex 2>/dev/null || warn "codex install failed (optional, skip if not used)"
  fi
fi

# ═════════════════════════════════════════════════════════════════════════════
section "Step 6 — Environment variables"
# ═════════════════════════════════════════════════════════════════════════════

ENV_FILE="$HOME/.bashrc"
PROFILE_SNIPPET="$PROJECT_ROOT/scripts/_env_snippet.sh"

# Generate token suggestion if not already set
if [[ -z "${CLI_CONTROLLER_TOKEN:-}" ]]; then
  SUGGESTED_TOKEN=$(openssl rand -hex 32 2>/dev/null || python3 -c "import secrets; print(secrets.token_hex(32))")
  warn "CLI_CONTROLLER_TOKEN is not set."
  echo
  echo "  Generate a strong token and add to $ENV_FILE:"
  echo
  echo "    export CLI_CONTROLLER_TOKEN=\"$SUGGESTED_TOKEN\""
  echo "    export CLI_CONTROLLER_URL=\"http://127.0.0.1:8080\""
  echo

  # Write snippet for easy sourcing
  cat > "$PROFILE_SNIPPET" <<EOF
# cli-orchestrator environment — generated by setup.sh
# IMPORTANT: replace the token below with your actual gateway token
export CLI_CONTROLLER_TOKEN="REPLACE_WITH_YOUR_TOKEN"
export CLI_CONTROLLER_URL="http://127.0.0.1:8080"
export PATH="\$HOME/.local/bin:\$PATH"
# Activate clio virtualenv
export PATH="$VENV_DIR/bin:\$PATH"
EOF
  success "Snippet written to $PROFILE_SNIPPET"
  info "After setting token, run: source $PROFILE_SNIPPET"
else
  success "CLI_CONTROLLER_TOKEN is set"
fi

# ═════════════════════════════════════════════════════════════════════════════
section "Step 7 — Systemd service for gateway (optional)"
# ═════════════════════════════════════════════════════════════════════════════

SYSTEMD_DIR="$HOME/.config/systemd/user"
SYSTEMD_FILE="$SYSTEMD_DIR/kjcli-gateway.service"

if [[ -f "$SYSTEMD_FILE" ]]; then
  success "Systemd unit already exists: $SYSTEMD_FILE"
else
  mkdir -p "$SYSTEMD_DIR"
  cat > "$SYSTEMD_FILE" <<'UNIT'
[Unit]
Description=KJCLIController gateway
After=network.target

[Service]
Type=simple
ExecStart=%h/bin/kjcli-controller --bind 127.0.0.1:8080 --token-file %h/.config/kjcli/token
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
UNIT
  success "Systemd unit written: $SYSTEMD_FILE"
  info "To enable: systemctl --user enable --now kjcli-gateway"
fi

# ═════════════════════════════════════════════════════════════════════════════
section "Summary"
# ═════════════════════════════════════════════════════════════════════════════

echo
success "Installation complete."
echo
echo "  Next steps (require human / interactive auth — cannot be scripted):"
echo
echo "  1. Set your gateway token in ~/.bashrc or source $PROFILE_SNIPPET"
echo "  2. Start the KJCLIController gateway on this server"
echo "  3. Auth each CLI on this server (OAuth requires browser once):"
echo "       claude          → run: claude auth"
echo "       gemini / agy    → run: gemini auth"
echo "       codex           → run: codex auth  (or set OPENAI_API_KEY)"
echo
echo "  After auth is done, test with:"
echo "       source $VENV_DIR/bin/activate"
echo "       clio providers"
echo

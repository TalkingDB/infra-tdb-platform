#!/usr/bin/env bash
# One-line host installer for the TalkingDB workspace.
#
#   curl -fsSL https://raw.githubusercontent.com/TalkingDB/infra-tdb-platform/main/scripts/bootstrap.sh | bash
#
# What it does:
#   1. Asks (once, upfront) where to create the TalkingDB folder
#      and whether to launch DevPod when cloning finishes.
#   2. Clones infra-tdb-platform + every active sibling in local/repo.yaml.
#   3. Asks which LLM provider to use (OpenAI / Groq / Ollama) and writes
#      credentials to infra-tdb-platform/.env (never committed).
#   4. Optionally launches `devpod up . --ide vscode`.
#
# Non-interactive overrides (skip prompts):
#   TDB_ROOT=/some/path           # workspace location
#   TDB_AUTO_DEVPOD=Y|N           # whether to launch DevPod at the end
#   TDB_INFRA_REPO=<git url>      # alternate infra repo source (e.g. a fork)
#   TDB_LLM_PROVIDER=openai|groq|ollama
#   TDB_LLM_API_KEY=<key>
#   TDB_LLM_BASE_URL=<url>        # required for ollama, optional override for others
#
# Idempotent: re-running skips repos that already exist and updates .env in place.

set -euo pipefail

INFRA_REPO="${TDB_INFRA_REPO:-https://github.com/TalkingDB/infra-tdb-platform.git}"
INFRA_NAME="infra-tdb-platform"
DEFAULT_ROOT="$PWD/TalkingDB"

if [[ -r /dev/tty ]]; then TTY=/dev/tty; else TTY=; fi

# ── Prompt helpers ────────────────────────────────────────────────────────────

ask_path() {
  local prompt="$1" default="$2" reply
  if [[ -z "$TTY" ]]; then REPLY="$default"; return; fi
  printf '%s\n  Press Enter for: %s\n  Or type a path: ' "$prompt" "$default" >&2
  read -r reply <"$TTY" || reply=""
  REPLY="${reply:-$default}"
}

ask_yn() {
  local prompt="$1" default="$2" reply hint
  case "$default" in [Yy]*) hint="[Y/n]" ;; *) hint="[y/N]" ;; esac
  if [[ -z "$TTY" ]]; then
    case "$default" in [Yy]*) REPLY=1 ;; *) REPLY=0 ;; esac
    return
  fi
  printf '%s %s: ' "$prompt" "$hint" >&2
  read -r reply <"$TTY" || reply=""
  reply="${reply:-$default}"
  case "$reply" in [Yy]*) REPLY=1 ;; *) REPLY=0 ;; esac
}

ask_secret() {
  # Reads input without echoing. Sets REPLY.
  local prompt="$1" reply
  if [[ -z "$TTY" ]]; then REPLY=""; return; fi
  printf '%s: ' "$prompt" >&2
  read -rs reply <"$TTY"
  echo >&2   # newline after silent input
  REPLY="$reply"
}

ask_input() {
  # Reads visible input with an optional default. Sets REPLY.
  local prompt="$1" default="${2:-}" reply
  if [[ -z "$TTY" ]]; then REPLY="$default"; return; fi
  if [[ -n "$default" ]]; then
    printf '%s [%s]: ' "$prompt" "$default" >&2
  else
    printf '%s: ' "$prompt" >&2
  fi
  read -r reply <"$TTY" || reply=""
  REPLY="${reply:-$default}"
}

# ── .env writer ───────────────────────────────────────────────────────────────
# Writes or updates a single KEY=VALUE line in the .env file.
# If the key already exists it is replaced; otherwise appended.

ENV_FILE=""   # set after INFRA_NAME is cloned

write_env() {
  local key="$1" value="$2"
  if grep -q "^${key}=" "$ENV_FILE" 2>/dev/null; then
    # Replace existing line (portable sed -i via temp file)
    local tmp
    tmp="$(mktemp)"
    sed "s|^${key}=.*|${key}=${value}|" "$ENV_FILE" > "$tmp"
    mv "$tmp" "$ENV_FILE"
  else
    printf '%s=%s\n' "$key" "$value" >> "$ENV_FILE"
  fi
}

# ── Phase 1: workspace path ───────────────────────────────────────────────────

if [[ -n "${TDB_ROOT:-}" ]]; then
  ROOT="$TDB_ROOT"
else
  ask_path "TalkingDB workspace path" "$DEFAULT_ROOT"
  ROOT="$REPLY"
fi

# ── Phase 2: DevPod preference ────────────────────────────────────────────────

LAUNCH_DEVPOD=0
if command -v devpod >/dev/null 2>&1; then
  if [[ -n "${TDB_AUTO_DEVPOD:-}" ]]; then
    case "$TDB_AUTO_DEVPOD" in [Yy]*|1) LAUNCH_DEVPOD=1 ;; esac
  else
    ask_yn "Launch DevPod once cloning finishes?" "Y"
    LAUNCH_DEVPOD="$REPLY"
  fi
fi

# ── Phase 3: clone repos ──────────────────────────────────────────────────────

mkdir -p "$ROOT"
ROOT="$(cd "$ROOT" && pwd)"   # resolve to absolute so relative inputs work
echo "▶ Workspace root: $ROOT"
cd "$ROOT"

if [[ ! -d "$INFRA_NAME/.git" ]]; then
  echo "▶ Cloning $INFRA_NAME"
  git clone "$INFRA_REPO" "$INFRA_NAME"
else
  echo "✓ $INFRA_NAME already present"
fi

REPO_YAML="$ROOT/$INFRA_NAME/local/repo.yaml"
if [[ ! -f "$REPO_YAML" ]]; then
  echo "✖ $REPO_YAML missing — aborting" >&2
  exit 1
fi

while IFS= read -r url; do
  [[ -z "$url" ]] && continue
  name="$(basename "${url%.git}")"
  if [[ -d "$name/.git" ]]; then
    echo "✓ $name already present"
  else
    echo "▶ Cloning $name"
    git clone "$url" "$name"
  fi
done < <(
  grep -E '^[[:space:]]*-[[:space:]]+https://' "$REPO_YAML" \
    | grep -oE 'https://[^[:space:]]+'
)

echo
echo "✔ All repositories ready under: $ROOT"

# ── Phase 4: LLM provider setup ───────────────────────────────────────────────

ENV_FILE="$ROOT/$INFRA_NAME/.env"

# Initialise .env if it doesn't exist, then lock permissions immediately
if [[ ! -f "$ENV_FILE" ]]; then
  touch "$ENV_FILE"
fi
chmod 600 "$ENV_FILE"

# Ensure .env is gitignored inside infra-tdb-platform
GITIGNORE="$ROOT/$INFRA_NAME/.gitignore"
if ! grep -qxF '.env' "$GITIGNORE" 2>/dev/null; then
  echo '.env' >> "$GITIGNORE"
fi

echo
echo "── LLM provider setup ───────────────────────────────────────"

# Allow full non-interactive override via env vars
if [[ -n "${TDB_LLM_PROVIDER:-}" && -n "${TDB_LLM_API_KEY:-}" ]]; then
  PROVIDER="${TDB_LLM_PROVIDER}"
  LLM_API_KEY="${TDB_LLM_API_KEY}"
  LLM_BASE_URL="${TDB_LLM_BASE_URL:-}"
else
  # Provider selection
  if [[ -n "$TTY" ]]; then
    printf '  Which LLM provider do you want to use?\n' >&2
    printf '    1) OpenAI\n' >&2
    printf '    2) Groq\n' >&2
    printf '    3) Ollama (cloud)\n' >&2
    printf '  Choice [1]: ' >&2
    read -r provider_choice <"$TTY" || provider_choice=""
    provider_choice="${provider_choice:-1}"
  else
    provider_choice="1"
  fi

  case "$provider_choice" in
    1) PROVIDER="openai" ;;
    2) PROVIDER="groq" ;;
    3) PROVIDER="ollama" ;;
    *)
      echo "  ✖ Invalid choice, defaulting to openai" >&2
      PROVIDER="openai"
      ;;
  esac

  # API key (silent input — never echoed)
  ask_secret "  ${PROVIDER} API key (Won't be visible in console, paste and press enter)"
  LLM_API_KEY="$REPLY"

  if [[ -z "$LLM_API_KEY" ]]; then
    echo "  ⚠ No API key entered — you can set it manually in $ENV_FILE" >&2
  fi

  # Base URL
  case "$PROVIDER" in
    openai) DEFAULT_URL="https://api.openai.com/v1" ;;
    groq)   DEFAULT_URL="https://api.groq.com/openai/v1" ;;
    ollama) DEFAULT_URL="" ;;   # no safe default — must be their hosted URL
  esac

  ask_input "  Base URL" "$DEFAULT_URL"
  LLM_BASE_URL="$REPLY"

  if [[ "$PROVIDER" == "ollama" && -z "$LLM_BASE_URL" ]]; then
    echo "  ⚠ No base URL entered for Ollama — you can set OLLAMA_BASE_URL manually in $ENV_FILE" >&2
  fi
fi

# Write to .env — provider-specific key names so services can reference them directly,
# plus a unified LLM_PROVIDER flag so your app knows which one is active.
write_env "LLM_PROVIDER" "$PROVIDER"

case "$PROVIDER" in
  openai)
    [[ -n "$LLM_API_KEY"   ]] && write_env "OPENAI_API_KEY"  "$LLM_API_KEY"
    [[ -n "$LLM_BASE_URL"  ]] && write_env "OPENAI_BASE_URL" "$LLM_BASE_URL"
    ;;
  groq)
    [[ -n "$LLM_API_KEY"   ]] && write_env "GROQ_API_KEY"    "$LLM_API_KEY"
    [[ -n "$LLM_BASE_URL"  ]] && write_env "GROQ_BASE_URL"   "$LLM_BASE_URL"
    ;;
  ollama)
    [[ -n "$LLM_API_KEY"   ]] && write_env "OLLAMA_API_KEY"  "$LLM_API_KEY"
    [[ -n "$LLM_BASE_URL"  ]] && write_env "OLLAMA_BASE_URL" "$LLM_BASE_URL"
    ;;
esac

echo "  ✔ Secrets written to $ENV_FILE (mode 600)"
echo

# ── Phase 5: launch DevPod ────────────────────────────────────────────────────

if [[ "$LAUNCH_DEVPOD" -eq 1 ]]; then
  echo "▶ Launching DevPod (workspace root: $ROOT)"
  cd "$ROOT"
  exec devpod up . \
    --ide vscode \
    --devcontainer-path "$INFRA_NAME/.devcontainer/devcontainer.json"
fi

echo "Next steps:"
echo "  cd \"$ROOT\""
if command -v devpod >/dev/null 2>&1; then
  echo "  devpod up . --ide vscode --devcontainer-path $INFRA_NAME/.devcontainer/devcontainer.json"
else
  echo "  # Install DevPod first: https://devpod.sh/docs/getting-started/install"
  echo "  devpod up . --ide vscode --devcontainer-path $INFRA_NAME/.devcontainer/devcontainer.json"
fi
echo
echo "Or, for native (legacy) run without DevPod:"
echo "  cd $INFRA_NAME && make sync && make local"
#!/usr/bin/env bash
# One-line host installer for the TalkingDB workspace.
#
#   curl -fsSL https://raw.githubusercontent.com/TalkingDB/infra-tdb-platform/main/scripts/bootstrap.sh | bash
#
# What it does:
#   1. Asks (once, upfront) where to create the TalkingDB folder
#      and whether to launch DevPod when cloning finishes.
#   2. Clones infra-tdb-platform + every active sibling in local/repo.yaml.
#   3. Asks which LLM provider to use (OpenAI / Groq / Ollama), then stores
#      credentials in Infisical if available (installing the CLI and walking
#      through login + project init if needed), falling back to a local
#      infra-tdb-platform/.env file (never committed) if Infisical isn't
#      usable for this user.
#   4. Optionally launches `devpod up . --ide vscode`.
#
# Non-interactive overrides (skip prompts):
#   TDB_ROOT=/some/path           # workspace location
#   TDB_AUTO_DEVPOD=Y|N           # whether to launch DevPod at the end
#   TDB_INFRA_REPO=<git url>      # alternate infra repo source (e.g. a fork)
#   TDB_USE_INFISICAL=Y|N         # skip the "use Infisical?" prompt
#   TDB_INFISICAL_PROJECT_ID=<id> # skip the project ID prompt (Project Settings → Project ID)
#   TDB_LLM_PROVIDER=openai|groq|ollama
#   TDB_LLM_API_KEY=<key>
#   TDB_LLM_BASE_URL=<url>        # required for ollama, optional override for others
#
# Idempotent: re-running skips repos that already exist, updates secrets
# in place (Infisical or .env), and skips `infisical init` if already linked.

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

# ── Unified secret writer ─────────────────────────────────────────────────────
# Dispatches to Infisical or .env depending on which backend is active.
# SECRET_BACKEND is set in Phase 4 to either "infisical" or "env".

write_secret() {
  local key="$1" value="$2"
  if [[ "$SECRET_BACKEND" == "infisical" ]]; then
    infisical secrets set LLM_PROVIDER=openai
    infisical secrets set "${key}=${value}" >/dev/null 2>&1 \
      && echo "  ✓ ${key} → Infisical" \
      || echo "  ✖ Failed to write ${key} to Infisical" >&2
  else
    write_env "$key" "$value"
  fi
}

# ── Infisical helpers ─────────────────────────────────────────────────────────

infisical_install() {
  echo "  ▶ Installing Infisical CLI..." >&2
  if command -v brew >/dev/null 2>&1; then
    brew install infisical/get-cli/infisical >/dev/null 2>&1
  elif command -v apt-get >/dev/null 2>&1; then
    curl -1sLf 'https://artifacts-cli.infisical.com/setup.deb.sh' 2>/dev/null | sudo -E bash >/dev/null 2>&1 \
      && sudo apt-get update -y >/dev/null 2>&1 \
      && sudo apt-get install -y infisical >/dev/null 2>&1
  elif command -v npm >/dev/null 2>&1; then
    npm install -g @infisical/cli >/dev/null 2>&1
  fi
  command -v infisical >/dev/null 2>&1
}

infisical_setup() {
  # Returns 0 (success, ready to use) or 1 (unavailable, caller should fall back).
  local infra_dir="$1"

  if [[ -z "$TTY" ]]; then
    echo "  ⚠ No terminal attached — skipping Infisical (non-interactive)" >&2
    return 1
  fi

  if ! command -v infisical >/dev/null 2>&1; then
    if ! infisical_install; then
      echo "  ⚠ Could not install Infisical CLI — falling back to .env" >&2
      return 1
    fi
    echo "  ✓ Infisical CLI installed" >&2
  fi

  # Already logged in?
  if ! infisical user whoami >/dev/null 2>&1; then
    echo "  ▶ Logging in to Infisical (opens your browser)..." >&2
    # IMPORTANT: when this script is run via `curl ... | bash`, stdin is the
    # curl pipe, not the keyboard. `infisical login`'s interactive prompts
    # inherit that exhausted pipe and immediately hit EOF, which surfaces as
    # "error: ^D / Unable to parse domain url". Redirecting its stdin to
    # /dev/tty explicitly (same trick our own ask_* helpers use) fixes this
    # on every platform, not just Windows.
    if [[ -z "$TTY" ]] || ! infisical login <"$TTY"; then
      echo "  ⚠ Infisical login failed or was cancelled — falling back to .env" >&2
      return 1
    fi
  else
    echo "  ✓ Already logged in to Infisical" >&2
  fi

  # Already linked to a project in this repo?
  if [[ -f "$infra_dir/.infisical.json" ]]; then
    echo "  ✓ Already linked to an Infisical project" >&2
    return 0
  fi

  # Ask for the project ID directly rather than relying on infisical init's
  # interactive picker (every user/org has their own project — there's no
  # single shared ID we can default to). Find this in the Infisical
  # dashboard under Project Settings → Project ID.
  local project_id env_name
  if [[ -n "${TDB_INFISICAL_PROJECT_ID:-}" ]]; then
    project_id="$TDB_INFISICAL_PROJECT_ID"
  else
    ask_input "  Infisical project ID (leave blank to pick interactively)" ""
    project_id="$REPLY"
  fi

  if [[ -n "$project_id" ]]; then
    ask_input "  Infisical environment" "dev"
    env_name="$REPLY"

    # .infisical.json is just {"workspaceId": ..., "defaultEnvironment": ...} —
    # exactly what `infisical init` would write, so we can create it directly
    # and skip the interactive org/project picker entirely.
    cat > "$infra_dir/.infisical.json" <<JSON
{
  "workspaceId": "${project_id}",
  "defaultEnvironment": "${env_name}"
}
JSON

    # Validate the ID actually works before trusting this backend
    if ! (cd "$infra_dir" && infisical secrets >/dev/null 2>&1); then
      echo "  ⚠ Could not access project '$project_id' — check the ID and your access — falling back to .env" >&2
      rm -f "$infra_dir/.infisical.json"
      return 1
    fi
    echo "  ✓ Linked to Infisical project $project_id ($env_name)" >&2
    return 0
  fi

  echo "  ▶ No project ID given — launching interactive picker..." >&2
  (cd "$infra_dir" && infisical init <"$TTY")
  if [[ ! -f "$infra_dir/.infisical.json" ]]; then
    echo "  ⚠ Infisical project link failed — falling back to .env" >&2
    return 1
  fi

  return 0
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
ROOT="$(cd "$ROOT" && pwd)"
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

# ── Phase 4: secret backend + LLM provider setup ──────────────────────────────

ENV_FILE="$ROOT/$INFRA_NAME/.env"

echo
echo "── Secrets setup ────────────────────────────────────────────"

SECRET_BACKEND="env"

if [[ -n "${TDB_USE_INFISICAL:-}" ]]; then
  case "$TDB_USE_INFISICAL" in [Yy]*|1) WANT_INFISICAL=1 ;; *) WANT_INFISICAL=0 ;; esac
else
  ask_yn "  Use Infisical for secrets?" "Y"
  WANT_INFISICAL="$REPLY"
fi

if [[ "$WANT_INFISICAL" -eq 1 ]]; then
  if infisical_setup "$ROOT/$INFRA_NAME"; then
    SECRET_BACKEND="infisical"
  fi
fi

if [[ "$SECRET_BACKEND" == "env" ]]; then
  # Initialise .env if it doesn't exist, then lock permissions immediately
  [[ -f "$ENV_FILE" ]] || touch "$ENV_FILE"
  chmod 600 "$ENV_FILE"

  # Ensure .env is gitignored inside infra-tdb-platform
  GITIGNORE="$ROOT/$INFRA_NAME/.gitignore"
  if ! grep -qxF '.env' "$GITIGNORE" 2>/dev/null; then
    echo '.env' >> "$GITIGNORE"
  fi
  echo "  ℹ Using local .env at $ENV_FILE" >&2
else
  echo "  ℹ Using Infisical for secret storage" >&2
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
  ask_secret "  ${PROVIDER} API key"
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

# Write secrets — provider-specific key names so services can reference them directly,
# plus a unified LLM_PROVIDER flag so your app knows which one is active.
# Dispatches to Infisical or .env automatically based on SECRET_BACKEND.
write_secret "LLM_PROVIDER" "$PROVIDER"

case "$PROVIDER" in
  openai)
    [[ -n "$LLM_API_KEY"   ]] && write_secret "OPENAI_API_KEY"  "$LLM_API_KEY"
    [[ -n "$LLM_BASE_URL"  ]] && write_secret "OPENAI_BASE_URL" "$LLM_BASE_URL"
    ;;
  groq)
    [[ -n "$LLM_API_KEY"   ]] && write_secret "GROQ_API_KEY"    "$LLM_API_KEY"
    [[ -n "$LLM_BASE_URL"  ]] && write_secret "GROQ_BASE_URL"   "$LLM_BASE_URL"
    ;;
  ollama)
    [[ -n "$LLM_API_KEY"   ]] && write_secret "OLLAMA_API_KEY"  "$LLM_API_KEY"
    [[ -n "$LLM_BASE_URL"  ]] && write_secret "OLLAMA_BASE_URL" "$LLM_BASE_URL"
    ;;
esac

echo
if [[ "$SECRET_BACKEND" == "infisical" ]]; then
  echo "  ✔ Secrets stored in Infisical"
  echo "  ℹ Run services with: infisical run -- <your command>"
else
  echo "  ✔ Secrets written to $ENV_FILE (mode 600)"
fi
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
#!/usr/bin/env bash
# One-line host installer for the TalkingDB workspace.
#
#   curl -fsSL https://raw.githubusercontent.com/TalkingDB/infra-tdb-platform/main/scripts/bootstrap.sh | bash
#
# What it does:
#   1. Asks (once, upfront) where to create the TalkingDB folder
#      and whether to launch DevPod when cloning finishes.
#   2. Clones infra-tdb-platform + every active sibling in local/repo.yaml.
#   3. Asks how secrets should be managed (Infisical or .env) and which
#      LLM provider to use (local Ollama or cloud OpenAI/Grok), then
#      performs that setup on THIS machine — writing module-ttt/.env so
#      it's already in place (bind-mounted) by the time DevPod starts.
#      This runs here, not inside postCreateCommand, because DevPod does
#      not attach your terminal's stdin to lifecycle commands, so prompts
#      there never show up and silently fall back to defaults.
#   4. Optionally launches `devpod up . --ide vscode`.
#
# Non-interactive overrides (skip prompts):
#   TDB_ROOT=/some/path           # workspace location
#   TDB_AUTO_DEVPOD=Y|N           # whether to launch DevPod at the end
#   TDB_INFRA_REPO=<git url>      # alternate infra repo source (e.g. a fork)
#   LLM_PROVIDER=ollama|openai|grok
#   OPENAI_API_KEY=...        # required if LLM_PROVIDER=openai
#   GROK_API_KEY=...          # required if LLM_PROVIDER=grok
#   OLLAMA_BASE_URL=...       # override for LLM_PROVIDER=ollama
#
# Idempotent: re-running skips repos that already exist.

set -euo pipefail

INFRA_REPO="${TDB_INFRA_REPO:-https://github.com/vamsi-a-hash/infra-tdb-platform.git}"
INFRA_NAME="infra-tdb-platform"
DEFAULT_ROOT="$PWD/TalkingDB"

if [[ -r /dev/tty ]]; then TTY=/dev/tty; else TTY=; fi

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

ask() {
  # generic free-text/number prompt -> sets REPLY (empty default if no TTY)
  local prompt="$1" default="${2:-}" reply
  if [[ -z "$TTY" ]]; then REPLY="$default"; return; fi
  printf '%s' "$prompt" >&2
  read -r reply <"$TTY" || reply=""
  REPLY="${reply:-$default}"
}

if [[ -n "${TDB_ROOT:-}" ]]; then
  ROOT="$TDB_ROOT"
else
  ask_path "TalkingDB workspace path" "$DEFAULT_ROOT"
  ROOT="$REPLY"
fi

LAUNCH_DEVPOD=0
if command -v devpod >/dev/null 2>&1; then
  if [[ -n "${TDB_AUTO_DEVPOD:-}" ]]; then
    case "$TDB_AUTO_DEVPOD" in [Yy]*|1) LAUNCH_DEVPOD=1 ;; esac
  else
    ask_yn "Launch DevPod once cloning finishes?" "Y"
    LAUNCH_DEVPOD="$REPLY"
  fi
fi

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

# ------------------------------------------------------------------------
# LLM provider + secrets setup. Runs here (host, real TTY) rather than in
# postCreateCommand, and writes straight into module-ttt/.env so it's
# already configured — via bind mount — by the time the container starts.
# ------------------------------------------------------------------------
MODULE_DIR="$ROOT/module-ttt"
ENV_FILE="$MODULE_DIR/.env"
SECRETS_MODE_FILE="$MODULE_DIR/.secrets_mode"

if [[ -d "$MODULE_DIR" ]]; then
  if [[ ! -f "$ENV_FILE" && -f "$MODULE_DIR/.env.example" ]]; then
    cp "$MODULE_DIR/.env.example" "$ENV_FILE"
  fi
  touch "$ENV_FILE"

  set_var() {
    local name="$1" value="$2"
    if grep -q "^${name}=" "$ENV_FILE" 2>/dev/null; then
      sed -i.bak "s|^${name}=.*|${name}=${value}|" "$ENV_FILE" && rm -f "$ENV_FILE.bak"
    else
      echo "${name}=${value}" >> "$ENV_FILE"
    fi
  }


  if [[ -f "$SECRETS_MODE_FILE" ]]; then
    echo "✓ LLM provider already configured ($(cat "$SECRETS_MODE_FILE") / $(grep '^LLM_PROVIDER=' "$ENV_FILE" | cut -d= -f2)); skipping setup."
    echo "  Delete $SECRETS_MODE_FILE and rerun this script to reconfigure."
  else
    echo
    echo "▶ How should secrets be managed?"
    echo "  1) Infisical (recommended)"
    echo "  2) .env file"

    if [[ -n "${TDB_SECRETS_MODE:-}" ]]; then
      SECRETS_CHOICE_RAW="$TDB_SECRETS_MODE"
    else
      ask "Choose [1/2, default 1]: " "1"
      SECRETS_CHOICE_RAW="$REPLY"
    fi

    SECRETS_MODE="dotenv"
    INFISICAL_STORAGE_OK=1

    case "$SECRETS_CHOICE_RAW" in
      1|infisical)
        echo "▶ Setting up Infisical..."

        if ! command -v infisical >/dev/null 2>&1; then
          echo "  Installing Infisical CLI..."
          if command -v brew >/dev/null 2>&1; then
            brew install infisical/get-cli/infisical >/dev/null 2>&1 || true
          elif command -v scoop >/dev/null 2>&1; then
            scoop bucket add infisical https://github.com/Infisical/scoop-infisical.git >/dev/null 2>&1 || true
            scoop install infisical >/dev/null 2>&1 || true
          elif command -v npm >/dev/null 2>&1; then
            npm install -g @infisical/cli >/dev/null 2>&1 || true
          elif command -v apt-get >/dev/null 2>&1; then
            curl -1sLf 'https://artifacts-cli.infisical.com/setup.deb.sh' | sudo -E bash >/dev/null 2>&1 \
              && sudo apt-get install -y -qq infisical >/dev/null 2>&1 || true
          fi

          if command -v infisical >/dev/null 2>&1; then
            echo "  ✓ Infisical CLI installed"
          else
            echo "  ⚠ Could not install Infisical CLI automatically."
            echo "    Install it yourself (https://infisical.com/docs/cli/overview) and rerun this script."
            echo "  ⚠ Falling back to .env for now."
          fi
        fi

        if command -v infisical >/dev/null 2>&1; then
          echo "  Please log in to Infisical (follow any browser/URL prompt below):"
          # Was: `infisical login <"$TTY" >&2 2>/dev/null || infisical login`.
          # That redirected infisical's own stderr to /dev/null on the first
          # attempt - which is exactly where device-flow/browser login URLs
          # get printed - so the user never saw what to do, and the fallback
          # attempt had no TTY at all under `curl | bash`. Net effect: login
          # essentially could never succeed. Fixed to one attempt with stdin
          # from the real terminal and nothing suppressed.
          if infisical login <"$TTY"; then
            SECRETS_MODE="infisical"
            echo "  ✓ Logged in to Infisical"
          else
            echo "  ⚠ Infisical login failed. Falling back to .env."
          fi
        fi
        ;;
      *)
        echo "  Using .env for secrets."
        ;;
    esac

    store_secret() {
      local name="$1" value="$2"
      if [[ "$SECRETS_MODE" == "infisical" ]]; then
        # Must run from $MODULE_DIR: that's where .infisical.json links this
        # workspace to its Infisical project. Running from $ROOT (the old
        # behavior - this function was never `cd`'d into $MODULE_DIR) means
        # there's no linked project in scope, so every call failed here,
        # silently, every time - `--env=dev` is likewise required, not
        # optional. Errors are shown now instead of swallowed entirely, so a
        # wrong environment slug or other Infisical-side issue is visible
        # instead of just quietly landing in .env with no explanation.
        if ! (cd "$MODULE_DIR" && infisical secrets set "$name=$value" --env=dev); then
          echo "  ⚠ Failed to store $name in Infisical, writing to .env instead."
          set_var "$name" "$value"
          INFISICAL_STORAGE_OK=0
        fi
      else
        set_var "$name" "$value"
      fi
    }

    echo
    echo "▶ Which LLM provider should this workspace use?"
    echo "  1) Local (Qwen 3 4B via Ollama — recommended, runs on this machine)"
    echo "  2) Cloud (OpenAI or Grok)"

    if [[ -n "${TDB_LLM_PROVIDER:-}" ]]; then
      case "$TDB_LLM_PROVIDER" in
        openai) PROVIDER_CHOICE_RAW=2; CLOUD_CHOICE_RAW=1 ;;
        grok)   PROVIDER_CHOICE_RAW=2; CLOUD_CHOICE_RAW=2 ;;
        *)      PROVIDER_CHOICE_RAW=1 ;;
      esac
    else
      ask "Choose [1/2, default 1]: " "1"
      PROVIDER_CHOICE_RAW="$REPLY"
    fi

    if [[ "$PROVIDER_CHOICE_RAW" == "2" ]]; then
      echo
      echo "▶ Which cloud provider?"
      echo "  1) OpenAI (GPT-5.4-Mini)"
      echo "  2) Grok (Grok 4.3)"

      if [[ -z "${CLOUD_CHOICE_RAW:-}" ]]; then
        ask "Choose [1/2, default 1]: " "1"
        CLOUD_CHOICE_RAW="$REPLY"
      fi

      if [[ "$CLOUD_CHOICE_RAW" == "2" ]]; then
        LLM_PROVIDER="grok"
        if [[ -n "${TDB_GROK_API_KEY:-}" ]]; then
          store_secret "GROK_API_KEY" "$TDB_GROK_API_KEY"
        else
          ask "  Enter your GROK_API_KEY: "
          store_secret "GROK_API_KEY" "$REPLY"
        fi
      else
        LLM_PROVIDER="openai"
        if [[ -n "${TDB_OPENAI_API_KEY:-}" ]]; then
          store_secret "OPENAI_API_KEY" "$TDB_OPENAI_API_KEY"
        else
          ask "  Enter your OPENAI_API_KEY: "
          store_secret "OPENAI_API_KEY" "$REPLY"
        fi
      fi


      store_secret "LLM_PROVIDER" "$LLM_PROVIDER"
      echo "✔ Configured $LLM_PROVIDER as the LLM provider."

    else
      LLM_PROVIDER="ollama"
      store_secret "LLM_PROVIDER" "$LLM_PROVIDER"


      echo
      echo "▶ Setting up local model (Qwen 3 4B via Ollama) on this machine..."

      if ! command -v ollama >/dev/null 2>&1; then
        echo "  Installing Ollama..."
        if [[ "$OSTYPE" == "darwin"* ]] && command -v brew >/dev/null 2>&1; then
          brew install ollama >/dev/null 2>&1 || true
        elif command -v curl >/dev/null 2>&1 && [[ "$OSTYPE" == "linux-gnu"* ]]; then
          curl -fsSL https://ollama.com/install.sh | sh
        else
          echo "  ⚠ Could not auto-install Ollama on this OS."
          echo "    Install it from https://ollama.com/download, then rerun this script."
        fi
      fi

      if command -v ollama >/dev/null 2>&1; then
        echo "  Pulling qwen3:4b (this can take a few minutes)..."
        ollama pull qwen3:4b || echo "  ⚠ Pull failed — run 'ollama pull qwen3:4b' manually later."
      fi

      # ttt-service runs inside the DevPod container, so it must reach
      # Ollama on the host via host.docker.internal, not localhost.
      OLLAMA_URL="${TDB_OLLAMA_BASE_URL:-http://host.docker.internal:11434/v1}"
      if [[ -z "${TDB_OLLAMA_BASE_URL:-}" ]]; then
        ask "  Ollama base URL for the container to use [default: $OLLAMA_URL]: " "$OLLAMA_URL"
        OLLAMA_URL="$REPLY"
      fi

      store_secret "OLLAMA_BASE_URL" "$OLLAMA_URL"
      echo "✔ Configured Ollama (qwen3:4b) as the LLM provider."
    fi

    if [[ "$SECRETS_MODE" == "infisical" && "$INFISICAL_STORAGE_OK" -eq 0 ]]; then
      SECRETS_MODE="dotenv"
      echo "  ⚠ One or more secrets fell back to .env — recording secrets mode as dotenv, not infisical."
    fi
    echo "$SECRETS_MODE" > "$SECRETS_MODE_FILE"
  fi
else
  echo "⚠ module-ttt not found under $ROOT — skipping LLM provider setup."
fi

if [[ "$LAUNCH_DEVPOD" -eq 1 ]]; then
  echo "▶ Launching DevPod (workspace root: $ROOT)"
  cd "$ROOT"
  exec devpod up . \
    --ide vscode \
    --devcontainer-path "$INFRA_NAME/.devcontainer/devcontainer.json"
fi

echo
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
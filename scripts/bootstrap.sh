#!/usr/bin/env bash
# One-line host installer for the TalkingDB workspace.
#
#   curl -fsSL https://raw.githubusercontent.com/TalkingDB/infra-tdb-platform/main/scripts/bootstrap.sh | bash
#
# What it does:
#   1. Asks (once, upfront) where to create the TalkingDB folder
#      and whether to launch DevPod when cloning finishes.
#   2. Clones infra-tdb-platform + every active sibling in local/repo.yaml.
#   3. Optionally launches `devpod up . --ide vscode`.
#
# Non-interactive overrides (skip prompts):
#   TDB_ROOT=/some/path           # workspace location
#   TDB_AUTO_DEVPOD=Y|N           # whether to launch DevPod at the end
#   TDB_INFRA_REPO=<git url>      # alternate infra repo source (e.g. a fork)
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

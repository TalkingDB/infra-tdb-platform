set -euo pipefail

# Derive paths from this script's own location so the container path
# is whatever DevPod chose (varies with parent folder name).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
WORKSPACE="$(cd "$INFRA_DIR/.." && pwd)"
MODULE_DIR="$WORKSPACE/module-ttt"

echo "▶ Trusting sibling repos in the workspace (WSL2 bind-mount ownership mismatch)"
for repo_git in "$WORKSPACE"/*/.git; do
  [[ -d "$repo_git" ]] && git config --global --add safe.directory "$(dirname "$repo_git")" || true
done

echo "▶ Stripping CRLF from shell scripts, Makefiles, and env files across workspace"
find "$WORKSPACE" -type f \( -name "*.sh" -o -name "Makefile" -o -name ".env" -o -name ".env.*" -o -name "env_example.sh" \) \
  -not -path "*/.git/*" \
  -not -path "*/.venv/*" \
  -not -path "*/node_modules/*" \
  -exec sed -i 's/\r$//' {} + 2>/dev/null || true

echo "▶ Disabling filemode tracking on sibling repos (NTFS bind mounts can't chmod)"
for repo_git in "$WORKSPACE"/*/.git; do
  [[ -d "$repo_git" ]] && git -C "$(dirname "$repo_git")" config core.filemode false || true
done

cd "$INFRA_DIR"

echo "▶ Cloning sibling repositories listed in local/repo.yaml"
make clone

echo "▶ Configuring container git to redirect GitHub SSH URLs through HTTPS"
git config --global --unset-all "url.https://github.com/.insteadOf" 2>/dev/null || true
mapfile -t prefixes < <(
  {
    find "$WORKSPACE" -maxdepth 3 -name config -path '*/.git/config' -print0 2>/dev/null \
      | xargs -0 -r grep -hoE 'git@github[^:]*:|ssh://git@github[^/]*/' 2>/dev/null
    echo "git@github.com:"
  } | sort -u
)
for prefix in "${prefixes[@]}"; do
  [[ -z "$prefix" ]] && continue
  git config --global --add "url.https://github.com/.insteadOf" "$prefix"
  echo "  ✓ $prefix → https://github.com/"
done

echo "▶ Syncing repositories and installing Poetry dependencies (mode=git)"
make sync

echo "▶ Installing LibreOffice"

if ! command -v soffice >/dev/null 2>&1; then
  sudo rm -f /etc/apt/sources.list.d/yarn.list
  sudo apt-get update -qq
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
    libreoffice-writer >/dev/null
fi

if ! command -v infisical >/dev/null 2>&1; then
  curl -1sLf 'https://artifacts-cli.infisical.com/setup.deb.sh' | sudo -E bash
  sudo apt-get update -qq
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq infisical >/dev/null
fi

echo "✔ LibreOffice installed"

if [[ -d "$MODULE_DIR" ]]; then
  if [[ ! -f "$MODULE_DIR/.env" && -f "$MODULE_DIR/.env.example" ]]; then
    echo "▶ Bootstrapping module-ttt/.env from .env.example"
    cp "$MODULE_DIR/.env.example" "$MODULE_DIR/.env"
  fi

  echo "▶ Pre-downloading spaCy en_core_web_md into module-ttt's venv"
  (cd "$MODULE_DIR" && poetry run python -m spacy download en_core_web_md) \
    || echo "⚠ spaCy model download failed; 'make local' will retry on first run"

  echo "▶ Installing git hooks in module-ttt"
  (cd "$MODULE_DIR" && make install-hooks) \
    || echo "⚠ git hooks install skipped"
fi

echo "▶ Generating .vscode/launch.json from sibling debugpy ports"
make debug-config || echo "⚠ debug-config skipped (no debugpy ports detected)"

echo "✔ Workspace ready. Run 'make local' from $INFRA_DIR to start the platform."
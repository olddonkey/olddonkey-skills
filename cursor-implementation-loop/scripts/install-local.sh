#!/usr/bin/env bash
# Install cursor-implementation-loop into this machine's Cursor user plugins dir.
# Default: copy (most reliable). Pass --link to symlink for faster iteration.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: install-local.sh [--link|--copy] [--force] [--skip-selftest]

  --copy          Copy plugin into ~/.cursor/plugins/local/ (default)
  --link          Symlink instead of copy (faster iteration; some Cursor
                  builds reject links whose target is outside that dir)
  --force         Replace an existing install at the destination
  --skip-selftest Skip running gate-selftest.sh after install

After install: restart Cursor, or run "Developer: Reload Window".
EOF
}

MODE=copy
FORCE=0
RUN_SELFTEST=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    --copy) MODE=copy; shift ;;
    --link) MODE=link; shift ;;
    --force) FORCE=1; shift ;;
    --skip-selftest) RUN_SELFTEST=0; shift ;;
    -h|--help) usage; exit 0 ;;
    *)
      echo "unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DEST_DIR="${HOME}/.cursor/plugins/local"
DEST="${DEST_DIR}/cursor-implementation-loop"

if [[ ! -f "$PLUGIN_ROOT/.cursor-plugin/plugin.json" ]]; then
  echo "error: plugin manifest missing at $PLUGIN_ROOT/.cursor-plugin/plugin.json" >&2
  exit 1
fi

mkdir -p "$DEST_DIR"

if [[ -e "$DEST" || -L "$DEST" ]]; then
  if [[ "$FORCE" -eq 1 ]]; then
    rm -rf "$DEST"
  else
    echo "error: already installed at $DEST" >&2
    echo "re-run with --force to replace, or: rm -rf \"$DEST\"" >&2
    exit 1
  fi
fi

case "$MODE" in
  copy)
    # Prefer rsync when available (excludes .git if nested); fall back to cp -R.
    if command -v rsync >/dev/null 2>&1; then
      rsync -a --delete \
        --exclude '.git/' \
        --exclude '.DS_Store' \
        "$PLUGIN_ROOT/" "$DEST/"
    else
      mkdir -p "$DEST"
      # shellcheck disable=SC2035
      cp -R "$PLUGIN_ROOT"/. "$DEST"/
    fi
    echo "installed (copy): $DEST"
    ;;
  link)
    ln -s "$PLUGIN_ROOT" "$DEST"
    echo "installed (symlink): $DEST -> $PLUGIN_ROOT"
    echo "note: if Cursor does not load the plugin, re-run with --copy --force"
    ;;
esac

echo
echo "Verify layout:"
echo "  manifest: $DEST/.cursor-plugin/plugin.json"
echo "  skill:    $DEST/skills/cursor-implementation-loop/SKILL.md"
echo "  agents:   $DEST/agents/"
ls -la "$DEST/.cursor-plugin/plugin.json" \
       "$DEST/skills/cursor-implementation-loop/SKILL.md" \
       "$DEST/agents/" >/dev/null
echo "  ok"

if [[ "$RUN_SELFTEST" -eq 1 ]]; then
  echo
  echo "Running gate selftest..."
  bash "$DEST/skills/cursor-implementation-loop/scripts/gate-selftest.sh"
fi

cat <<EOF

Next on this machine:
  1. Restart Cursor, or Command Palette → "Developer: Reload Window"
  2. Confirm under Customize that cursor-implementation-loop is present
  3. Optional but recommended: pin a model in
     $DEST/agents/loop-implementer.md
     (shipped value is model: inherit — a placeholder)
  4. In a target repo, run:
     /cursor-implementation-loop <your plan>

Uninstall:
  rm -rf "$DEST"
EOF

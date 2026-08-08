#!/usr/bin/env bash
# Install cursor-implementation-loop from a managed checkout without prompts.

set -euo pipefail

COPY_STAGE_ROOT=""
COPY_BACKUP_ROOT=""
COPY_BACKUP_ACTIVE=0
COPY_REPLACEMENT_COMMITTED=0
COPY_DEST=""
AGENT_STAGE_ROOT=""

cleanup() { # $1=status to preserve
  local status="$1" preserve_backup=0
  trap - EXIT HUP INT TERM

  if [[ $COPY_BACKUP_ACTIVE -eq 1 &&
        $COPY_REPLACEMENT_COMMITTED -eq 0 ]]; then
    if [[ -n "$COPY_BACKUP_ROOT" && -n "$COPY_DEST" &&
          ! -e "$COPY_DEST" && ! -L "$COPY_DEST" &&
          ( -e "$COPY_BACKUP_ROOT/cursor-implementation-loop" ||
            -L "$COPY_BACKUP_ROOT/cursor-implementation-loop" ) ]] &&
       mv "$COPY_BACKUP_ROOT/cursor-implementation-loop" "$COPY_DEST" \
         2>/dev/null; then
      COPY_BACKUP_ACTIVE=0
    else
      preserve_backup=1
      printf 'install-cursor: warning: prior bare-copy install is preserved at %s; manual recovery may be required\n' \
        "$COPY_BACKUP_ROOT/cursor-implementation-loop" >&2 || true
    fi
  fi
  if [[ -n "$COPY_STAGE_ROOT" ]]; then
    rm -rf "$COPY_STAGE_ROOT" || true
  fi
  if [[ -n "$AGENT_STAGE_ROOT" ]]; then
    rm -rf "$AGENT_STAGE_ROOT" || true
  fi
  if [[ -n "$COPY_BACKUP_ROOT" && $preserve_backup -eq 0 ]]; then
    rm -rf "$COPY_BACKUP_ROOT" || true
  fi
  exit "$status"
}

trap 'cleanup "$?"' EXIT
trap 'cleanup 129' HUP
trap 'cleanup 130' INT
trap 'cleanup 143' TERM

usage() {
  cat <<'USAGE'
Usage:
  curl -fsSL https://raw.githubusercontent.com/olddonkey/olddonkey-skills/main/install-cursor.sh | bash
  bash install-cursor.sh [--copy]
  bash install-cursor.sh --help

Options:
  --copy  Force bare-copy mode instead of installing a local-plugin symlink.
  --help  Show this help and exit.

Environment overrides:
  OLDDONKEY_SKILLS_DIR   Checkout location (default: $HOME/olddonkey-skills)
  OLDDONKEY_SKILLS_REPO  Clone source (default: https://github.com/olddonkey/olddonkey-skills)
                         A local repository path is supported.

Uninstall one-liners:
  Symlink mode:
    rm "$HOME/.cursor/plugins/local/cursor-implementation-loop"
  Bare-copy mode:
    rm -rf "$HOME/.cursor/skills/cursor-implementation-loop" && rm -f "$HOME/.cursor/agents/loop-implementer.md" "$HOME/.cursor/agents/loop-independent-reviewer.md"
  Managed checkout, after removing the install:
    rm -rf "${OLDDONKEY_SKILLS_DIR:-$HOME/olddonkey-skills}"
USAGE
}

error() {
  printf 'install-cursor: %s\n' "$1" >&2
  exit 1
}

path_exists() { # $1=path, including a broken symbolic link
  [[ -e "$1" || -L "$1" ]]
}

FORCE_COPY=0
for argument in "$@"; do
  case "$argument" in
    --copy)
      FORCE_COPY=1
      ;;
    --help)
      usage
      exit 0
      ;;
    *)
      printf 'install-cursor: unknown option: %s\n' "$argument" >&2
      usage >&2
      exit 2
      ;;
  esac
done

[[ -n "${HOME:-}" ]] || error 'HOME is not set'
[[ -d "$HOME" ]] || error "HOME is not an existing directory: $HOME"
command -v git >/dev/null 2>&1 || \
  error 'git is required; install Git and rerun this installer'

export GIT_TERMINAL_PROMPT=0
export GCM_INTERACTIVE=Never

CHECKOUT_DIR="${OLDDONKEY_SKILLS_DIR:-$HOME/olddonkey-skills}"
REPO_SOURCE="${OLDDONKEY_SKILLS_REPO:-https://github.com/olddonkey/olddonkey-skills}"
[[ -n "$CHECKOUT_DIR" ]] || error 'OLDDONKEY_SKILLS_DIR must not be empty'
[[ -n "$REPO_SOURCE" ]] || error 'OLDDONKEY_SKILLS_REPO must not be empty'

if path_exists "$CHECKOUT_DIR"; then
  CHECKOUT_TOPLEVEL=""
  if ! CHECKOUT_TOPLEVEL="$(git -C "$CHECKOUT_DIR" rev-parse \
      --show-toplevel 2>/dev/null)"; then
    error "$CHECKOUT_DIR exists but is not a Git checkout; move it aside or choose another OLDDONKEY_SKILLS_DIR"
  fi
  CHECKOUT_PHYSICAL="$(cd "$CHECKOUT_DIR" && pwd -P)" || \
    error "cannot resolve checkout directory: $CHECKOUT_DIR"
  TOPLEVEL_PHYSICAL="$(cd "$CHECKOUT_TOPLEVEL" && pwd -P)" || \
    error "cannot resolve Git checkout root: $CHECKOUT_TOPLEVEL"
  [[ "$CHECKOUT_PHYSICAL" == "$TOPLEVEL_PHYSICAL" ]] || \
    error "$CHECKOUT_DIR exists inside another Git checkout but is not its root; refusing to update it"

  ORIGIN_URL=""
  if ! ORIGIN_URL="$(git -C "$CHECKOUT_DIR" remote get-url origin 2>/dev/null)"; then
    error "$CHECKOUT_DIR is a Git checkout without an origin; expected origin $REPO_SOURCE and will not modify it"
  fi
  [[ "$ORIGIN_URL" == "$REPO_SOURCE" ]] || \
    error "$CHECKOUT_DIR has origin $ORIGIN_URL, expected $REPO_SOURCE; refusing to modify the wrong repository"

  printf 'Updating checkout with git pull --ff-only: %s\n' "$CHECKOUT_DIR"
  if ! git -C "$CHECKOUT_DIR" pull --ff-only; then
    error "git pull --ff-only failed in $CHECKOUT_DIR; resolve the checkout state and rerun"
  fi
else
  CHECKOUT_PARENT="$(dirname "$CHECKOUT_DIR")"
  if ! mkdir -p "$CHECKOUT_PARENT"; then
    error "cannot create checkout parent directory: $CHECKOUT_PARENT"
  fi
  printf 'Cloning checkout: %s\n' "$CHECKOUT_DIR"
  if [[ -d "$REPO_SOURCE" ]]; then
    if ! git clone --depth 1 --no-local "$REPO_SOURCE" "$CHECKOUT_DIR"; then
      error "git clone from local path $REPO_SOURCE failed; check the path and permissions, then rerun"
    fi
  elif ! git clone --depth 1 "$REPO_SOURCE" "$CHECKOUT_DIR"; then
    error "git clone from $REPO_SOURCE failed; check the source and network access, then rerun"
  fi
fi

PLUGIN_SOURCE="$CHECKOUT_DIR/cursor-implementation-loop"
SKILL_SOURCE="$PLUGIN_SOURCE/skills/cursor-implementation-loop"
IMPLEMENTER_SOURCE="$PLUGIN_SOURCE/agents/loop-implementer.md"
REVIEWER_SOURCE="$PLUGIN_SOURCE/agents/loop-independent-reviewer.md"
SOURCE_GATE="$SKILL_SOURCE/scripts/gate-selftest.sh"

[[ -d "$PLUGIN_SOURCE" ]] || \
  error "checkout is missing the Cursor plugin directory: $PLUGIN_SOURCE"
[[ -d "$SKILL_SOURCE" ]] || \
  error "checkout is missing the Cursor skill directory: $SKILL_SOURCE"
[[ -f "$IMPLEMENTER_SOURCE" ]] || \
  error "checkout is missing agent file: $IMPLEMENTER_SOURCE"
[[ -f "$REVIEWER_SOURCE" ]] || \
  error "checkout is missing agent file: $REVIEWER_SOURCE"
[[ -f "$SOURCE_GATE" ]] || \
  error "checkout is missing gate selftest: $SOURCE_GATE"

PLUGIN_PARENT="$HOME/.cursor/plugins/local"
PLUGIN_LINK="$PLUGIN_PARENT/cursor-implementation-loop"
CURSOR_SKILLS="$HOME/.cursor/skills"
CURSOR_AGENTS="$HOME/.cursor/agents"
COPY_DEST="$CURSOR_SKILLS/cursor-implementation-loop"

symlink_points_to_plugin() {
  local link_target="" link_physical="" source_physical=""
  [[ -L "$PLUGIN_LINK" ]] || return 1
  link_target="$(readlink "$PLUGIN_LINK")" || return 1
  link_physical="$(cd "$PLUGIN_PARENT" && cd "$link_target" && pwd -P)" || \
    return 1
  source_physical="$(cd "$PLUGIN_SOURCE" && pwd -P)" || return 1
  [[ "$link_physical" == "$source_physical" ]]
}

install_symlink() {
  local existing_target=""

  if path_exists "$PLUGIN_LINK"; then
    if symlink_points_to_plugin; then
      return 0
    fi
    if [[ -L "$PLUGIN_LINK" ]]; then
      existing_target="$(readlink "$PLUGIN_LINK" 2>/dev/null || true)"
      error "$PLUGIN_LINK already exists as a different symlink (target: $existing_target); move or remove it, then rerun"
    fi
    error "$PLUGIN_LINK already exists and is not the expected symlink; move or remove it, then rerun"
  fi

  if ! mkdir -p "$PLUGIN_PARENT"; then
    printf 'install-cursor: warning: cannot create %s; falling back to bare-copy mode\n' \
      "$PLUGIN_PARENT" >&2
    return 1
  fi
  if ln -s "$PLUGIN_SOURCE" "$PLUGIN_LINK"; then
    return 0
  fi
  if path_exists "$PLUGIN_LINK"; then
    error "$PLUGIN_LINK appeared while the installer was running; refusing to clobber it"
  fi
  printf 'install-cursor: warning: cannot create the local-plugin symlink; falling back to bare-copy mode\n' >&2
  return 1
}

install_copy() {
  local staged_skill="" backup_skill="" target=""

  if ! mkdir -p "$CURSOR_SKILLS" "$CURSOR_AGENTS"; then
    error "cannot create bare-copy directories under $HOME/.cursor"
  fi

  for target in \
      "$CURSOR_AGENTS/loop-implementer.md" \
      "$CURSOR_AGENTS/loop-independent-reviewer.md"; do
    if [[ -d "$target" && ! -L "$target" ]]; then
      error "$target already exists as a directory; move or remove it, then rerun"
    fi
  done

  AGENT_STAGE_ROOT="$(mktemp -d \
    "$CURSOR_AGENTS/.cursor-agents.install.XXXXXX")" || \
    error "cannot create an agent staging directory in $CURSOR_AGENTS"
  if ! cp "$IMPLEMENTER_SOURCE" "$REVIEWER_SOURCE" "$AGENT_STAGE_ROOT/"; then
    error "cannot stage Cursor agent files from $PLUGIN_SOURCE/agents"
  fi

  COPY_STAGE_ROOT="$(mktemp -d \
    "$CURSOR_SKILLS/.cursor-implementation-loop.install.XXXXXX")" || \
    error "cannot create a staging directory in $CURSOR_SKILLS"
  staged_skill="$COPY_STAGE_ROOT/cursor-implementation-loop"
  if ! cp -R "$SKILL_SOURCE" "$staged_skill"; then
    error "cannot stage the Cursor skill from $SKILL_SOURCE"
  fi

  if path_exists "$COPY_DEST"; then
    COPY_BACKUP_ROOT="$(mktemp -d \
      "$CURSOR_SKILLS/.cursor-implementation-loop.backup.XXXXXX")" || \
      error "cannot create a replacement backup in $CURSOR_SKILLS"
    backup_skill="$COPY_BACKUP_ROOT/cursor-implementation-loop"
    COPY_BACKUP_ACTIVE=1
    if ! mv "$COPY_DEST" "$backup_skill"; then
      COPY_BACKUP_ACTIVE=0
      error "cannot move the prior bare-copy skill aside: $COPY_DEST"
    fi
  fi

  if ! mv "$staged_skill" "$COPY_DEST"; then
    if [[ $COPY_BACKUP_ACTIVE -eq 1 && ! -e "$COPY_DEST" &&
          ! -L "$COPY_DEST" ]] &&
       mv "$COPY_BACKUP_ROOT/cursor-implementation-loop" "$COPY_DEST" \
         2>/dev/null; then
      COPY_BACKUP_ACTIVE=0
    fi
    error "cannot move the staged Cursor skill into place: $COPY_DEST"
  fi
  COPY_REPLACEMENT_COMMITTED=1
  if ! rmdir "$COPY_STAGE_ROOT"; then
    error "cannot remove the empty skill staging directory: $COPY_STAGE_ROOT"
  fi
  COPY_STAGE_ROOT=""

  if [[ $COPY_BACKUP_ACTIVE -eq 1 ]]; then
    if ! rm -rf "$COPY_BACKUP_ROOT"; then
      error "installed the new skill but could not remove its temporary backup: $COPY_BACKUP_ROOT"
    fi
    COPY_BACKUP_ACTIVE=0
    COPY_REPLACEMENT_COMMITTED=0
    COPY_BACKUP_ROOT=""
  fi

  for target in \
      "$CURSOR_AGENTS/loop-implementer.md" \
      "$CURSOR_AGENTS/loop-independent-reviewer.md"; do
    if [[ -L "$target" ]] && ! rm "$target"; then
      error "cannot replace agent symlink safely: $target"
    fi
    if ! mv "$AGENT_STAGE_ROOT/$(basename "$target")" "$target"; then
      error "cannot move the staged agent file into place: $target"
    fi
  done
  if ! rmdir "$AGENT_STAGE_ROOT"; then
    error "cannot remove the empty agent staging directory: $AGENT_STAGE_ROOT"
  fi
  AGENT_STAGE_ROOT=""
}

INSTALL_MODE=""
INSTALLED_GATE=""
VERIFY_TMPDIR=""
if [[ $FORCE_COPY -eq 1 ]]; then
  install_copy
  INSTALL_MODE="bare copy"
  INSTALLED_GATE="$COPY_DEST/scripts/gate-selftest.sh"
  VERIFY_TMPDIR="$CURSOR_SKILLS"
elif install_symlink; then
  INSTALL_MODE="symlink"
  INSTALLED_GATE="$PLUGIN_LINK/skills/cursor-implementation-loop/scripts/gate-selftest.sh"
  VERIFY_TMPDIR="$PLUGIN_PARENT"
else
  install_copy
  INSTALL_MODE="bare copy"
  INSTALLED_GATE="$COPY_DEST/scripts/gate-selftest.sh"
  VERIFY_TMPDIR="$CURSOR_SKILLS"
fi

printf 'Install mode: %s\n' "$INSTALL_MODE"
[[ -f "$INSTALLED_GATE" ]] || \
  error "installed gate selftest is missing: $INSTALLED_GATE; the install is not usable"

GATE_OUTPUT=""
GATE_STATUS=0
if GATE_OUTPUT="$(TMPDIR="$VERIFY_TMPDIR" bash "$INSTALLED_GATE" 2>&1)"; then
  GATE_STATUS=0
else
  GATE_STATUS=$?
fi
printf '%s\n' "$GATE_OUTPUT"

GATE_PASS_LINE=0
case $'\n'"$GATE_OUTPUT"$'\n' in
  *$'\nselftest: PASS'*$'\n')
    GATE_PASS_LINE=1
    ;;
esac
if [[ $GATE_STATUS -ne 0 || $GATE_PASS_LINE -ne 1 ]]; then
  error "installed gate selftest failed or omitted its PASS line; the install is not usable ($INSTALLED_GATE)"
fi

cat <<'NEXT_STEPS'
Next steps:
  1. Reload Cursor with "Developer: Reload Window".
  2. Invoke the workflow with /cursor-implementation-loop.
  3. ~/.cursor/agents/loop-implementer.md ships with model: inherit; pinning a real model is recommended (edit its frontmatter).
NEXT_STEPS

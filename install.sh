#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
install.sh - symlink teebox and its shell completion from this checkout.

Usage: ./install.sh [--bin-dir DIR] [--shell bash|zsh]... [--uninstall] [--dry-run]

  --bin-dir DIR   where the teebox link goes (default: first of $XDG_BIN_HOME,
                  ~/.local/bin, ~/bin that is on PATH, else ~/.local/bin)
  --shell NAME    completion for bash or zsh, repeatable (default: login shell, $SHELL)
  --uninstall     remove links that point into this checkout
  --dry-run       print the actions only

Only symlinks are created or replaced; an existing regular file is never touched.
Shell rc files are never edited: lines to add are printed.
EOF
}

say()  { echo "install: $*"; }
die()  { echo "install: $*" >&2; exit 1; }

[ "${BASH_VERSINFO[0]}" -gt 4 ] || { [ "${BASH_VERSINFO[0]}" -eq 4 ] && [ "${BASH_VERSINFO[1]}" -ge 4 ]; } \
  || die "needs bash 4.4+ (macOS: brew install bash)"

REPO="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
BIN_DIR="" SHELLS=() UNINSTALL=0 DRY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --bin-dir)   [ $# -ge 2 ] || die "--bin-dir needs a value"; BIN_DIR="$2"; shift ;;
    --bin-dir=*) BIN_DIR="${1#*=}" ;;
    --shell)     [ $# -ge 2 ] || die "--shell needs a value"; SHELLS+=("$2"); shift ;;
    --shell=*)   SHELLS+=("${1#*=}") ;;
    --uninstall) UNINSTALL=1 ;;
    --dry-run)   DRY=1 ;;
    -h|--help)   usage; exit 0 ;;
    *)           die "unknown arg '$1' (see --help)" ;;
  esac
  shift
done

run() { if [ "$DRY" = 1 ]; then echo "+ $*"; else "$@"; fi; }
on_path() { case ":$PATH:" in *":$1:"*) return 0 ;; esac; return 1; }
xdg_dir() { case "$1" in /*) printf '%s' "$1" ;; *) printf '%s' "$HOME/$2" ;; esac; }
DATA_HOME="$(xdg_dir "${XDG_DATA_HOME:-}" .local/share)"

# SHELL FLAGS CODE: rc files may print banners, so only lines after the marker count
probe_shell() {
  local t=()
  command -v "$1" >/dev/null 2>&1 || return 0
  ! command -v timeout >/dev/null 2>&1 || t=(timeout 10)
  { "${t[@]}" "$1" "$2" "echo @teebox-probe@; $3" </dev/null 2>/dev/null || true; } \
    | awk 'f; /^@teebox-probe@$/ { f = 1 }'
}

link() {
  local src="$1" dst="$2" old
  if [ -L "$dst" ]; then
    old="$(readlink -- "$dst")"
    if [ "$old" = "$src" ]; then say "ok      $dst"; return 0; fi
    say "replace $dst (was -> $old)"
  elif [ -e "$dst" ]; then
    say "skip    $dst: exists and is not a symlink; remove it and re-run"
    return 1
  else
    say "link    $dst -> $src"
  fi
  run mkdir -p -- "$(dirname -- "$dst")"
  run ln -sfn -- "$src" "$dst"
}

unlink_ours() {
  local dst="$1"
  [ -L "$dst" ] || return 0
  case "$(readlink -- "$dst")" in
    "$REPO"/*) say "remove  $dst"; run rm -f -- "$dst" ;;
  esac
}

BIN_CANDIDATES=()
case "${XDG_BIN_HOME:-}" in /*) BIN_CANDIDATES+=("$XDG_BIN_HOME") ;; esac
BIN_CANDIDATES+=("$HOME/.local/bin" "$HOME/bin")
if [ -z "$BIN_DIR" ]; then
  for d in "${BIN_CANDIDATES[@]}"; do
    if on_path "$d"; then BIN_DIR="$d"; break; fi
  done
  BIN_DIR="${BIN_DIR:-${BIN_CANDIDATES[0]}}"
fi

if [ "${#SHELLS[@]}" -eq 0 ]; then
  sh="$(basename -- "${SHELL:-}")"
  case "$sh" in
    bash|zsh) SHELLS=("$sh") ;;
    *) say "no completion for login shell '${sh:-unknown}' (bash and zsh supported; --shell NAME)" ;;
  esac
fi

# bash-completion's user dir: first of $BASH_COMPLETION_USER_DIR, else ${XDG_DATA_HOME:-~/.local/share}/bash-completion
bash_comp_dir() { local d="${1:-$2/bash-completion}"; printf '%s/completions' "${d%%:*}"; }
BASH_COMP_DIR="$(bash_comp_dir "${BASH_COMPLETION_USER_DIR:-}" "$DATA_HOME")"
BASH_COMP_LOADED=0
ZSH_DEFAULT_DIR="$DATA_HOME/zsh/site-functions"
zsh_fpath=() ZDOT='~' ZSHRC='~/.zshrc'
for sh in "${SHELLS[@]}"; do
  case "$sh" in
    # macOS terminals run login shells: bash-completion often comes from .bash_profile
    bash) for f in -ic -lic; do
            mapfile -t b < <(probe_shell bash "$f" 'declare -F _comp_load __load_completion >/dev/null && echo 1 || echo 0
              printf "%s\n" "${BASH_COMPLETION_USER_DIR-}" "${XDG_DATA_HOME:-$HOME/.local/share}"')
            [ "${b[0]:-0}" = 1 ] || continue
            BASH_COMP_LOADED=1 BASH_COMP_DIR="$(bash_comp_dir "${b[1]}" "${b[2]}")"
            break
          done ;;
    zsh)  mapfile -t zsh_fpath < <(probe_shell zsh -ic 'print -r -- ${ZDOTDIR:-$HOME}; print -rl -- $fpath')
          [ "${#zsh_fpath[@]}" -eq 0 ] || { ZDOT="${zsh_fpath[0]}"; zsh_fpath=("${zsh_fpath[@]:1}"); }
          # the .zshrc zsh reads: ZDOTDIR as of .zshenv; .zshrc itself may set it later
          d="$(probe_shell zsh -c 'print -r -- ${ZDOTDIR:-$HOME}')" && [ -n "$d" ] && ZSHRC="$d/.zshrc" ;;
    *)    die "--shell '$sh': need bash or zsh" ;;
  esac
done

if [ "$UNINSTALL" = 1 ]; then
  for d in "$BIN_DIR" "${BIN_CANDIDATES[@]}"; do unlink_ours "$d/teebox"; done
  unlink_ours "$BASH_COMP_DIR/teebox"
  for d in "${zsh_fpath[@]}" "$ZSH_DEFAULT_DIR"; do unlink_ours "$d/_teebox"; done
  exit 0
fi

link "$REPO/teebox" "$BIN_DIR/teebox"
on_path "$BIN_DIR" || say "add to PATH (shell rc): export PATH=\"$BIN_DIR:\$PATH\""

for sh in "${SHELLS[@]}"; do
  case "$sh" in
    bash)
      link "$REPO/completions/teebox.bash" "$BASH_COMP_DIR/teebox" || true
      # bash-completion 2.8+ lazy-loads from the user dir; without it nothing does
      [ "$BASH_COMP_LOADED" = 1 ] \
        || say "bash-completion 2.8+ not loaded; add to ~/.bashrc: source \"$REPO/completions/teebox.bash\""
      ;;
    zsh)
      dir=""
      for d in "${zsh_fpath[@]}"; do
        case "$d" in
          "$REPO/completions") say "ok      zsh fpath already has $d"; dir=-; break ;;
          # user-owned function dirs only, never a framework's (oh-my-zsh plugins, caches)
          "$HOME"/*/zsh/site-functions|"$HOME"/*.zfunc|"$HOME"/*.zfunctions|"$HOME"/*.zsh_functions|"$HOME"/*.zsh/completion*|"$HOME"/*.zsh/functions)
            [ -d "$d" ] && [ -w "$d" ] && { dir="$d"; break; } ;;
        esac
      done
      [ "$dir" != - ] || continue
      link "$REPO/completions/_teebox" "${dir:-$ZSH_DEFAULT_DIR}/_teebox" || true
      if [ -n "$dir" ]; then
        unlink_ours "$ZSH_DEFAULT_DIR/_teebox"
      else
        say "add to $ZSHRC before compinit or your framework's init (zim, oh-my-zsh, ...): fpath=(\"$ZSH_DEFAULT_DIR\" \$fpath)"
      fi
      say "zsh: exec zsh; if completion is missing, rm -f $ZDOT/.zcompdump* first"
      ;;
  esac
done

for dep in jq; do command -v "$dep" >/dev/null 2>&1 || say "missing host dependency: $dep"; done
{ yq --version 2>/dev/null | grep -q mikefarah; } || command -v tomlq >/dev/null 2>&1 \
  || say "missing host dependency: yq (mikefarah v4.40+) or python yq's tomlq"
command -v docker >/dev/null 2>&1 || command -v podman >/dev/null 2>&1 \
  || say "missing host dependency: docker or podman"

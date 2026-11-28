# bash completion for teebox (zsh: completions/_teebox)
_teebox() {
  local cmd cur prev i w line eq=0 flags=() value_flags=" " pass=() has_topic=0 topics=()
  cmd="${COMP_WORDS[0]/#\~/$HOME}"
  cur="${COMP_WORDS[COMP_CWORD]}"
  prev="${COMP_WORDS[COMP_CWORD-1]:-}"
  # COMP_WORDBREAKS splits --key=VAL into --key, =, VAL (and a:b into a, :, b)
  if [ "$cur" = = ]; then
    cur="" eq=1
  elif [ "$prev" = = ] && [ "$COMP_CWORD" -ge 2 ]; then
    prev="${COMP_WORDS[COMP_CWORD-2]}" eq=1
  fi

  while IFS= read -r line; do
    [[ "$line" =~ ^\ \ (-([a-z]),\ )?--([a-z-]+)(\ [A-Z])? ]] || continue
    flags+=("--${BASH_REMATCH[3]}")
    [ -z "${BASH_REMATCH[2]}" ] || flags+=("-${BASH_REMATCH[2]}")
    [ -z "${BASH_REMATCH[4]}" ] || value_flags+="--${BASH_REMATCH[3]} ${BASH_REMATCH[2]:+-${BASH_REMATCH[2]} }"
  done < <("$cmd" --help 2>&1)

  for (( i = 1; i < COMP_CWORD; i++ )); do
    w="${COMP_WORDS[i]}"
    if [ "$w" = -- ]; then
      return 0
    elif [[ "$value_flags" == *" $w "* ]]; then
      [ "${COMP_WORDS[i+1]:-}" != = ] || i=$((i + 1))
      i=$((i + 1))
      case "$w" in -d|--dir) [ "$i" -ge "$COMP_CWORD" ] || pass+=(--dir "${COMP_WORDS[i]/#\~/$HOME}") ;; esac
    elif [ "$w" = --allow-home ]; then
      if [ "${COMP_WORDS[i+1]:-}" = = ]; then pass+=("--allow-home=${COMP_WORDS[i+2]:-}"); else pass+=(--allow-home); fi
    elif [ "$w" = = ] || [ "$w" = : ]; then
      i=$((i + 1))
    elif [[ "$w" != -* ]]; then
      has_topic=1
    fi
  done

  if [[ "$value_flags" == *" $prev "* ]]; then
    case "$prev" in
      -a|--agent)      _teebox_words "$cur" $(_teebox_agents "$cmd") ;;
      --engine)        _teebox_words "$cur" docker podman ;;
      -d|--dir|--home) compopt -o filenames; mapfile -t COMPREPLY < <(compgen -d -- "$cur") ;;
      --ro|--device)   compopt -o filenames; mapfile -t COMPREPLY < <(compgen -f -- "$cur") ;;
      --pass-env|--pass-env-add) mapfile -t COMPREPLY < <(compgen -e -- "$cur") ;;
      *)               COMPREPLY=() ;;
    esac
    return 0
  fi
  if [ "$eq" = 1 ]; then
    _teebox_words "$cur" true false
    return 0
  fi

  if [[ "$cur" == -* ]]; then
    _teebox_words "$cur" "${flags[@]}" --
  elif [ "$has_topic" = 0 ]; then
    mapfile -t topics < <("$cmd" "${pass[@]}" --topics 2>/dev/null)
    _teebox_words "$cur" "${topics[@]}"
  fi
}

_teebox_words() {
  local cur="$1" w
  shift
  COMPREPLY=()
  for w; do
    [[ "$w" == "$cur"* ]] && COMPREPLY+=("$(printf '%q' "$w")")
  done
}

# [agents.NAME] headers of the shipped defaults and the user config
_teebox_agents() {
  local bin dir cfg
  bin="$(command -v -- "$1")" && bin="$(readlink -f -- "$bin")" || return 0
  dir="${XDG_CONFIG_HOME:-}"
  [[ "$dir" == /* ]] || dir="$HOME/.config"
  cfg="$dir/teebox/config.toml"
  sed -n 's/^[[:space:]]*\[agents\.\([a-z0-9_-]*\)\][[:space:]]*\(#.*\)\{0,1\}$/\1/p' \
    "$(dirname -- "$bin")/config/defaults.toml" "$cfg" 2>/dev/null | sort -u
}

complete -F _teebox teebox

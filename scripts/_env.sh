#!/usr/bin/env bash
# _env.sh -- shared env-file helpers. Source, do not execute. See .docs/CONNECT.md.

_load_env_file() {
    local f="$1"
    [[ -f "$f" ]] || return 0
    echo "-> Loading $f"
    while IFS='=' read -r key value || [[ -n "$key" ]]; do
        key="${key%"${key##*[![:space:]]}"}"
        [[ -z "$key" || "$key" == \#* ]] && continue
        if [[ "$value" == \"* ]]; then
            value="${value#\"}"; value="${value%%\"*}"
        else
            value="${value%%#*}"
            value="${value#"${value%%[![:space:]]*}"}"
            value="${value%"${value##*[![:space:]]}"}"
        fi
        [[ -z "${!key+x}" ]] && export "$key=$value"
    done < "$f"
}

# Like _load_env_file but OVERWRITES already-set vars. For an explicitly-selected file
# (e.g. a dataset env the operator pointed at) that should win over global defaults -- but
# NOT over a var exported on the command line, so callers pass the CLI-set keys to protect.
_load_env_file_force() {
    local f="$1"; shift
    local protected=" $* "
    [[ -f "$f" ]] || return 0
    echo "-> Loading $f (overrides)"
    while IFS='=' read -r key value || [[ -n "$key" ]]; do
        key="${key%"${key##*[![:space:]]}"}"
        [[ -z "$key" || "$key" == \#* ]] && continue
        if [[ "$value" == \"* ]]; then
            value="${value#\"}"; value="${value%%\"*}"
        else
            value="${value%%#*}"
            value="${value#"${value%%[![:space:]]*}"}"
            value="${value%"${value##*[![:space:]]}"}"
        fi
        [[ "$protected" == *" $key "* ]] && continue
        export "$key=$value"
    done < "$f"
}

robot_name_from_env() {
    sed -n 's/^[[:space:]]*ROBOT_NAME[[:space:]]*=[[:space:]]*"\?\([^"#]*\)"\?.*/\1/p' "$1" \
        | head -1 | sed 's/[[:space:]]*$//'
}

# env-file values keep "$HOME"/"${HOME}"/"~" literal; expand a leading home ref.
_expand_home() { local p="$1"; p="${p/#\$HOME/$HOME}"; p="${p/#\~/$HOME}"; echo "${p/#\$\{HOME\}/$HOME}"; }

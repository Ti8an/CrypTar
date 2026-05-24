#!/usr/bin/env bash
[[ -n "${_CONFIG_LOADED:-}" ]] && return 0
_CONFIG_LOADED=1

readonly CFG_DIR="$HOME/.config/cryptar"

# Outputs lines of "KEY_ID : UID" for every public GPG key, one per line → stdout.
# Callers capture with: IFS=$'\n' read -r -d '' -a arr < <(cfg_list_gpg_keys && printf '\0')
cfg_list_gpg_keys() {
    gpg --list-keys --with-colons 2>/dev/null | awk -F: '
        /^pub/ { key=$5 }
        /^uid/ { uid=$10; print key " : " uid }
    '
}

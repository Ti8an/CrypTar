#!/usr/bin/env bash
[[ -n "${_CLOUD_LOADED:-}" ]] && return 0
_CLOUD_LOADED=1

# ══ Cloud storage core ════════════════════════════════════════════════════════
# Shared layer for --cloud commands: connection config (encrypted INI, same
# GPG key / lock / atomic-write path as servers.conf.gpg), connection
# resolution, HTTP transport with bounded retries, error classification,
# secret redaction, provider dispatch and multi-destination uploads.
#
# Provider modules (src/providers/cloud/*.sh) implement, for provider <p>:
#   <p>_auth          <conn_ref>                 interactive OAuth; fills tokens
#   <p>_account       <conn_ref>                 echo account identifier
#   <p>_ensure_folder <conn_ref>                 resolve/create destination
#   <p>_test          <conn_ref>                 auth + folder access check
#   <p>_upload        <conn_ref> <file> <name>   upload; sets CLOUD_UPLOADED_NAME
#   <p>_default_folder                           echo default destination
# <conn_ref> is the name of an associative array holding one connection.
#
# Secrets policy:
#   * tokens/client secrets live only in clouds.conf.gpg and in memory;
#   * curl receives URL, headers and body through a config fd (-K <(...)), so
#     nothing secret appears in argv / `ps`;
#   * xtrace is suspended inside provider operations;
#   * remote error text is passed through cloud_redact before logging.
# ═════════════════════════════════════════════════════════════════════════════

_CLOUD_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# config.sh is load-guarded; sourcing it here makes the dependency explicit
# (src/lib/*.sh are auto-loaded alphabetically, cloud.sh before config.sh).
source "$_CLOUD_LIB_DIR/config.sh"

CLOUD_CFG_FILE="$CFG_DIR/clouds.conf.gpg"
CLOUD_PROVIDERS_DIR="$_CLOUD_LIB_DIR/../providers/cloud"
CLOUD_PROVIDER_IDS=(gdrive yadisk)

# Tunables — overridable from the environment.
CLOUD_MAX_RETRIES="${CRYPTAR_CLOUD_MAX_RETRIES:-4}"
CLOUD_CONNECT_TIMEOUT="${CRYPTAR_CLOUD_CONNECT_TIMEOUT:-15}"
CLOUD_REQ_TIMEOUT="${CRYPTAR_CLOUD_REQ_TIMEOUT:-60}"
CLOUD_STALL_TIMEOUT="${CRYPTAR_CLOUD_STALL_TIMEOUT:-120}"
CLOUD_MAX_NAME_TRIES=100

# Per-request auth state, set by providers and cleared by cloud_provider_call.
CLOUD_BEARER=""
CLOUD_AUTH_SCHEME="Bearer"

# Error codes returned by cloud functions (and used as process exit codes
# when a single connection operation fails).
CLOUD_E_GENERIC=1
CLOUD_E_AUTH=10       # invalid / expired / revoked authorization
CLOUD_E_PERM=11       # insufficient permissions or OAuth scope
CLOUD_E_NET=12        # network error or timeout
CLOUD_E_RATE=13       # rate limit (429 / rateLimitExceeded / 423 Locked)
CLOUD_E_QUOTA=14      # storage quota exhausted
CLOUD_E_NOTFOUND=15   # remote resource not found
CLOUD_E_CONFIG=16     # missing/invalid local config or OAuth client, deps
CLOUD_E_API=17        # other API error
CLOUD_E_TOOLARGE=18   # file exceeds provider limit
CLOUD_E_CONFLICT=19   # remote resource already exists
CLOUD_E_SERVER=20     # provider 5xx

# Exit code of a multi-destination send where some (not all) uploads failed.
CLOUD_EXIT_PARTIAL=3

# Canonical key order inside a connection section.
_CLOUD_KEY_ORDER=(provider account folder folder_id client_id client_secret
                  refresh_token access_token expires_at device_id created)

# ── Small helpers ─────────────────────────────────────────────────────────────

_cloud_sleep() { sleep "$1"; }

# _cloud_trap_save <var> — capture the current EXIT/INT/TERM traps so a
# temporary cleanup trap can be undone without clobbering the caller's.
# Only done in the top-level shell: inside a subshell `trap -p` reports the
# parent's (inactive) traps, and "restoring" them would arm them there.
_cloud_trap_save() {
    local -n _cts_out="$1"
    _cts_out=""
    if [[ "$BASHPID" == "$$" ]]; then
        _cts_out="$(trap -p EXIT INT TERM)"
    fi
    return 0
}

# Restore traps captured with _cloud_trap_save.
_cloud_trap_restore() {
    trap - EXIT INT TERM
    [[ -n "${1:-}" ]] && eval "$1"
    return 0
}

_cloud_trim() {
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

cloud_provider_label() {
    case "$1" in
        gdrive) echo "Google Drive" ;;
        yadisk) echo "Yandex Disk"  ;;
        *)      echo "$1"           ;;
    esac
}

_cloud_provider_file() {
    case "$1" in
        gdrive) echo "google_drive.sh" ;;
        yadisk) echo "yandex_disk.sh"  ;;
        *)      return 1               ;;
    esac
}

# Connection names are the stable identifiers: 1–64 chars of [A-Za-z0-9_-],
# starting with a letter or digit. Purely numeric names are rejected so that
# a number on the command line always means a list index — never ambiguous.
cloud_validate_name() {
    local n="$1"
    [[ "$n" =~ ^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$ ]] || return 1
    [[ ! "$n" =~ ^[0-9]+$ ]]
}

# INI values must be single-line and free of control characters.
_cloud_valid_value() {
    [[ "$1" != *[[:cntrl:]]* ]]
}

cloud_require_deps() {
    local -a missing=()
    local c
    for c in curl jq "$@"; do
        command -v "$c" &>/dev/null || missing+=("$c")
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        log_err "Не найдены зависимости для облачных команд: ${missing[*]}"
        log_info "Установите их: sudo apt-get install ${missing[*]}  (или повторно запустите install.sh)"
        return $CLOUD_E_CONFIG
    fi
}

# Mask tokens and secrets in arbitrary text (error bodies, messages).
cloud_redact() {
    printf '%s' "$1" | sed -E \
        -e 's/("(access_token|refresh_token|id_token|client_secret|device_code|code|token)"[[:space:]]*:[[:space:]]*")[^"]*/\1***/g' \
        -e 's/(^|[^A-Za-z0-9_])((access_token|refresh_token|client_secret|device_code|code|token)=)[^&[:space:]"]*/\1\2***/g' \
        -e 's/(Bearer|OAuth)[[:space:]]+[A-Za-z0-9._~+\/=-]+/\1 ***/g' \
        -e 's/ya29\.[A-Za-z0-9._-]+/***/g' \
        -e 's#1//[A-Za-z0-9._-]+#***#g' \
        -e 's/y[0-9]_[A-Za-z0-9_-]{20,}/***/g'
}

cloud_human_size() {
    local b="$1"
    if   (( b >= 1073741824 )); then printf '%d.%d ГБ\n' $(( b / 1073741824 )) $(( b % 1073741824 * 10 / 1073741824 ))
    elif (( b >= 1048576 ));    then printf '%d.%d МБ\n' $(( b / 1048576 )) $(( b % 1048576 * 10 / 1048576 ))
    elif (( b >= 1024 ));       then printf '%d КБ\n' $(( b / 1024 ))
    else printf '%d Б\n' "$b"; fi
}

cloud_file_size() {
    stat -c %s -- "$1" 2>/dev/null || wc -c < "$1" | tr -d ' '
}

# Insert "-<n>" before the archive suffix: a_1.tar.gz.gpg → a_1-2.tar.gz.gpg
cloud_unique_name() {
    local name="$1" n="$2" base ext
    case "$name" in
        *.tar.gz.gpg) base="${name%.tar.gz.gpg}"; ext=".tar.gz.gpg" ;;
        ?*.*)         base="${name%.*}";          ext=".${name##*.}" ;;
        *)            base="$name";               ext="" ;;
    esac
    printf '%s-%s%s\n' "$base" "$n" "$ext"
}

# True for an existing *.gpg file whose first OpenPGP packet is an encrypted
# session key (PKESK tag 1 / SKESK tag 3), or an ASCII-armored message.
# Checks the header only — no key or passphrase is needed.
cloud_is_encrypted_archive() {
    local f="$1" b tag
    [[ -f "$f" && "$f" == *.gpg ]] || return 1
    b="$(od -An -tu1 -N1 -- "$f" 2>/dev/null | tr -d ' \n')"
    [[ "$b" =~ ^[0-9]+$ ]] || return 1
    if (( (b & 0xC0) == 0xC0 )); then
        tag=$(( b & 0x3F ))          # new packet format
    elif (( b & 0x80 )); then
        tag=$(( (b >> 2) & 0x0F ))   # old packet format
    else
        head -c 27 -- "$f" | grep -q '^-----BEGIN PGP MESSAGE-----'
        return
    fi
    (( tag == 1 || tag == 3 ))
}

# ── Encrypted INI storage (clouds.conf.gpg) ───────────────────────────────────
# Same format as servers.conf.gpg: [name] sections with key=value lines.
# Only section names are ever passed to external commands; values (which
# include secrets) are written with builtins.

_cloud_ini_sections() {
    awk '
        /^[[:space:]]*([#;]|$)/ { next }
        { l = $0; gsub(/^[[:space:]]+|[[:space:]]+$/, "", l) }
        l ~ /^\[.*\]$/ { print substr(l, 2, length(l) - 2) }
    ' "$1"
}

# _cloud_ini_has <plain_file> <name> [ci] — section exists (ci: ignore case).
_cloud_ini_has() {
    _cloud_ini_sections "$1" | awk -v n="$2" -v ci="${3:-}" '
        (ci ? tolower($0) == tolower(n) : $0 == n) { found = 1 }
        END { exit !found }
    '
}

_cloud_ini_section() {
    awk -v section="[$2]" '
        /^[[:space:]]*([#;]|$)/ { next }
        { l = $0; gsub(/^[[:space:]]+|[[:space:]]+$/, "", l) }
        l ~ /^\[.*\]$/ { if (in_sec) exit; in_sec = (l == section); next }
        in_sec && index(l, "=") {
            eq = index(l, "=")
            k = substr(l, 1, eq - 1); v = substr(l, eq + 1)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", k)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", v)
            print k "=" v
        }
    ' "$1"
}

# Print "name<TAB>provider<TAB>account<TAB>folder" for every connection in
# file order. Secrets never leave this function.
cloud_cfg_table() {
    [[ -f "$CLOUD_CFG_FILE" ]] || return 0
    local tmp st out rc=0
    _cloud_trap_save st
    tmp="$(cfg_decrypt "$CLOUD_CFG_FILE")" || return $CLOUD_E_CONFIG
    trap "_cfg_shred $(printf '%q' "$tmp"); trap - EXIT INT TERM" EXIT INT TERM

    out="$(awk '
        function flush() {
            if (cur != "") print cur "\t" f["provider"] "\t" f["account"] "\t" f["folder"]
        }
        /^[[:space:]]*([#;]|$)/ { next }
        { l = $0; gsub(/^[[:space:]]+|[[:space:]]+$/, "", l) }
        l ~ /^\[.*\]$/ {
            flush(); cur = substr(l, 2, length(l) - 2)
            split("", f); next
        }
        cur != "" && index(l, "=") {
            eq = index(l, "=")
            k = substr(l, 1, eq - 1); v = substr(l, eq + 1)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", k)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", v)
            f[k] = v
        }
        END { flush() }
    ' "$tmp")" || rc=$CLOUD_E_CONFIG

    _cfg_shred "$tmp"
    _cloud_trap_restore "$st"
    [[ -n "$out" ]] && printf '%s\n' "$out"
    return $rc
}

# cloud_cfg_names <array_ref> — connection names in list order.
cloud_cfg_names() {
    local -n _ccn_out="$1"
    local _tbl _line
    _tbl="$(cloud_cfg_table)" || return $?
    _ccn_out=()
    while IFS= read -r _line; do
        [[ -n "$_line" ]] && _ccn_out+=("${_line%%$'\t'*}")
    done <<< "$_tbl"
    return 0
}

cloud_cfg_exists() {
    local -a _names=()
    cloud_cfg_names _names || return 1
    local n
    for n in "${_names[@]}"; do
        [[ "${n,,}" == "${1,,}" ]] && return 0
    done
    return 1
}

# cloud_cfg_load <name> <assoc_ref> — single decrypt; fills the array with
# every field of the section plus name=<name>.
cloud_cfg_load() {
    local _name="$1"
    local -n _ccl_out="$2"
    _ccl_out=()
    if [[ ! -f "$CLOUD_CFG_FILE" ]]; then
        log_err "Облачные подключения не настроены. Добавьте: crypTar --cloud add"
        return $CLOUD_E_CONFIG
    fi

    local tmp st _l
    _cloud_trap_save st
    tmp="$(cfg_decrypt "$CLOUD_CFG_FILE")" || return $CLOUD_E_CONFIG
    trap "_cfg_shred $(printf '%q' "$tmp"); trap - EXIT INT TERM" EXIT INT TERM
    while IFS= read -r _l; do
        _ccl_out["${_l%%=*}"]="${_l#*=}"
    done < <(_cloud_ini_section "$tmp" "$_name")
    _cfg_shred "$tmp"
    _cloud_trap_restore "$st"

    if [[ -z "${_ccl_out[provider]:-}" ]]; then
        _ccl_out=()
        log_err "Подключение '$_name' не найдено или повреждено"
        return $CLOUD_E_CONFIG
    fi
    _ccl_out[name]="$_name"
}

# cloud_cfg_add <assoc_ref> — append a new connection. Refuses to overwrite:
# the duplicate check runs under the config lock (case-insensitive).
cloud_cfg_add() {
    local -n _cca="$1"
    local name="${_cca[name]:-}" k
    if ! cloud_validate_name "$name"; then
        log_err "Недопустимое имя подключения: '$name'"
        return $CLOUD_E_CONFIG
    fi
    if [[ -z "${_cca[provider]:-}" ]] || ! _cloud_provider_file "${_cca[provider]}" >/dev/null; then
        log_err "Неизвестный провайдер: '${_cca[provider]:-}'"
        return $CLOUD_E_CONFIG
    fi
    for k in "${!_cca[@]}"; do
        if ! [[ "$k" =~ ^[a-z_][a-z0-9_]*$ ]] || ! _cloud_valid_value "${_cca[$k]}"; then
            log_err "Недопустимое поле конфигурации: '$k'"
            return $CLOUD_E_CONFIG
        fi
    done

    _cfg_lock || return $CLOUD_E_CONFIG
    local tmp st rc=0
    _cloud_trap_save st
    tmp="$(cfg_decrypt "$CLOUD_CFG_FILE")" || { _cfg_unlock; return $CLOUD_E_CONFIG; }
    trap "_cfg_shred $(printf '%q' "$tmp"); _cfg_unlock; trap - EXIT INT TERM" EXIT INT TERM

    if _cloud_ini_has "$tmp" "$name" ci; then
        log_err "Подключение '$name' уже существует — выберите другое имя"
        _cfg_shred "$tmp"; _cfg_unlock; _cloud_trap_restore "$st"
        return $CLOUD_E_CONFLICT
    fi

    {
        if [[ -s "$tmp" ]]; then printf '\n'; fi
        printf '[%s]\n' "$name"
        for k in "${_CLOUD_KEY_ORDER[@]}"; do
            [[ -n "${_cca[$k]:-}" ]] && printf '%s=%s\n' "$k" "${_cca[$k]}"
        done
        for k in $(printf '%s\n' "${!_cca[@]}" | sort); do
            [[ "$k" == name || "$k" == _* ]] && continue
            [[ " ${_CLOUD_KEY_ORDER[*]} " == *" $k "* ]] && continue
            printf '%s=%s\n' "$k" "${_cca[$k]}"
        done
    } >> "$tmp"

    cfg_encrypt "$tmp" "$CLOUD_CFG_FILE" || rc=$CLOUD_E_CONFIG
    _cfg_unlock
    _cloud_trap_restore "$st"
    return $rc
}

# cloud_cfg_set <name> <key> <value> [<key> <value> ...] — update fields of
# one connection in a single locked decrypt/encrypt cycle. Other connections
# and other fields are copied through unchanged. Pure-bash rewrite: values
# never reach an external command line.
cloud_cfg_set() {
    local name="$1"; shift
    if (( $# == 0 || $# % 2 )); then
        log_err "cloud_cfg_set: ожидаются пары ключ/значение"
        return $CLOUD_E_GENERIC
    fi
    local -A upd=()
    while (( $# )); do
        if ! [[ "$1" =~ ^[a-z_][a-z0-9_]*$ ]] || ! _cloud_valid_value "$2"; then
            log_err "Недопустимое поле конфигурации: '$1'"
            return $CLOUD_E_CONFIG
        fi
        upd["$1"]="$2"; shift 2
    done

    _cfg_lock || return $CLOUD_E_CONFIG
    local tmp newtmp st rc=0
    _cloud_trap_save st
    tmp="$(cfg_decrypt "$CLOUD_CFG_FILE")" || { _cfg_unlock; return $CLOUD_E_CONFIG; }
    newtmp="$(_cfg_tmp_file)" || { _cfg_shred "$tmp"; _cfg_unlock; return $CLOUD_E_CONFIG; }
    trap "_cfg_shred $(printf '%q' "$tmp"); _cfg_shred $(printf '%q' "$newtmp"); _cfg_unlock; trap - EXIT INT TERM" EXIT INT TERM

    if ! _cloud_ini_has "$tmp" "$name"; then
        log_err "Подключение '$name' не найдено"
        _cfg_shred "$tmp"; _cfg_shred "$newtmp"; _cfg_unlock; _cloud_trap_restore "$st"
        return $CLOUD_E_CONFIG
    fi

    local -A written=()
    local line trimmed k in_sec=0
    _cloud_emit_missing() {
        local _k
        for _k in "${!upd[@]}"; do
            [[ -n "${written[$_k]:-}" ]] || printf '%s=%s\n' "$_k" "${upd[$_k]}"
        done
    }
    while IFS= read -r line || [[ -n "$line" ]]; do
        trimmed="$(_cloud_trim "$line")"
        if [[ "$trimmed" == \[*\] ]]; then
            if (( in_sec )); then _cloud_emit_missing; fi
            in_sec=0
            [[ "$trimmed" == "[$name]" ]] && in_sec=1
            printf '%s\n' "$line"
            continue
        fi
        if (( in_sec )) && [[ "$trimmed" == *=* && "$trimmed" != [\#\;]* ]]; then
            k="$(_cloud_trim "${trimmed%%=*}")"
            if [[ -n "${upd[$k]+x}" ]]; then
                printf '%s=%s\n' "$k" "${upd[$k]}"
                written["$k"]=1
                continue
            fi
        fi
        printf '%s\n' "$line"
    done < "$tmp" > "$newtmp"
    if (( in_sec )); then _cloud_emit_missing >> "$newtmp"; fi
    unset -f _cloud_emit_missing

    _cfg_shred "$tmp"
    cfg_encrypt "$newtmp" "$CLOUD_CFG_FILE" || rc=$CLOUD_E_CONFIG
    _cfg_unlock
    _cloud_trap_restore "$st"
    return $rc
}

# cloud_cfg_remove <name> — drop one section; everything else is preserved.
# Local only: nothing is deleted from the remote cloud.
cloud_cfg_remove() {
    local name="$1"
    _cfg_lock || return $CLOUD_E_CONFIG
    local tmp newtmp st rc=0
    _cloud_trap_save st
    tmp="$(cfg_decrypt "$CLOUD_CFG_FILE")" || { _cfg_unlock; return $CLOUD_E_CONFIG; }
    newtmp="$(_cfg_tmp_file)" || { _cfg_shred "$tmp"; _cfg_unlock; return $CLOUD_E_CONFIG; }
    trap "_cfg_shred $(printf '%q' "$tmp"); _cfg_shred $(printf '%q' "$newtmp"); _cfg_unlock; trap - EXIT INT TERM" EXIT INT TERM

    if ! _cloud_ini_has "$tmp" "$name"; then
        log_err "Подключение '$name' не найдено"
        _cfg_shred "$tmp"; _cfg_shred "$newtmp"; _cfg_unlock; _cloud_trap_restore "$st"
        return $CLOUD_E_CONFIG
    fi

    awk -v section="[$name]" '
        { l = $0; gsub(/^[[:space:]]+|[[:space:]]+$/, "", l) }
        l ~ /^\[.*\]$/ { skip = (l == section) }
        !skip { print }
    ' "$tmp" > "$newtmp"

    _cfg_shred "$tmp"
    cfg_encrypt "$newtmp" "$CLOUD_CFG_FILE" || rc=$CLOUD_E_CONFIG
    _cfg_unlock
    _cloud_trap_restore "$st"
    return $rc
}

# cloud_conn_update <conn_ref> <key> <value> [...] — update an in-memory
# connection and persist the change, unless the connection is still being
# created by the add wizard (_unsaved=1).
cloud_conn_update() {
    local -n _ccu="$1"; shift
    local -a _pairs=("$@")
    local i
    for (( i = 0; i < ${#_pairs[@]}; i += 2 )); do
        _ccu["${_pairs[i]}"]="${_pairs[i+1]}"
    done
    [[ "${_ccu[_unsaved]:-}" == 1 ]] && return 0
    cloud_cfg_set "${_ccu[name]}" "$@"
}

# Make sure a GPG key for config encryption is chosen (same rules as the
# --server add wizard). Returns non-zero when no key can be used.
cloud_ensure_encrypt_key() {
    [[ -f "$CFG_KEY_FILE" ]] && return 0
    local -a keys=()
    IFS=$'\n' read -r -d '' -a keys < <(cfg_list_gpg_keys && printf '\0') || true
    if [[ ${#keys[@]} -eq 0 || -z "${keys[0]}" ]]; then
        log_err "GPG-ключи не найдены. Создайте ключ (gpg --full-generate-key) и повторите."
        return $CLOUD_E_CONFIG
    fi
    log_warn "Для сохранения облачного конфига необходим GPG-ключ шифрования."
    local sel
    sel="$(ui_select "Выберите GPG-ключ для шифрования конфига" "${keys[@]}")"
    [[ -n "$sel" ]] || { log_err "Ключ не выбран — отменено."; return $CLOUD_E_CONFIG; }
    cfg_set_encrypt_key "${sel%% : *}"
}

# ── Selection ─────────────────────────────────────────────────────────────────
# Indices are 1-based and match the ID column of `crypTar --cloud list`.

# cloud_resolve <name|index> — echo the connection name.
cloud_resolve() {
    local id="$1" n
    local -a names=()
    cloud_cfg_names names || return $CLOUD_E_CONFIG
    if [[ ${#names[@]} -eq 0 ]]; then
        log_err "Облачные подключения не настроены. Добавьте: crypTar --cloud add"
        return $CLOUD_E_CONFIG
    fi
    if [[ "$id" =~ ^[0-9]+$ ]]; then
        if (( 10#$id >= 1 && 10#$id <= ${#names[@]} )); then
            echo "${names[10#$id - 1]}"
            return 0
        fi
        log_err "Нет подключения с номером $id (доступно: 1–${#names[@]})"
        return $CLOUD_E_CONFIG
    fi
    for n in "${names[@]}"; do
        if [[ "$n" == "$id" ]]; then echo "$n"; return 0; fi
    done
    log_err "Подключение '$id' не найдено. Список: crypTar --cloud list"
    return $CLOUD_E_CONFIG
}

# _cloud_parse_selection <input> <count> — echo 1-based indices, one per line.
# Accepts "2", "1,3", "1 3", "1-3", "all". Returns 1 on any invalid token.
_cloud_parse_selection() {
    local input="$1" count="$2" tok a b i
    local -a toks=() out=()
    local -A seen=()
    input="$(_cloud_trim "$input")"
    if [[ "${input,,}" == all || "$input" == "*" ]]; then
        for (( i = 1; i <= count; i++ )); do echo "$i"; done
        return 0
    fi
    read -r -a toks <<< "${input//,/ }"
    [[ ${#toks[@]} -gt 0 ]] || return 1
    for tok in "${toks[@]}"; do
        if [[ "$tok" =~ ^[0-9]+$ ]]; then
            a=$((10#$tok)); b=$a
        elif [[ "$tok" =~ ^([0-9]+)-([0-9]+)$ ]]; then
            a=$((10#${BASH_REMATCH[1]})); b=$((10#${BASH_REMATCH[2]}))
        else
            return 1
        fi
        (( a >= 1 && b <= count && a <= b )) || return 1
        for (( i = a; i <= b; i++ )); do
            [[ -n "${seen[$i]:-}" ]] && continue
            seen[$i]=1; out+=("$i")
        done
    done
    printf '%s\n' "${out[@]}"
}

# Print the numbered connection menu to stderr.
_cloud_print_menu() {
    local tbl="$1" i=1 name provider account _f
    while IFS=$'\t' read -r name provider account _f; do
        [[ -n "$name" ]] || continue
        printf '  [%d] %-24s %-13s %s\n' "$i" "$name" "$(cloud_provider_label "$provider")" "${account:-}" >&2
        i=$((i + 1))
    done <<< "$tbl"
}

# cloud_pick <multi:0|1> <prompt> — interactive selection from the configured
# connections; echoes selected names (one per line). Empty input or EOF
# cancels (return 1).
cloud_pick() {
    local multi="$1" prompt="$2" tbl answer idx
    local -a names=()
    tbl="$(cloud_cfg_table)" || return $CLOUD_E_CONFIG
    cloud_cfg_names names || return $CLOUD_E_CONFIG
    if [[ ${#names[@]} -eq 0 ]]; then
        log_err "Облачные подключения не настроены. Добавьте: crypTar --cloud add"
        return $CLOUD_E_CONFIG
    fi
    _cloud_print_menu "$tbl"
    local hint="номер"
    [[ "$multi" == 1 ]] && hint="номера через запятую, диапазон 1-3 или all"
    while true; do
        printf '%s (%s; пусто — отмена): ' "$prompt" "$hint" >&2
        IFS= read -r answer || return 1
        [[ -z "$(_cloud_trim "$answer")" ]] && return 1
        if [[ "$multi" != 1 && ! "$(_cloud_trim "$answer")" =~ ^[0-9]+$ ]]; then
            echo "  Введите один номер от 1 до ${#names[@]}" >&2
            continue
        fi
        local sel
        if sel="$(_cloud_parse_selection "$answer" "${#names[@]}")"; then
            while IFS= read -r idx; do
                echo "${names[idx - 1]}"
            done <<< "$sel"
            return 0
        fi
        echo "  Некорректный выбор — допустимы номера от 1 до ${#names[@]}" >&2
    done
}

# ── HTTP transport ────────────────────────────────────────────────────────────

_cloud_cfg_quote() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    printf '"%s"' "$s"
}

# Percent-encode (RFC 3986 unreserved set kept), pure bash.
cloud_urlencode() {
    local LC_ALL=C s="$1" out="" c i
    for (( i = 0; i < ${#s}; i++ )); do
        c="${s:i:1}"
        case "$c" in
            [A-Za-z0-9.~_-]) out+="$c" ;;
            *) printf -v c '%%%02X' "'$c"; out+="$c" ;;
        esac
    done
    printf '%s' "$out"
}

# cloud_form <key> <value> [...] — application/x-www-form-urlencoded body.
cloud_form() {
    local out="" sep=""
    while (( $# >= 2 )); do
        out+="$sep$(cloud_urlencode "$1")=$(cloud_urlencode "$2")"
        sep="&"; shift 2
    done
    printf '%s' "$out"
}

# curl config consumed via -K: carries method, URL, headers, bearer token and
# body so that none of them appear on the command line.
_cloud_curl_config() {
    local method="$1" url="$2" auth="$3" body_var="$4" hdrs_var="$5"
    local -n _hdrs="$hdrs_var"
    local h
    printf 'globoff\n'
    printf 'request = %s\n' "$(_cloud_cfg_quote "$method")"
    printf 'url = %s\n' "$(_cloud_cfg_quote "$url")"
    for h in "${_hdrs[@]}"; do
        printf 'header = %s\n' "$(_cloud_cfg_quote "$h")"
    done
    if [[ "$auth" == 1 ]]; then
        printf 'header = %s\n' "$(_cloud_cfg_quote "Authorization: ${CLOUD_AUTH_SCHEME:-Bearer} ${CLOUD_BEARER:-}")"
    fi
    if [[ -n "$body_var" ]]; then
        printf 'data-binary = %s\n' "$(_cloud_cfg_quote "${!body_var}")"
    fi
}

# Thin curl wrapper — the only place a network call happens. Tests replace it.
# Args: <body_out> <headers_out> <config_path> [extra curl args...]
# Prints the HTTP status code; returns curl's exit code.
_cloud_transport() {
    local body_out="$1" hdr_out="$2" cfg="$3"; shift 3
    local -a quiet=(-sS)
    [[ "${CLOUD_PROGRESS:-0}" == 1 ]] && quiet=(-S --progress-bar)
    curl "${quiet[@]}" --config "$cfg" -o "$body_out" -D "$hdr_out" \
         -w '%{http_code}' "$@"
}

# Header value from the last response block (case-insensitive name).
cloud_http_header() {
    awk -v n="${1,,}" '
        { line = $0; sub(/\r$/, "", line) }
        index(line, ":") {
            k = tolower(substr(line, 1, index(line, ":") - 1))
            if (k == n) { v = substr(line, index(line, ":") + 1); sub(/^[ \t]+/, "", v); last = v }
        }
        END { if (last != "") print last }
    ' <<< "${CLOUD_HTTP_HEADERS:-}"
}

# Classify the last response (CLOUD_CURL_RC / CLOUD_HTTP_CODE / BODY) and
# echo the matching CLOUD_E_* code.
cloud_http_error_code() {
    local rc="${CLOUD_CURL_RC:-0}" code="${CLOUD_HTTP_CODE:-000}" body="${CLOUD_HTTP_BODY:-}"
    if (( rc != 0 )); then
        case "$rc" in
            2|3|26|27|43) echo $CLOUD_E_GENERIC ;;   # local/usage errors
            *)            echo $CLOUD_E_NET ;;
        esac
        return
    fi
    case "$code" in
        000) echo $CLOUD_E_NET ;;
        400)
            if [[ "$body" == *invalid_grant* ]]; then echo $CLOUD_E_AUTH
            elif [[ "$body" == *invalid_client* || "$body" == *unauthorized_client* ]]; then echo $CLOUD_E_CONFIG
            else echo $CLOUD_E_API; fi ;;
        401)
            if [[ "$body" == *invalid_client* ]]; then echo $CLOUD_E_CONFIG
            else echo $CLOUD_E_AUTH; fi ;;
        403)
            if [[ "$body" == *[Rr]ate[Ll]imit* || "$body" == *dailyLimitExceeded* ]]; then echo $CLOUD_E_RATE
            elif [[ "$body" == *storageQuotaExceeded* || "$body" == *[Qq]uota[A-Za-z]*Exhausted* ]]; then echo $CLOUD_E_QUOTA
            else echo $CLOUD_E_PERM; fi ;;
        404|410) echo $CLOUD_E_NOTFOUND ;;
        409)     echo $CLOUD_E_CONFLICT ;;
        413)     echo $CLOUD_E_TOOLARGE ;;
        423|429) echo $CLOUD_E_RATE ;;
        507)     echo $CLOUD_E_QUOTA ;;
        5??)     echo $CLOUD_E_SERVER ;;
        *)       echo $CLOUD_E_API ;;
    esac
}

_cloud_is_transient() {
    case "$1" in
        "$CLOUD_E_NET"|"$CLOUD_E_RATE"|"$CLOUD_E_SERVER") return 0 ;;
        *) return 1 ;;
    esac
}

# Seconds to wait before retry <attempt> (0-based): Retry-After when the
# server sent one (capped at 120 s), else exponential 1,2,4,8… capped at 32.
_cloud_backoff_delay() {
    local attempt="$1" ra
    ra="$(cloud_http_header Retry-After)"
    if [[ "$ra" =~ ^[0-9]+$ ]]; then
        (( ra > 120 )) && ra=120
        echo "$ra"
        return
    fi
    local d=$(( 1 << attempt ))
    (( d > 32 )) && d=32
    echo "$d"
}

# _cloud_request <METHOD> <URL> [options]
#   -H <header>        extra request header (repeatable)
#   --auth             send "Authorization: $CLOUD_AUTH_SCHEME $CLOUD_BEARER"
#   --body-var <var>   send the value of <var> as the request body
#   --upload <file|->  stream a file (or stdin) as the body; never auto-retried
#   --no-retry         single attempt (non-idempotent requests)
#   --long             no total time limit (uploads) — stall detection only
# Sets CLOUD_HTTP_CODE, CLOUD_HTTP_BODY, CLOUD_HTTP_HEADERS, CLOUD_CURL_RC.
# Returns 0 for 2xx and 308 (resumable "incomplete"), else a CLOUD_E_* code.
# Transient failures (network, 429, 5xx, rate-limit 403) are retried with
# exponential backoff up to CLOUD_MAX_RETRIES times.
_cloud_request() {
    local method="$1" url="$2"; shift 2
    local -a hdrs=()
    local auth=0 body_var="" upload="" retry=1 long=0
    while (( $# )); do
        case "$1" in
            -H)         hdrs+=("$2"); shift 2 ;;
            --auth)     auth=1; shift ;;
            --body-var) body_var="$2"; shift 2 ;;
            --upload)   upload="$2"; retry=0; shift 2 ;;
            --no-retry) retry=0; shift ;;
            --long)     long=1; shift ;;
            *) log_err "_cloud_request: неизвестная опция $1"; return $CLOUD_E_GENERIC ;;
        esac
    done

    local max=0 attempt=0 body_f hdr_f code rc err delay
    (( retry )) && max="$CLOUD_MAX_RETRIES"
    local -a extra=(--connect-timeout "$CLOUD_CONNECT_TIMEOUT")
    if (( long )); then
        extra+=(--speed-limit 1 --speed-time "$CLOUD_STALL_TIMEOUT")
    else
        extra+=(--max-time "$CLOUD_REQ_TIMEOUT")
    fi
    [[ -n "$upload" ]] && extra+=(-T "$upload")

    while true; do
        body_f="$(_cfg_tmp_file)" || return $CLOUD_E_GENERIC
        hdr_f="$(_cfg_tmp_file)"  || { _cfg_shred "$body_f"; return $CLOUD_E_GENERIC; }
        rc=0
        code="$(_cloud_transport "$body_f" "$hdr_f" \
                    <(_cloud_curl_config "$method" "$url" "$auth" "$body_var" hdrs) \
                    "${extra[@]}")" || rc=$?
        CLOUD_CURL_RC=$rc
        CLOUD_HTTP_CODE="$code"
        [[ "$CLOUD_HTTP_CODE" =~ ^[0-9]{3}$ ]] || CLOUD_HTTP_CODE=000
        CLOUD_HTTP_BODY="$(cat -- "$body_f" 2>/dev/null)" || CLOUD_HTTP_BODY=""
        CLOUD_HTTP_HEADERS="$(tr -d '\r' < "$hdr_f" 2>/dev/null)" || CLOUD_HTTP_HEADERS=""
        _cfg_shred "$body_f"; _cfg_shred "$hdr_f"

        if (( rc == 0 )) && [[ "$CLOUD_HTTP_CODE" == 2?? || "$CLOUD_HTTP_CODE" == 308 ]]; then
            return 0
        fi
        err="$(cloud_http_error_code)"
        if (( attempt < max )) && _cloud_is_transient "$err"; then
            delay="$(_cloud_backoff_delay "$attempt")"
            attempt=$((attempt + 1))
            log_warn "Временная ошибка ($(cloud_error_text "$err"), HTTP $CLOUD_HTTP_CODE) — повтор $attempt/$max через ${delay} с"
            _cloud_sleep "$delay"
            continue
        fi
        return "$err"
    done
}

# ── Error reporting ───────────────────────────────────────────────────────────

cloud_error_text() {
    case "$1" in
        "$CLOUD_E_AUTH")     echo "ошибка авторизации (токен недействителен, истёк или отозван)" ;;
        "$CLOUD_E_PERM")     echo "недостаточно прав доступа" ;;
        "$CLOUD_E_NET")      echo "сетевая ошибка или тайм-аут" ;;
        "$CLOUD_E_RATE")     echo "превышен лимит запросов" ;;
        "$CLOUD_E_QUOTA")    echo "недостаточно места в облаке" ;;
        "$CLOUD_E_NOTFOUND") echo "ресурс не найден" ;;
        "$CLOUD_E_CONFIG")   echo "ошибка конфигурации" ;;
        "$CLOUD_E_TOOLARGE") echo "файл превышает лимит провайдера" ;;
        "$CLOUD_E_CONFLICT") echo "ресурс уже существует" ;;
        "$CLOUD_E_SERVER")   echo "ошибка на стороне провайдера" ;;
        "$CLOUD_E_API")      echo "ошибка API" ;;
        *)                   echo "ошибка" ;;
    esac
}

cloud_error_hint() {
    local name="${CLOUD_CTX_NAME:-<имя>}"
    case "$1" in
        "$CLOUD_E_AUTH")     echo "Повторите авторизацию: crypTar --cloud reauth $name" ;;
        "$CLOUD_E_PERM")     echo "Проверьте выданные приложению права (scope) и доступ к папке назначения; при необходимости: crypTar --cloud reauth $name" ;;
        "$CLOUD_E_NET")      echo "Проверьте подключение к интернету, DNS и прокси, затем повторите." ;;
        "$CLOUD_E_RATE")     echo "Подождите несколько минут и повторите." ;;
        "$CLOUD_E_QUOTA")    echo "Освободите место в облаке или выберите другое подключение." ;;
        "$CLOUD_E_TOOLARGE") echo "Яндекс Диск: лимит 1 ГБ на файл (50 ГБ с Яндекс 360)." ;;
        "$CLOUD_E_SERVER")   echo "Сервис временно недоступен — повторите позже." ;;
        *) ;;
    esac
}

# Short provider-supplied error description from the last response body.
cloud_api_reason() {
    local m
    m="$(jq -r '
        if type == "object" then
            ((.error | objects | .message) // .error_description // .description
             // .message // (.error | strings) // empty)
        else empty end
    ' <<< "${CLOUD_HTTP_BODY:-}" 2>/dev/null | head -c 300)" || m=""
    cloud_redact "$m"
}

# Log an actionable message for the last failed request; returns its code.
cloud_report_http_error() {
    local ctx="$1" code reason hint
    code="$(cloud_http_error_code)"
    reason="$(cloud_api_reason)"
    if (( ${CLOUD_CURL_RC:-0} != 0 )); then
        log_err "$ctx: $(cloud_error_text "$code") (curl: код $CLOUD_CURL_RC)"
    else
        log_err "$ctx: $(cloud_error_text "$code")${reason:+ — $reason} (HTTP $CLOUD_HTTP_CODE)"
    fi
    hint="$(cloud_error_hint "$code")"
    [[ -n "$hint" ]] && log_info "$hint"
    return "$code"
}

# ── Provider dispatch ─────────────────────────────────────────────────────────

cloud_provider_load() {
    local p="$1" file
    file="$(_cloud_provider_file "$p")" || {
        log_err "Неизвестный облачный провайдер: '$p'"
        return $CLOUD_E_CONFIG
    }
    [[ "$(type -t "${p}_upload")" == function ]] && return 0
    [[ -f "$CLOUD_PROVIDERS_DIR/$file" ]] || {
        log_err "Не найден модуль провайдера: $CLOUD_PROVIDERS_DIR/$file"
        return $CLOUD_E_CONFIG
    }
    source "$CLOUD_PROVIDERS_DIR/$file"
}

# cloud_provider_call <provider> <op> [args...]
# xtrace is suspended for the duration: provider code handles OAuth tokens.
cloud_provider_call() {
    local provider="$1" op="$2"; shift 2
    local _xt=0 rc=0
    { [[ $- == *x* ]] && _xt=1; set +x; } 2>/dev/null
    cloud_provider_load "$provider" || rc=$?
    if (( rc == 0 )); then
        if [[ "$(type -t "${provider}_${op}")" == function ]]; then
            "${provider}_${op}" "$@" || rc=$?
        else
            log_err "Провайдер '$provider' не поддерживает операцию '$op'"
            rc=$CLOUD_E_GENERIC
        fi
    fi
    CLOUD_BEARER=""
    CLOUD_AUTH_SCHEME="Bearer"
    if (( _xt )); then set -x; fi
    return $rc
}

# ── Multi-destination upload ──────────────────────────────────────────────────

# cloud_upload_many <file> <name> [<name> ...]
# Uploads the same local file to every connection, sequentially; one failure
# does not stop the others. Prints a result table.
# Returns 0 (all OK), CLOUD_EXIT_PARTIAL (some failed) or 1 (all failed).
cloud_upload_many() {
    local file="$1"; shift
    local base n rc
    local -A conn=()
    local -a r_name=() r_prov=() r_stat=() r_info=()
    local ok=0 fail=0
    base="$(basename -- "$file")"

    for n in "$@"; do
        rc=0
        CLOUD_CTX_NAME="$n"
        CLOUD_UPLOADED_NAME=""
        cloud_cfg_load "$n" conn || rc=$?
        if (( rc == 0 )); then
            log_step "[$n] Загрузка $base → $(cloud_provider_label "${conn[provider]}"):${conn[folder]:-}"
            cloud_provider_call "${conn[provider]}" upload conn "$file" "$base" || rc=$?
        fi
        r_name+=("$n")
        r_prov+=("$(cloud_provider_label "${conn[provider]:-?}")")
        if (( rc == 0 )); then
            ok=$((ok + 1))
            r_stat+=("OK")
            r_info+=("${conn[folder]:-}/${CLOUD_UPLOADED_NAME:-$base}")
            log_ok "[$n] Загружено: ${CLOUD_UPLOADED_NAME:-$base}"
        else
            fail=$((fail + 1))
            r_stat+=("ОШИБКА")
            r_info+=("$(cloud_error_text "$rc")")
            log_err "[$n] Загрузка не удалась: $(cloud_error_text "$rc")"
        fi
        conn=()   # drop tokens from memory between destinations
    done
    CLOUD_CTX_NAME=""

    echo ""
    log_info "📊 Результаты загрузки в облако:"
    local i
    for i in "${!r_name[@]}"; do
        printf '  %-24s %-13s %-7s %s\n' "${r_name[i]}" "${r_prov[i]}" "${r_stat[i]}" "${r_info[i]}"
    done

    if (( fail == 0 )); then return 0; fi
    if (( ok > 0 )); then return $CLOUD_EXIT_PARTIAL; fi
    return 1
}

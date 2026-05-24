#!/usr/bin/env bash
[[ -n "${_CONFIG_LOADED:-}" ]] && return 0
_CONFIG_LOADED=1

# ══ Security caveats ══════════════════════════════════════════════════════════
# 1. `unset password` is hygiene only — the value may linger in process memory
#    and appear in core dumps. Bash has no mechanism to zero memory explicitly.
# 2. Decrypted plaintext lives in /dev/shm for the minimum window required by
#    GPG. /dev/shm is RAM-backed tmpfs; it is not normally written to disk, but
#    can appear in hibernation images or kernel crash dumps.
# 3. For higher security requirements consider rewriting this layer in a
#    language with explicit memory control (Go, Rust).
# ═════════════════════════════════════════════════════════════════════════════

readonly CFG_DIR="$HOME/.config/cryptar"
readonly CFG_FILE="$CFG_DIR/servers.conf.gpg"
readonly CFG_KEY_FILE="$CFG_DIR/.gpg_key_id"
readonly CFG_LOCK_FILE="$CFG_DIR/.lock"

# ── Internal helpers ──────────────────────────────────────────────────────────

_cfg_ensure_dir() {
    [[ -d "$CFG_DIR" ]] && return 0
    mkdir -p "$CFG_DIR"
    chmod 700 "$CFG_DIR"
}

_cfg_tmp_file() {
    if [[ -d /dev/shm && -w /dev/shm ]]; then
        mktemp /dev/shm/cryptar_XXXXXX
    else
        mktemp
    fi
}

_cfg_shred() {
    local path="$1"
    [[ -f "$path" ]] || return 0
    if command -v shred &>/dev/null; then
        shred -u "$path" 2>/dev/null || rm -f "$path"
    else
        rm -f "$path"
    fi
}

# Acquire an exclusive advisory lock on CFG_LOCK_FILE.
# Uses automatic FD assignment — requires bash 4.1+.
_cfg_lock() {
    # FIX 2: fail loudly when flock is absent rather than silently continuing
    # without a lock, which would make all concurrency guarantees invisible failures.
    command -v flock &>/dev/null || { log_err "flock не найден — установите util-linux"; return 1; }
    _cfg_ensure_dir
    exec {_CFG_LOCK_FD}>>"$CFG_LOCK_FILE"
    flock -x "$_CFG_LOCK_FD"
}

_cfg_unlock() {
    flock -u "$_CFG_LOCK_FD"
    exec {_CFG_LOCK_FD}>&-
}

# ── GPG key helpers ───────────────────────────────────────────────────────────

# Output "KEY_ID : UID" for every public key → stdout.
cfg_list_gpg_keys() {
    gpg --list-keys --with-colons 2>/dev/null | awk -F: '
        /^pub/ { key=$5 }
        /^uid/ { uid=$10; print key " : " uid }
    '
}

cfg_set_encrypt_key() {
    local key_id="$1"
    _cfg_ensure_dir
    printf '%s\n' "$key_id" > "$CFG_KEY_FILE"
    chmod 600 "$CFG_KEY_FILE"
}

# ── Encrypt / Decrypt ─────────────────────────────────────────────────────────

# Decrypt CFG_FILE to a RAM-backed temp file.
# Echoes the temp file path to stdout — caller is responsible for cleanup.
# This function is always invoked in a subshell (via $(...)), so its trap is
# subshell-local and does not interfere with the caller's trap state.
cfg_decrypt() {
    local tmp
    tmp="$(_cfg_tmp_file)" || { log_err "Не удалось создать временный файл"; return 1; }

    # FIX 4: cfg_decrypt runs in a subshell (called via $(...)).
    # The trap below fires on subshell exit — including the normal path.
    # It is disarmed with `trap -` just before echoing the path to hand
    # ownership to the caller. A signal arriving in that narrow window
    # will not shred the tmp file; callers must register their own trap.
    trap '_cfg_shred "$tmp"; trap - EXIT INT TERM' EXIT INT TERM

    if [[ ! -f "$CFG_FILE" ]]; then
        trap - EXIT INT TERM   # normal exit: caller takes ownership
        echo "$tmp"
        return 0
    fi

    if ! gpg --quiet -d "$CFG_FILE" > "$tmp" 2>/dev/null; then
        trap - EXIT INT TERM
        _cfg_shred "$tmp"
        log_err "Не удалось расшифровать $CFG_FILE"
        return 1
    fi

    trap - EXIT INT TERM   # normal exit: caller takes ownership
    echo "$tmp"
}

# Encrypt tmp → CFG_FILE atomically, then secure-delete tmp.
# Writes to CFG_FILE.tmp first and renames — prevents a partial overwrite if
# the process is killed during the GPG write.
# No trap here: this function runs in the caller's shell (not a subshell) and
# must not clobber the caller's trap registration.
cfg_encrypt() {
    local tmp="$1"
    local key_id result=0

    _cfg_ensure_dir

    if [[ ! -f "$CFG_KEY_FILE" ]]; then
        log_err "Ключ шифрования не задан. Выполните: cfg_set_encrypt_key <key_id>"
        _cfg_shred "$tmp"
        return 1
    fi
    key_id="$(cat "$CFG_KEY_FILE")"

    if gpg --quiet --yes --encrypt --recipient "$key_id" \
           --output "$CFG_FILE.tmp" "$tmp" 2>/dev/null; then
        # FIX 3: guard mv failure — a cross-device move or permission error
        # would otherwise leave the encrypted .tmp file stranded on disk.
        if mv "$CFG_FILE.tmp" "$CFG_FILE" 2>/dev/null; then
            chmod 600 "$CFG_FILE"
        else
            log_err "Не удалось переименовать $CFG_FILE.tmp → $CFG_FILE"
            rm -f "$CFG_FILE.tmp"
            result=1
        fi
    else
        log_err "Не удалось зашифровать конфиг (ключ: $key_id)"
        rm -f "$CFG_FILE.tmp"   # clean up the failed partial write
        result=1
    fi

    _cfg_shred "$tmp"
    return $result
}

# ── INI queries ───────────────────────────────────────────────────────────────

cfg_list_servers() {
    [[ ! -f "$CFG_FILE" ]] && return 0

    local tmp
    tmp="$(cfg_decrypt)" || return 1
    trap '_cfg_shred "$tmp"; trap - EXIT INT TERM' EXIT INT TERM

    # Capture into variable before shredding — ensures awk finishes reading
    # the file before it is deleted (eliminates a TOCTOU race).
    local result
    result="$(awk '
        /^[[:space:]]*([#;]|$)/ { next }
        /^\[/ { gsub(/^\[|\]$/, ""); print }
    ' "$tmp")"

    trap - EXIT INT TERM
    _cfg_shred "$tmp"
    echo "$result"
}

cfg_server_exists() {
    local name="$1"
    [[ ! -f "$CFG_FILE" ]] && return 1

    local tmp
    tmp="$(cfg_decrypt)" || return 1
    trap '_cfg_shred "$tmp"; trap - EXIT INT TERM' EXIT INT TERM

    # AWK section-header match prevents false positives: grep -qF "[$name]"
    # would also match a description field containing the literal "[name]".
    local found
    found="$(awk -v section="[$name]" '
        /^[[:space:]]*([#;]|$)/ { next }
        /^\[/ && $0 == section  { print 1; exit }
    ' "$tmp")"

    trap - EXIT INT TERM
    _cfg_shred "$tmp"
    [[ "$found" == "1" ]]
}

cfg_get() {
    local name="$1" field="$2"

    local tmp
    tmp="$(cfg_decrypt)" || return 1
    trap '_cfg_shred "$tmp"; trap - EXIT INT TERM' EXIT INT TERM

    # Capture before shredding to avoid a race between awk reading and deletion.
    local result
    result="$(awk -v section="[$name]" -v key="$field" '
        /^[[:space:]]*([#;]|$)/ { next }
        { gsub(/^[[:space:]]+|[[:space:]]+$/, "") }
        /^\[/ { in_sec = ($0 == section) }
        in_sec && $0 ~ ("^" key "[[:space:]]*=") {
            val = substr($0, index($0, "=") + 1)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", val)
            print val; exit
        }
    ' "$tmp")"

    trap - EXIT INT TERM
    _cfg_shred "$tmp"
    echo "$result"
}

# ── INI mutations — all acquire CFG_LOCK_FILE before touching the config ──────

cfg_set() {
    local name="$1" field="$2" value="$3"

    _cfg_lock || return 1

    local tmp newtmp
    tmp="$(cfg_decrypt)"      || { _cfg_unlock; return 1; }
    newtmp="$(_cfg_tmp_file)" || { _cfg_shred "$tmp"; _cfg_unlock; return 1; }

    trap '_cfg_shred "$tmp"; _cfg_shred "$newtmp"; _cfg_unlock; trap - EXIT INT TERM' EXIT INT TERM

    awk -v section="[$name]" -v key="$field" -v val="$value" '
        /^[[:space:]]*[#;]/ { next }
        { gsub(/^[[:space:]]+|[[:space:]]+$/, "") }
        /^\[/ {
            if (in_sec && !found) { print key "=" val; found=1 }
            in_sec = ($0 == section)
        }
        in_sec && $0 ~ ("^" key "[[:space:]]*=") { print key "=" val; found=1; next }
        { print }
        END { if (in_sec && !found) print key "=" val }
    ' "$tmp" > "$newtmp"

    _cfg_shred "$tmp"
    cfg_encrypt "$newtmp"
    local rc=$?

    trap - EXIT INT TERM
    _cfg_unlock
    return $rc
}

cfg_add_server() {
    local name="$1"
    local host="$2"
    local port="$3"
    local user="$4"
    local auth_type="$5"
    local password="$6"
    local key_path="$7"
    local gpg_key_id="$8"
    local description="$9"

    # ── Validate inputs before any I/O ────────────────────────────────────────
    local _missing=""
    [[ -z "$name"      ]] && _missing+="name "
    [[ -z "$host"      ]] && _missing+="host "
    [[ -z "$user"      ]] && _missing+="user "
    [[ -z "$auth_type" ]] && _missing+="auth_type "
    if [[ -n "$_missing" ]]; then
        log_err "cfg_add_server: пустые обязательные поля: ${_missing% }"
        unset password; return 1
    fi
    if ! [[ "$port" =~ ^[0-9]+$ ]] || (( port < 1 || port > 65535 )); then
        log_err "cfg_add_server: порт должен быть числом 1–65535 (получено: '$port')"
        unset password; return 1
    fi
    if [[ "$auth_type" != "password" && "$auth_type" != "key" ]]; then
        log_err "cfg_add_server: auth_type должен быть 'password' или 'key'"
        unset password; return 1
    fi
    if [[ "$auth_type" == "password" && -z "$password" ]]; then
        log_err "cfg_add_server: пароль обязателен при auth_type=password"
        unset password; return 1
    fi
    if [[ "$auth_type" == "key" ]]; then
        if [[ -z "$key_path" ]]; then
            log_err "cfg_add_server: путь к ключу обязателен при auth_type=key"
            unset password; return 1
        fi
        if [[ ! -f "$key_path" || ! -r "$key_path" ]]; then
            log_err "cfg_add_server: ключ не найден или недоступен: $key_path"
            unset password; return 1
        fi
    fi
    # ─────────────────────────────────────────────────────────────────────────

    _cfg_lock || { unset password; return 1; }

    local tmp
    tmp="$(cfg_decrypt)" || { unset password; _cfg_unlock; return 1; }

    trap '_cfg_shred "$tmp"; _cfg_unlock; trap - EXIT INT TERM' EXIT INT TERM

    # FIX 1: use AWK section-header match instead of grep -qF.
    # grep -qF "[$name]" produces false positives when a field value (e.g.
    # description) contains the literal string [$name].  AWK restricts the
    # match to lines that are actual section headers.
    local _dup
    _dup="$(awk -v section="[$name]" '
        /^[[:space:]]*([#;]|$)/ { next }
        /^\[/ && $0 == section  { print 1; exit }
    ' "$tmp")"
    if [[ "$_dup" == "1" ]]; then
        log_err "Сервер '$name' уже существует"
        trap - EXIT INT TERM
        _cfg_shred "$tmp"
        unset password
        _cfg_unlock
        return 1
    fi

    [[ -s "$tmp" ]] && printf '\n' >> "$tmp"

    {
        printf '[%s]\n'          "$name"
        printf 'host=%s\n'      "$host"
        printf 'port=%s\n'      "$port"
        printf 'user=%s\n'      "$user"
        printf 'auth_type=%s\n' "$auth_type"
        [[ "$auth_type" == "password" ]] && printf 'password=%s\n' "$password"
        [[ -n "$key_path"    ]] && printf 'key_path=%s\n'    "$key_path"
        [[ -n "$gpg_key_id"  ]] && printf 'gpg_key_id=%s\n' "$gpg_key_id"
        [[ -n "$description" ]] && printf 'description=%s\n' "$description"
    } >> "$tmp"

    unset password   # clear before handing the file to cfg_encrypt

    cfg_encrypt "$tmp"
    local rc=$?

    trap - EXIT INT TERM
    _cfg_unlock
    return $rc
}

cfg_remove_server() {
    local name="$1"

    _cfg_lock || return 1

    local tmp newtmp
    tmp="$(cfg_decrypt)"      || { _cfg_unlock; return 1; }
    newtmp="$(_cfg_tmp_file)" || { _cfg_shred "$tmp"; _cfg_unlock; return 1; }

    trap '_cfg_shred "$tmp"; _cfg_shred "$newtmp"; _cfg_unlock; trap - EXIT INT TERM' EXIT INT TERM

    # skip=1 from [target] until the next section header resets it to 0.
    # Blank separator lines are preserved: they're not headers, so skip is
    # still 0 before [target] and the line prints; the blank after target's
    # last key is skipped (skip=1 there), which is acceptable.
    awk -v section="[$name]" '
        /^\[/ { skip = ($0 == section) }
        !skip  { print }
    ' "$tmp" > "$newtmp"

    _cfg_shred "$tmp"
    cfg_encrypt "$newtmp"
    local rc=$?

    trap - EXIT INT TERM
    _cfg_unlock
    return $rc
}

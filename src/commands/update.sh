#!/usr/bin/env bash
# src/commands/update.sh — crypTar --check-update / --update
#
# Source of updates: the latest *published stable* GitHub Release of
# $UPD_REPO (GET /repos/{repo}/releases/latest — drafts and prereleases are
# excluded by GitHub; the flags are re-checked here). The `main` branch and
# arbitrary commits are never used.
#
# Release payload, in order of preference:
#   1. signed artifacts attached to the release (see README "Публикация релиза"):
#        cryptar-<ver>.tar.gz, SHA256SUMS, SHA256SUMS.asc
#      SHA256SUMS.asc is verified in a throw-away GNUPGHOME against the key
#      pinned in the INSTALLED copy (src/keys/release-signing-key.asc), never
#      against the user's keyring. Once a key is pinned, unsigned releases are
#      refused (no silent downgrade to the weaker mode).
#   2. no pinned key: GitHub's source archive of the release tag over HTTPS.
#      Integrity is checked (gzip, layout, version, syntax), authenticity relies
#      on HTTPS + GitHub only — documented as a limitation.
#
# Download, extraction and validation run as the invoking user in a private
# temp dir; only the final install step (src/install/core.sh) is run through
# sudo, and only when the installation directories are not writable.

[[ -n "${_UPDATE_LOADED:-}" ]] && return 0
_UPDATE_LOADED=1

source "$SRC_DIR/install/core.sh"

UPD_REPO="${CRYPTAR_UPDATE_REPO:-Ti8an/CrypTar}"
readonly UPD_KEY_FILE="$SRC_DIR/keys/release-signing-key.asc"
readonly UPD_MAX_BYTES=$(( 50 * 1024 * 1024 ))

# Exit codes
readonly UPD_E_FAIL=1    # generic / validation failure
readonly UPD_E_NET=2     # network / GitHub unavailable
readonly UPD_E_PERM=3    # cannot write to the installation

# Filled by upd_fetch_latest
UPD_TAG="" UPD_VER=""
# Filled by _upd_detect_install
UPD_BIN="" UPD_BIN_DIR="" UPD_LIB_DIR=""
_UPD_TMP=""

# ── SemVer precedence ─────────────────────────────────────────────────────────

# upd_semver_cmp <a> <b> — echo -1, 0 or 1 (SemVer 2.0.0 §11; build metadata
# ignored). Both arguments must be valid SemVer.
upd_semver_cmp() {
    local LC_ALL=C a="${1%%+*}" b="${2%%+*}"
    local a_core="${a%%-*}" b_core="${b%%-*}" a_pre="" b_pre=""
    [[ "$a" == *-* ]] && a_pre="${a#*-}"
    [[ "$b" == *-* ]] && b_pre="${b#*-}"

    local -a x y
    IFS=. read -r -a x <<< "$a_core"
    IFS=. read -r -a y <<< "$b_core"
    local i
    for i in 0 1 2; do
        if _upd_num_lt "${x[$i]}" "${y[$i]}"; then echo -1; return; fi
        if _upd_num_lt "${y[$i]}" "${x[$i]}"; then echo 1;  return; fi
    done

    # A version without prerelease has higher precedence than one with it.
    if [[ -z "$a_pre" && -z "$b_pre" ]]; then echo 0; return; fi
    if [[ -z "$a_pre" ]]; then echo 1;  return; fi
    if [[ -z "$b_pre" ]]; then echo -1; return; fi

    IFS=. read -r -a x <<< "$a_pre"
    IFS=. read -r -a y <<< "$b_pre"
    local n=${#x[@]} p q
    (( ${#y[@]} > n )) && n=${#y[@]}
    for (( i = 0; i < n; i++ )); do
        if (( i >= ${#x[@]} )); then echo -1; return; fi
        if (( i >= ${#y[@]} )); then echo 1;  return; fi
        p="${x[$i]}" q="${y[$i]}"
        [[ "$p" == "$q" ]] && continue
        if [[ "$p" =~ ^[0-9]+$ && "$q" =~ ^[0-9]+$ ]]; then
            if _upd_num_lt "$p" "$q"; then echo -1; else echo 1; fi
        elif [[ "$p" =~ ^[0-9]+$ ]]; then echo -1      # numeric < alphanumeric
        elif [[ "$q" =~ ^[0-9]+$ ]]; then echo 1
        elif [[ "$p" < "$q" ]]; then echo -1
        else echo 1
        fi
        return
    done
    echo 0
}

# Arbitrary-length non-negative integer "<" without arithmetic overflow.
_upd_num_lt() {
    local a="$1" b="$2"
    (( ${#a} != ${#b} )) && { (( ${#a} < ${#b} )); return; }
    [[ "$a" < "$b" ]]
}

# ── HTTP ──────────────────────────────────────────────────────────────────────

# _upd_http <url> <out_file> <hdr_file> [accept] — echo the final HTTP status.
# Returns curl's exit code. HTTPS only, also across redirects; bounded size.
_upd_http() {
    local url="$1" out="$2" hdr="$3" accept="${4:-application/octet-stream}"
    curl -sS -L --proto '=https' --proto-redir '=https' \
         --connect-timeout 15 --max-time 300 --max-filesize "$UPD_MAX_BYTES" \
         -A "CrypTar/${VERSION:-unknown}" -H "Accept: $accept" \
         -o "$out" -D "$hdr" -w '%{http_code}' -- "$url" 2>/dev/null
}

# _upd_header <hdr_file> <name> — value of the last occurrence of a header.
_upd_header() {
    awk -v n="$(tr '[:upper:]' '[:lower:]' <<< "$2")" '
        { line=$0; sub(/\r$/, "", line); i=index(line, ":") }
        i > 0 && tolower(substr(line, 1, i-1)) == n { v=substr(line, i+1); sub(/^[ \t]+/, "", v) }
        END { if (v != "") print v }' "$1" 2>/dev/null
}

_upd_net_error() {
    local what="$1" rc="$2"
    case "$rc" in
        6)  log_err "$what: не удалось разрешить имя сервера (нет сети или DNS)." ;;
        7)  log_err "$what: не удалось подключиться (нет сети или доступ заблокирован)." ;;
        28) log_err "$what: превышено время ожидания ответа." ;;
        35|51|58|60|77|83|90|91)
            log_err "$what: ошибка TLS/проверки сертификата (curl код $rc)." ;;
        63) log_err "$what: размер ответа превышает допустимый ($(( UPD_MAX_BYTES / 1024 / 1024 )) МБ)." ;;
        *)  log_err "$what: сетевая ошибка (curl код $rc)." ;;
    esac
}

# ── Release metadata ──────────────────────────────────────────────────────────

# upd_fetch_latest — set UPD_TAG / UPD_VER from the latest stable release.
upd_fetch_latest() {
    local body="$_UPD_TMP/release.json" hdr="$_UPD_TMP/release.hdr" code rc=0
    code="$(_upd_http "https://api.github.com/repos/$UPD_REPO/releases/latest" \
            "$body" "$hdr" "application/vnd.github+json")" || rc=$?
    if (( rc != 0 )); then
        _upd_net_error "GitHub недоступен" "$rc"
        return "$UPD_E_NET"
    fi

    case "$code" in
        200) ;;
        404)
            log_err "В репозитории $UPD_REPO нет опубликованных стабильных релизов."
            return "$UPD_E_FAIL" ;;
        403|429)
            if [[ "$(_upd_header "$hdr" x-ratelimit-remaining)" == 0 || "$code" == 429 ]]; then
                local reset when=""
                reset="$(_upd_header "$hdr" x-ratelimit-reset)"
                [[ "$reset" =~ ^[0-9]+$ ]] && when="$(date -d "@$reset" '+%H:%M' 2>/dev/null || true)"
                log_err "Превышен лимит запросов к GitHub API${when:+ — повторите после $when}."
            else
                log_err "GitHub отклонил запрос (HTTP $code)."
            fi
            return "$UPD_E_NET" ;;
        5??)
            log_err "GitHub временно недоступен (HTTP $code). Повторите позже."
            return "$UPD_E_NET" ;;
        *)
            log_err "Неожиданный ответ GitHub API (HTTP ${code:-нет})."
            return "$UPD_E_FAIL" ;;
    esac

    local tag draft pre
    if ! { IFS=$'\t' read -r tag draft pre < <(jq -r \
            'if type == "object" then [(.tag_name // "" | tostring), (.draft | tostring), (.prerelease | tostring)] | @tsv else error("not an object") end' \
            "$body" 2>/dev/null); } || [[ -z "$tag" ]]; then
        log_err "Некорректные метаданные релиза от GitHub."
        return "$UPD_E_FAIL"
    fi
    if [[ "$draft" != false || "$pre" != false ]]; then
        log_err "Последний релиз не является стабильным (draft=$draft, prerelease=$pre) — пропущен."
        return "$UPD_E_FAIL"
    fi
    local ver="${tag#v}"
    if ! inst_is_semver "$ver"; then
        log_err "Тег последнего релиза не соответствует SemVer: '${tag:0:64}'."
        return "$UPD_E_FAIL"
    fi
    UPD_TAG="$tag" UPD_VER="$ver"
}

# ── Helpers ───────────────────────────────────────────────────────────────────

_upd_need() {
    local c missing=()
    for c in "$@"; do command -v "$c" &>/dev/null || missing+=("$c"); done
    (( ${#missing[@]} == 0 )) && return 0
    log_err "Не найдены необходимые утилиты: ${missing[*]}. Установите их (например: sudo apt-get install ${missing[*]})."
    return 1
}

_upd_mktemp() {
    _UPD_TMP="$( umask 077; mktemp -d "${TMPDIR:-/tmp}/cryptar-update.XXXXXX" )" \
        || { log_err "Не удалось создать временный каталог."; return 1; }
}

_upd_cleanup() {
    [[ -n "$_UPD_TMP" && -d "$_UPD_TMP" ]] && rm -rf -- "$_UPD_TMP"
    _UPD_TMP=""
}

_upd_current_version() {
    if ! inst_is_semver "${VERSION:-}"; then
        log_err "Не удалось определить установленную версию ('${VERSION:-}')."
        return 1
    fi
}

_upd_validate_repo() {
    [[ "$UPD_REPO" =~ ^[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9._-]+$ ]] && return 0
    log_err "Некорректное значение CRYPTAR_UPDATE_REPO: ожидается 'владелец/репозиторий'."
    return 1
}

# _upd_detect_install — locate the running installation from the entry point
# itself (installed copies have SRC_DIR baked to <lib_dir>/src).
_upd_detect_install() {
    local self="${CRYPTAR_SELF:-}"
    if [[ -z "$self" || ! -f "$self" ]]; then
        log_err "Не удалось определить путь к исполняемому файлу crypTar."
        return 1
    fi
    if [[ "$SRC_DIR" == "$SCRIPT_DIR/src" && -f "$SCRIPT_DIR/VERSION" ]]; then
        log_err "crypTar запущен из рабочей копии репозитория ($SCRIPT_DIR)."
        log_info "Обновите её через git (git pull) или установите программу: ./install.sh"
        return 1
    fi
    local lib_dir="${SRC_DIR%/src}"
    if [[ "$lib_dir" == "$SRC_DIR" || "${lib_dir##*/}" != cryptar || ! -d "$SRC_DIR" ]]; then
        log_err "Нестандартная установка (библиотека: $SRC_DIR) — обновление невозможно."
        log_info "Переустановите программу через install.sh."
        return 1
    fi
    UPD_BIN="$self"
    UPD_BIN_DIR="${self%/*}"
    UPD_LIB_DIR="$lib_dir"
}

_upd_have_sudo() { command -v sudo &>/dev/null; }

# True when the current user can perform the install step without sudo.
_upd_can_write() {
    [[ -w "$UPD_BIN_DIR" && -w "$UPD_LIB_DIR" ]] || return 1
    [[ ! -e "$UPD_LIB_DIR/src" || -w "$UPD_LIB_DIR/src" ]]
}

# ── Download & verification ───────────────────────────────────────────────────

# _upd_download <url> <out> <what> — 0 ok, 4 = HTTP 404, other = error (reported).
_upd_download() {
    local url="$1" out="$2" what="$3" code rc=0
    code="$(_upd_http "$url" "$out" "$out.hdr")" || rc=$?
    rm -f -- "$out.hdr"
    if (( rc != 0 )); then
        rm -f -- "$out"
        _upd_net_error "Загрузка $what" "$rc"
        return "$UPD_E_NET"
    fi
    case "$code" in
        200) [[ -s "$out" ]] && return 0
             log_err "Загрузка $what: получен пустой ответ." ;;
        404) rm -f -- "$out"; return 4 ;;
        *)   log_err "Загрузка $what: HTTP ${code:-нет ответа}." ;;
    esac
    rm -f -- "$out"
    return "$UPD_E_FAIL"
}

# _upd_verify_signature <file> <sig> — verify against the pinned key in an
# isolated keyring. The user's GNUPGHOME is never touched.
_upd_verify_signature() {
    local file="$1" sig="$2" home status fpr key_fprs
    home="$_UPD_TMP/gnupg"
    ( umask 077; mkdir -p "$home" ) || return 1
    if ! GNUPGHOME="$home" gpg --batch --quiet --no-autostart --import "$UPD_KEY_FILE" 2>/dev/null; then
        log_err "Не удалось загрузить доверенный ключ подписи релизов ($UPD_KEY_FILE)."
        return 1
    fi
    key_fprs="$(GNUPGHOME="$home" gpg --batch --with-colons --fingerprint 2>/dev/null \
                | awk -F: '$1 == "fpr" { print $10 }')"
    status="$(GNUPGHOME="$home" gpg --batch --no-autostart --status-fd 1 \
              --verify "$sig" "$file" 2>/dev/null)" || true
    # VALIDSIG <sig-fpr> ... <primary-key-fpr> — must belong to the pinned key.
    fpr="$(awk '$2 == "VALIDSIG" { print $NF }' <<< "$status")"
    if [[ -z "$fpr" ]] || ! grep -qxF -- "$fpr" <<< "$key_fprs"; then
        log_err "Подпись релиза недействительна или сделана не доверенным ключом. Обновление отменено."
        return 1
    fi
}

# _upd_fetch_payload — download and verify the release archive; set UPD_ARCHIVE.
_upd_fetch_payload() {
    local base="https://github.com/$UPD_REPO/releases/download/$UPD_TAG"
    local art="cryptar-$UPD_VER.tar.gz" sums="$_UPD_TMP/SHA256SUMS" rc=0
    UPD_ARCHIVE="$_UPD_TMP/$art"

    _upd_download "$base/SHA256SUMS" "$sums" "SHA256SUMS" || rc=$?
    if (( rc == 4 )); then
        if [[ -f "$UPD_KEY_FILE" ]]; then
            log_err "Релиз $UPD_TAG не содержит подписанного манифеста (SHA256SUMS), а установленная версия требует подпись. Обновление отменено."
            return "$UPD_E_FAIL"
        fi
        log_warn "Релиз не содержит подписанных артефактов: используется архив исходников GitHub."
        log_warn "Целостность архива проверяется, подлинность обеспечивается только HTTPS и GitHub."
        UPD_ARCHIVE="$_UPD_TMP/source.tar.gz"
        rc=0
        _upd_download "https://github.com/$UPD_REPO/archive/refs/tags/$UPD_TAG.tar.gz" \
                      "$UPD_ARCHIVE" "архива релиза" || rc=$?
        (( rc == 4 )) && log_err "Архив релиза $UPD_TAG не найден."
        (( rc == 0 )) || return "$(( rc == 4 ? UPD_E_FAIL : rc ))"
        return 0
    fi
    (( rc == 0 )) || return "$rc"

    if [[ -f "$UPD_KEY_FILE" ]]; then
        _upd_need gpg || return "$UPD_E_FAIL"
        rc=0
        _upd_download "$base/SHA256SUMS.asc" "$sums.asc" "SHA256SUMS.asc" || rc=$?
        if (( rc == 4 )); then
            log_err "Релиз $UPD_TAG не содержит подписи SHA256SUMS.asc. Обновление отменено."
            return "$UPD_E_FAIL"
        fi
        (( rc == 0 )) || return "$rc"
        _upd_verify_signature "$sums" "$sums.asc" || return "$UPD_E_FAIL"
        log_ok "Подпись манифеста релиза проверена"
    else
        log_warn "Доверенный ключ подписи не настроен: SHA256SUMS проверяет только целостность, не подлинность."
    fi

    rc=0
    _upd_download "$base/$art" "$UPD_ARCHIVE" "$art" || rc=$?
    (( rc == 4 )) && log_err "Релиз $UPD_TAG не содержит файла $art."
    (( rc == 0 )) || return "$(( rc == 4 ? UPD_E_FAIL : rc ))"

    _upd_need sha256sum || return "$UPD_E_FAIL"
    local expected actual
    expected="$(awk -v f="$art" '($2 == f || $2 == "*" f) && $1 ~ /^[0-9a-fA-F]{64}$/ { print tolower($1); exit }' "$sums")"
    actual="$(sha256sum -- "$UPD_ARCHIVE" | awk '{ print $1 }')"
    if [[ -z "$expected" ]]; then
        log_err "SHA256SUMS не содержит контрольной суммы для $art."
        return "$UPD_E_FAIL"
    fi
    if [[ "$expected" != "$actual" ]]; then
        log_err "Контрольная сумма $art не совпадает — архив повреждён или подменён."
        return "$UPD_E_FAIL"
    fi
    log_ok "Контрольная сумма архива совпадает"
}

# _upd_extract <archive> — validate the listing, extract, echo the tree path.
# Accepts only regular files and directories under a single top-level dir.
_upd_extract() {
    local archive="$1" dest="$_UPD_TMP/x" names top bad
    if ! gzip -t -- "$archive" 2>/dev/null; then
        log_err "Архив релиза повреждён (ошибка gzip)."
        return 1
    fi
    if ! names="$(tar -tzf "$archive" 2>/dev/null)" || [[ -z "$names" ]]; then
        log_err "Архив релиза повреждён или пуст."
        return 1
    fi
    bad="$(awk '
        /^\// || /(^|\/)\.\.(\/|$)/ { print; exit }
        { sub(/^\.\//, ""); split($0, p, "/"); if (p[1] == "") { print; exit } tops[p[1]] = 1 }
        END { n = 0; for (t in tops) n++; if (n != 1) print "<несколько корневых каталогов>" }' <<< "$names")"
    if [[ -n "$bad" ]]; then
        log_err "Архив релиза содержит недопустимый путь: ${bad:0:120}"
        return 1
    fi
    # Entry types: GNU/busybox tar -tv print the type as the first character.
    bad="$(tar -tvzf "$archive" 2>/dev/null | awk 'substr($0, 1, 1) != "-" && substr($0, 1, 1) != "d" { print; exit }')"
    if [[ -n "$bad" ]]; then
        log_err "Архив релиза содержит ссылки или специальные файлы — установка отменена."
        return 1
    fi

    mkdir -p -- "$dest"
    if ! tar -xzf "$archive" -C "$dest" --no-same-owner --no-same-permissions 2>/dev/null; then
        log_err "Не удалось распаковать архив релиза."
        return 1
    fi
    top="$(awk '{ sub(/^\.\//, ""); split($0, p, "/"); print p[1]; exit }' <<< "$names")"
    [[ -n "$top" && -d "$dest/$top" ]] || { log_err "Неверная структура архива релиза."; return 1; }
    printf '%s\n' "$dest/$top"
}

# ── Commands ──────────────────────────────────────────────────────────────────

# _upd_check — shared by both commands. Echo nothing; set UPD_CMP:
#   1 — update available, 0 — up to date, -1 — installed is newer.
_upd_check() {
    _upd_validate_repo && _upd_current_version || return "$UPD_E_FAIL"
    _upd_need curl jq || return "$UPD_E_FAIL"
    log_info "Установленная версия: $VERSION"
    log_step "Проверяем последний стабильный релиз ($UPD_REPO)..."
    upd_fetch_latest || return $?
    UPD_CMP="$(upd_semver_cmp "$UPD_VER" "$VERSION")"
    log_info "Последняя стабильная версия: $UPD_VER"
}

cmd_check_update() {
    (( $# == 0 )) || { log_err "Использование: crypTar --check-update"; return "$UPD_E_FAIL"; }
    _upd_mktemp || return "$UPD_E_FAIL"
    trap '_upd_cleanup' EXIT
    local rc=0
    _upd_check || rc=$?
    _upd_cleanup
    trap - EXIT
    (( rc == 0 )) || return "$rc"

    case "$UPD_CMP" in
        1)  log_ok "Доступно обновление: $VERSION → $UPD_VER"
            log_info "Будет установлена версия $UPD_VER. Установить: crypTar --update" ;;
        0)  log_ok "Установлена последняя стабильная версия." ;;
        *)  log_info "Установленная версия ($VERSION) новее последнего стабильного релиза ($UPD_VER)." ;;
    esac
}

cmd_update() {
    local assume_yes=0 arg
    for arg in "$@"; do
        case "$arg" in
            -y|--yes) assume_yes=1 ;;
            *) log_err "Неизвестный аргумент: $arg"
               log_err "Использование: crypTar --update [-y|--yes]"
               return "$UPD_E_FAIL" ;;
        esac
    done

    _upd_detect_install || return "$UPD_E_FAIL"
    _upd_mktemp || return "$UPD_E_FAIL"
    trap '_upd_cleanup' EXIT
    trap '_upd_cleanup; trap - EXIT; echo >&2; log_err "Обновление прервано — установленная версия не изменена."; exit 130' INT TERM HUP

    local rc=0
    _upd_update "$assume_yes" || rc=$?
    _upd_cleanup
    trap - EXIT INT TERM HUP
    return "$rc"
}

_upd_update() {
    local assume_yes="$1" rc=0
    _upd_check || return $?

    case "$UPD_CMP" in
        0)  log_ok "Установлена последняя стабильная версия — обновление не требуется."
            return 0 ;;
        -1) log_info "Установленная версия ($VERSION) новее последнего стабильного релиза ($UPD_VER) — понижение версии не выполняется."
            return 0 ;;
    esac

    local use_sudo=0
    if ! _upd_can_write; then
        if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
            log_err "Нет прав на запись в $UPD_BIN_DIR или $UPD_LIB_DIR."
            return "$UPD_E_PERM"
        fi
        if ! _upd_have_sudo; then
            log_err "Для обновления системной установки ($UPD_LIB_DIR) нужны права администратора, а sudo не найден."
            log_info "Запустите обновление от root: crypTar --update"
            return "$UPD_E_PERM"
        fi
        use_sudo=1
    fi

    echo
    log_info "Текущая версия: $VERSION"
    log_info "Новая версия:   $UPD_VER  (релиз $UPD_TAG)"
    log_info "Установка:      $UPD_BIN, $UPD_LIB_DIR/src"
    (( use_sudo )) && log_warn "Для установки потребуются права администратора (sudo) — только на шаге замены файлов."
    if (( ! assume_yes )); then
        if [[ ! -t 0 ]]; then
            log_err "Нет интерактивного терминала для подтверждения. Для автоматического обновления используйте: crypTar --update --yes"
            return "$UPD_E_FAIL"
        fi
        ui_confirm "Установить CrypTar $UPD_VER?" || { log_info "Отменено."; return 0; }
    fi

    _upd_need tar gzip || return "$UPD_E_FAIL"
    log_step "Загружаем релиз $UPD_TAG..."
    _upd_fetch_payload || return $?

    local tree
    tree="$(_upd_extract "$UPD_ARCHIVE")" || return "$UPD_E_FAIL"
    inst_check_tree "$tree" "$UPD_VER" >/dev/null || return "$UPD_E_FAIL"
    log_ok "Архив релиза проверен"

    log_step "Устанавливаем CrypTar $UPD_VER..."
    if (( use_sudo )); then
        # The script run as root is the INSTALLED (trusted) core, not the
        # downloaded one; it re-validates its own staged copy of the tree.
        # It is passed by content (bash -c) so no file inside src/ stays open
        # while src/ is being replaced.
        local core
        core="$(cat "$SRC_DIR/install/core.sh")" || return "$UPD_E_FAIL"
        sudo -- bash -c "$core" core.sh install-tree \
            "$tree" "$UPD_BIN_DIR" "$UPD_LIB_DIR" "$UPD_VER" || rc=$?
    else
        inst_install_tree "$tree" "$UPD_BIN_DIR" "$UPD_LIB_DIR" "$UPD_VER" || rc=$?
    fi
    if (( rc != 0 )); then
        log_err "Установка не выполнена — версия $VERSION оставлена без изменений."
        return "$UPD_E_FAIL"
    fi

    local out
    out="$("$UPD_BIN" --version 2>/dev/null </dev/null)" || true
    if [[ "$out" != "CrypTar v$UPD_VER" ]]; then
        log_err "Установленная программа сообщает неожиданную версию: '${out:0:80}'."
        return "$UPD_E_FAIL"
    fi
    log_ok "CrypTar обновлён: $VERSION → $UPD_VER"
    log_info "Конфигурация (~/.config/cryptar), GPG- и SSH-ключи не изменялись."
    log_info "Если новая версия требует новых зависимостей, они перечислены в описании релиза."
}

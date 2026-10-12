#!/usr/bin/env bash
[[ -n "${_YADISK_LOADED:-}" ]] && return 0
_YADISK_LOADED=1

# ══ Yandex Disk provider (REST API v1) ════════════════════════════════════════
# Auth:   Yandex ID device-code flow (oauth.yandex.ru/device/code → /token).
#         Rights are fixed when the app is registered; recommended:
#         cloud_api:disk.write, cloud_api:disk.read, cloud_api:disk.info
#         (or cloud_api:disk.app_folder only, with an app:/ destination).
# Folder: a Disk path (folder=/CrypTar, disk:/Backups, app:/CrypTar); Yandex
#         addresses resources by path — there are no folder IDs.
# Upload: GET /resources/upload (overwrite=false) → PUT the file to the
#         returned href (no OAuth header — the href is pre-authorized).
#         202 Accepted is followed up until the file appears on the Disk.
# Tokens: access_token (≈1 year), refresh_token and expires_at are kept in
#         the encrypted config; refreshed a day before expiry.
# ═════════════════════════════════════════════════════════════════════════════

YADISK_OAUTH_URL="https://oauth.yandex.ru"
YADISK_API="https://cloud-api.yandex.net/v1/disk"
_YADISK_FORM_CT="Content-Type: application/x-www-form-urlencoded"
_YADISK_REFRESH_MARGIN=86400
_YADISK_POLL_MAX=30

yadisk_default_folder() { echo "/CrypTar"; }

# Normalize to "<scheme>/a/b": scheme is "disk:", "app:" or "" (= disk root).
yadisk_normalize_folder() {
    local raw scheme="" seg out=""
    local -a segs=()
    raw="$(_cloud_trim "$1")"
    [[ -n "$raw" && "$raw" != *[[:cntrl:]]* ]] || return 1
    case "$raw" in
        disk:*) scheme="disk:"; raw="${raw#disk:}" ;;
        app:*)  scheme="app:";  raw="${raw#app:}" ;;
    esac
    IFS='/' read -r -a segs <<< "$raw"
    for seg in "${segs[@]}"; do
        seg="$(_cloud_trim "$seg")"
        [[ -n "$seg" ]] || continue
        [[ "$seg" == "." || "$seg" == ".." ]] && return 1
        out+="/$seg"
    done
    [[ -n "$out" ]] || return 1
    echo "$scheme$out"
}

# ── OAuth ─────────────────────────────────────────────────────────────────────

_yadisk_require_client() {
    local -n __yrc="$1"
    if [[ -z "${__yrc[client_id]:-}" || -z "${__yrc[client_secret]:-}" ]]; then
        log_err "Яндекс: не задан OAuth-клиент (ClientID / Client secret)."
        log_info "Зарегистрируйте приложение на https://oauth.yandex.ru — см. README, раздел «Яндекс Диск: настройка OAuth»."
        return $CLOUD_E_CONFIG
    fi
}

# Store tokens from the last successful /token response.
_yadisk_take_tokens() {
    local cref="$1" persist="$2"
    local -n __ytt="$1"
    local tok rt exp now
    tok="$(jq -r '.access_token // empty' <<< "$CLOUD_HTTP_BODY" 2>/dev/null)"
    rt="$(jq -r '.refresh_token // empty' <<< "$CLOUD_HTTP_BODY" 2>/dev/null)"
    exp="$(jq -r '.expires_in // 31536000 | tostring' <<< "$CLOUD_HTTP_BODY" 2>/dev/null)"
    CLOUD_HTTP_BODY=""
    if [[ -z "$tok" ]]; then
        log_err "Яндекс: в ответе нет access_token"
        return $CLOUD_E_API
    fi
    [[ "$exp" =~ ^[0-9]+$ ]] || exp=31536000
    now="$(date +%s)"
    [[ -n "$rt" ]] || rt="${__ytt[refresh_token]:-}"
    if [[ "$persist" == 1 ]]; then
        cloud_conn_update "$cref" access_token "$tok" refresh_token "$rt" expires_at "$(( now + exp ))" \
            || log_warn "Яндекс: не удалось сохранить обновлённый токен в конфиг"
    else
        __ytt[access_token]="$tok"
        __ytt[refresh_token]="$rt"
        __ytt[expires_at]="$(( now + exp ))"
    fi
    CLOUD_AUTH_SCHEME="OAuth"
    CLOUD_BEARER="$tok"
}

yadisk_auth() {
    local cref="$1"
    local -n __ya="$1"
    _yadisk_require_client "$cref" || return

    if [[ -z "${__ya[device_id]:-}" ]]; then
        __ya[device_id]="cryptar-$(od -An -tx1 -N8 /dev/urandom | tr -d ' \n')"
    fi
    local form host
    host="$(hostname 2>/dev/null || echo host)"
    form="$(cloud_form client_id "${__ya[client_id]}" device_id "${__ya[device_id]}" \
                       device_name "CrypTar (${host:0:80})")"
    _cloud_request POST "$YADISK_OAUTH_URL/device/code" -H "$_YADISK_FORM_CT" --body-var form \
        || { cloud_report_http_error "Яндекс: запрос кода устройства"; return; }

    local device_code user_code vurl expires interval
    {
        IFS= read -r device_code; IFS= read -r user_code; IFS= read -r vurl
        IFS= read -r expires;     IFS= read -r interval
    } < <(jq -r '(.device_code // ""), (.user_code // ""),
                 (.verification_url // "https://oauth.yandex.ru/device"),
                 (.expires_in // 300 | tostring), (.interval // 5 | tostring)' \
               <<< "$CLOUD_HTTP_BODY" 2>/dev/null)
    if [[ -z "$device_code" || -z "$user_code" ]]; then
        log_err "Яндекс: некорректный ответ на запрос кода устройства"
        return $CLOUD_E_API
    fi
    [[ "$interval" =~ ^[0-9]+$ && "$interval" -gt 0 ]] || interval=5
    [[ "$expires"  =~ ^[0-9]+$ ]] || expires=300

    echo "" >&2
    log_info "Откройте в браузере (на любом устройстве): $vurl" >&2
    log_info "и введите код: $user_code" >&2
    log_step "Ожидаем подтверждения доступа (до $(( expires / 60 )) мин)..." >&2

    local polls=$(( expires / interval + 1 )) err
    while (( polls > 0 )); do
        polls=$((polls - 1))
        _cloud_sleep "$interval"
        form="$(cloud_form grant_type device_code code "$device_code" \
                           client_id "${__ya[client_id]}" client_secret "${__ya[client_secret]}")"
        if _cloud_request POST "$YADISK_OAUTH_URL/token" -H "$_YADISK_FORM_CT" --body-var form; then
            _yadisk_take_tokens "$cref" 0 || return
            if [[ -z "${__ya[refresh_token]:-}" ]]; then
                log_warn "Яндекс: refresh_token не получен — по истечении токена потребуется reauth"
            fi
            log_ok "Яндекс: доступ предоставлен"
            return 0
        fi
        err="$(jq -r '.error // empty' <<< "$CLOUD_HTTP_BODY" 2>/dev/null)"
        case "$err" in
            authorization_pending) ;;
            slow_down)             interval=$((interval + 5)) ;;
            access_denied)         log_err "Яндекс: пользователь отклонил запрос доступа"; return $CLOUD_E_AUTH ;;
            invalid_grant|expired_token)
                                   log_err "Яндекс: код подтверждения недействителен или истёк — повторите"; return $CLOUD_E_AUTH ;;
            *)                     cloud_report_http_error "Яндекс: получение токена"; return ;;
        esac
    done
    log_err "Яндекс: время ожидания подтверждения истекло"
    return $CLOUD_E_AUTH
}

# Ensure CLOUD_BEARER holds a usable token; refresh shortly before expiry.
_yadisk_token() {
    local cref="$1"
    local -n __yt="$1"
    local now exp_at tok="${__yt[access_token]:-}"
    now="$(date +%s)"
    exp_at="${__yt[expires_at]:-0}"
    [[ "$exp_at" =~ ^[0-9]+$ ]] || exp_at=0

    CLOUD_AUTH_SCHEME="OAuth"
    if [[ -n "$tok" ]] && (( now + _YADISK_REFRESH_MARGIN < exp_at )); then
        CLOUD_BEARER="$tok"
        return 0
    fi
    if [[ -n "${__yt[refresh_token]:-}" ]] && _yadisk_require_client "$cref"; then
        local form
        form="$(cloud_form grant_type refresh_token refresh_token "${__yt[refresh_token]}" \
                           client_id "${__yt[client_id]}" client_secret "${__yt[client_secret]}")"
        if _cloud_request POST "$YADISK_OAUTH_URL/token" -H "$_YADISK_FORM_CT" --body-var form; then
            local persist=1
            [[ "${__yt[_unsaved]:-}" == 1 ]] && persist=0
            _yadisk_take_tokens "$cref" "$persist"
            return
        fi
        if [[ -n "$tok" ]] && (( now < exp_at )); then
            log_warn "Яндекс: не удалось обновить токен ($(cloud_error_text "$(cloud_http_error_code)")) — используем текущий"
            CLOUD_BEARER="$tok"
            return 0
        fi
        cloud_report_http_error "Яндекс: обновление токена"
        return
    fi
    if [[ -n "$tok" ]] && (( now < exp_at )); then
        CLOUD_BEARER="$tok"
        return 0
    fi
    log_err "Яндекс: токен подключения '${__yt[name]:-}' истёк"
    CLOUD_HTTP_CODE=401
    CLOUD_CURL_RC=0
    CLOUD_HTTP_BODY=""
    log_info "$(cloud_error_hint $CLOUD_E_AUTH)"
    return $CLOUD_E_AUTH
}

# ── Account / quota ───────────────────────────────────────────────────────────

yadisk_account() {
    local cref="$1"
    local -n __yac="$1"
    _yadisk_token "$cref" || return
    _cloud_request GET "$YADISK_API/?fields=user,total_space,used_space" --auth \
        || { cloud_report_http_error "Яндекс: данные Диска"; return; }
    __yac[account]="$(jq -r '.user.login // .user.display_name // empty' <<< "$CLOUD_HTTP_BODY" 2>/dev/null)"
}

# ── Folders ───────────────────────────────────────────────────────────────────

# Create each path component; an existing directory is fine.
yadisk_ensure_folder() {
    local cref="$1"
    local -n __yef="$1"
    _yadisk_token "$cref" || return

    local path scheme rest cur seg
    local -a segs=()
    path="$(yadisk_normalize_folder "${__yef[folder]:-$(yadisk_default_folder)}")" \
        || { log_err "Яндекс: некорректный путь папки назначения"; return $CLOUD_E_CONFIG; }
    scheme="${path%%/*}"
    rest="${path#"$scheme"}"
    cur="$scheme"
    IFS='/' read -r -a segs <<< "${rest#/}"
    for seg in "${segs[@]}"; do
        cur+="/$seg"
        if _cloud_request PUT "$YADISK_API/resources?path=$(cloud_urlencode "$cur")" --auth; then
            log_step "Яндекс: создана папка $cur"
            continue
        fi
        if [[ "$CLOUD_HTTP_CODE" == 409 && "$CLOUD_HTTP_BODY" == *DiskPathPointsToExistentDirectoryError* ]]; then
            continue
        fi
        if [[ "$CLOUD_HTTP_CODE" == 409 ]]; then
            log_err "Яндекс: '$cur' существует, но не является папкой (или родитель отсутствует)"
            return $CLOUD_E_CONFLICT
        fi
        cloud_report_http_error "Яндекс: создание папки $cur"
        return
    done
    if [[ "$path" != "${__yef[folder]:-}" ]]; then
        cloud_conn_update "$cref" folder "$path" \
            || log_warn "Яндекс: не удалось сохранить путь папки в конфиг"
    fi
    return 0
}

# Echo the remote file size, or nothing when absent/unknown.
_yadisk_remote_size() {
    local rpath="$1"
    _cloud_request GET "$YADISK_API/resources?path=$(cloud_urlencode "$rpath")&fields=size,type" --auth \
        || return 0
    jq -r 'select(.type == "file") | .size // empty | tostring' <<< "$CLOUD_HTTP_BODY" 2>/dev/null
}

# After 202 Accepted: wait until the file is stored (bounded).
_yadisk_wait_stored() {
    local rpath="$1" op_id="$2" size="$3" n status rs
    for (( n = 0; n < _YADISK_POLL_MAX; n++ )); do
        if [[ -n "$op_id" ]]; then
            if _cloud_request GET "$YADISK_API/operations/$(cloud_urlencode "$op_id")" --auth; then
                status="$(jq -r '.status // empty' <<< "$CLOUD_HTTP_BODY" 2>/dev/null)"
                case "$status" in
                    success) return 0 ;;
                    failed)  log_err "Яндекс: сервер сообщил об ошибке обработки файла"; return $CLOUD_E_API ;;
                esac
            fi
        else
            rs="$(_yadisk_remote_size "$rpath")"
            [[ "$rs" == "$size" ]] && return 0
        fi
        _cloud_sleep $(( n < 4 ? 1 << n : 10 ))
    done
    log_warn "Яндекс: файл принят сервером (202), но обработка ещё не завершена — проверьте позже"
    return 0
}

# ── Upload ────────────────────────────────────────────────────────────────────

yadisk_upload() {
    local cref="$1" file="$2" name="$3"
    local -n __yu="$1"
    _yadisk_token "$cref"        || return
    yadisk_ensure_folder "$cref" || return

    local dir size remote="$name" i=1 attempts=0 rpath href op_id rc code rs
    dir="$(yadisk_normalize_folder "${__yu[folder]}")" || return $CLOUD_E_CONFIG
    size="$(cloud_file_size "$file")" || { log_err "Не удалось определить размер $file"; return $CLOUD_E_GENERIC; }
    local CLOUD_PROGRESS=0
    [[ -t 2 ]] && CLOUD_PROGRESS=1

    while true; do
        rpath="$dir/$remote"
        # overwrite=false: Yandex answers 409 when the name is taken, which
        # drives the "-N" suffix policy without a race-prone listing.
        if ! _cloud_request GET "$YADISK_API/resources/upload?path=$(cloud_urlencode "$rpath")&overwrite=false" --auth; then
            if [[ "$CLOUD_HTTP_CODE" == 409 ]]; then
                if (( i > CLOUD_MAX_NAME_TRIES )); then
                    log_err "Яндекс: не удалось подобрать свободное имя для '$name'"
                    return $CLOUD_E_CONFLICT
                fi
                remote="$(cloud_unique_name "$name" "$i")"
                i=$((i + 1))
                continue
            fi
            cloud_report_http_error "Яндекс: получение ссылки для загрузки"
            return
        fi
        href="$(jq -r '.href // empty' <<< "$CLOUD_HTTP_BODY" 2>/dev/null)"
        op_id="$(jq -r '.operation_id // empty' <<< "$CLOUD_HTTP_BODY" 2>/dev/null)"
        if [[ -z "$href" ]]; then
            log_err "Яндекс: в ответе нет ссылки для загрузки"
            return $CLOUD_E_API
        fi
        [[ "$remote" != "$name" ]] && log_warn "Яндекс: '$name' уже существует — загружаем как '$remote'"

        rc=0
        _cloud_request PUT "$href" --long --upload "$file" || rc=$?
        if (( rc == 0 )); then
            if [[ "$CLOUD_HTTP_CODE" == 202 ]]; then
                _yadisk_wait_stored "$rpath" "$op_id" "$size" || return
            fi
            CLOUD_UPLOADED_NAME="$remote"
            return 0
        fi

        code="$(cloud_http_error_code)"
        if ! _cloud_is_transient "$code" || (( attempts >= CLOUD_MAX_RETRIES )); then
            cloud_report_http_error "Яндекс: загрузка '$remote'"
            return
        fi
        attempts=$((attempts + 1))
        log_warn "Яндекс: загрузка прервана ($(cloud_error_text "$code")) — повтор $attempts/$CLOUD_MAX_RETRIES"
        _cloud_sleep "$(_cloud_backoff_delay "$((attempts - 1))")"
        # The PUT may have completed despite the error — check before
        # uploading again. A fresh link is requested for the next attempt.
        rs="$(_yadisk_remote_size "$rpath")"
        if [[ "$rs" == "$size" ]]; then
            CLOUD_UPLOADED_NAME="$remote"
            return 0
        fi
    done
}

# ── Connection test ───────────────────────────────────────────────────────────

yadisk_test() {
    local cref="$1"
    local -n __yts="$1"
    _yadisk_token "$cref" || return
    if ! _cloud_request GET "$YADISK_API/?fields=user,total_space,used_space" --auth; then
        if [[ "$(cloud_http_error_code)" == "$CLOUD_E_PERM" ]]; then
            # Token without cloud_api:disk.info (e.g. app-folder-only apps).
            log_warn "Яндекс: нет права cloud_api:disk.info — квота не проверяется"
            yadisk_ensure_folder "$cref" || return
            log_ok "Авторизация: OK"
            log_ok "Папка назначения доступна: ${__yts[folder]:-}"
            return 0
        fi
        cloud_report_http_error "Яндекс: данные Диска"
        return
    fi
    log_ok "Авторизация: OK"
    local login total used
    login="$(jq -r '.user.login // "-"' <<< "$CLOUD_HTTP_BODY")"
    total="$(jq -r '.total_space // empty | tostring' <<< "$CLOUD_HTTP_BODY")"
    used="$(jq -r '.used_space // empty | tostring' <<< "$CLOUD_HTTP_BODY")"
    log_info "Аккаунт: $login"
    if [[ "$total" =~ ^[0-9]+$ && "$used" =~ ^[0-9]+$ ]]; then
        log_info "Свободно: $(cloud_human_size $(( total - used ))) из $(cloud_human_size "$total")"
        (( total - used <= 0 )) && log_warn "Диск заполнен — загрузка будет невозможна"
    fi
    yadisk_ensure_folder "$cref" || return
    log_ok "Папка назначения доступна: ${__yts[folder]:-}"
}

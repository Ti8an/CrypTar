#!/usr/bin/env bash
[[ -n "${_GDRIVE_LOADED:-}" ]] && return 0
_GDRIVE_LOADED=1

# ══ Google Drive provider (Drive API v3) ══════════════════════════════════════
# Auth:   OAuth 2.0 device authorization grant ("TVs and Limited Input
#         devices" client). No local HTTP listener is needed, so it also works
#         over SSH on headless backup hosts. Google allows the drive.file scope
#         for this flow — the minimal scope: CrypTar sees only files and
#         folders it created itself.
# Folder: stored as a human path (folder=CrypTar or Backups/CrypTar) plus the
#         resolved Drive folder ID (folder_id=...). Drive identifies folders
#         by ID, not path; the ID is re-resolved when it disappears.
# Upload: resumable upload session; interrupted transfers are resumed from
#         the offset the server reports.
# Tokens: only refresh_token is persisted; access tokens (1 h) live in memory.
# ═════════════════════════════════════════════════════════════════════════════

GDRIVE_SCOPE="https://www.googleapis.com/auth/drive.file"
GDRIVE_DEVICE_URL="https://oauth2.googleapis.com/device/code"
GDRIVE_TOKEN_URL="https://oauth2.googleapis.com/token"
GDRIVE_API="https://www.googleapis.com/drive/v3"
GDRIVE_UPLOAD_API="https://www.googleapis.com/upload/drive/v3"
GDRIVE_FOLDER_MIME="application/vnd.google-apps.folder"
_GDRIVE_FORM_CT="Content-Type: application/x-www-form-urlencoded"
_GDRIVE_JSON_CT="Content-Type: application/json; charset=UTF-8"

gdrive_default_folder() { echo "CrypTar"; }

# Normalize "a / b/" → "a/b". Rejects empty paths and control characters.
gdrive_normalize_folder() {
    local raw="$1" seg out=""
    local -a segs=()
    [[ "$raw" != *[[:cntrl:]]* ]] || return 1
    IFS='/' read -r -a segs <<< "$raw"
    for seg in "${segs[@]}"; do
        seg="$(_cloud_trim "$seg")"
        [[ -n "$seg" ]] || continue
        out+="${out:+/}$seg"
    done
    [[ -n "$out" ]] || return 1
    echo "$out"
}

_gdrive_q_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\'/\\\'}"
    printf '%s' "$s"
}

# ── OAuth ─────────────────────────────────────────────────────────────────────

_gdrive_require_client() {
    local -n __grc="$1"
    if [[ -z "${__grc[client_id]:-}" || -z "${__grc[client_secret]:-}" ]]; then
        log_err "Google: не задан OAuth-клиент (client_id / client_secret)."
        log_info "Создайте OAuth-клиент типа «TVs and Limited Input devices» — см. README, раздел «Google Drive: настройка OAuth»."
        return $CLOUD_E_CONFIG
    fi
}

gdrive_auth() {
    local cref="$1"
    local -n __ga="$1"
    _gdrive_require_client "$cref" || return

    local form
    form="$(cloud_form client_id "${__ga[client_id]}" scope "$GDRIVE_SCOPE")"
    _cloud_request POST "$GDRIVE_DEVICE_URL" -H "$_GDRIVE_FORM_CT" --body-var form \
        || { cloud_report_http_error "Google: запрос кода устройства"; return; }

    local device_code user_code vurl expires interval
    {
        IFS= read -r device_code; IFS= read -r user_code; IFS= read -r vurl
        IFS= read -r expires;     IFS= read -r interval
    } < <(jq -r '(.device_code // ""), (.user_code // ""),
                 (.verification_url // .verification_uri // ""),
                 (.expires_in // 1800 | tostring), (.interval // 5 | tostring)' \
               <<< "$CLOUD_HTTP_BODY" 2>/dev/null)
    if [[ -z "$device_code" || -z "$user_code" ]]; then
        log_err "Google: некорректный ответ на запрос кода устройства"
        return $CLOUD_E_API
    fi
    [[ "$interval" =~ ^[0-9]+$ && "$interval" -gt 0 ]] || interval=5
    [[ "$expires"  =~ ^[0-9]+$ ]] || expires=1800

    echo "" >&2
    log_info "Откройте в браузере (на любом устройстве): $vurl" >&2
    log_info "и введите код: $user_code" >&2
    log_step "Ожидаем подтверждения доступа (до $(( expires / 60 )) мин)..." >&2

    local polls=$(( expires / interval + 1 )) err tok rt
    while (( polls > 0 )); do
        polls=$((polls - 1))
        _cloud_sleep "$interval"
        form="$(cloud_form client_id "${__ga[client_id]}" client_secret "${__ga[client_secret]}" \
                           device_code "$device_code" \
                           grant_type "urn:ietf:params:oauth:grant-type:device_code")"
        if _cloud_request POST "$GDRIVE_TOKEN_URL" -H "$_GDRIVE_FORM_CT" --body-var form; then
            tok="$(jq -r '.access_token // empty' <<< "$CLOUD_HTTP_BODY" 2>/dev/null)"
            rt="$(jq -r '.refresh_token // empty' <<< "$CLOUD_HTTP_BODY" 2>/dev/null)"
            CLOUD_HTTP_BODY=""
            if [[ -z "$tok" || -z "$rt" ]]; then
                log_err "Google: в ответе нет access_token/refresh_token"
                return $CLOUD_E_API
            fi
            __ga[refresh_token]="$rt"
            __ga[_access_token]="$tok"
            __ga[_access_exp]=$(( SECONDS + 3000 ))
            log_ok "Google: доступ предоставлен"
            return 0
        fi
        err="$(jq -r '.error // empty' <<< "$CLOUD_HTTP_BODY" 2>/dev/null)"
        case "$err" in
            authorization_pending) ;;
            slow_down)             interval=$((interval + 5)) ;;
            access_denied)         log_err "Google: пользователь отклонил запрос доступа"; return $CLOUD_E_AUTH ;;
            expired_token)         log_err "Google: срок действия кода истёк — повторите"; return $CLOUD_E_AUTH ;;
            *)                     cloud_report_http_error "Google: получение токена"; return ;;
        esac
    done
    log_err "Google: время ожидания подтверждения истекло"
    return $CLOUD_E_AUTH
}

# Ensure CLOUD_BEARER holds a valid access token for the connection.
_gdrive_token() {
    local cref="$1"
    local -n __gt="$1"
    CLOUD_AUTH_SCHEME="Bearer"
    if [[ -n "${__gt[_access_token]:-}" ]] && (( SECONDS < ${__gt[_access_exp]:-0} )); then
        CLOUD_BEARER="${__gt[_access_token]}"
        return 0
    fi
    _gdrive_require_client "$cref" || return
    if [[ -z "${__gt[refresh_token]:-}" ]]; then
        log_err "Google: подключение '${__gt[name]:-}' не авторизовано"
        return $CLOUD_E_AUTH
    fi

    local form tok exp rt
    form="$(cloud_form client_id "${__gt[client_id]}" client_secret "${__gt[client_secret]}" \
                       refresh_token "${__gt[refresh_token]}" grant_type refresh_token)"
    _cloud_request POST "$GDRIVE_TOKEN_URL" -H "$_GDRIVE_FORM_CT" --body-var form \
        || { cloud_report_http_error "Google: обновление токена доступа"; return; }
    tok="$(jq -r '.access_token // empty' <<< "$CLOUD_HTTP_BODY" 2>/dev/null)"
    exp="$(jq -r '.expires_in // 3600 | tostring' <<< "$CLOUD_HTTP_BODY" 2>/dev/null)"
    rt="$(jq -r '.refresh_token // empty' <<< "$CLOUD_HTTP_BODY" 2>/dev/null)"
    CLOUD_HTTP_BODY=""
    if [[ -z "$tok" ]]; then
        log_err "Google: в ответе нет access_token"
        return $CLOUD_E_API
    fi
    [[ "$exp" =~ ^[0-9]+$ ]] || exp=3600
    __gt[_access_token]="$tok"
    __gt[_access_exp]=$(( SECONDS + exp - 60 ))
    CLOUD_BEARER="$tok"
    # Google rarely rotates refresh tokens; persist one if it does.
    if [[ -n "$rt" && "$rt" != "${__gt[refresh_token]}" ]]; then
        cloud_conn_update "$cref" refresh_token "$rt" \
            || log_warn "Google: не удалось сохранить обновлённый refresh_token"
    fi
    return 0
}

# ── Account / quota ───────────────────────────────────────────────────────────

# Sets conn[account] (e-mail); echoes nothing.
gdrive_account() {
    local cref="$1"
    local -n __gacc="$1"
    _gdrive_token "$cref" || return
    _cloud_request GET "$GDRIVE_API/about?fields=user(emailAddress,displayName)" --auth \
        || { cloud_report_http_error "Google: данные аккаунта"; return; }
    __gacc[account]="$(jq -r '.user.emailAddress // .user.displayName // empty' <<< "$CLOUD_HTTP_BODY" 2>/dev/null)"
}

# ── Folders ───────────────────────────────────────────────────────────────────

# _gdrive_find_child <parent_id> <name> [mime] — echo the first matching
# file ID (walks every result page); empty output = not found.
_gdrive_find_child() {
    local parent="$1" name="$2" mime="${3:-}" q page="" url id
    q="name = '$(_gdrive_q_escape "$name")' and '$(_gdrive_q_escape "$parent")' in parents and trashed = false"
    [[ -n "$mime" ]] && q+=" and mimeType = '$mime'"
    while true; do
        url="$GDRIVE_API/files?q=$(cloud_urlencode "$q")&fields=$(cloud_urlencode 'nextPageToken,files(id,name)')&pageSize=100&spaces=drive"
        [[ -n "$page" ]] && url+="&pageToken=$(cloud_urlencode "$page")"
        _cloud_request GET "$url" --auth \
            || { cloud_report_http_error "Google: поиск '$name'"; return; }
        id="$(jq -r --arg n "$name" '[.files[]? | select(.name == $n) | .id][0] // empty' <<< "$CLOUD_HTTP_BODY")"
        if [[ -n "$id" ]]; then echo "$id"; return 0; fi
        page="$(jq -r '.nextPageToken // empty' <<< "$CLOUD_HTTP_BODY")"
        [[ -n "$page" ]] || return 0
    done
}

# Folder creation is not idempotent: a retried POST could create duplicates.
# After a transient failure, look for the folder before trying once more.
_gdrive_create_folder() {
    local parent="$1" name="$2" body id
    body="$(jq -cn --arg n "$name" --arg p "$parent" --arg m "$GDRIVE_FOLDER_MIME" \
                '{name: $n, mimeType: $m, parents: [$p]}')"
    local try
    for try in 1 2; do
        if _cloud_request POST "$GDRIVE_API/files?fields=id" --auth -H "$_GDRIVE_JSON_CT" \
                --body-var body --no-retry; then
            id="$(jq -r '.id // empty' <<< "$CLOUD_HTTP_BODY")"
            [[ -n "$id" ]] && { echo "$id"; return 0; }
            log_err "Google: в ответе на создание папки нет id"
            return $CLOUD_E_API
        fi
        local code
        code="$(cloud_http_error_code)"
        if [[ "$try" == 1 ]] && _cloud_is_transient "$code"; then
            _cloud_sleep "$(_cloud_backoff_delay 0)"
            id="$(_gdrive_find_child "$parent" "$name" "$GDRIVE_FOLDER_MIME")" || return
            [[ -n "$id" ]] && { echo "$id"; return 0; }
            continue
        fi
        break
    done
    cloud_report_http_error "Google: создание папки '$name'"
}

# Resolve (and create when missing) the destination folder; keeps
# conn[folder_id] current and persists it when it changes.
gdrive_ensure_folder() {
    local cref="$1"
    local -n __gef="$1"
    _gdrive_token "$cref" || return

    local fid="${__gef[folder_id]:-}"
    if [[ -n "$fid" ]]; then
        if _cloud_request GET "$GDRIVE_API/files/$(cloud_urlencode "$fid")?fields=id,mimeType,trashed" --auth; then
            if jq -e --arg m "$GDRIVE_FOLDER_MIME" '.trashed != true and .mimeType == $m' \
                    <<< "$CLOUD_HTTP_BODY" >/dev/null 2>&1; then
                return 0
            fi
            log_warn "Google: папка назначения в корзине — будет найдена или создана заново"
        elif [[ "$CLOUD_HTTP_CODE" == 404 ]]; then
            log_warn "Google: папка назначения не найдена (удалена?) — будет найдена или создана заново"
        else
            cloud_report_http_error "Google: проверка папки назначения"
            return
        fi
    fi

    local path parent="root" seg id
    local -a segs=()
    path="$(gdrive_normalize_folder "${__gef[folder]:-$(gdrive_default_folder)}")" \
        || { log_err "Google: некорректный путь папки назначения"; return $CLOUD_E_CONFIG; }
    IFS='/' read -r -a segs <<< "$path"
    for seg in "${segs[@]}"; do
        id="$(_gdrive_find_child "$parent" "$seg" "$GDRIVE_FOLDER_MIME")" || return
        if [[ -z "$id" ]]; then
            log_step "Google: создаём папку '$seg'"
            id="$(_gdrive_create_folder "$parent" "$seg")" || return
        fi
        parent="$id"
    done
    cloud_conn_update "$cref" folder "$path" folder_id "$parent" \
        || log_warn "Google: не удалось сохранить folder_id в конфиг"
    return 0
}

# Echo every file name in a folder (all pages).
_gdrive_list_names() {
    local fid="$1" q page="" url
    q="'$(_gdrive_q_escape "$fid")' in parents and trashed = false"
    while true; do
        url="$GDRIVE_API/files?q=$(cloud_urlencode "$q")&fields=$(cloud_urlencode 'nextPageToken,files(name)')&pageSize=1000&spaces=drive"
        [[ -n "$page" ]] && url+="&pageToken=$(cloud_urlencode "$page")"
        _cloud_request GET "$url" --auth \
            || { cloud_report_http_error "Google: список файлов папки"; return; }
        jq -r '.files[]?.name' <<< "$CLOUD_HTTP_BODY"
        page="$(jq -r '.nextPageToken // empty' <<< "$CLOUD_HTTP_BODY")"
        [[ -n "$page" ]] || return 0
    done
}

# ── Upload ────────────────────────────────────────────────────────────────────

# Start a resumable session; echo the session URI.
_gdrive_start_session() {
    local fid="$1" name="$2" size="$3" body loc
    body="$(jq -cn --arg n "$name" --arg p "$fid" '{name: $n, parents: [$p]}')"
    _cloud_request POST "$GDRIVE_UPLOAD_API/files?uploadType=resumable&fields=id,name,size" --auth \
        -H "$_GDRIVE_JSON_CT" \
        -H "X-Upload-Content-Type: application/octet-stream" \
        -H "X-Upload-Content-Length: $size" \
        --body-var body \
        || { cloud_report_http_error "Google: создание сессии загрузки"; return; }
    loc="$(cloud_http_header Location)"
    if [[ -z "$loc" ]]; then
        log_err "Google: сервер не вернул адрес сессии загрузки"
        return $CLOUD_E_API
    fi
    echo "$loc"
}

# Ask the session how many bytes it has. Sets _GD_OFFSET; returns
# 0 = incomplete (resume from _GD_OFFSET), 2 = already complete,
# CLOUD_E_NOTFOUND = session expired, other = error.
_gdrive_session_status() {
    local session="$1" size="$2" range
    _GD_OFFSET=0
    _cloud_request PUT "$session" -H "Content-Range: bytes */$size" -H "Content-Length: 0" \
        || return "$(cloud_http_error_code)"
    case "$CLOUD_HTTP_CODE" in
        200|201) return 2 ;;
        308)
            range="$(cloud_http_header Range)"
            if [[ "$range" =~ ^bytes=0-([0-9]+)$ ]]; then
                _GD_OFFSET=$(( BASH_REMATCH[1] + 1 ))
            fi
            return 0 ;;
    esac
    return $CLOUD_E_API
}

gdrive_upload() {
    local cref="$1" file="$2" name="$3"
    local -n __gu="$1"
    _gdrive_token "$cref"        || return
    gdrive_ensure_folder "$cref" || return
    local fid="${__gu[folder_id]}"

    # Filename-conflict policy: never overwrite; pick "<base>-N<ext>".
    local names remote="$name" i=1 nm
    names="$(_gdrive_list_names "$fid")" || return
    local -A taken=()
    while IFS= read -r nm; do
        [[ -n "$nm" ]] && taken["$nm"]=1
    done <<< "$names"
    while [[ -n "${taken[$remote]:-}" ]]; do
        if (( i > CLOUD_MAX_NAME_TRIES )); then
            log_err "Google: не удалось подобрать свободное имя для '$name'"
            return $CLOUD_E_CONFLICT
        fi
        remote="$(cloud_unique_name "$name" "$i")"
        i=$((i + 1))
    done
    [[ "$remote" != "$name" ]] && log_warn "Google: '$name' уже существует — загружаем как '$remote'"

    local size session
    size="$(cloud_file_size "$file")" || { log_err "Не удалось определить размер $file"; return $CLOUD_E_GENERIC; }
    session="$(_gdrive_start_session "$fid" "$remote" "$size")" || return

    local offset=0 attempts=0 restarts=0 rc st code
    local CLOUD_PROGRESS=0
    [[ -t 2 ]] && CLOUD_PROGRESS=1
    while true; do
        rc=0
        if (( offset == 0 )); then
            _cloud_request PUT "$session" --long --upload "$file" || rc=$?
        else
            # Stream the tail of the file (no temp copy). The empty
            # Transfer-Encoding header stops curl from chunking stdin, so the
            # explicit Content-Length is the only length Google sees.
            _cloud_request PUT "$session" --long --upload - \
                -H "Content-Range: bytes $offset-$(( size - 1 ))/$size" \
                -H "Content-Length: $(( size - offset ))" \
                -H "Transfer-Encoding:" \
                < <(tail -c +"$(( offset + 1 ))" -- "$file") || rc=$?
        fi
        if (( rc == 0 )) && [[ "$CLOUD_HTTP_CODE" == 200 || "$CLOUD_HTTP_CODE" == 201 ]]; then
            CLOUD_UPLOADED_NAME="$remote"
            return 0
        fi

        if (( rc == 0 )); then
            code=$CLOUD_E_NET            # 308 after a full PUT: upload cut short
        else
            code="$(cloud_http_error_code)"
        fi
        if [[ "$CLOUD_HTTP_CODE" == 404 || "$CLOUD_HTTP_CODE" == 410 ]]; then
            code=$CLOUD_E_NOTFOUND
        elif ! _cloud_is_transient "$code"; then
            cloud_report_http_error "Google: загрузка '$remote'"
            return
        fi

        attempts=$((attempts + 1))
        if (( attempts > CLOUD_MAX_RETRIES )); then
            cloud_report_http_error "Google: загрузка '$remote' (попытки исчерпаны)"
            return
        fi
        _cloud_sleep "$(_cloud_backoff_delay "$((attempts - 1))")"

        st=0
        if [[ "$code" != "$CLOUD_E_NOTFOUND" ]]; then
            _gdrive_session_status "$session" "$size" || st=$?
        else
            st=$CLOUD_E_NOTFOUND
        fi
        case "$st" in
            0)  offset=$_GD_OFFSET
                log_info "Google: возобновляем загрузку с байта $offset из $size" ;;
            2)  CLOUD_UPLOADED_NAME="$remote"
                return 0 ;;
            "$CLOUD_E_NOTFOUND")
                if (( restarts >= 1 )); then
                    log_err "Google: сессия загрузки повторно утеряна"
                    return $CLOUD_E_API
                fi
                restarts=$((restarts + 1))
                log_warn "Google: сессия загрузки истекла — начинаем заново"
                session="$(_gdrive_start_session "$fid" "$remote" "$size")" || return
                offset=0 ;;
            *)  cloud_report_http_error "Google: проверка состояния загрузки"
                return ;;
        esac
    done
}

# ── Connection test ───────────────────────────────────────────────────────────

gdrive_test() {
    local cref="$1"
    local -n __gts="$1"
    _gdrive_token "$cref" || return
    log_ok "Авторизация: OK"
    _cloud_request GET "$GDRIVE_API/about?fields=user(emailAddress),storageQuota(limit,usage)" --auth \
        || { cloud_report_http_error "Google: данные аккаунта"; return; }
    local email limit usage
    email="$(jq -r '.user.emailAddress // "-"' <<< "$CLOUD_HTTP_BODY")"
    limit="$(jq -r '.storageQuota.limit // empty' <<< "$CLOUD_HTTP_BODY")"
    usage="$(jq -r '.storageQuota.usage // empty' <<< "$CLOUD_HTTP_BODY")"
    log_info "Аккаунт: $email"
    if [[ "$limit" =~ ^[0-9]+$ && "$usage" =~ ^[0-9]+$ ]]; then
        log_info "Свободно: $(cloud_human_size $(( limit - usage ))) из $(cloud_human_size "$limit")"
        (( limit - usage <= 0 )) && log_warn "Хранилище заполнено — загрузка будет невозможна"
    fi
    gdrive_ensure_folder "$cref" || return
    log_ok "Папка назначения доступна: ${__gts[folder]:-} (id ${__gts[folder_id]:-?})"
}

#!/usr/bin/env bats
# tests/test_cloud_providers.sh — Google Drive / Yandex Disk providers against
# mocked HTTP responses. No real accounts, tokens or uploads are involved.
#
# Requires: bats-core, gpg, jq; flock for the tests that persist config.
# Run: bats tests/test_cloud_providers.sh

load cloud_helper

setup_file()    { cloud_setup_keyring; }
teardown_file() { cloud_teardown_keyring; }

setup() {
    cloud_setup_env
    require_jq
    source "$REPO_DIR/src/providers/cloud/google_drive.sh"
    source "$REPO_DIR/src/providers/cloud/yandex_disk.sh"
    printf '%0300d' 0 > "$HOME/a.tar.gz.gpg"     # 300-byte fixture
}
teardown() { cloud_teardown_env; }

# In-memory connections (not persisted unless a test saves them).
_gd_conn() {
    declare -gA GD=(
        [name]=google-work [provider]=gdrive [folder]=CrypTar [folder_id]=FID
        [client_id]=CID [client_secret]=CSECRET [refresh_token]=RTSECRET [_unsaved]=1
    )
}
_ya_conn() {
    declare -gA YA=(
        [name]=yandex-backup [provider]=yadisk [folder]=/CrypTar
        [client_id]=YCID [client_secret]=YCSECRET [refresh_token]=YRT
        [access_token]=YATOKEN [expires_at]=$(( $(date +%s) + 30 * 86400 )) [_unsaved]=1
    )
}

# ══ Google Drive ══════════════════════════════════════════════════════════════

_gd_token_ok() {   # common route fragment: token endpoint
    [[ "$2" == "$GDRIVE_TOKEN_URL" ]] && { MOCK_BODY='{"access_token":"ya29.ACCESS","expires_in":3599}'; return 0; }
    return 1
}

@test "gdrive: refresh token is exchanged via the config fd, never argv" {
    _gd_conn
    mock_route() { _gd_token_ok "$@" || MOCK_BODY='{}'; }
    _gdrive_token GD
    [ "$CLOUD_BEARER" = "ya29.ACCESS" ]
    [ "${GD[_access_token]}" = "ya29.ACCESS" ]
    refute_grep "RTSECRET\|CSECRET" "$MOCK_DIR/argv"
    grep -q "refresh_token=RTSECRET" "$MOCK_DIR/cfg.1"
    # A second call within the token lifetime makes no request.
    _gdrive_token GD
    [ "$(mock_total_requests)" -eq 1 ]
}

@test "gdrive: revoked refresh token is reported as an auth error" {
    _gd_conn
    mock_route() { MOCK_CODE=400; MOCK_BODY='{"error":"invalid_grant","error_description":"Token has been expired or revoked."}'; }
    run _gdrive_token GD
    [ "$status" -eq "$CLOUD_E_AUTH" ]
    [[ "$output" == *"reauth"* ]]
    [ "$(mock_total_requests)" -eq 1 ]
}

@test "gdrive: missing OAuth client is a setup error and makes no request" {
    _gd_conn
    GD[client_secret]=""
    GD[_access_token]=""
    run _gdrive_token GD
    [ "$status" -eq "$CLOUD_E_CONFIG" ]
    [ "$(mock_total_requests)" -eq 0 ]
}

@test "gdrive: device flow handles pending and slow_down, then stores refresh token" {
    _gd_conn
    GD[refresh_token]=""
    mock_route() {
        case "$2" in
            "$GDRIVE_DEVICE_URL")
                MOCK_BODY='{"device_code":"DEVCODE","user_code":"ABCD-EFGH","verification_url":"https://www.google.com/device","expires_in":1800,"interval":5}' ;;
            "$GDRIVE_TOKEN_URL")
                case "$(mock_count tok)" in
                    1) MOCK_CODE=428; MOCK_BODY='{"error":"authorization_pending"}' ;;
                    2) MOCK_CODE=403; MOCK_BODY='{"error":"slow_down"}' ;;
                    *) MOCK_BODY='{"access_token":"ya29.NEW","refresh_token":"1//NEWRT","expires_in":3599}' ;;
                esac ;;
        esac
    }
    run gdrive_auth GD
    [ "$status" -eq 0 ]
    [[ "$output" == *"ABCD-EFGH"* ]]
    [[ "$output" != *DEVCODE* && "$output" != *NEWRT* ]]
    [ "$(tr '\n' ' ' < "$MOCK_DIR/sleeps")" = "5 5 10 " ]
    gdrive_auth GD 2>/dev/null >/dev/null
    [ "${GD[refresh_token]}" = "1//NEWRT" ]
    grep -q "device_code=DEVCODE" "$MOCK_DIR/cfg.3"
    grep -q "grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Adevice_code" "$MOCK_DIR/cfg.3"
}

@test "gdrive: user denial ends the device flow with an auth error" {
    _gd_conn
    mock_route() {
        case "$2" in
            "$GDRIVE_DEVICE_URL") MOCK_BODY='{"device_code":"D","user_code":"U","verification_url":"https://www.google.com/device","expires_in":60,"interval":5}' ;;
            *) MOCK_CODE=403; MOCK_BODY='{"error":"access_denied"}' ;;
        esac
    }
    run gdrive_auth GD
    [ "$status" -eq "$CLOUD_E_AUTH" ]
}

@test "gdrive: existing folder_id is verified without searching or creating" {
    _gd_conn
    mock_route() {
        _gd_token_ok "$@" && return
        case "$1 $2" in
            "GET $GDRIVE_API/files/FID?"*) MOCK_BODY='{"id":"FID","mimeType":"application/vnd.google-apps.folder","trashed":false}' ;;
            *) MOCK_CODE=500 ;;
        esac
    }
    gdrive_ensure_folder GD
    [ "${GD[folder_id]}" = "FID" ]
    [ "$(mock_requests_matching "POST $GDRIVE_API/files*")" -eq 0 ]
    [ "$(mock_requests_matching "GET $GDRIVE_API/files?q=*")" -eq 0 ]
}

@test "gdrive: deleted folder is re-resolved across result pages" {
    _gd_conn
    mock_route() {
        _gd_token_ok "$@" && return
        case "$1 $2" in
            "GET $GDRIVE_API/files/FID?"*) MOCK_CODE=404; MOCK_BODY='{"error":{"code":404,"message":"File not found"}}' ;;
            "GET $GDRIVE_API/files?q="*pageToken=P2*) MOCK_BODY='{"files":[{"id":"NEWFID","name":"CrypTar"}]}' ;;
            "GET $GDRIVE_API/files?q="*) MOCK_BODY='{"nextPageToken":"P2","files":[{"id":"X","name":"Other"}]}' ;;
            *) MOCK_CODE=500 ;;
        esac
    }
    gdrive_ensure_folder GD 2>/dev/null
    [ "${GD[folder_id]}" = "NEWFID" ]
    [ "$(mock_requests_matching "POST *")" -eq 1 ]   # only the token request
}

@test "gdrive: missing folder path is created segment by segment" {
    _gd_conn
    GD[folder]="Backups/CrypTar"; GD[folder_id]=""
    mock_route() {
        _gd_token_ok "$@" && return
        case "$1 $2" in
            "GET $GDRIVE_API/files?q="*) MOCK_BODY='{"files":[]}' ;;
            "POST $GDRIVE_API/files?fields=id")
                if [[ "$3" == *'\"name\":\"Backups\"'* ]]; then MOCK_BODY='{"id":"ID_B"}'; else MOCK_BODY='{"id":"ID_C"}'; fi ;;
            *) MOCK_CODE=500 ;;
        esac
    }
    gdrive_ensure_folder GD 2>/dev/null >/dev/null
    [ "${GD[folder_id]}" = "ID_C" ]
    [ "$(mock_requests_matching "POST $GDRIVE_API/files?fields=id")" -eq 2 ]
    grep -q '\\"parents\\":\[\\"ID_B\\"\]' "$MOCK_DIR"/cfg.*
}

@test "gdrive: folder creation is not blindly repeated after a transient error" {
    _gd_conn
    GD[folder_id]=""
    mock_route() {
        _gd_token_ok "$@" && return
        case "$1 $2" in
            "POST $GDRIVE_API/files?fields=id") MOCK_CODE=503 ;;
            "GET $GDRIVE_API/files?q="*)
                # second search (after the failed create) finds the folder
                if [[ "$(mock_count search)" -ge 2 ]]; then MOCK_BODY='{"files":[{"id":"CREATED","name":"CrypTar"}]}'
                else MOCK_BODY='{"files":[]}'; fi ;;
        esac
    }
    gdrive_ensure_folder GD 2>/dev/null >/dev/null
    [ "${GD[folder_id]}" = "CREATED" ]
    [ "$(mock_requests_matching "POST $GDRIVE_API/files?fields=id")" -eq 1 ]
}

# Route for a complete upload; tests override pieces through variables.
_gd_upload_route() {
    _gd_token_ok "$@" && return
    case "$1 $2" in
        "GET $GDRIVE_API/files/FID?"*) MOCK_BODY='{"id":"FID","mimeType":"application/vnd.google-apps.folder","trashed":false}' ;;
        "GET $GDRIVE_API/files?q="*) MOCK_BODY="${GD_EXISTING:-}"; [[ -n "$MOCK_BODY" ]] || MOCK_BODY='{"files":[]}' ;;
        "POST $GDRIVE_UPLOAD_API/files?uploadType=resumable"*)
            MOCK_HEADERS="Location: https://upload.example/session-$(mock_count session)" ;;
        "PUT https://upload.example/session-"*) gd_put_route "$@" ;;
        *) MOCK_CODE=599 ;;
    esac
}

@test "gdrive: upload uses a resumable session and never overwrites (unique name)" {
    _gd_conn
    GD_EXISTING='{"files":[{"name":"a.tar.gz.gpg"},{"name":"a-1.tar.gz.gpg"}]}'
    gd_put_route() { MOCK_BODY='{"id":"NEWFILE","name":"a-2.tar.gz.gpg","size":"300"}'; }
    mock_route() { _gd_upload_route "$@"; }
    gdrive_upload GD "$HOME/a.tar.gz.gpg" a.tar.gz.gpg 2>/dev/null
    [ "$CLOUD_UPLOADED_NAME" = "a-2.tar.gz.gpg" ]
    grep -q 'X-Upload-Content-Length: 300' "$MOCK_DIR"/cfg.*
    grep -q '\\"name\\":\\"a-2.tar.gz.gpg\\"' "$MOCK_DIR"/cfg.*
    grep -q -- "-T $HOME/a.tar.gz.gpg" "$MOCK_DIR/argv"
    refute_grep "session-" "$MOCK_DIR/argv"   # session URI stays out of argv
}

@test "gdrive: interrupted upload resumes from the server-reported offset" {
    _gd_conn
    gd_put_route() {
        if [[ "$3" == *"Content-Range: bytes */300"* ]]; then
            MOCK_CODE=308; MOCK_HEADERS='Range: bytes=0-99'
        elif [[ "$3" == *"Content-Range: bytes 100-299/300"* ]]; then
            MOCK_BODY='{"id":"F","name":"a.tar.gz.gpg","size":"300"}'
        else
            MOCK_CODE=000; MOCK_RC=56          # connection reset mid-upload
        fi
    }
    mock_route() { _gd_upload_route "$@"; }
    gdrive_upload GD "$HOME/a.tar.gz.gpg" a.tar.gz.gpg 2>/dev/null
    [ "$CLOUD_UPLOADED_NAME" = "a.tar.gz.gpg" ]
    # the resumed request streamed exactly the remaining 200 bytes
    [ "$(cat "$MOCK_DIR"/stdin.*)" = "200" ]
    grep -q "Content-Length: 200" "$MOCK_DIR"/cfg.*
    grep -q 'header = "Transfer-Encoding:"' "$MOCK_DIR"/cfg.*   # no chunked encoding
    [ "$(mock_requests_matching "POST $GDRIVE_UPLOAD_API/*")" -eq 1 ]   # same session reused
}

@test "gdrive: expired upload session is restarted once" {
    _gd_conn
    gd_put_route() {
        case "$2" in
            */session-1)
                if [[ "$3" == *"bytes */300"* ]]; then MOCK_CODE=404; else MOCK_CODE=000; MOCK_RC=28; fi ;;
            */session-2) MOCK_BODY='{"id":"F"}' ;;
        esac
    }
    mock_route() { _gd_upload_route "$@"; }
    gdrive_upload GD "$HOME/a.tar.gz.gpg" a.tar.gz.gpg 2>/dev/null
    [ "$CLOUD_UPLOADED_NAME" = "a.tar.gz.gpg" ]
    [ "$(mock_requests_matching "POST $GDRIVE_UPLOAD_API/*")" -eq 2 ]
}

@test "gdrive: storage quota error is reported and not retried" {
    _gd_conn
    gd_put_route() { MOCK_CODE=403; MOCK_BODY='{"error":{"errors":[{"reason":"storageQuotaExceeded"}],"message":"The user'"'"'s Drive storage quota has been exceeded."}}'; }
    mock_route() { _gd_upload_route "$@"; }
    run gdrive_upload GD "$HOME/a.tar.gz.gpg" a.tar.gz.gpg
    [ "$status" -eq "$CLOUD_E_QUOTA" ]
    [[ "$output" == *"quota"* ]]
    [ "$(mock_requests_matching "PUT *")" -eq 1 ]
}

@test "gdrive: transient upload failures are bounded" {
    _gd_conn
    gd_put_route() {
        if [[ "$3" == *"bytes */300"* ]]; then MOCK_CODE=308; else MOCK_CODE=000; MOCK_RC=56; fi
    }
    mock_route() { _gd_upload_route "$@"; }
    run gdrive_upload GD "$HOME/a.tar.gz.gpg" a.tar.gz.gpg
    [ "$status" -eq "$CLOUD_E_NET" ]
    # 1 initial + CLOUD_MAX_RETRIES resumed PUTs, each preceded by a status query
    [ "$(mock_requests_matching "PUT *")" -eq $(( 1 + 2 * CLOUD_MAX_RETRIES )) ]
}

@test "gdrive: a refreshed folder_id is persisted to the encrypted config" {
    require_flock
    add_conn google-work gdrive "" CrypTar
    local -A c=()
    cloud_cfg_load google-work c
    mock_route() {
        _gd_token_ok "$@" && return
        case "$1 $2" in
            "GET $GDRIVE_API/files?q="*) MOCK_BODY='{"files":[{"id":"PERSISTED","name":"CrypTar"}]}' ;;
            *) MOCK_CODE=500 ;;
        esac
    }
    gdrive_ensure_folder c 2>/dev/null
    local -A again=()
    cloud_cfg_load google-work again
    [ "${again[folder_id]}" = "PERSISTED" ]
}

# ══ Yandex Disk ═══════════════════════════════════════════════════════════════

_ya_route() {
    case "$1 $2" in
        "PUT $YADISK_API/resources?path="*) MOCK_CODE=409; MOCK_BODY='{"error":"DiskPathPointsToExistentDirectoryError"}' ;;
        "GET $YADISK_API/resources/upload?path="*) ya_link_route "$@" ;;
        "PUT https://uploader.example/"*) ya_put_route "$@" ;;
        "GET $YADISK_API/resources?path="*) ya_meta_route "$@" ;;
        "GET $YADISK_API/operations/"*) ya_op_route "$@" ;;
        *) MOCK_CODE=599 ;;
    esac
}
ya_link_route() { MOCK_BODY='{"href":"https://uploader.example/put/1","method":"PUT","templated":false}'; }
ya_put_route()  { MOCK_CODE=201; }
ya_meta_route() { MOCK_CODE=404; }
ya_op_route()   { MOCK_BODY='{"status":"success"}'; }

@test "yadisk: folder normalization keeps the Yandex path model" {
    [ "$(yadisk_normalize_folder "CrypTar")" = "/CrypTar" ]
    [ "$(yadisk_normalize_folder "/a//b/")" = "/a/b" ]
    [ "$(yadisk_normalize_folder "disk:/Backups")" = "disk:/Backups" ]
    [ "$(yadisk_normalize_folder "app:/CrypTar")" = "app:/CrypTar" ]
    run yadisk_normalize_folder "/a/../b"; [ "$status" -ne 0 ]
    run yadisk_normalize_folder "  ";      [ "$status" -ne 0 ]
}

@test "yadisk: existing destination folder is accepted" {
    _ya_conn
    mock_route() { _ya_route "$@"; }
    yadisk_ensure_folder YA
    grep -q 'Authorization: OAuth YATOKEN' "$MOCK_DIR/cfg.1"
}

@test "yadisk: nested folders are created level by level" {
    _ya_conn
    YA[folder]="/Backups/CrypTar"
    mock_route() { MOCK_CODE=201; MOCK_BODY='{}'; }
    yadisk_ensure_folder YA >/dev/null
    [ "$(mock_requests_matching "PUT $YADISK_API/resources?path=%2FBackups")" -eq 1 ]
    [ "$(mock_requests_matching "PUT $YADISK_API/resources?path=%2FBackups%2FCrypTar")" -eq 1 ]
}

@test "yadisk: name collision picks a unique name; upload href gets no OAuth header" {
    _ya_conn
    ya_link_route() {
        if [[ "$2" == *"a.tar.gz.gpg&"* ]]; then
            MOCK_CODE=409; MOCK_BODY='{"error":"DiskResourceAlreadyExistsError"}'
        else
            MOCK_BODY='{"href":"https://uploader.example/put/1","method":"PUT","templated":false}'
        fi
    }
    mock_route() { _ya_route "$@"; }
    yadisk_upload YA "$HOME/a.tar.gz.gpg" a.tar.gz.gpg 2>/dev/null
    [ "$CLOUD_UPLOADED_NAME" = "a-1.tar.gz.gpg" ]
    [ "$(mock_requests_matching "*overwrite=false*")" -eq 2 ]
    local put_cfg
    put_cfg="$(grep -l 'url = "https://uploader.example/put/1"' "$MOCK_DIR"/cfg.*)"
    refute_grep Authorization "$put_cfg"
    refute_grep "uploader.example" "$MOCK_DIR/argv"
}

@test "yadisk: 202 Accepted waits for the async operation" {
    _ya_conn
    ya_link_route() { MOCK_BODY='{"href":"https://uploader.example/put/1","operation_id":"OP1"}'; }
    ya_put_route()  { MOCK_CODE=202; }
    ya_op_route() {
        if [[ "$(mock_count op)" -lt 2 ]]; then MOCK_BODY='{"status":"in-progress"}'; else MOCK_BODY='{"status":"success"}'; fi
    }
    mock_route() { _ya_route "$@"; }
    yadisk_upload YA "$HOME/a.tar.gz.gpg" a.tar.gz.gpg 2>/dev/null
    [ "$CLOUD_UPLOADED_NAME" = "a.tar.gz.gpg" ]
    [ "$(mock_requests_matching "GET $YADISK_API/operations/OP1")" -eq 2 ]
}

@test "yadisk: insufficient storage (507) is a quota error, not retried" {
    _ya_conn
    ya_put_route() { MOCK_CODE=507; MOCK_BODY='{"error":"InsufficientStorageError"}'; }
    mock_route() { _ya_route "$@"; }
    run yadisk_upload YA "$HOME/a.tar.gz.gpg" a.tar.gz.gpg
    [ "$status" -eq "$CLOUD_E_QUOTA" ]
    [ "$(mock_requests_matching "PUT https://uploader.example/*")" -eq 1 ]
}

@test "yadisk: file too large (413) is reported with the provider limit" {
    _ya_conn
    ya_put_route() { MOCK_CODE=413; }
    mock_route() { _ya_route "$@"; }
    run yadisk_upload YA "$HOME/a.tar.gz.gpg" a.tar.gz.gpg
    [ "$status" -eq "$CLOUD_E_TOOLARGE" ]
    [[ "$output" == *"1 ГБ"* ]]
}

@test "yadisk: after a dropped connection the remote file is checked before re-uploading" {
    _ya_conn
    ya_put_route()  { MOCK_CODE=000; MOCK_RC=52; }
    ya_meta_route() { MOCK_BODY='{"type":"file","size":300}'; }   # upload did land
    mock_route() { _ya_route "$@"; }
    yadisk_upload YA "$HOME/a.tar.gz.gpg" a.tar.gz.gpg 2>/dev/null
    [ "$CLOUD_UPLOADED_NAME" = "a.tar.gz.gpg" ]
    [ "$(mock_requests_matching "PUT https://uploader.example/*")" -eq 1 ]
}

@test "yadisk: transient upload failure is retried with a fresh link" {
    _ya_conn
    ya_put_route() {
        if [[ "$(mock_count put)" -eq 1 ]]; then MOCK_CODE=503; else MOCK_CODE=201; fi
    }
    mock_route() { _ya_route "$@"; }
    yadisk_upload YA "$HOME/a.tar.gz.gpg" a.tar.gz.gpg 2>/dev/null
    [ "$CLOUD_UPLOADED_NAME" = "a.tar.gz.gpg" ]
    [ "$(mock_requests_matching "GET $YADISK_API/resources/upload*")" -eq 2 ]
    [ "$(cat "$MOCK_DIR/sleeps")" = "1" ]
}

@test "yadisk: token close to expiry is refreshed and persisted" {
    require_flock
    local -A seed=(
        [name]=yandex-backup [provider]=yadisk [folder]=/CrypTar
        [client_id]=YCID [client_secret]=YCSECRET [refresh_token]=OLDRT
        [access_token]=OLDTOKEN [expires_at]=$(( $(date +%s) + 3600 ))
    )
    cloud_cfg_add seed
    local -A c=()
    cloud_cfg_load yandex-backup c
    mock_route() {
        [[ "$2" == "$YADISK_OAUTH_URL/token" ]] && MOCK_BODY='{"access_token":"NEWTOKEN","refresh_token":"NEWRT","expires_in":31536000}'
    }
    _yadisk_token c
    [ "$CLOUD_BEARER" = "NEWTOKEN" ]
    grep -q "grant_type=refresh_token" "$MOCK_DIR/cfg.1"
    local -A after=()
    cloud_cfg_load yandex-backup after
    [ "${after[access_token]}" = "NEWTOKEN" ]
    [ "${after[refresh_token]}" = "NEWRT" ]
}

@test "yadisk: expired token without refresh token is an auth error" {
    _ya_conn
    YA[expires_at]=1; YA[refresh_token]=""
    run _yadisk_token YA
    [ "$status" -eq "$CLOUD_E_AUTH" ]
    [ "$(mock_total_requests)" -eq 0 ]
}

@test "yadisk: device flow polls until the user confirms" {
    _ya_conn
    YA[access_token]=""; YA[refresh_token]=""
    mock_route() {
        case "$2" in
            "$YADISK_OAUTH_URL/device/code") MOCK_BODY='{"device_code":"YDEV","user_code":"1234567","verification_url":"https://oauth.yandex.ru/device","interval":5,"expires_in":300}' ;;
            "$YADISK_OAUTH_URL/token")
                if [[ "$(mock_count tok)" -eq 1 ]]; then MOCK_CODE=400; MOCK_BODY='{"error":"authorization_pending"}'
                else MOCK_BODY='{"access_token":"YNEW","refresh_token":"YNEWRT","expires_in":31536000}'; fi ;;
        esac
    }
    yadisk_auth YA >/dev/null 2>&1
    [ "${YA[access_token]}" = "YNEW" ]
    [ "${YA[refresh_token]}" = "YNEWRT" ]
    [[ "${YA[device_id]}" == cryptar-* ]]
    grep -q "code=YDEV" "$MOCK_DIR/cfg.3"
    refute_grep "YDEV\|YCSECRET" "$MOCK_DIR/argv"
}

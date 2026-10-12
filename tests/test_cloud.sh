#!/usr/bin/env bats
# tests/test_cloud.sh — unit tests for src/lib/cloud.sh
#
# Requires: bats-core, gpg; flock (util-linux) and jq for the config / HTTP
# tests (skipped when missing). No network access: HTTP is mocked.
# Run: bats tests/test_cloud.sh

load cloud_helper

setup_file()    { cloud_setup_keyring; }
teardown_file() { cloud_teardown_keyring; }
setup()         { cloud_setup_env; }
teardown()      { cloud_teardown_env; }

# ── Names ─────────────────────────────────────────────────────────────────────

@test "cloud_validate_name accepts typical names with hyphens" {
    cloud_validate_name "google-work"
    cloud_validate_name "google_personal"
    cloud_validate_name "yandex-backup"
    cloud_validate_name "1drive"
}

@test "cloud_validate_name rejects unsafe or ambiguous names" {
    run cloud_validate_name "";            [ "$status" -ne 0 ]
    run cloud_validate_name "123";         [ "$status" -ne 0 ]   # would clash with an index
    run cloud_validate_name "-x";          [ "$status" -ne 0 ]
    run cloud_validate_name "a b";         [ "$status" -ne 0 ]
    run cloud_validate_name "a/b";         [ "$status" -ne 0 ]
    run cloud_validate_name "a.b";         [ "$status" -ne 0 ]
    run cloud_validate_name "x]";          [ "$status" -ne 0 ]
    run cloud_validate_name "$(printf 'a%.0s' {1..65})"; [ "$status" -ne 0 ]
}

# ── Config storage ────────────────────────────────────────────────────────────

@test "several accounts of the same provider are listed in order" {
    require_flock
    add_conn google-work     gdrive a@example.com
    add_conn google-personal gdrive b@example.com
    add_conn yandex-backup   yadisk c-login /CrypTar
    run cloud_cfg_table
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "google-work"$'\t'"gdrive"$'\t'"a@example.com"$'\t'"CrypTar" ]
    [ "${lines[1]}" = "google-personal"$'\t'"gdrive"$'\t'"b@example.com"$'\t'"CrypTar" ]
    [ "${lines[2]}" = "yandex-backup"$'\t'"yadisk"$'\t'"c-login"$'\t'"/CrypTar" ]
    [ "${#lines[@]}" -eq 3 ]
}

@test "cloud_cfg_table never prints secrets" {
    require_flock
    add_conn google-work gdrive
    run cloud_cfg_table
    [[ "$output" != *rt-secret* ]]
    [[ "$output" != *csecret* ]]
}

@test "adding a duplicate name is rejected and the original is kept" {
    require_flock
    add_conn google-work gdrive a@example.com
    local -A dup=([name]=Google-Work [provider]=gdrive [refresh_token]=OTHER)
    run cloud_cfg_add dup
    [ "$status" -eq "$CLOUD_E_CONFLICT" ]
    local -A c=()
    cloud_cfg_load google-work c
    [ "${c[refresh_token]}" = "rt-secret-google-work" ]
    run cloud_cfg_table
    [ "${#lines[@]}" -eq 1 ]
}

@test "config file is GPG-encrypted, owner-only, and holds no plaintext tokens" {
    require_flock
    add_conn google-work gdrive
    [ -f "$CLOUD_CFG_FILE" ]
    refute_grep "rt-secret" "$CLOUD_CFG_FILE"
    cloud_cfg_plain | grep -q "^refresh_token=rt-secret-google-work$"
    if [[ "$(uname -s)" != MINGW* && "$(uname -s)" != MSYS* && "$(uname -s)" != CYGWIN* ]]; then
        [ "$(stat -c %a "$CLOUD_CFG_FILE")" = "600" ]
    fi
    [ ! -e "$CLOUD_CFG_FILE.tmp" ]
}

@test "cloud config is separate from servers.conf.gpg" {
    require_flock
    add_conn google-work gdrive
    [ ! -f "$CFG_FILE" ]
    run cfg_list_servers
    [ -z "$output" ]
    cfg_add_server "srv1" "10.0.0.1" "22" "alice" "password" "pw" "" "" ""
    run cloud_cfg_table
    [ "${#lines[@]}" -eq 1 ]
    [[ "$output" != *srv1* ]]
}

@test "cloud_cfg_set updates one connection without touching others" {
    require_flock
    add_conn google-work     gdrive
    add_conn google-personal gdrive
    cloud_cfg_set google-work folder_id FOLDER123 refresh_token NEWRT

    local -A a=() b=()
    cloud_cfg_load google-work a
    cloud_cfg_load google-personal b
    [ "${a[folder_id]}" = "FOLDER123" ]
    [ "${a[refresh_token]}" = "NEWRT" ]
    [ "${a[client_id]}" = "cid-google-work" ]
    [ "${b[refresh_token]}" = "rt-secret-google-personal" ]
    [ -z "${b[folder_id]:-}" ]
    [ "$(cloud_cfg_plain | grep -c '^refresh_token=')" -eq 2 ]
    [ ! -e "$CLOUD_CFG_FILE.tmp" ]
}

@test "cloud_cfg_set rejects multi-line values (no INI injection)" {
    require_flock
    add_conn google-work gdrive
    run cloud_cfg_set google-work folder $'x\n[evil]'
    [ "$status" -ne 0 ]
    run cloud_cfg_table
    [ "${#lines[@]}" -eq 1 ]
}

@test "a failed encryption leaves the previous config intact (atomic update)" {
    require_flock
    add_conn google-work gdrive
    cp "$CLOUD_CFG_FILE" "$HOME/before.gpg"
    rm -f "$CFG_KEY_FILE"                      # cfg_encrypt now fails
    run cloud_cfg_set google-work folder_id NEW
    [ "$status" -ne 0 ]
    cmp -s "$CLOUD_CFG_FILE" "$HOME/before.gpg"
    [ ! -e "$CLOUD_CFG_FILE.tmp" ]
}

@test "cloud_cfg_remove removes only the target connection" {
    require_flock
    add_conn google-work     gdrive
    add_conn google-personal gdrive
    add_conn yandex-backup   yadisk
    cloud_cfg_remove google-personal
    run cloud_cfg_table
    [ "${#lines[@]}" -eq 2 ]
    [[ "${lines[0]}" == google-work* ]]
    [[ "${lines[1]}" == yandex-backup* ]]
    local -A y=()
    cloud_cfg_load yandex-backup y
    [ "${y[refresh_token]}" = "rt-secret-yandex-backup" ]
}

@test "cloud_cfg_remove of a missing connection fails without changes" {
    require_flock
    add_conn google-work gdrive
    cp "$CLOUD_CFG_FILE" "$HOME/before.gpg"
    run cloud_cfg_remove ghost
    [ "$status" -ne 0 ]
    cmp -s "$CLOUD_CFG_FILE" "$HOME/before.gpg"
}

# ── Resolution / selection ────────────────────────────────────────────────────

@test "cloud_resolve maps 1-based index and exact name" {
    require_flock
    add_conn google-work   gdrive
    add_conn yandex-backup yadisk
    [ "$(cloud_resolve 1)" = "google-work" ]
    [ "$(cloud_resolve 2)" = "yandex-backup" ]
    [ "$(cloud_resolve yandex-backup)" = "yandex-backup" ]
}

@test "cloud_resolve rejects invalid identifiers" {
    require_flock
    add_conn google-work gdrive
    run cloud_resolve 0;           [ "$status" -ne 0 ]
    run cloud_resolve 2;           [ "$status" -ne 0 ]
    run cloud_resolve ghost;       [ "$status" -ne 0 ]
    run cloud_resolve Google-Work; [ "$status" -ne 0 ]   # exact match only
}

@test "_cloud_parse_selection handles lists, ranges, all and duplicates" {
    [ "$(_cloud_parse_selection "1,3" 3 | tr '\n' ' ')" = "1 3 " ]
    [ "$(_cloud_parse_selection "2-3" 3 | tr '\n' ' ')" = "2 3 " ]
    [ "$(_cloud_parse_selection "all" 3 | tr '\n' ' ')" = "1 2 3 " ]
    [ "$(_cloud_parse_selection "1, 1 ,2" 3 | tr '\n' ' ')" = "1 2 " ]
    run _cloud_parse_selection "0" 3;   [ "$status" -ne 0 ]
    run _cloud_parse_selection "4" 3;   [ "$status" -ne 0 ]
    run _cloud_parse_selection "x" 3;   [ "$status" -ne 0 ]
    run _cloud_parse_selection "3-1" 3; [ "$status" -ne 0 ]
}

@test "cloud_pick multi-select returns the chosen names" {
    require_flock
    add_conn google-work     gdrive
    add_conn google-personal gdrive
    add_conn yandex-backup   yadisk
    run cloud_pick 1 "Куда" <<< "1,3"
    [ "$status" -eq 0 ]
    [[ "$output" == *"google-work"* ]]
    [[ "$output" == *"yandex-backup"* ]]
    [[ "$output" != *$'\n'"google-personal"* ]]
}

@test "cloud_pick cancels on empty input and on EOF" {
    require_flock
    add_conn google-work gdrive
    run cloud_pick 1 "Куда" <<< ""
    [ "$status" -ne 0 ]
    run cloud_pick 0 "Куда" < /dev/null
    [ "$status" -ne 0 ]
}

# ── Helpers ───────────────────────────────────────────────────────────────────

@test "cloud_redact masks tokens, secrets and authorization headers" {
    local out
    out="$(cloud_redact '{"access_token":"ya29.SECRET1","refresh_token":"1//SECRET2","error":"x"} client_secret=SECRET3&a=1 Authorization: Bearer SECRET4 OAuth y0_SECRETSECRETSECRETSECRET5')"
    [[ "$out" != *SECRET* ]]
    [[ "$out" == *'"error":"x"'* ]]
    [[ "$out" == *"a=1"* ]]
}

@test "log output of a failed request is redacted" {
    require_jq
    CLOUD_CURL_RC=0 CLOUD_HTTP_CODE=400
    CLOUD_HTTP_BODY='{"error":"invalid_request","error_description":"bad refresh_token=1//LEAKED"}'
    run cloud_report_http_error "ctx"
    [[ "$output" != *LEAKED* ]]
    [[ "$output" == *"HTTP 400"* ]]
}

@test "cloud_unique_name keeps the archive suffix" {
    [ "$(cloud_unique_name "a_12_10_2026.tar.gz.gpg" 1)" = "a_12_10_2026-1.tar.gz.gpg" ]
    [ "$(cloud_unique_name "notes.txt" 2)" = "notes-2.txt" ]
    [ "$(cloud_unique_name "README" 3)" = "README-3" ]
}

@test "cloud_is_encrypted_archive distinguishes real OpenPGP data" {
    make_encrypted "$HOME/real.tar.gz.gpg"
    cloud_is_encrypted_archive "$HOME/real.tar.gz.gpg"

    echo "plain text" > "$HOME/fake.gpg"
    run cloud_is_encrypted_archive "$HOME/fake.gpg"
    [ "$status" -ne 0 ]

    cp "$HOME/real.tar.gz.gpg" "$HOME/real.bin"   # right content, wrong name
    run cloud_is_encrypted_archive "$HOME/real.bin"
    [ "$status" -ne 0 ]

    run cloud_is_encrypted_archive "$HOME/missing.gpg"
    [ "$status" -ne 0 ]
}

@test "cloud_require_deps reports missing tools" {
    run cloud_require_deps definitely-not-installed-xyz
    [ "$status" -eq "$CLOUD_E_CONFIG" ]
    [[ "$output" == *definitely-not-installed-xyz* ]]
}

# ── HTTP: classification, retries, secrecy ────────────────────────────────────

@test "error classification covers auth, scope, rate, quota and network" {
    _cls() { CLOUD_CURL_RC="$1" CLOUD_HTTP_CODE="$2" CLOUD_HTTP_BODY="$3" cloud_http_error_code; }
    [ "$(_cls 0 401 '{}')" -eq "$CLOUD_E_AUTH" ]
    [ "$(_cls 0 400 '{"error":"invalid_grant"}')" -eq "$CLOUD_E_AUTH" ]
    [ "$(_cls 0 401 '{"error":"invalid_client"}')" -eq "$CLOUD_E_CONFIG" ]
    [ "$(_cls 0 403 '{"error":{"errors":[{"reason":"insufficientPermissions"}]}}')" -eq "$CLOUD_E_PERM" ]
    [ "$(_cls 0 403 '{"error":{"errors":[{"reason":"userRateLimitExceeded"}]}}')" -eq "$CLOUD_E_RATE" ]
    [ "$(_cls 0 403 '{"error":{"errors":[{"reason":"storageQuotaExceeded"}]}}')" -eq "$CLOUD_E_QUOTA" ]
    [ "$(_cls 0 429 '')" -eq "$CLOUD_E_RATE" ]
    [ "$(_cls 0 507 '')" -eq "$CLOUD_E_QUOTA" ]
    [ "$(_cls 0 413 '')" -eq "$CLOUD_E_TOOLARGE" ]
    [ "$(_cls 0 404 '')" -eq "$CLOUD_E_NOTFOUND" ]
    [ "$(_cls 0 503 '')" -eq "$CLOUD_E_SERVER" ]
    [ "$(_cls 7 000 '')" -eq "$CLOUD_E_NET" ]
    [ "$(_cls 28 000 '')" -eq "$CLOUD_E_NET" ]
    [ "$(_cls 26 000 '')" -eq "$CLOUD_E_GENERIC" ]
}

@test "_cloud_request retries transient 5xx with exponential backoff" {
    mock_route() {
        local n; n="$(mock_count r)"
        if (( n < 3 )); then MOCK_CODE=503; MOCK_BODY='{}'; else MOCK_CODE=200; MOCK_BODY='{"ok":1}'; fi
    }
    _cloud_request GET "https://api.example/x"
    [ "$CLOUD_HTTP_CODE" = "200" ]
    [ "$(mock_total_requests)" -eq 3 ]
    [ "$(tr '\n' ' ' < "$MOCK_DIR/sleeps")" = "1 2 " ]
}

@test "_cloud_request honours Retry-After on 429" {
    mock_route() {
        local n; n="$(mock_count r)"
        if (( n == 1 )); then MOCK_CODE=429; MOCK_HEADERS='Retry-After: 7'
        else MOCK_CODE=200; fi
    }
    _cloud_request GET "https://api.example/x"
    [ "$(cat "$MOCK_DIR/sleeps")" = "7" ]
}

@test "_cloud_request retries network errors and classifies them" {
    mock_route() { MOCK_CODE=000; MOCK_RC=7; }
    run _cloud_request GET "https://api.example/x"
    [ "$status" -eq "$CLOUD_E_NET" ]
    [ "$(mock_total_requests)" -eq $(( CLOUD_MAX_RETRIES + 1 )) ]
}

@test "_cloud_request does not retry permanent errors" {
    mock_route() { MOCK_CODE=400; MOCK_BODY='{"error":"bad"}'; }
    run _cloud_request GET "https://api.example/x"
    [ "$status" -eq "$CLOUD_E_API" ]
    [ "$(mock_total_requests)" -eq 1 ]

    : > "$MOCK_DIR/requests"
    mock_route() { MOCK_CODE=401; }
    run _cloud_request GET "https://api.example/x"
    [ "$status" -eq "$CLOUD_E_AUTH" ]
    [ "$(mock_total_requests)" -eq 1 ]
}

@test "_cloud_request retry count is bounded" {
    mock_route() { MOCK_CODE=503; }
    run _cloud_request GET "https://api.example/x"
    [ "$status" -eq "$CLOUD_E_SERVER" ]
    [ "$(mock_total_requests)" -eq $(( CLOUD_MAX_RETRIES + 1 )) ]
}

@test "--no-retry and uploads make exactly one attempt" {
    mock_route() { MOCK_CODE=503; }
    run _cloud_request POST "https://api.example/x" --no-retry
    [ "$(mock_total_requests)" -eq 1 ]
    echo data > "$HOME/f"
    run _cloud_request PUT "https://api.example/u" --upload "$HOME/f"
    [ "$(mock_total_requests)" -eq 2 ]
}

@test "tokens, bodies and URLs are passed via curl config, never argv" {
    CLOUD_BEARER="ya29.TOPSECRET"
    local body="refresh_token=RTSECRET"
    _cloud_request POST "https://api.example/x?upload_id=SESSIONSECRET" --auth --body-var body
    refute_grep "SECRET" "$MOCK_DIR/argv"
    grep -q 'header = "Authorization: Bearer ya29.TOPSECRET"' "$MOCK_DIR/cfg.1"
    grep -q 'data-binary = "refresh_token=RTSECRET"' "$MOCK_DIR/cfg.1"
    grep -q 'url = "https://api.example/x?upload_id=SESSIONSECRET"' "$MOCK_DIR/cfg.1"
}

@test "requests without --auth carry no Authorization header" {
    CLOUD_BEARER="ya29.TOPSECRET"
    _cloud_request GET "https://upload.example/href"
    refute_grep "Authorization" "$MOCK_DIR/cfg.1"
}

@test "curl config escapes quotes and backslashes in values" {
    local body='{"name":"a\"b\\c"}'
    _cloud_request POST "https://api.example/x" --body-var body
    grep -qF 'data-binary = "{\"name\":\"a\\\"b\\\\c\"}"' "$MOCK_DIR/cfg.1"
}

@test "cloud_form percent-encodes values" {
    [ "$(cloud_form a 'x y' b 'p&q=r/é')" = "a=x%20y&b=p%26q%3Dr%2F%C3%A9" ]
}

# ── Multi-destination upload ──────────────────────────────────────────────────

_fake_providers() {
    : > "$MOCK_DIR/uploads"
    gdrive_upload() { echo "${2}|${3}" >> "$MOCK_DIR/uploads"; _fake_result "$1"; }
    yadisk_upload() { echo "${2}|${3}" >> "$MOCK_DIR/uploads"; _fake_result "$1"; }
    _fake_result() {
        local -n __fr="$1"
        [[ " ${FAKE_FAIL:-} " == *" ${__fr[name]} "* ]] && return "$CLOUD_E_QUOTA"
        CLOUD_UPLOADED_NAME="remote-${__fr[name]}"
        return 0
    }
}

@test "cloud_upload_many uploads the same file to every destination" {
    require_flock
    add_conn google-work   gdrive
    add_conn yandex-backup yadisk
    _fake_providers
    echo data > "$HOME/a.tar.gz.gpg"
    run cloud_upload_many "$HOME/a.tar.gz.gpg" google-work yandex-backup
    [ "$status" -eq 0 ]
    [ "$(wc -l < "$MOCK_DIR/uploads")" -eq 2 ]
    [ "$(cut -d'|' -f1 "$MOCK_DIR/uploads" | sort -u)" = "$HOME/a.tar.gz.gpg" ]
}

@test "cloud_upload_many reports partial failure with exit code 3" {
    require_flock
    add_conn google-work   gdrive
    add_conn yandex-backup yadisk
    _fake_providers
    echo data > "$HOME/a.tar.gz.gpg"
    FAKE_FAIL="yandex-backup"
    run cloud_upload_many "$HOME/a.tar.gz.gpg" google-work yandex-backup
    [ "$status" -eq "$CLOUD_EXIT_PARTIAL" ]
    [[ "$output" == *"google-work"*"OK"* ]]
    [[ "$output" == *"yandex-backup"*"ОШИБКА"* ]]
    [ -f "$HOME/a.tar.gz.gpg" ]
}

@test "cloud_upload_many returns 1 when every upload fails" {
    require_flock
    add_conn google-work gdrive
    _fake_providers
    echo data > "$HOME/a.tar.gz.gpg"
    FAKE_FAIL="google-work"
    run cloud_upload_many "$HOME/a.tar.gz.gpg" google-work
    [ "$status" -eq 1 ]
}

#!/usr/bin/env bats
# tests/test_cloud_commands.sh — --cloud subcommands (dispatch, add, list,
# remove, test, send, reauth) plus backward-compatibility checks.
#
# Provider network operations are replaced by fakes; archive creation and
# GPG encryption are real (isolated keyring).
# Requires: bats-core, gpg, curl, jq; flock for config-backed tests.
# Run: bats tests/test_cloud_commands.sh

load cloud_helper

setup_file()    { cloud_setup_keyring; }
teardown_file() { cloud_teardown_keyring; }

setup() {
    cloud_setup_env
    CRYPTAR="$REPO_DIR/crypTar"
    source "$REPO_DIR/src/commands/cloud/dispatch.sh"
    for f in add list remove test send; do
        source "$REPO_DIR/src/commands/cloud/$f.sh"
    done
    source "$REPO_DIR/src/providers/cloud/google_drive.sh"
    source "$REPO_DIR/src/providers/cloud/yandex_disk.sh"
    _install_fake_providers
    WORK="$HOME/work"
    mkdir -p "$WORK"
    cd "$WORK"
}
teardown() {
    cd /
    cloud_teardown_env
}

# Fake network operations for both providers. Behaviour is steered by:
#   FAKE_FAIL_UPLOAD="name ..."  uploads that fail (quota error)
#   FAKE_TEST_RC=<code>          result of <p>_test
#   FAKE_AUTH_RC=<code>          result of <p>_auth
_install_fake_providers() {
    : > "$MOCK_DIR/uploads"
    local p
    for p in gdrive yadisk; do
        eval "
        ${p}_auth() {
            local -n __fa=\"\$1\"
            [[ \${FAKE_AUTH_RC:-0} -eq 0 ]] || return \$FAKE_AUTH_RC
            __fa[refresh_token]=\"fake-rt-\${__fa[name]}\"
            return 0
        }
        ${p}_account() { local -n __fc=\"\$1\"; __fc[account]=\"user-\${__fc[name]}@example.com\"; }
        ${p}_ensure_folder() { local -n __ff=\"\$1\"; __ff[folder_id]=\"fid-\${__ff[name]}\"; return 0; }
        ${p}_test() { echo \"fake test \$1\"; return \${FAKE_TEST_RC:-0}; }
        ${p}_upload() {
            local -n __fu=\"\$1\"
            echo \"\${__fu[name]}|\$2|\$3\" >> \"\$MOCK_DIR/uploads\"
            [[ \" \${FAKE_FAIL_UPLOAD:-} \" == *\" \${__fu[name]} \"* ]] && return \$CLOUD_E_QUOTA
            CLOUD_UPLOADED_NAME=\"\$3\"
            return 0
        }"
    done
}

_three_conns() {
    add_conn google-work     gdrive a@example.com
    add_conn google-personal gdrive b@example.com
    add_conn yandex-backup   yadisk c-login /CrypTar
}

# ── Dispatch via the real executable ─────────────────────────────────────────

@test "crypTar --cloud without subcommand prints usage and exits 1" {
    run "$CRYPTAR" --cloud
    [ "$status" -eq 1 ]
    [[ "$output" == *"--cloud"* ]]
}

@test "crypTar --cloud help exits 0" {
    run "$CRYPTAR" --cloud help
    [ "$status" -eq 0 ]
    [[ "$output" == *"send"* ]]
}

@test "crypTar --cloud with unknown subcommand exits 1" {
    run "$CRYPTAR" --cloud frobnicate
    [ "$status" -eq 1 ]
    [[ "$output" == *"frobnicate"* ]]
}

@test "crypTar --cloud list on empty config exits 0" {
    require_flock
    run "$CRYPTAR" --cloud list
    [ "$status" -eq 0 ]
}

@test "crypTar --cloud send with a missing file exits 1 before any network use" {
    run "$CRYPTAR" --cloud send --to x "$WORK/missing.tar.gz.gpg"
    [ "$status" -eq 1 ]
    [[ "$output" == *"missing.tar.gz.gpg"* ]]
}

@test "--help mentions the cloud commands" {
    run "$CRYPTAR" --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"--cloud"* ]]
}

# ── list ──────────────────────────────────────────────────────────────────────

@test "list shows several accounts per provider with unverified status" {
    require_flock
    _three_conns
    run cloud_list
    [ "$status" -eq 0 ]
    [[ "$output" == *"1"*"google-work"*"Google Drive"*"a@example.com"*"configured"* ]]
    [[ "$output" == *"2"*"google-personal"*"Google Drive"* ]]
    [[ "$output" == *"3"*"yandex-backup"*"Yandex Disk"* ]]
    [[ "$output" != *rt-secret* && "$output" != *csecret* ]]
}

@test "list --check reports live status per connection" {
    require_flock
    add_conn google-work gdrive
    FAKE_TEST_RC=$CLOUD_E_AUTH
    run cloud_list --check
    [ "$status" -eq 0 ]
    [[ "$output" == *"AUTH ERROR"* ]]
    FAKE_TEST_RC=0
    run cloud_list --check
    [[ "$output" == *"google-work"*"OK"* ]]
}

# ── add ───────────────────────────────────────────────────────────────────────

@test "add wizard rejects invalid and duplicate names, then saves" {
    require_flock
    add_conn google-work gdrive
    # provider 0 (Google Drive); names: invalid, duplicate, new; reuse client: y; folder: default
    run cloud_add <<< $'0\n123\ngoogle-work\ngoogle-personal\ny\n\n'
    [ "$status" -eq 0 ]
    [[ "$output" == *"уже существует"* ]]
    local -A c=() old=()
    cloud_cfg_load google-personal c
    [ "${c[provider]}" = "gdrive" ]
    [ "${c[client_id]}" = "cid-google-work" ]           # reused OAuth client
    [ "${c[refresh_token]}" = "fake-rt-google-personal" ]
    [ "${c[account]}" = "user-google-personal@example.com" ]
    [ "${c[folder]}" = "CrypTar" ]
    [ "${c[folder_id]}" = "fid-google-personal" ]
    [ -z "${c[_unsaved]:-}" ]
    cloud_cfg_load google-work old
    [ "${old[refresh_token]}" = "rt-secret-google-work" ]   # untouched
}

@test "add wizard takes the OAuth client from the environment" {
    require_flock
    CRYPTAR_YADISK_CLIENT_ID=env-id CRYPTAR_YADISK_CLIENT_SECRET=env-secret \
        run cloud_add <<< $'1\nyandex-backup\n/Backups/CrypTar\n'
    [ "$status" -eq 0 ]
    local -A c=()
    cloud_cfg_load yandex-backup c
    [ "${c[client_id]}" = "env-id" ]
    [ "${c[folder]}" = "/Backups/CrypTar" ]
    [[ "$output" != *env-secret* ]]
}

@test "add wizard saves nothing when authorization fails" {
    require_flock
    FAKE_AUTH_RC=$CLOUD_E_AUTH
    CRYPTAR_GDRIVE_CLIENT_ID=i CRYPTAR_GDRIVE_CLIENT_SECRET=s \
        run cloud_add <<< $'0\ngoogle-work\n'
    [ "$status" -eq "$CLOUD_E_AUTH" ]
    [ ! -f "$CLOUD_CFG_FILE" ]
}

@test "add wizard requires OAuth client credentials" {
    require_flock
    run cloud_add <<< $'0\ngoogle-work\n\n\n'
    [ "$status" -eq "$CLOUD_E_CONFIG" ]
    [ ! -f "$CLOUD_CFG_FILE" ]
}

# ── remove ────────────────────────────────────────────────────────────────────

@test "remove by name after confirmation" {
    require_flock
    _three_conns
    run cloud_remove google-personal <<< "y"
    [ "$status" -eq 0 ]
    run cloud_cfg_exists google-personal
    [ "$status" -ne 0 ]
    cloud_cfg_exists google-work
    cloud_cfg_exists yandex-backup
}

@test "remove by index after confirmation" {
    require_flock
    _three_conns
    run cloud_remove 3 <<< "y"
    [ "$status" -eq 0 ]
    run cloud_cfg_exists yandex-backup
    [ "$status" -ne 0 ]
    [ "$(cloud_cfg_table | wc -l)" -eq 2 ]
}

@test "remove is cancelled when not confirmed" {
    require_flock
    _three_conns
    run cloud_remove google-work <<< "n"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Отменено"* ]]
    cloud_cfg_exists google-work
}

@test "remove rejects invalid identifiers without changing anything" {
    require_flock
    _three_conns
    cp "$CLOUD_CFG_FILE" "$HOME/before.gpg"
    run cloud_remove ghost <<< "y";       [ "$status" -ne 0 ]
    run cloud_remove 9 <<< "y";           [ "$status" -ne 0 ]
    run cloud_remove 0 <<< "y";           [ "$status" -ne 0 ]
    run cloud_remove a b;                 [ "$status" -ne 0 ]
    cmp -s "$CLOUD_CFG_FILE" "$HOME/before.gpg"
}

@test "remove without argument offers an interactive list" {
    require_flock
    _three_conns
    run cloud_remove <<< $'2\ny'
    [ "$status" -eq 0 ]
    run cloud_cfg_exists google-personal
    [ "$status" -ne 0 ]
}

# ── test ──────────────────────────────────────────────────────────────────────

@test "test returns the specific error code for one connection" {
    require_flock
    add_conn google-work gdrive
    FAKE_TEST_RC=$CLOUD_E_NET
    run cloud_test google-work
    [ "$status" -eq "$CLOUD_E_NET" ]
    [[ "$output" == *"сетев"* ]]
}

@test "test --all reports partial failure" {
    require_flock
    _three_conns
    yadisk_test() { return "$CLOUD_E_AUTH"; }
    run cloud_test --all
    [ "$status" -eq "$CLOUD_EXIT_PARTIAL" ]
    [[ "$output" == *"google-work"*"OK"* ]]
    [[ "$output" == *"yandex-backup"*"ОШИБКА"* ]]
}

@test "test with unknown connection fails" {
    require_flock
    add_conn google-work gdrive
    run cloud_test ghost
    [ "$status" -ne 0 ]
}

# ── send ──────────────────────────────────────────────────────────────────────

@test "send uploads an existing encrypted archive to every --to destination" {
    require_flock
    _three_conns
    make_encrypted "$WORK/backup.tar.gz.gpg"
    cp "$WORK/backup.tar.gz.gpg" "$HOME/orig.gpg"
    cmd_archive_and_encrypt() { echo "MUST NOT RE-ENCRYPT" >&2; return 99; }
    run cloud_send --to google-work,yandex-backup backup.tar.gz.gpg
    [ "$status" -eq 0 ]
    [ "$(wc -l < "$MOCK_DIR/uploads")" -eq 2 ]
    grep -q "^google-work|backup.tar.gz.gpg|backup.tar.gz.gpg$" "$MOCK_DIR/uploads"
    grep -q "^yandex-backup|backup.tar.gz.gpg|backup.tar.gz.gpg$" "$MOCK_DIR/uploads"
    [[ "$output" != *"MUST NOT RE-ENCRYPT"* ]]
    cmp -s "$WORK/backup.tar.gz.gpg" "$HOME/orig.gpg"   # input untouched
}

@test "send accepts absolute paths and repeated --to" {
    require_flock
    _three_conns
    make_encrypted "$WORK/b.tar.gz.gpg"
    run cloud_send --to google-work --to=google-personal "$WORK/b.tar.gz.gpg"
    [ "$status" -eq 0 ]
    [ "$(cut -d'|' -f1 "$MOCK_DIR/uploads" | tr '\n' ' ')" = "google-work google-personal " ]
}

@test "send rejects unknown destinations before uploading anything" {
    require_flock
    _three_conns
    make_encrypted "$WORK/b.tar.gz.gpg"
    run cloud_send --to google-work,nope,2 "$WORK/b.tar.gz.gpg"
    [ "$status" -eq 1 ]
    [[ "$output" == *"nope"* ]]
    [ ! -s "$MOCK_DIR/uploads" ]
}

@test "send returns 3 and keeps the archive on partial failure" {
    require_flock
    _three_conns
    make_encrypted "$WORK/b.tar.gz.gpg"
    FAKE_FAIL_UPLOAD="yandex-backup"
    run cloud_send --to google-work,yandex-backup "$WORK/b.tar.gz.gpg"
    [ "$status" -eq "$CLOUD_EXIT_PARTIAL" ]
    [ -f "$WORK/b.tar.gz.gpg" ]
}

@test "send refuses a .gpg file that is not OpenPGP-encrypted" {
    require_flock
    _three_conns
    echo "not encrypted" > "$WORK/fake.tar.gz.gpg"
    run cloud_send --to google-work "$WORK/fake.tar.gz.gpg"
    [ "$status" -eq 1 ]
    [ ! -s "$MOCK_DIR/uploads" ]
}

@test "send validates arguments" {
    run cloud_send;                         [ "$status" -eq 1 ]
    run cloud_send --to;                    [ "$status" -eq 1 ]
    run cloud_send --bogus x;               [ "$status" -eq 1 ]
    run cloud_send a b;                     [ "$status" -eq 1 ]
}

@test "send without --to uses the interactive multi-select" {
    require_flock
    _three_conns
    make_encrypted "$WORK/b.tar.gz.gpg"
    run cloud_send "$WORK/b.tar.gz.gpg" <<< "1,3"
    [ "$status" -eq 0 ]
    [ "$(cut -d'|' -f1 "$MOCK_DIR/uploads" | tr '\n' ' ')" = "google-work yandex-backup " ]
}

@test "send of a directory archives+encrypts once and reuses the artifact" {
    require_flock
    _three_conns
    mkdir -p "$WORK/docs"; echo "secret doc" > "$WORK/docs/a.txt"
    # stdin: GPG key index 0; then "n" = keep the local copy
    run cloud_send --to google-work,yandex-backup "$WORK/docs" <<< $'0\nn'
    [ "$status" -eq 0 ]
    [ "$(wc -l < "$MOCK_DIR/uploads")" -eq 2 ]
    [ "$(cut -d'|' -f2 "$MOCK_DIR/uploads" | sort -u | wc -l)" -eq 1 ]   # same file
    local remote
    remote="$(cut -d'|' -f3 "$MOCK_DIR/uploads" | head -1)"
    [[ "$remote" =~ ^docs_[0-9_]+\.tar\.gz\.gpg$ ]]
    [ -f "$WORK/$remote" ]                                  # kept in cwd
    cloud_is_encrypted_archive "$WORK/$remote"
    # round-trip: the uploaded artifact decrypts back to the original
    mkdir "$HOME/out" && gpg --quiet --batch -d "$WORK/$remote" | tar -xz -C "$HOME/out"
    [ "$(cat "$HOME/out/docs/a.txt")" = "secret doc" ]
}

@test "send of a directory deletes the local copy only on full success and request" {
    require_flock
    add_conn google-work gdrive
    mkdir -p "$WORK/docs"; echo x > "$WORK/docs/a.txt"
    run cloud_send --to google-work "$WORK/docs" <<< $'0\ny'
    [ "$status" -eq 0 ]
    [ -z "$(ls "$WORK"/*.gpg 2>/dev/null)" ]
}

@test "send of a directory keeps the archive when an upload fails (no delete prompt)" {
    require_flock
    add_conn google-work gdrive
    mkdir -p "$WORK/docs"; echo x > "$WORK/docs/a.txt"
    FAKE_FAIL_UPLOAD="google-work"
    run cloud_send --to google-work "$WORK/docs" <<< $'0\ny'
    [ "$status" -eq 1 ]
    [ -n "$(ls "$WORK"/docs_*.tar.gz.gpg 2>/dev/null)" ]
}

# ── reauth ────────────────────────────────────────────────────────────────────

@test "reauth replaces tokens of one connection only" {
    require_flock
    _three_conns
    run cloud_reauth google-personal <<< "y"
    [ "$status" -eq 0 ]
    local -A a=() b=()
    cloud_cfg_load google-personal b
    cloud_cfg_load google-work a
    [ "${b[refresh_token]}" = "fake-rt-google-personal" ]
    [ "${a[refresh_token]}" = "rt-secret-google-work" ]
}

# ── Key rotation and backward compatibility ───────────────────────────────────

@test "--server set-key re-encrypts the cloud config with the new key" {
    require_flock
    add_conn google-work gdrive
    GNUPGHOME="$_CL_GNUPGHOME" gpg --batch --quiet --passphrase '' --quick-gen-key "Rotated <rot@cryptar.local>" ed25519 sign 0 2>/dev/null
    local fpr
    fpr="$(gpg --list-keys --with-colons rot@cryptar.local | awk -F: '/^fpr/{print $10; exit}')"
    gpg --batch --quiet --passphrase '' --quick-add-key "$fpr" cv25519 encr 0 2>/dev/null
    local new_id
    new_id="$(gpg --list-keys --with-colons rot@cryptar.local | awk -F: '/^pub/{print $5; exit}')"
    source "$REPO_DIR/src/commands/server/set_key.sh"
    local idx
    idx="$(cfg_list_gpg_keys | awk -v k="$new_id" '$1 == k {print NR - 1; exit}')"
    run srv_set_key <<< "$idx"
    [ "$status" -eq 0 ]
    [ "$(cat "$CFG_KEY_FILE")" = "$new_id" ]
    gpg --batch --list-packets "$CLOUD_CFG_FILE" 2>/dev/null | grep -qi "keyid"
    local -A c=()
    cloud_cfg_load google-work c
    [ "${c[refresh_token]}" = "rt-secret-google-work" ]
    # cleanup the extra key so other tests keep a single-key keyring
    gpg --batch --yes --delete-secret-and-public-key "$fpr" 2>/dev/null || true
}

@test "crypTar <dir> and crypTar -d still round-trip (no cloud involved)" {
    mkdir -p "$WORK/src"; echo "hello" > "$WORK/src/f.txt"
    run "$CRYPTAR" "$WORK/src" <<< "0"
    [ "$status" -eq 0 ]
    local out
    out="$(ls "$WORK"/src_*.tar.gz.gpg)"
    [ -f "$out" ]
    rm -rf "$WORK/src"
    run "$CRYPTAR" -d "$out"
    [ "$status" -eq 0 ]
    [ "$(cat "$WORK/src/f.txt")" = "hello" ]
    [ ! -f "$CLOUD_CFG_FILE" ]
}

@test "crypTar --server list is unaffected by cloud connections" {
    require_flock
    add_conn google-work gdrive
    run "$CRYPTAR" --server list
    [ "$status" -eq 0 ]
    [[ "$output" != *google-work* ]]
}

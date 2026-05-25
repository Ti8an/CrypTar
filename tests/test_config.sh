#!/usr/bin/env bats
# tests/test_config.sh — unit tests for src/lib/config.sh
#
# Requires: bats-core, gpg, flock (util-linux — Linux only)
# Run: bats tests/test_config.sh

# ── One-time GPG key generation for the whole file ──────────────────────────
# Generating an EdDSA key is fast (< 1 s); doing it once keeps the suite quick.

setup_file() {
    export _CFG_GNUPGHOME
    _CFG_GNUPGHOME="$(mktemp -d)"
    chmod 700 "$_CFG_GNUPGHOME"

    GNUPGHOME="$_CFG_GNUPGHOME" gpg --batch --quiet --gen-key <<'GPGEOF'
%no-protection
Key-Type: EDDSA
Key-Curve: ed25519
Subkey-Type: ECDH
Subkey-Curve: cv25519
Name-Real: CrypTar Test
Name-Email: test@cryptar.local
Expire-Date: 0
GPGEOF

    export _CFG_KEY_ID
    _CFG_KEY_ID="$(
        GNUPGHOME="$_CFG_GNUPGHOME" \
        gpg --list-keys --with-colons 2>/dev/null \
        | awk -F: '/^pub/{print $5; exit}'
    )"
}

teardown_file() {
    rm -rf "$_CFG_GNUPGHOME"
}

# ── Per-test setup — isolated HOME so CFG_DIR never touches the real config ─

setup() {
    export GNUPGHOME="$_CFG_GNUPGHOME"

    # Override HOME before sourcing config.sh so the readonly CFG_DIR points
    # at a throwaway directory, not the developer's real ~/.config/cryptar.
    export HOME
    HOME="$(mktemp -d)"
    chmod 700 "$HOME"

    REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
    source "$REPO_DIR/src/utils/log.sh"
    source "$REPO_DIR/src/lib/config.sh"

    # Register the test key as the encryption key for this test's config dir.
    cfg_set_encrypt_key "$_CFG_KEY_ID"
}

teardown() {
    rm -rf "$HOME"
}

# ── Helper — skip when flock is unavailable (macOS without homebrew util-linux)

_require_flock() {
    command -v flock &>/dev/null || skip "flock not available on this platform"
}

# ── Tests ────────────────────────────────────────────────────────────────────

@test "cfg_server_exists returns 1 for a server that has never been added" {
    run cfg_server_exists "ghost"
    [ "$status" -eq 1 ]
}

@test "cfg_server_exists returns 0 after the server is added" {
    _require_flock
    cfg_add_server "existent" "10.0.0.1" "22" "alice" "password" "pw" "" "" ""
    run cfg_server_exists "existent"
    [ "$status" -eq 0 ]
}

@test "INI round-trip: add server, read back host field" {
    _require_flock
    cfg_add_server "roundtrip" "192.168.1.42" "22" "deploy" "password" "s3cr3t" "" "" "CI"
    result="$(cfg_get "roundtrip" "host")"
    [ "$result" = "192.168.1.42" ]
}

@test "INI round-trip: add server, read back non-default port" {
    _require_flock
    cfg_add_server "portsrv" "10.0.0.2" "2222" "root" "password" "pw" "" "" ""
    result="$(cfg_get "portsrv" "port")"
    [ "$result" = "2222" ]
}

@test "INI round-trip: add server, read back user field" {
    _require_flock
    cfg_add_server "usersrv" "10.0.0.3" "22" "carol" "password" "pw" "" "" ""
    result="$(cfg_get "usersrv" "user")"
    [ "$result" = "carol" ]
}

@test "cfg_remove_server removes the target server" {
    _require_flock
    cfg_add_server "removeme" "1.2.3.4" "22" "bob" "password" "pw" "" "" ""
    cfg_remove_server "removeme"

    run cfg_server_exists "removeme"
    [ "$status" -eq 1 ]
}

@test "cfg_remove_server leaves other servers intact" {
    _require_flock
    cfg_add_server "keep_me"   "1.1.1.1" "22" "alice" "password" "p1" "" "" ""
    cfg_add_server "delete_me" "2.2.2.2" "22" "bob"   "password" "p2" "" "" ""

    cfg_remove_server "delete_me"

    run cfg_server_exists "keep_me"
    [ "$status" -eq 0 ]
}

@test "temp file is created in /dev/shm when available" {
    if [[ ! -d /dev/shm || ! -w /dev/shm ]]; then
        skip "/dev/shm not available on this platform"
    fi
    run _cfg_tmp_file
    [ "$status" -eq 0 ]
    # Path must start with /dev/shm/ — NOT /tmp/
    [[ "$output" == /dev/shm/cryptar_* ]]
    rm -f "$output"
}

@test "temp file is deleted after encrypt/decrypt cycle" {
    _require_flock
    cfg_add_server "cleantest" "9.9.9.9" "22" "dave" "password" "pw" "" "" ""

    # cfg_decrypt returns the path of the decrypted temp file; caller owns it.
    local tmp
    tmp="$(cfg_decrypt)"
    [ -f "$tmp" ]

    _cfg_shred "$tmp"
    [ ! -f "$tmp" ]
}

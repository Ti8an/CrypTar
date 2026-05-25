#!/usr/bin/env bats
# tests/test_commands.sh — integration tests for the crypTar CLI entry point
#
# Requires: bats-core, gpg
# Run: bats tests/test_commands.sh
#
# Each test invokes the real crypTar binary in a subprocess so we exercise
# the full dispatch path without touching the developer's real config.

# ── One-time GPG key generation ───────────────────────────────────────────────

setup_file() {
    export _CMD_GNUPGHOME
    _CMD_GNUPGHOME="$(mktemp -d)"
    chmod 700 "$_CMD_GNUPGHOME"

    GNUPGHOME="$_CMD_GNUPGHOME" gpg --batch --quiet --gen-key <<'GPGEOF'
%no-protection
Key-Type: EDDSA
Key-Curve: ed25519
Subkey-Type: ECDH
Subkey-Curve: cv25519
Name-Real: CrypTar Test
Name-Email: cmdtest@cryptar.local
Expire-Date: 0
GPGEOF
}

teardown_file() {
    rm -rf "$_CMD_GNUPGHOME"
}

# ── Per-test setup ────────────────────────────────────────────────────────────

setup() {
    export GNUPGHOME="$_CMD_GNUPGHOME"

    export HOME
    HOME="$(mktemp -d)"
    chmod 700 "$HOME"

    REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
    CRYPTAR="$REPO_DIR/crypTar"
}

teardown() {
    rm -rf "$HOME"
}

# ── Tests ─────────────────────────────────────────────────────────────────────

@test "crypTar --version exits 0 and prints version string" {
    run bash "$CRYPTAR" --version
    [ "$status" -eq 0 ]
    [[ "$output" == *"CrypTar v"* ]]
}

@test "crypTar --help exits 0" {
    run bash "$CRYPTAR" --help
    [ "$status" -eq 0 ]
}

@test "crypTar -h exits 0" {
    run bash "$CRYPTAR" -h
    [ "$status" -eq 0 ]
}

@test "crypTar with no arguments exits 1" {
    run bash "$CRYPTAR"
    [ "$status" -eq 1 ]
}

@test "crypTar -d with a nonexistent file exits 1 and mentions the filename" {
    run bash "$CRYPTAR" -d nonexistent_file_xyz.gpg
    [ "$status" -eq 1 ]
    [[ "$output" == *"nonexistent_file_xyz.gpg"* ]]
}

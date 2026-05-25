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

    # [FIX 10] Ensure the binary is executable so direct invocation (./crypTar)
    # works and the shebang line is exercised rather than bypassed by `bash`.
    REPO_DIR_TMP="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
    chmod +x "$REPO_DIR_TMP/crypTar"
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
    # [FIX 10] Direct invocation exercises the shebang line; use 'bash "$CRYPTAR"'
    # only if the script is not yet marked executable.
    run "$CRYPTAR" --version
    [ "$status" -eq 0 ]
    [[ "$output" == *"CrypTar v"* ]]
}

@test "crypTar --help exits 0" {
    run "$CRYPTAR" --help  # [FIX 10] direct invocation
    [ "$status" -eq 0 ]
}

@test "crypTar -h exits 0" {
    run "$CRYPTAR" -h  # [FIX 10] direct invocation
    [ "$status" -eq 0 ]
}

@test "crypTar with no arguments exits 1" {
    run "$CRYPTAR"  # [FIX 10] direct invocation
    [ "$status" -eq 1 ]
}

@test "crypTar -d with a nonexistent file exits 1 and mentions the filename" {
    # [FIX 8] Merge stderr into stdout so the assertion catches errors written to
    # either stream — crypTar routes its log_err output to stderr.
    # [FIX 10] Direct invocation.
    run "$CRYPTAR" -d nonexistent_file_xyz.gpg 2>&1
    [ "$status" -eq 1 ]
    [[ "$output" == *"nonexistent_file_xyz.gpg"* ]]
}

# [FIX 9] Smoke test: --server list must succeed even when no servers have been
# configured yet.  This exercises the dispatch path and the empty-list branch.
@test "crypTar --server list exits 0 with empty config" {
    run "$CRYPTAR" --server list 2>&1  # [FIX 10] direct invocation
    [ "$status" -eq 0 ]
}

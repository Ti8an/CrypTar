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

    # [FIX MEDIUM] Ensure the keyring is removed even when bats is killed mid-run
    # (SIGKILL, CI timeout) and teardown_file never executes.
    trap 'rm -rf "$_CMD_GNUPGHOME"' EXIT

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

    # [FIX HIGH] Wait for the key to be fully registered before any test uses it.
    # gpg --list-secret-keys forces trustdb settlement and fails loudly if the
    # key was not actually created, turning a flaky CI race into a hard setup error.
    GNUPGHOME="$_CMD_GNUPGHOME" gpg --list-secret-keys >/dev/null 2>&1 \
        || { echo "GPG key generation failed or key not found"; exit 1; }

    # [FIX MEDIUM] Compute _REPO_DIR once so setup() doesn't re-run cd+dirname
    # on every single test.
    export _REPO_DIR
    _REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
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

    # [FIX MEDIUM] Reuse _REPO_DIR computed once in setup_file.
    CRYPTAR="$_REPO_DIR/crypTar"

    # [FIX HIGH] Never chmod the binary from tests — that mutates the repository
    # and breaks parallel CI jobs. Check once per test and skip the whole suite
    # if the file is not executable, with a clear fix instruction.
    if [[ ! -x "$CRYPTAR" ]]; then
        skip "crypTar is not executable — fix with: chmod +x crypTar"
    fi
}

teardown() {
    rm -rf "$HOME"
}

# ── Tests ─────────────────────────────────────────────────────────────────────

@test "crypTar --version exits 0 and prints version string" {
    run "$CRYPTAR" --version
    [ "$status" -eq 0 ]
    # [FIX LOW] Regex is more resilient to minor formatting changes than a glob —
    # e.g. extra whitespace or a different separator won't break the assertion.
    [[ "$output" =~ CrypTar[[:space:]]+v[0-9] ]]
}

@test "crypTar --help exits 0 and prints usage" {
    run "$CRYPTAR" --help
    [ "$status" -eq 0 ]
    # [FIX LOW] Assert content so an accidentally emptied help string doesn't
    # pass — match both Russian and English spellings for portability.
    [[ "$output" == *"Использование"* || "$output" == *"Usage"* ]]
}

@test "crypTar -h exits 0 and prints usage" {
    run "$CRYPTAR" -h
    [ "$status" -eq 0 ]
    # [FIX LOW] Same content guard as --help above.
    [[ "$output" == *"Использование"* || "$output" == *"Usage"* ]]
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
    # [FIX MEDIUM] cfg_list_servers calls cfg_decrypt which requires flock
    # (util-linux). Skip gracefully on macOS without homebrew util-linux rather
    # than producing a false failure that obscures real test results.
    command -v flock &>/dev/null || skip "flock not available on this platform"
    run "$CRYPTAR" --server list 2>&1
    [ "$status" -eq 0 ]
}

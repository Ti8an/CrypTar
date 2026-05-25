#!/usr/bin/env bats
# tests/test_transfer.sh — unit tests for src/lib/transfer.sh
#
# Requires: bats-core
# Run: bats tests/test_transfer.sh

# ── Per-test setup ────────────────────────────────────────────────────────────

setup() {
    REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
    source "$REPO_DIR/src/utils/log.sh"

    # Stub out every external function that transfer.sh depends on so tests
    # never touch a real network.  Overrides are defined as shell functions
    # in this subshell; they shadow the real ones that transfer.sh exports.

    # Stub: _validate_cfg_name — accept any identifier-looking name
    _validate_cfg_name() { [[ "$1" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]]; }

    # Stub: _creds_load — populate minimal globals for a server named "srv"
    _creds_load() {
        local name="$1"
        declare -g "cfg_${name}_host";       printf -v "cfg_${name}_host"       '%s' "10.0.0.1"
        declare -g "cfg_${name}_port";       printf -v "cfg_${name}_port"       '%s' "22"
        declare -g "cfg_${name}_user";       printf -v "cfg_${name}_user"       '%s' "user"
        declare -g "cfg_${name}_auth_type";  printf -v "cfg_${name}_auth_type"  '%s' "key"
        declare -g "cfg_${name}_remote_path"; printf -v "cfg_${name}_remote_path" '%s' "~/backups"
    }

    # Stub: _creds_unload — clear those globals
    _creds_unload() {
        local name="$1"
        unset "cfg_${name}_host" "cfg_${name}_port" "cfg_${name}_user" \
              "cfg_${name}_auth_type" "cfg_${name}_key_path" \
              "cfg_${name}_password" "cfg_${name}_remote_path"
    }

    # Stub: trn_mkdir_remote — always succeeds silently
    trn_mkdir_remote() { return 0; }

    # Default stub: ssh_exec — always succeeds (overridden per-test)
    ssh_exec() { return 0; }

    # Default stub: scp_send — always succeeds
    scp_send() { return 0; }

    source "$REPO_DIR/src/lib/transfer.sh"
}

# ── trn_has_rsync ─────────────────────────────────────────────────────────────

@test "trn_has_rsync returns 1 when rsync is absent locally" {
    # Shadow 'command' so rsync lookup fails
    command() {
        [[ "$1 $2" == "-v rsync" ]] && return 1
        builtin command "$@"
    }
    run trn_has_rsync "srv"
    [ "$status" -eq 1 ]
}

@test "trn_has_rsync returns 0 when rsync is present locally and on remote" {
    # rsync present locally — command -v rsync succeeds
    # ssh_exec (remote check) also succeeds (default stub)
    if ! command -v rsync &>/dev/null; then
        skip "rsync not installed locally"
    fi
    ssh_exec() { return 0; }
    run trn_has_rsync "srv"
    [ "$status" -eq 0 ]
}

@test "trn_has_rsync returns 1 when rsync absent on remote" {
    if ! command -v rsync &>/dev/null; then
        skip "rsync not installed locally"
    fi
    # Remote check fails
    ssh_exec() { return 1; }
    run trn_has_rsync "srv"
    [ "$status" -eq 1 ]
}

# ── trn_send dispatch ─────────────────────────────────────────────────────────

@test "trn_send dispatches to rsync when rsync is available" {
    # Override trn_has_rsync to report rsync available (return 0)
    trn_has_rsync() { return 0; }

    # Record which backend was chosen
    trn_via_rsync() { echo "RSYNC_USED"; return 0; }
    trn_via_scp()   { echo "SCP_USED";   return 0; }

    local dummy_file
    dummy_file="$(mktemp)"
    run trn_send "srv" "$dummy_file"
    rm -f "$dummy_file"

    [ "$status" -eq 0 ]
    [[ "$output" == *"RSYNC_USED"* ]]
}

@test "trn_send dispatches to scp when rsync is unavailable" {
    # Override trn_has_rsync to report rsync absent (return 1)
    trn_has_rsync() { return 1; }

    trn_via_rsync() { echo "RSYNC_USED"; return 0; }
    trn_via_scp()   { echo "SCP_USED";   return 0; }

    local dummy_file
    dummy_file="$(mktemp)"
    run trn_send "srv" "$dummy_file"
    rm -f "$dummy_file"

    [ "$status" -eq 0 ]
    [[ "$output" == *"SCP_USED"* ]]
}

@test "trn_send rejects an invalid server name" {
    run trn_send "bad-name" "/tmp/x"
    [ "$status" -eq 1 ]
}

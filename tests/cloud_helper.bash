# tests/cloud_helper.bash — shared fixtures for the cloud test files.
# Loaded with `load cloud_helper` from bats.
#
# No test touches the network: every HTTP request goes through
# _cloud_transport, which is replaced here by a scriptable mock. Each test
# defines mock_route() to decide the response for (method, url, curl-config).

# ── Keyring (once per file) ───────────────────────────────────────────────────

cloud_setup_keyring() {
    export _CL_GNUPGHOME
    _CL_GNUPGHOME="$(mktemp -d)"
    chmod 700 "$_CL_GNUPGHOME"
    GNUPGHOME="$_CL_GNUPGHOME" gpg --batch --quiet --gen-key <<'GPGEOF'
%no-protection
Key-Type: EDDSA
Key-Curve: ed25519
Subkey-Type: ECDH
Subkey-Curve: cv25519
Name-Real: CrypTar Cloud Test
Name-Email: cloudtest@cryptar.local
Expire-Date: 0
GPGEOF
    export _CL_KEY_ID
    _CL_KEY_ID="$(GNUPGHOME="$_CL_GNUPGHOME" gpg --list-keys --with-colons 2>/dev/null \
                  | awk -F: '/^pub/{print $5; exit}')"
    [[ -n "$_CL_KEY_ID" ]] || { echo "GPG key generation failed"; return 1; }
    export _REPO_DIR
    _REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
}

cloud_teardown_keyring() {
    GNUPGHOME="$_CL_GNUPGHOME" gpgconf --kill all 2>/dev/null || true
    rm -rf "$_CL_GNUPGHOME"
}

# ── Per-test environment ──────────────────────────────────────────────────────

cloud_setup_env() {
    export GNUPGHOME="$_CL_GNUPGHOME"
    export HOME
    HOME="$(mktemp -d)"
    chmod 700 "$HOME"
    REPO_DIR="$_REPO_DIR"
    SRC_DIR="$REPO_DIR/src"
    export MOCK_DIR="$HOME/mock"
    mkdir -p "$MOCK_DIR"
    : > "$MOCK_DIR/requests"
    : > "$MOCK_DIR/argv"
    : > "$MOCK_DIR/sleeps"

    source "$REPO_DIR/src/utils/log.sh"
    source "$REPO_DIR/src/utils/ui.sh"
    source "$REPO_DIR/src/lib/config.sh"
    source "$REPO_DIR/src/lib/cloud.sh"
    cfg_set_encrypt_key "$_CL_KEY_ID"

    # Never sleep in tests; record requested delays instead.
    _cloud_sleep() { echo "$1" >> "$MOCK_DIR/sleeps"; }
    _cloud_transport() { _mock_transport "$@"; }
}

cloud_teardown_env() {
    rm -rf "$HOME"
}

require_flock() { command -v flock &>/dev/null || skip "flock not available on this platform"; }
require_jq()    { command -v jq    &>/dev/null || skip "jq not installed"; }
require_curl()  { command -v curl  &>/dev/null || skip "curl not installed"; }

# ── Mock HTTP transport ───────────────────────────────────────────────────────

# mock_count <key> — increment and echo a per-test counter (file-based: the
# transport runs in a command-substitution subshell).
mock_count() {
    local f="$MOCK_DIR/count.$1" n=0
    [[ -f "$f" ]] && n="$(cat "$f")"
    n=$((n + 1))
    echo "$n" > "$f"
    echo "$n"
}

# Default route: everything 200 with an empty JSON object.
mock_route() { MOCK_CODE=200; MOCK_BODY='{}'; }

_mock_transport() {
    local body_out="$1" hdr_out="$2" cfg="$3"; shift 3
    local cfg_text method url seq h
    cfg_text="$(cat "$cfg")"
    method="$(sed -n 's/^request = "\(.*\)"$/\1/p' <<< "$cfg_text")"
    url="$(sed -n 's/^url = "\(.*\)"$/\1/p' <<< "$cfg_text")"
    seq="$(mock_count _seq)"
    printf '%s %s\n' "$method" "$url" >> "$MOCK_DIR/requests"
    printf '%s\n' "$cfg_text" > "$MOCK_DIR/cfg.$seq"
    printf '%s\n' "$*" >> "$MOCK_DIR/argv"
    if [[ " $* " == *" -T - "* ]]; then
        wc -c | tr -d ' ' > "$MOCK_DIR/stdin.$seq"
    fi

    MOCK_CODE=200 MOCK_BODY='' MOCK_HEADERS='' MOCK_RC=0
    mock_route "$method" "$url" "$cfg_text"

    printf '%s' "$MOCK_BODY" > "$body_out"
    {
        printf 'HTTP/1.1 %s Mock\r\n' "$MOCK_CODE"
        if [[ -n "$MOCK_HEADERS" ]]; then
            while IFS= read -r h; do printf '%s\r\n' "$h"; done <<< "$MOCK_HEADERS"
        fi
        printf '\r\n'
    } > "$hdr_out"
    printf '%s' "$MOCK_CODE"
    return "$MOCK_RC"
}

# Number of recorded requests whose "METHOD URL" line matches a glob.
mock_requests_matching() {
    local pat="$1" n=0 line
    while IFS= read -r line; do
        # shellcheck disable=SC2053
        [[ "$line" == $pat ]] && n=$((n + 1))
    done < "$MOCK_DIR/requests"
    echo "$n"
}

mock_total_requests() { wc -l < "$MOCK_DIR/requests" | tr -d ' '; }

# ── Fixtures ──────────────────────────────────────────────────────────────────

# add_conn <name> <provider> [account] [folder] — save a connection with
# recognisable fake secrets.
add_conn() {
    local -A c=(
        [name]="$1" [provider]="$2" [account]="${3:-}" [folder]="${4:-CrypTar}"
        [client_id]="cid-$1" [client_secret]="csecret-$1" [refresh_token]="rt-secret-$1"
    )
    cloud_cfg_add c
}

# make_encrypted <path> — a real OpenPGP-encrypted file for the test key.
make_encrypted() {
    echo "payload $RANDOM" | gpg --batch --quiet --yes --trust-model always \
        --encrypt --recipient "$_CL_KEY_ID" --output "$1"
}

# Decrypted clouds.conf contents (for assertions).
cloud_cfg_plain() {
    gpg --quiet --batch -d "$CLOUD_CFG_FILE" 2>/dev/null
}

# refute_grep <pattern> <file...> — fail when the pattern IS found.
# (A bare `! grep` never fails a bats test: negated commands ignore set -e.)
refute_grep() {
    if grep -q "$@"; then
        echo "unexpected match for '$1' in ${*:2}" >&2
        return 1
    fi
}

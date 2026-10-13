#!/usr/bin/env bats
# tests/test_update.sh — crypTar --check-update / --update and the shared
# install core (src/install/core.sh).
#
# Requires: bats-core, jq, tar, gzip, gpg, sha256sum
# Run: bats tests/test_update.sh
#
# Nothing here touches the network, the real installation or the real
# keyring: HOME and GNUPGHOME are temporary, and `curl`, `sudo` and `git` are
# replaced by stubs in $FAKEBIN (curl serves fixtures from $MOCK_HTTP).

setup_file() {
    export _UPD_REPO_DIR
    _UPD_REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

    # Release-signing keys for the signed-manifest tests: a pinned one and a
    # stranger. Generated once, in a keyring that is not the user's.
    export _UPD_SIGN_HOME
    _UPD_SIGN_HOME="$(mktemp -d)"
    chmod 700 "$_UPD_SIGN_HOME"
    local who
    for who in pinned stranger; do
        GNUPGHOME="$_UPD_SIGN_HOME" gpg --batch --quiet --gen-key <<GPGEOF
%no-protection
Key-Type: EDDSA
Key-Curve: ed25519
Name-Real: CrypTar Release $who
Name-Email: $who@cryptar.local
Expire-Date: 0
GPGEOF
    done
    GNUPGHOME="$_UPD_SIGN_HOME" gpg --list-secret-keys >/dev/null 2>&1 \
        || { echo "GPG key generation failed"; return 1; }
}

teardown_file() {
    GNUPGHOME="$_UPD_SIGN_HOME" gpgconf --kill all 2>/dev/null || true
    rm -rf "$_UPD_SIGN_HOME"
}

setup() {
    command -v jq &>/dev/null || skip "jq not installed"
    REPO="$_UPD_REPO_DIR"
    CUR_VER="$(cat "$REPO/VERSION")"

    export HOME="$BATS_TEST_TMPDIR/home"
    mkdir -p "$HOME"
    export GNUPGHOME="$HOME/.gnupg"
    mkdir -p "$GNUPGHOME" && chmod 700 "$GNUPGHOME"
    export TMPDIR="$BATS_TEST_TMPDIR/tmp"
    mkdir -p "$TMPDIR"
    unset CRYPTAR_UPDATE_REPO

    BIN_DIR="$HOME/.local/bin"
    LIB_DIR="$HOME/.local/lib/cryptar"
    BIN="$BIN_DIR/crypTar"

    export MOCK_HTTP="$BATS_TEST_TMPDIR/http"
    mkdir -p "$MOCK_HTTP"
    : > "$MOCK_HTTP/requests"
    FAKEBIN="$BATS_TEST_TMPDIR/fakebin"
    mkdir -p "$FAKEBIN"
    _write_fake_curl
    _write_fake_git
    export PATH="$FAKEBIN:$PATH"

    source "$REPO/src/install/core.sh"
}

# ── Stubs ─────────────────────────────────────────────────────────────────────

_write_fake_curl() {
    cat > "$FAKEBIN/curl" <<'EOF'
#!/usr/bin/env bash
# Serves $MOCK_HTTP/<key>.{body,code,hdr,rc}; key = URL without scheme,
# non [A-Za-z0-9._-] replaced by "_". Unknown URLs → 404.
out="" hdr="" url=""
while (( $# )); do
    case "$1" in
        -o) out="$2"; shift 2 ;;
        -D) hdr="$2"; shift 2 ;;
        -w|-A|-H|--proto|--proto-redir|--connect-timeout|--max-time|--max-filesize) shift 2 ;;
        --) url="$2"; shift 2 ;;
        *)  shift ;;
    esac
done
echo "$url" >> "$MOCK_HTTP/requests"
[[ -n "${MOCK_NET_DOWN:-}" ]] && exit 6
key="$(printf '%s' "${url#https://}" | sed 's/[^A-Za-z0-9._-]/_/g')"
f="$MOCK_HTTP/$key"
[[ -f "$f.rc" ]] && exit "$(cat "$f.rc")"
code=404
[[ -f "$f.body" ]] && code=200
[[ -f "$f.code" ]] && code="$(cat "$f.code")"
if [[ -n "$out" ]]; then
    if [[ -f "$f.body" ]]; then cp "$f.body" "$out"; else printf 'Not Found' > "$out"; fi
fi
if [[ -n "$hdr" ]]; then
    { printf 'HTTP/2 %s\r\n' "$code"; [[ -f "$f.hdr" ]] && cat "$f.hdr"; printf '\r\n'; } > "$hdr"
fi
printf '%s' "$code"
EOF
    chmod +x "$FAKEBIN/curl"
}

_write_fake_git() {
    printf '#!/usr/bin/env bash\necho "git $*" >> "%s/git-calls"\nexit 127\n' "$MOCK_HTTP" > "$FAKEBIN/git"
    chmod +x "$FAKEBIN/git"
}

_write_fake_sudo() {
    cat > "$FAKEBIN/sudo" <<EOF
#!/usr/bin/env bash
# One line per call: the leading flags and the trailing arguments (the
# script body passed to bash -c is left out).
printf 'sudo %s %s %s ... %s\n' "\$1" "\$2" "\$3" "\${*: -6}" >> "$MOCK_HTTP/sudo-calls"
[[ "\$1" == -- ]] && shift
exec "\$@"
EOF
    chmod +x "$FAKEBIN/sudo"
}

_key() { printf '%s' "${1#https://}" | sed 's/[^A-Za-z0-9._-]/_/g'; }

# serve <url> <code> [body_file] [headers_text]
serve() {
    local k; k="$(_key "$1")"
    echo "$2" > "$MOCK_HTTP/$k.code"
    [[ -n "${3:-}" ]] && cp "$3" "$MOCK_HTTP/$k.body"
    [[ -n "${4:-}" ]] && printf '%s' "$4" > "$MOCK_HTTP/$k.hdr"
    return 0
}

API="https://api.github.com/repos/Ti8an/CrypTar/releases/latest"
src_url() { echo "https://github.com/Ti8an/CrypTar/archive/refs/tags/v$1.tar.gz"; }
dl_url()  { echo "https://github.com/Ti8an/CrypTar/releases/download/v$1/$2"; }

# serve_latest <ver> [draft] [prerelease]
serve_latest() {
    printf '{"tag_name":"v%s","draft":%s,"prerelease":%s,"tarball_url":"https://evil.example/x"}' \
        "$1" "${2:-false}" "${3:-false}" > "$BATS_TEST_TMPDIR/latest.json"
    serve "$API" 200 "$BATS_TEST_TMPDIR/latest.json"
}

# make_release <ver> [mutator] — tarball at $REL_TGZ from the working tree.
make_release() {
    local ver="$1" root="$BATS_TEST_TMPDIR/rel"
    rm -rf "$root"
    mkdir -p "$root/cryptar-$ver"
    cp -R "$REPO/crypTar" "$REPO/src" "$REPO/install.sh" "$root/cryptar-$ver/"
    echo "$ver" > "$root/cryptar-$ver/VERSION"
    [[ -n "${2:-}" ]] && "$2" "$root/cryptar-$ver"
    REL_TGZ="$BATS_TEST_TMPDIR/cryptar-$ver.tar.gz"
    tar -czf "$REL_TGZ" -C "$root" "cryptar-$ver"
}

# Publish a release in "source archive" mode (no signed artifacts).
publish_source() {
    make_release "$1" "${2:-}"
    serve_latest "$1"
    serve "$(src_url "$1")" 200 "$REL_TGZ"
}

# Publish signed artifacts; signer = pinned | stranger.
publish_signed() {
    local ver="$1" signer="${2:-pinned}" d="$BATS_TEST_TMPDIR/signed"
    make_release "$ver"
    serve_latest "$ver"
    rm -rf "$d"; mkdir -p "$d"
    cp "$REL_TGZ" "$d/cryptar-$ver.tar.gz"
    ( cd "$d" && sha256sum "cryptar-$ver.tar.gz" > SHA256SUMS )
    GNUPGHOME="$_UPD_SIGN_HOME" gpg --batch --quiet --armor --detach-sign \
        --local-user "$signer@cryptar.local" --output "$d/SHA256SUMS.asc" "$d/SHA256SUMS"
    serve "$(dl_url "$ver" SHA256SUMS)" 200 "$d/SHA256SUMS"
    serve "$(dl_url "$ver" SHA256SUMS.asc)" 200 "$d/SHA256SUMS.asc"
    serve "$(dl_url "$ver" "cryptar-$ver.tar.gz")" 200 "$d/cryptar-$ver.tar.gz"
}

pin_key() {
    mkdir -p "$LIB_DIR/src/keys"
    GNUPGHOME="$_UPD_SIGN_HOME" gpg --batch --armor --export pinned@cryptar.local \
        > "$LIB_DIR/src/keys/release-signing-key.asc"
}

# Install the working tree as the "current" version into $HOME/.local.
install_current() {
    inst_install_tree "$REPO" "$BIN_DIR" "$LIB_DIR" >/dev/null 2>&1
}

# User data that an update must never touch.
make_user_data() {
    mkdir -p "$HOME/.config/cryptar" "$HOME/.ssh"
    echo "encrypted-servers" > "$HOME/.config/cryptar/servers.conf.gpg"
    echo "encrypted-clouds"  > "$HOME/.config/cryptar/clouds.conf.gpg"
    echo "ABCDEF0123456789"  > "$HOME/.config/cryptar/.gpg_key_id"
    mkdir -p "$GNUPGHOME/private-keys-v1.d"
    echo "secret key"        > "$GNUPGHOME/private-keys-v1.d/TEST.key"
    echo "private"           > "$HOME/.ssh/id_ed25519"
    echo 'export PATH="$PATH:/opt/x"' > "$HOME/.bashrc"
    echo "user file" > "$LIB_DIR/notes.txt"
}

snap() { ( cd "$1" && find . -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum ) | sha256sum; }
snap_user() { { snap "$HOME/.config/cryptar"; snap "$GNUPGHOME"; snap "$HOME/.ssh"; sha256sum "$HOME/.bashrc" "$LIB_DIR/notes.txt"; } | sha256sum; }
snap_install() { { snap "$LIB_DIR/src"; sha256sum "$BIN"; } | sha256sum; }

refute_grep() { if grep -q "$@"; then echo "unexpected match: $*"; return 1; fi; }

# Load the installed program's environment in-process (for stubbing functions).
load_installed() {
    SCRIPT_DIR="$BIN_DIR"
    SRC_DIR="$LIB_DIR/src"
    VERSION="$CUR_VER"
    CRYPTAR_SELF="$BIN"
    source "$SRC_DIR/utils/log.sh"
    source "$SRC_DIR/utils/ui.sh"
    source "$SRC_DIR/commands/update.sh"
}

# ══ SemVer ════════════════════════════════════════════════════════════════════

@test "semver: precedence rules incl. the project's -N release counter" {
    load_installed_semver() { SRC_DIR="$REPO/src"; source "$REPO/src/utils/log.sh"; source "$REPO/src/commands/update.sh"; }
    load_installed_semver
    [ "$(upd_semver_cmp 1.3.1-4 1.3.1-4)" = 0 ]
    [ "$(upd_semver_cmp 1.3.1-5 1.3.1-4)" = 1 ]
    [ "$(upd_semver_cmp 1.4.0-5 1.3.1-4)" = 1 ]
    [ "$(upd_semver_cmp 1.2.1-3 1.3.1-4)" = -1 ]
    [ "$(upd_semver_cmp 1.10.0 1.9.0)" = 1 ]
    [ "$(upd_semver_cmp 1.0.0-10 1.0.0-9)" = 1 ]
    [ "$(upd_semver_cmp 1.0.0 1.0.0-alpha)" = 1 ]
    [ "$(upd_semver_cmp 1.0.0-alpha 1.0.0-alpha.1)" = -1 ]
    [ "$(upd_semver_cmp 1.0.0-1 1.0.0-alpha)" = -1 ]
    [ "$(upd_semver_cmp 1.0.0+build.2 1.0.0+build.1)" = 0 ]
    [ "$(upd_semver_cmp 2.0.0 10.0.0)" = -1 ]
}

@test "semver: validation rejects malformed versions" {
    inst_is_semver 1.3.1-4
    inst_is_semver 1.0.0-rc.1+sha.abc
    ! inst_is_semver 1.3
    ! inst_is_semver 01.2.3
    ! inst_is_semver v1.2.3
    ! inst_is_semver '1.2.3; rm -rf /'
    ! inst_is_semver 1.2.3-
}

# ══ --check-update ════════════════════════════════════════════════════════════

@test "check-update: reports available update and changes nothing" {
    install_current
    serve_latest 9.9.9
    local before; before="$(snap_install)"
    run "$BIN" --check-update
    [ "$status" -eq 0 ]
    [[ "$output" == *"Установленная версия: $CUR_VER"* ]]
    [[ "$output" == *"Доступно обновление: $CUR_VER → 9.9.9"* ]]
    [ "$(snap_install)" = "$before" ]
    # Only the metadata endpoint was queried — no download.
    [ "$(wc -l < "$MOCK_HTTP/requests")" -eq 1 ]
    grep -qxF "$API" "$MOCK_HTTP/requests"
}

@test "check-update: up to date" {
    install_current
    serve_latest "$CUR_VER"
    run "$BIN" --check-update
    [ "$status" -eq 0 ]
    [[ "$output" == *"Установлена последняя стабильная версия"* ]]
}

@test "check-update: network failure is reported, exit 2" {
    install_current
    MOCK_NET_DOWN=1 run "$BIN" --check-update
    [ "$status" -eq 2 ]
    [[ "$output" == *"GitHub недоступен"* ]]
}

@test "check-update: GitHub API rate limit is reported" {
    install_current
    echo '{"message":"API rate limit exceeded"}' > "$BATS_TEST_TMPDIR/rl.json"
    serve "$API" 403 "$BATS_TEST_TMPDIR/rl.json" $'x-ratelimit-remaining: 0\r\nx-ratelimit-reset: 1700000000\r\n'
    run "$BIN" --check-update
    [ "$status" -eq 2 ]
    [[ "$output" == *"лимит запросов"* ]]
}

@test "check-update: no published releases (404)" {
    install_current
    run "$BIN" --check-update
    [ "$status" -eq 1 ]
    [[ "$output" == *"нет опубликованных стабильных релизов"* ]]
}

@test "check-update: malformed metadata is rejected" {
    install_current
    echo 'not json' > "$BATS_TEST_TMPDIR/bad.json"
    serve "$API" 200 "$BATS_TEST_TMPDIR/bad.json"
    run "$BIN" --check-update
    [ "$status" -eq 1 ]
    [[ "$output" == *"Некорректные метаданные"* ]]

    printf '{"tag_name":"latest-main","draft":false,"prerelease":false}' > "$BATS_TEST_TMPDIR/bad.json"
    serve "$API" 200 "$BATS_TEST_TMPDIR/bad.json"
    run "$BIN" --check-update
    [ "$status" -eq 1 ]
    [[ "$output" == *"не соответствует SemVer"* ]]
}

@test "check-update: rejects extra arguments" {
    install_current
    run "$BIN" --check-update now
    [ "$status" -eq 1 ]
    [ ! -s "$MOCK_HTTP/requests" ]
}

# ══ --update: decision ════════════════════════════════════════════════════════

@test "update: nothing to do when already on the latest version" {
    install_current
    serve_latest "$CUR_VER"
    local before; before="$(snap_install)"
    run "$BIN" --update --yes
    [ "$status" -eq 0 ]
    [[ "$output" == *"обновление не требуется"* ]]
    [ "$(snap_install)" = "$before" ]
    [ "$(wc -l < "$MOCK_HTTP/requests")" -eq 1 ]
}

@test "update: never downgrades automatically" {
    install_current
    publish_source 1.0.0-1
    local before; before="$(snap_install)"
    run "$BIN" --update --yes
    [ "$status" -eq 0 ]
    [[ "$output" == *"понижение версии не выполняется"* ]]
    [ "$(snap_install)" = "$before" ]
    refute_grep -F "archive" "$MOCK_HTTP/requests"
}

@test "update: prerelease returned by the API is ignored" {
    install_current
    make_release 9.9.9
    serve_latest 9.9.9 false true
    serve "$(src_url 9.9.9)" 200 "$REL_TGZ"
    local before; before="$(snap_install)"
    run "$BIN" --update --yes
    [ "$status" -ne 0 ]
    [[ "$output" == *"не является стабильным"* ]]
    [ "$(snap_install)" = "$before" ]
    refute_grep -F "archive" "$MOCK_HTTP/requests"
}

@test "update: draft returned by the API is ignored" {
    install_current
    serve_latest 9.9.9 true false
    run "$BIN" --check-update
    [ "$status" -ne 0 ]
    [[ "$output" == *"не является стабильным"* ]]
}

@test "update: only /releases/latest is used, never a branch" {
    install_current
    publish_source 9.9.9
    run "$BIN" --update --yes
    [ "$status" -eq 0 ]
    refute_grep -E "/(main|master|heads)/|zipball|tarball|evil" "$MOCK_HTTP/requests"
}

@test "update: requires --yes without a terminal" {
    install_current
    publish_source 9.9.9
    local before; before="$(snap_install)"
    run "$BIN" --update </dev/null
    [ "$status" -eq 1 ]
    [[ "$output" == *"--update --yes"* ]]
    [ "$(snap_install)" = "$before" ]
}

@test "update: unknown option is rejected before any request" {
    install_current
    run "$BIN" --update --force
    [ "$status" -eq 1 ]
    [ ! -s "$MOCK_HTTP/requests" ]
}

@test "update: refuses to run from a repository working copy" {
    run "$REPO/crypTar" --update --yes
    [ "$status" -eq 1 ]
    [[ "$output" == *"рабочей копии"* ]]
    [ ! -s "$MOCK_HTTP/requests" ]
}

# ══ --update: success path ════════════════════════════════════════════════════

@test "update: user installation is updated without sudo, data preserved" {
    install_current
    make_user_data
    _write_fake_sudo
    publish_source 9.9.9
    local user_before; user_before="$(snap_user)"

    run "$BIN" --update --yes
    [ "$status" -eq 0 ]
    [[ "$output" == *"CrypTar обновлён: $CUR_VER → 9.9.9"* ]]
    run "$BIN" --version
    [ "$output" = "CrypTar v9.9.9" ]
    grep -qxF "SRC_DIR=\"$LIB_DIR/src\"" "$BIN"

    [ "$(snap_user)" = "$user_before" ]
    [ ! -e "$MOCK_HTTP/sudo-calls" ]
    # No staging/backup leftovers, temp dir cleaned.
    [ -z "$(find "$LIB_DIR" "$BIN_DIR" -maxdepth 1 -name '.*' ! -name . -print)" ]
    [ -z "$(ls -A "$TMPDIR")" ]
}

@test "update: works without git (release archives only)" {
    install_current
    publish_source 9.9.9
    run "$BIN" --update --yes
    [ "$status" -eq 0 ]
    [ ! -e "$MOCK_HTTP/git-calls" ]
}

@test "update: installed files get regular permissions" {
    install_current
    publish_source 9.9.9
    run "$BIN" --update --yes
    [ "$status" -eq 0 ]
    [ -x "$BIN" ]
    [ -z "$(find "$LIB_DIR/src" ! -type f ! -type d)" ]
}

@test "update: existing commands keep working after update" {
    install_current
    publish_source 9.9.9
    run "$BIN" --update --yes
    [ "$status" -eq 0 ]
    run "$BIN" --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"--update"* ]]
    [[ "$output" == *"--check-update"* ]]
    run "$BIN" --server bogus
    [[ "$output" != *"command not found"* ]]
}

# ══ --update: failures leave the installation intact ══════════════════════════

@test "update: network failure during download keeps the installed version" {
    install_current
    make_release 9.9.9
    serve_latest 9.9.9
    echo 7 > "$MOCK_HTTP/$(_key "$(src_url 9.9.9)").rc"
    local before; before="$(snap_install)"
    run "$BIN" --update --yes
    [ "$status" -eq 2 ]
    [[ "$output" == *"не удалось подключиться"* ]]
    [ "$(snap_install)" = "$before" ]
    [ -z "$(ls -A "$TMPDIR")" ]
}

@test "update: HTTP error during download keeps the installed version" {
    install_current
    serve_latest 9.9.9
    serve "$(src_url 9.9.9)" 502
    local before; before="$(snap_install)"
    run "$BIN" --update --yes
    [ "$status" -ne 0 ]
    [[ "$output" == *"HTTP 502"* ]]
    [ "$(snap_install)" = "$before" ]
}

@test "update: corrupted archive is not installed" {
    install_current
    serve_latest 9.9.9
    head -c 4096 /dev/urandom > "$BATS_TEST_TMPDIR/garbage"
    serve "$(src_url 9.9.9)" 200 "$BATS_TEST_TMPDIR/garbage"
    local before; before="$(snap_install)"
    run "$BIN" --update --yes
    [ "$status" -eq 1 ]
    [[ "$output" == *"повреждён"* ]]
    [ "$(snap_install)" = "$before" ]
}

@test "update: archive without the project layout is not installed" {
    install_current
    _drop_lib() { rm -rf "$1/src/lib"; }
    publish_source 9.9.9 _drop_lib
    local before; before="$(snap_install)"
    run "$BIN" --update --yes
    [ "$status" -eq 1 ]
    [[ "$output" == *"Неверная структура релиза"* ]]
    [ "$(snap_install)" = "$before" ]
}

@test "update: archive with a symlink is not installed" {
    install_current
    _add_link() { ln -s "$1/VERSION" "$1/src/lib/evil.sh" 2>/dev/null || true; }
    publish_source 9.9.9 _add_link
    if ! tar -tvzf "$REL_TGZ" | grep -q '^l'; then skip "platform tar does not store symlinks"; fi
    local before; before="$(snap_install)"
    run "$BIN" --update --yes
    [ "$status" -eq 1 ]
    [[ "$output" == *"ссылки или специальные файлы"* ]]
    [ "$(snap_install)" = "$before" ]
}

@test "update: archive with absolute paths is not installed" {
    install_current
    serve_latest 9.9.9
    mkdir -p "$BATS_TEST_TMPDIR/abs"
    echo x > "$BATS_TEST_TMPDIR/abs/evil"
    tar -czPf "$BATS_TEST_TMPDIR/abs.tgz" "$BATS_TEST_TMPDIR/abs/evil"
    tar -tzf "$BATS_TEST_TMPDIR/abs.tgz" | grep -q '^/' || skip "platform tar strips leading /"
    serve "$(src_url 9.9.9)" 200 "$BATS_TEST_TMPDIR/abs.tgz"
    local before; before="$(snap_install)"
    run "$BIN" --update --yes
    [ "$status" -eq 1 ]
    [[ "$output" == *"недопустимый путь"* ]]
    [ "$(snap_install)" = "$before" ]
}

@test "update: archive version different from the release tag is rejected" {
    install_current
    make_release 9.9.8
    serve_latest 9.9.9
    serve "$(src_url 9.9.9)" 200 "$REL_TGZ"
    local before; before="$(snap_install)"
    run "$BIN" --update --yes
    [ "$status" -eq 1 ]
    [[ "$output" == *"Версия в архиве (9.9.8) не совпадает с ожидаемой (9.9.9)"* ]]
    [ "$(snap_install)" = "$before" ]
}

@test "update: failed post-install verification rolls back to the previous version" {
    install_current
    make_user_data
    _break_version() { sed -i 's|--version) echo "CrypTar v$VERSION"|--version) echo "CrypTar vBROKEN"|' "$1/crypTar"; }
    publish_source 9.9.9 _break_version
    grep -q 'vBROKEN' "$BATS_TEST_TMPDIR/rel/cryptar-9.9.9/crypTar"
    local before user_before
    before="$(snap_install)"; user_before="$(snap_user)"
    run "$BIN" --update --yes
    [ "$status" -eq 1 ]
    [[ "$output" == *"Предыдущая версия восстановлена"* ]]
    [ "$(snap_install)" = "$before" ]
    [ "$(snap_user)" = "$user_before" ]
    run "$BIN" --version
    [ "$output" = "CrypTar v$CUR_VER" ]
    [ -z "$(find "$LIB_DIR" "$BIN_DIR" -maxdepth 1 -name '.*' ! -name . -print)" ]
}

@test "update: release with a shell syntax error is not installed" {
    install_current
    _syntax() { printf 'if then fi {\n' >> "$1/src/utils/log.sh"; }
    publish_source 9.9.9 _syntax
    local before; before="$(snap_install)"
    run "$BIN" --update --yes
    [ "$status" -eq 1 ]
    [[ "$output" == *"Синтаксическая ошибка"* ]]
    [ "$(snap_install)" = "$before" ]
}

# ══ Permissions ═══════════════════════════════════════════════════════════════

@test "permissions: system install uses sudo only for the install step" {
    install_current
    _write_fake_sudo
    publish_source 9.9.9
    load_installed
    _upd_can_write() { return 1; }   # simulate root-owned /usr/local
    [ "${EUID}" -ne 0 ] || skip "must run as non-root"

    run cmd_update --yes
    [ "$status" -eq 0 ]
    [[ "$output" == *"потребуются права администратора"* ]]
    [ "$(wc -l < "$MOCK_HTTP/sudo-calls")" -eq 1 ]
    grep -qF "sudo -- bash -c " "$MOCK_HTTP/sudo-calls"
    grep -qF "core.sh install-tree " "$MOCK_HTTP/sudo-calls"
    grep -qF " $BIN_DIR $LIB_DIR 9.9.9" "$MOCK_HTTP/sudo-calls"
    run "$BIN" --version
    [ "$output" = "CrypTar v9.9.9" ]
}

@test "permissions: system install without sudo fails cleanly before download" {
    install_current
    publish_source 9.9.9
    load_installed
    _upd_can_write() { return 1; }
    [ "${EUID}" -ne 0 ] || skip "must run as non-root"
    _upd_have_sudo() { return 1; }
    local before; before="$(snap_install)"
    run cmd_update --yes
    [ "$status" -eq 3 ]
    [[ "$output" == *"sudo не найден"* ]]
    [ "$(snap_install)" = "$before" ]
    refute_grep -F "archive" "$MOCK_HTTP/requests"
}

@test "permissions: failing sudo leaves the installation intact" {
    install_current
    publish_source 9.9.9
    printf '#!/usr/bin/env bash\necho "sudo: a password is required" >&2\nexit 1\n' > "$FAKEBIN/sudo"
    chmod +x "$FAKEBIN/sudo"
    load_installed
    _upd_can_write() { return 1; }
    [ "${EUID}" -ne 0 ] || skip "must run as non-root"
    local before; before="$(snap_install)"
    run cmd_update --yes
    [ "$status" -eq 1 ]
    [[ "$output" == *"оставлена без изменений"* ]]
    [ "$(snap_install)" = "$before" ]
    [ -z "$(ls -A "$TMPDIR")" ]
}

@test "permissions: core refuses an unwritable target" {
    mkdir -p "$BATS_TEST_TMPDIR/ro/bin" "$BATS_TEST_TMPDIR/ro/cryptar"
    chmod 555 "$BATS_TEST_TMPDIR/ro/bin"
    if [[ -w "$BATS_TEST_TMPDIR/ro/bin" ]]; then
        chmod 755 "$BATS_TEST_TMPDIR/ro/bin"
        skip "chmod does not restrict writes on this platform"
    fi
    run inst_install_tree "$REPO" "$BATS_TEST_TMPDIR/ro/bin" "$BATS_TEST_TMPDIR/ro/cryptar"
    chmod 755 "$BATS_TEST_TMPDIR/ro/bin"
    [ "$status" -eq 1 ]
    [[ "$output" == *"Нет прав на запись"* ]]
    [ ! -e "$BATS_TEST_TMPDIR/ro/bin/crypTar" ]
}

# ══ Signed release artifacts ══════════════════════════════════════════════════

@test "signed: valid signature by the pinned key is accepted" {
    install_current
    pin_key
    publish_signed 9.9.9 pinned
    local keyring_before; keyring_before="$(snap "$GNUPGHOME")"
    run "$BIN" --update --yes
    [ "$status" -eq 0 ]
    [[ "$output" == *"Подпись манифеста релиза проверена"* ]]
    [[ "$output" == *"Контрольная сумма архива совпадает"* ]]
    run "$BIN" --version
    [ "$output" = "CrypTar v9.9.9" ]
    # The user's keyring was not touched.
    [ "$(snap "$GNUPGHOME")" = "$keyring_before" ]
}

@test "signed: signature by another key is rejected" {
    install_current
    pin_key
    publish_signed 9.9.9 stranger
    local before; before="$(snap_install)"
    run "$BIN" --update --yes
    [ "$status" -eq 1 ]
    [[ "$output" == *"Подпись релиза недействительна"* ]]
    [ "$(snap_install)" = "$before" ]
}

@test "signed: tampered archive fails the checksum" {
    install_current
    pin_key
    publish_signed 9.9.9 pinned
    _evil() { echo '# tampered' >> "$1/src/utils/log.sh"; }
    make_release 9.9.9 _evil
    serve "$(dl_url 9.9.9 cryptar-9.9.9.tar.gz)" 200 "$REL_TGZ"
    local before; before="$(snap_install)"
    run "$BIN" --update --yes
    [ "$status" -eq 1 ]
    [[ "$output" == *"Контрольная сумма"*"не совпадает"* ]]
    [ "$(snap_install)" = "$before" ]
}

@test "signed: pinned key makes unsigned releases unacceptable" {
    install_current
    pin_key
    publish_source 9.9.9
    local before; before="$(snap_install)"
    run "$BIN" --update --yes
    [ "$status" -eq 1 ]
    [[ "$output" == *"требует подпись"* ]]
    [ "$(snap_install)" = "$before" ]
    refute_grep -F "/archive/" "$MOCK_HTTP/requests"
}

@test "signed: manifest without signature is refused when a key is pinned" {
    install_current
    pin_key
    publish_signed 9.9.9 pinned
    rm -f "$MOCK_HTTP/$(_key "$(dl_url 9.9.9 SHA256SUMS.asc)")".*
    run "$BIN" --update --yes
    [ "$status" -eq 1 ]
    [[ "$output" == *"не содержит подписи"* ]]
}

# ══ install.sh ════════════════════════════════════════════════════════════════

_run_installer() {
    # Stub everything install.sh might try to install system-wide.
    printf '#!/usr/bin/env bash\necho "sudo $*" >> "%s/sudo-calls"\nexit 0\n' "$MOCK_HTTP" > "$FAKEBIN/sudo"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$FAKEBIN/sshpass"
    chmod +x "$FAKEBIN/sudo" "$FAKEBIN/sshpass"
    PATH="$FAKEBIN:$PATH" bash "$REPO/install.sh" </dev/null
}

@test "install.sh: re-running keeps user data and does not duplicate PATH lines" {
    [ "${EUID}" -ne 0 ] || skip "must run as non-root"
    echo "# rc" > "$HOME/.bashrc"
    echo "# rc" > "$HOME/.zshrc"
    run _run_installer
    [ "$status" -eq 0 ]
    [ "$("$BIN" --version)" = "CrypTar v$CUR_VER" ]
    make_user_data
    echo "# rc" > "$HOME/.bashrc"
    echo "export PATH=\"\$PATH:$BIN_DIR\"" >> "$HOME/.bashrc"
    local user_before; user_before="$(snap_user)"
    local zsh_before; zsh_before="$(cat "$HOME/.zshrc")"

    run _run_installer
    [ "$status" -eq 0 ]
    [ "$(snap_user)" = "$user_before" ]
    [ "$(cat "$HOME/.zshrc")" = "$zsh_before" ]
    [ "$(grep -c "$BIN_DIR" "$HOME/.zshrc")" -eq 1 ]
    [ "$("$BIN" --version)" = "CrypTar v$CUR_VER" ]
}

@test "install.sh: never generates GPG keys non-interactively" {
    [ "${EUID}" -ne 0 ] || skip "must run as non-root"
    run _run_installer
    [ "$status" -eq 0 ]
    [[ "$output" == *"GPG-ключи не найдены"* ]]
    [ -z "$(gpg --list-secret-keys --with-colons 2>/dev/null)" ]
}

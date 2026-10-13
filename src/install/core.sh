#!/usr/bin/env bash
# src/install/core.sh — shared install core for install.sh and crypTar --update.
#
# Installs a prepared source tree (crypTar, VERSION, src/) into
#   <bin_dir>/crypTar        — the entry point with VERSION and SRC_DIR baked in
#   <lib_dir>/src/           — the library
# without touching anything else: ~/.config/cryptar, GPG/SSH keys, shell rc
# files and other files in <lib_dir> are never read or modified.
#
# Procedure: copy the tree into a private staging dir next to the target
# (same filesystem → rename), validate the STAGED copy (layout, version,
# file types, bash -n), then swap src/ and rename the new entry point over the
# old one, run `crypTar --version` and roll back on any failure or signal.
#
# Usable both as a library (`source`) and as a script — the latter is how
# `crypTar --update` runs the privileged step through sudo:
#   bash core.sh install-tree <tree> <bin_dir> <lib_dir> [expected_version]
#   bash -c "$(cat core.sh)" core.sh install-tree …   (what --update runs)

[[ -n "${_INST_CORE_LOADED:-}" ]] && return 0
_INST_CORE_LOADED=1

# SemVer 2.0.0 (https://semver.org), optional leading "v" NOT included.
readonly INST_SEMVER_RE='^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-((0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*)(\.(0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*))*))?(\+[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?$'

# Files every release must contain (present in all published releases).
readonly -a INST_REQUIRED_FILES=(
    crypTar VERSION
    src/utils/log.sh src/utils/ui.sh
    src/lib/config.sh
    src/commands/encrypt.sh src/commands/decrypt.sh src/commands/send.sh
)

# The two lines of crypTar that installation rewrites.
readonly INST_LINE_VERSION='VERSION="$(cat "$SCRIPT_DIR/VERSION")"'
readonly INST_LINE_SRC='SRC_DIR="$SCRIPT_DIR/src"'

_inst_err() { printf '❌ %s\n' "$*" >&2; }

inst_is_semver() { [[ "$1" =~ $INST_SEMVER_RE ]]; }

# inst_default_paths — sets INST_BIN_DIR / INST_LIB_DIR for the current user.
inst_default_paths() {
    if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
        INST_BIN_DIR="/usr/local/bin"
        INST_LIB_DIR="/usr/local/lib/cryptar"
    else
        INST_BIN_DIR="$HOME/.local/bin"
        INST_LIB_DIR="$HOME/.local/lib/cryptar"
    fi
}

# A path is baked into a double-quoted assignment and used as a sed
# replacement: refuse characters that would break either.
_inst_safe_path() {
    local p="$1"
    [[ "$p" == /* && "$p" != *$'\n'* ]] || return 1
    [[ "$p" != *[\"\$\`\\\|\&]* ]]
}

# inst_check_tree <dir> [expected_version] — validate a source tree and echo
# its version. Rejects missing files, symlinks/special files, an unexpected
# version and an entry point whose install lines cannot be rewritten.
inst_check_tree() {
    local dir="$1" expected="${2:-}" f ver bad

    [[ -d "$dir" && ! -L "$dir" ]] || { _inst_err "Каталог с исходниками не найден: $dir"; return 1; }
    for f in "${INST_REQUIRED_FILES[@]}"; do
        if [[ ! -f "$dir/$f" || -L "$dir/$f" ]]; then
            _inst_err "Неверная структура релиза: нет файла $f"
            return 1
        fi
    done
    [[ ! -L "$dir/src" ]] || { _inst_err "Неверная структура релиза: src/ — символическая ссылка"; return 1; }
    bad="$(find "$dir/src" ! -type f ! -type d -print -quit 2>/dev/null)"
    if [[ -n "$bad" ]]; then
        _inst_err "Релиз содержит недопустимый файл (ссылка или спецфайл): ${bad#"$dir"/}"
        return 1
    fi

    IFS= read -r ver < "$dir/VERSION" || true
    ver="${ver%$'\r'}"
    inst_is_semver "$ver" || { _inst_err "Некорректная версия в файле VERSION: '$ver'"; return 1; }
    if [[ -n "$expected" && "$ver" != "$expected" ]]; then
        _inst_err "Версия в архиве ($ver) не совпадает с ожидаемой ($expected)"
        return 1
    fi

    if ! grep -qxF -- "$INST_LINE_VERSION" "$dir/crypTar" \
       || ! grep -qxF -- "$INST_LINE_SRC" "$dir/crypTar"; then
        _inst_err "Неверная структура релиза: crypTar не содержит ожидаемых строк VERSION/SRC_DIR"
        return 1
    fi
    printf '%s\n' "$ver"
}

# inst_render_bin <crypTar_src> <version> <lib_dir> <out> — bake VERSION and
# SRC_DIR into the entry point and verify both substitutions took place.
inst_render_bin() {
    local src="$1" ver="$2" lib_dir="$3" out="$4"
    inst_is_semver "$ver" || return 1
    _inst_safe_path "$lib_dir" || { _inst_err "Недопустимый путь установки: $lib_dir"; return 1; }
    sed \
        -e "s|^VERSION=\"\$(cat \"\$SCRIPT_DIR/VERSION\")\"\$|VERSION=\"$ver\"|" \
        -e "s|^SRC_DIR=\"\$SCRIPT_DIR/src\"\$|SRC_DIR=\"$lib_dir/src\"|" \
        "$src" > "$out" || return 1
    grep -qxF -- "VERSION=\"$ver\"" "$out" && grep -qxF -- "SRC_DIR=\"$lib_dir/src\"" "$out" \
        || { _inst_err "Не удалось подготовить исполняемый файл crypTar"; return 1; }
}

# Syntax-check every shell file of a staged tree without executing it.
_inst_syntax_check() {
    local root="$1" f
    while IFS= read -r -d '' f; do
        bash -n "$f" 2>/dev/null || { _inst_err "Синтаксическая ошибка в ${f#"$root"/}"; return 1; }
    done < <(find "$root" -type f \( -name '*.sh' -o -name crypTar \) -print0)
}

# ── install state (for rollback) ──────────────────────────────────────────────
_INST_STAGE="" _INST_NEW_BIN="" _INST_SRC_BAK="" _INST_BIN_BAK=""
_INST_BIN="" _INST_SRCDIR="" _INST_PHASE=""

# Undo a partially applied install. Phase: src-moved → src-swapped → bin-swapped.
_inst_rollback() {
    case "$_INST_PHASE" in
        bin-swapped)
            if [[ -n "$_INST_BIN_BAK" && -f "$_INST_BIN_BAK" ]]; then
                mv -f -- "$_INST_BIN_BAK" "$_INST_BIN" && _INST_BIN_BAK=""
            else
                rm -f -- "$_INST_BIN"   # there was no previous entry point
            fi
            ;&
        src-swapped)
            [[ -n "$_INST_SRC_BAK" && -d "$_INST_SRC_BAK" ]] && rm -rf -- "$_INST_SRCDIR"
            ;&
        src-moved)
            if [[ -n "$_INST_SRC_BAK" && -d "$_INST_SRC_BAK" ]]; then
                mv -- "$_INST_SRC_BAK" "$_INST_SRCDIR" && _INST_SRC_BAK=""
            fi
            ;;
    esac
    _INST_PHASE=""
}

_inst_cleanup() {
    [[ -n "$_INST_STAGE"   ]] && rm -rf -- "$_INST_STAGE"
    [[ -n "$_INST_NEW_BIN" ]] && rm -f  -- "$_INST_NEW_BIN"
    [[ -n "$_INST_SRC_BAK" ]] && rm -rf -- "$_INST_SRC_BAK"
    [[ -n "$_INST_BIN_BAK" ]] && rm -f  -- "$_INST_BIN_BAK"
    _INST_STAGE="" _INST_NEW_BIN="" _INST_SRC_BAK="" _INST_BIN_BAK=""
}

_inst_on_signal() {
    trap - INT TERM HUP
    _inst_err "Установка прервана — восстанавливаем предыдущую версию"
    _inst_rollback
    _inst_cleanup
    exit 130
}

# inst_install_tree <tree> <bin_dir> <lib_dir> [expected_version]
# Returns 0 on success; on failure the previous installation is restored and
# 1 is returned. Echoes nothing on stdout.
inst_install_tree() {
    local tree="$1" bin_dir="$2" lib_dir="$3" expected="${4:-}"
    local ver rc=0 out

    _inst_safe_path "$bin_dir" && _inst_safe_path "$lib_dir" \
        || { _inst_err "Недопустимый путь установки"; return 1; }
    [[ "${lib_dir##*/}" == cryptar ]] \
        || { _inst_err "Каталог библиотеки должен называться 'cryptar': $lib_dir"; return 1; }

    mkdir -p -- "$bin_dir" "$lib_dir" 2>/dev/null \
        || { _inst_err "Нет прав на создание $bin_dir или $lib_dir"; return 1; }
    [[ -w "$bin_dir" && -w "$lib_dir" ]] \
        || { _inst_err "Нет прав на запись в $bin_dir или $lib_dir"; return 1; }
    [[ ! -e "$lib_dir/src" || -w "$lib_dir/src" ]] \
        || { _inst_err "Нет прав на запись в $lib_dir/src"; return 1; }

    _INST_BIN="$bin_dir/crypTar"
    _INST_SRCDIR="$lib_dir/src"
    [[ ! -L "$_INST_SRCDIR" ]] || { _inst_err "$_INST_SRCDIR — символическая ссылка, установка отменена"; return 1; }
    local saved_traps
    saved_traps="$(trap -p INT TERM HUP)"
    trap _inst_on_signal INT TERM HUP

    # 1. Stage a private copy next to the target and validate the copy itself,
    #    so later changes to <tree> cannot affect what gets installed.
    if ! _INST_STAGE="$(mktemp -d "$lib_dir/.stage.XXXXXX")" \
       || ! cp -R -- "$tree/crypTar" "$tree/VERSION" "$tree/src" "$_INST_STAGE/" 2>/dev/null; then
        _inst_err "Не удалось подготовить файлы в $lib_dir"
        rc=1
    fi
    if (( rc == 0 )); then
        find "$_INST_STAGE" -type d -exec chmod 755 {} + \
            && find "$_INST_STAGE" -type f -exec chmod 644 {} + || rc=1
    fi
    (( rc == 0 )) && { ver="$(inst_check_tree "$_INST_STAGE" "$expected")" || rc=1; }
    (( rc == 0 )) && { _inst_syntax_check "$_INST_STAGE" || rc=1; }

    # 2. Render the entry point next to its final location (same dir → rename).
    if (( rc == 0 )); then
        if _INST_NEW_BIN="$(mktemp "$bin_dir/.crypTar.new.XXXXXX")" \
           && inst_render_bin "$_INST_STAGE/crypTar" "$ver" "$lib_dir" "$_INST_NEW_BIN" \
           && chmod 755 "$_INST_NEW_BIN"; then
            :
        else
            _inst_err "Не удалось подготовить $bin_dir/crypTar"
            rc=1
        fi
    fi

    # 3. Back up the current entry point (copy keeps the running one intact).
    if (( rc == 0 )) && [[ -e "$_INST_BIN" ]]; then
        if [[ ! -f "$_INST_BIN" ]]; then
            _inst_err "$_INST_BIN не является обычным файлом — установка отменена"
            rc=1
        elif ! _INST_BIN_BAK="$(mktemp "$bin_dir/.crypTar.old.XXXXXX")" \
             || ! cp -p -- "$_INST_BIN" "$_INST_BIN_BAK"; then
            _inst_err "Не удалось сохранить резервную копию $_INST_BIN"
            rc=1
        fi
    fi

    # 4. Swap: old src/ aside → new src/ in place → rename the entry point.
    if (( rc == 0 )) && [[ -e "$_INST_SRCDIR" ]]; then
        _INST_SRC_BAK="$lib_dir/.src.old.$$.$RANDOM"
        if mv -- "$_INST_SRCDIR" "$_INST_SRC_BAK"; then
            _INST_PHASE="src-moved"
        else
            _INST_SRC_BAK=""
            _inst_err "Не удалось переместить $_INST_SRCDIR"
            rc=1
        fi
    fi
    if (( rc == 0 )); then
        if mv -- "$_INST_STAGE/src" "$_INST_SRCDIR"; then
            _INST_PHASE="src-swapped"
        else
            _inst_err "Не удалось установить новую библиотеку"
            rc=1
        fi
    fi
    if (( rc == 0 )); then
        if mv -f -- "$_INST_NEW_BIN" "$_INST_BIN"; then
            _INST_NEW_BIN="" _INST_PHASE="bin-swapped"
        else
            _inst_err "Не удалось установить $_INST_BIN"
            rc=1
        fi
    fi

    # 5. Verify the installed program reports the expected version.
    if (( rc == 0 )); then
        out="$("$_INST_BIN" --version 2>/dev/null </dev/null)" || true
        if [[ "$out" != "CrypTar v$ver" ]]; then
            _inst_err "Проверка установленной версии не прошла (получено: '${out:0:80}')"
            rc=1
        fi
    fi

    if (( rc != 0 )); then
        if [[ -n "$_INST_PHASE" ]]; then
            _inst_rollback
            _inst_err "Предыдущая версия восстановлена"
        fi
    fi
    _INST_PHASE=""
    _inst_cleanup
    trap - INT TERM HUP
    eval "$saved_traps"
    return "$rc"
}

# ── Script mode (used through sudo by crypTar --update) ───────────────────────
# (`bash core.sh …` or `bash -c "<content>" core.sh …`; never when sourced)
if [[ "${BASH_SOURCE[0]:-$0}" == "$0" ]]; then
    set -uo pipefail
    case "${1:-}" in
        install-tree)
            (( $# >= 4 && $# <= 5 )) || { _inst_err "usage: core.sh install-tree <tree> <bin_dir> <lib_dir> [version]"; exit 2; }
            inst_install_tree "$2" "$3" "$4" "${5:-}"
            exit $?
            ;;
        *)
            _inst_err "usage: core.sh install-tree <tree> <bin_dir> <lib_dir> [version]"
            exit 2
            ;;
    esac
fi

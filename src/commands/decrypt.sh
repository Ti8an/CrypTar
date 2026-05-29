#!/usr/bin/env bash
[[ -n "${_DECRYPT_LOADED:-}" ]] && return 0
_DECRYPT_LOADED=1

cmd_decrypt() {
    if [ -z "${2-}" ]; then
        log_err "Укажите файл для расшифровки: crypTar -d <file.gpg>"
        exit 1
    fi

    local ENC_FILE="$2"
    if [ ! -f "$ENC_FILE" ]; then
        log_err "Файл не найден: $ENC_FILE"
        exit 1
    fi

    if [[ "$ENC_FILE" != *.gpg ]]; then
        log_err "Неверный формат файла: ожидается расширение .gpg"
        exit 1
    fi

    log_step "Расшифровываем и распаковываем $ENC_FILE..."
    local TMP_TAR
    TMP_TAR="$(mktemp --tmpdir "crypTar.XXXXXX.tar.gz")"

    if ! gpg -d "$ENC_FILE" > "$TMP_TAR"; then
        rm -f "$TMP_TAR"
        log_err "Ошибка при расшифровке. Проверьте наличие приватного ключа."
        exit 1
    fi

    log_step "Распаковываем архив..."
    if ! tar -xzf "$TMP_TAR"; then
        rm -f "$TMP_TAR"
        log_err "Ошибка при распаковке архива."
        exit 1
    fi

    rm -f "$TMP_TAR"
    log_ok "Успешно расшифровано и распаковано."
}

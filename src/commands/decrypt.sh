#!/usr/bin/env bash

cmd_decrypt() {
    if [ -z "${2-}" ]; then
        echo "❌ Укажите файл для расшифровки: crypTar -d <file.gpg>"
        exit 1
    fi

    local ENC_FILE="$2"
    if [ ! -f "$ENC_FILE" ]; then
        echo "❌ Файл не найден: $ENC_FILE"
        exit 1
    fi

    echo "🔓 Расшифровываем и распаковываем $ENC_FILE..."
    local TMP_TAR
    TMP_TAR="$(mktemp --tmpdir "crypTar.XXXXXX.tar.gz")"

    if ! gpg -d "$ENC_FILE" > "$TMP_TAR"; then
        rm -f "$TMP_TAR"
        echo "❌ Ошибка при расшифровке. Проверьте наличие приватного ключа."
        exit 1
    fi

    echo "📦 Распаковываем архив..."
    if ! tar -xzf "$TMP_TAR"; then
        rm -f "$TMP_TAR"
        echo "❌ Ошибка при распаковке архива."
        exit 1
    fi

    rm -f "$TMP_TAR"
    echo "✅ Успешно расшифровано и распаковано."
}

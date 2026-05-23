#!/bin/bash
set -e

echo "🚀 Установка CrypTar..."

# === Проверка наличия необходимых утилит ===
for pkg in tar gpg; do
    if ! command -v $pkg &>/dev/null; then
        echo "⚙️ Устанавливаем $pkg..."
        sudo apt-get install -y $pkg
    else
        echo "✅ $pkg уже установлен."
    fi
done

# === Определяем пользователя и путь установки ===
if [ "$EUID" -eq 0 ]; then
    INSTALL_DIR="/usr/local/bin"
else
    INSTALL_DIR="$HOME/.local/bin"
    mkdir -p "$INSTALL_DIR"
fi

# === Копируем основной скрипт ===
SCRIPT_SOURCE="$(dirname "$0")/crypTar"
SCRIPT_TARGET="$INSTALL_DIR/crypTar"

echo "📦 Копируем $SCRIPT_SOURCE → $SCRIPT_TARGET"
cp "$SCRIPT_SOURCE" "$SCRIPT_TARGET"
chmod +x "$SCRIPT_TARGET"

# === Добавляем путь в PATH при необходимости ===
if [[ ":$PATH:" != *":$INSTALL_DIR:"* ]]; then
    echo "📂 Добавляем $INSTALL_DIR в PATH..."
    echo "export PATH=\"\$PATH:$INSTALL_DIR\"" >> "$HOME/.bashrc"
    export PATH="$PATH:$INSTALL_DIR"
fi

# === Специальный случай для root ===
if [ "$EUID" -eq 0 ]; then
    if [ -d "/root/.local/bin" ] && [[ ":$PATH:" != *":/root/.local/bin:"* ]]; then
        echo "📂 Добавляем /root/.local/bin в PATH..."
        echo 'export PATH=$PATH:/root/.local/bin' >> /root/.bashrc
        export PATH=$PATH:/root/.local/bin
    fi
fi

# === Проверка наличия GPG-ключей ===
echo
echo "🔍 Проверяем наличие GPG-ключей..."

# Извлекаем пары: KEY_ID | USER_ID
IFS=$'\n' read -r -d '' -a KEYS < <(gpg --list-keys --with-colons 2>/dev/null | awk -F: '
    /^pub/ { key=$5 }
    /^uid/ { uid=$10; print key "|" uid }
' && printf '\0')

if [ ${#KEYS[@]} -eq 0 ]; then
    echo "🔐 GPG-ключи не найдены!"
    read -p "Хотите создать новый ключ для шифрования архивов? (y/n): " CREATE_KEY
    if [[ "$CREATE_KEY" =~ ^[Yy]$ ]]; then
        echo "⚙️ Создание нового GPG-ключа..."
        gpg --full-generate-key
        echo "✅ Ключ успешно создан!"
    else
        echo "⚠️ Без ключей CrypTar не сможет выполнять шифрование."
    fi
else
    echo "🔑 Найдены следующие GPG-ключи:"
    for i in "${!KEYS[@]}"; do
        KEY_ID="$(echo "${KEYS[$i]}" | cut -d'|' -f1)"
        USER_ID="$(echo "${KEYS[$i]}" | cut -d'|' -f2)"
        echo "[$i] $KEY_ID ($USER_ID)"
    done
fi


echo
echo "✅ Установка завершена!"
echo "Теперь можно использовать CrypTar так:"
echo "👉 crypTar /путь/к/папке_или_файлу"

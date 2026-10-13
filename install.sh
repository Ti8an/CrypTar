#!/bin/bash
set -e

echo "🚀 Установка CrypTar..."

# === Проверка наличия необходимых утилит ===

_apt_pkg() {
    local cmd="$1" pkg="${2:-$1}"
    if ! command -v "$cmd" &>/dev/null; then
        echo "⚙️ Устанавливаем $pkg..."
        sudo apt-get install -y "$pkg"
    else
        echo "✅ $cmd уже установлен."
    fi
}

_apt_pkg tar
_apt_pkg gpg gnupg
_apt_pkg ssh openssh-client
# Облачные команды (--cloud): HTTP-клиент и разбор JSON
_apt_pkg curl
_apt_pkg jq

if ! command -v sshpass &>/dev/null; then
    echo "⚙️ Устанавливаем sshpass..."
    echo "⚠️  ПРЕДУПРЕЖДЕНИЕ: sshpass передаёт пароль через переменную среды."
    echo "   Используйте аутентификацию по ключу там, где это возможно."
    sudo apt-get install -y sshpass
else
    echo "✅ sshpass уже установлен."
fi

# === Определяем пользователя и путь установки ===
REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=src/install/core.sh
source "$REPO_DIR/src/install/core.sh"
inst_default_paths
INSTALL_DIR="$INST_BIN_DIR"
LIB_DIR="$INST_LIB_DIR"

# === Создаём каталог конфигурации (существующий не изменяется) ===
if [[ ! -d "$HOME/.config/cryptar" ]]; then
    echo "📂 Создаём $HOME/.config/cryptar/ (700)..."
    mkdir -p "$HOME/.config/cryptar"
    chmod 700 "$HOME/.config/cryptar"
fi

# === Устанавливаем crypTar и src/ ===
# Общее ядро с crypTar --update: подготовка во временном каталоге, проверка,
# замена только $LIB_DIR/src и $INSTALL_DIR/crypTar, откат при ошибке.
echo "📦 Устанавливаем $INSTALL_DIR/crypTar и $LIB_DIR/src/"
if ! inst_install_tree "$REPO_DIR" "$INSTALL_DIR" "$LIB_DIR"; then
    echo "❌ Установка не выполнена."
    exit 1
fi
echo "✅ Установлена версия $(cat "$REPO_DIR/VERSION")"

# === Добавляем путь в PATH при необходимости (без повторов) ===
_add_to_path() {
    local rc_file="$1" dir="$2"
    local line="export PATH=\"\$PATH:$dir\""
    [[ -f "$rc_file" ]] || return 0
    # Any uncommented PATH assignment already mentioning the dir counts —
    # covers lines written by older installers in other quoting styles.
    if awk -v d="$dir" '!/^[[:space:]]*#/ && /PATH=/ && index($0, d) { found=1 } END { exit !found }' \
           "$rc_file" 2>/dev/null; then
        return 0
    fi
    echo "📂 Добавляем $dir в PATH ($rc_file)..."
    printf '%s\n' "$line" >> "$rc_file"
}

if [[ ":$PATH:" != *":$INSTALL_DIR:"* ]]; then
    _add_to_path "$HOME/.bashrc" "$INSTALL_DIR"
    _add_to_path "$HOME/.zshrc" "$INSTALL_DIR"
    export PATH="$PATH:$INSTALL_DIR"
fi

# === Специальный случай для root ===
if [ "$EUID" -eq 0 ] && [ -d "/root/.local/bin" ] && [[ ":$PATH:" != *":/root/.local/bin:"* ]]; then
    _add_to_path /root/.bashrc /root/.local/bin
    export PATH="$PATH:/root/.local/bin"
fi

# === Проверка наличия GPG-ключей ===
echo
echo "🔍 Проверяем наличие GPG-ключей..."

# Извлекаем пары: KEY_ID | USER_ID
IFS=$'\n' read -r -d '' -a KEYS < <(gpg --list-keys --with-colons 2>/dev/null | awk -F: '
    /^pub/ { key=$5 }
    /^uid/ { uid=$10; print key "|" uid }
' && printf '\0')

if [ ${#KEYS[@]} -eq 0 ] && [ ! -t 0 ]; then
    echo "🔐 GPG-ключи не найдены. Создайте ключ: gpg --full-generate-key"
elif [ ${#KEYS[@]} -eq 0 ]; then
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
echo "☁️  Облачные хранилища (Google Drive, Яндекс Диск): crypTar --cloud add"
echo "🔄 Обновление до последней стабильной версии: crypTar --update"
echo "💡 Папку установки можно удалить:"
echo "   rm -rf $REPO_DIR"

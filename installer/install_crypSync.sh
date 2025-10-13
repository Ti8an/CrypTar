#!/bin/bash
set -e

echo "🚀 Установка CrypSync..."

# Определяем путь к корню проекта
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"

# Проверяем наличие Python3
if ! command -v python3 &> /dev/null; then
    echo "❌ Python3 не найден. Установи его командой:"
    echo "   sudo apt install python3 python3-venv -y"
    exit 1
fi

# Создаём виртуальное окружение, если его нет
if [ ! -d "venv" ]; then
    echo "📦 Создаём виртуальное окружение..."
    python3 -m venv venv
else
    echo "✅ Виртуальное окружение уже существует."
fi

# Активируем окружение
source venv/bin/activate

# Обновляем pip и ставим зависимости
echo "📦 Устанавливаем зависимости..."
pip install --upgrade pip
if [ -f "requirements.txt" ]; then
    pip install -r requirements.txt
else
    echo "⚠️ Файл requirements.txt не найден, пропускаем..."
fi

# Устанавливаем CrypSync как пакет (editable mode)
echo "⚙️ Устанавливаем CrypSync..."
pip install -e .

# Проверяем, куда установилась команда
COMMAND_PATH="$(which crypSync || true)"

if [ -z "$COMMAND_PATH" ]; then
    echo "⚠️ Команда crypSync не найдена в PATH. Добавляем ~/.local/bin..."
    export PATH="$PATH:$HOME/.local/bin"
    echo 'export PATH="$PATH:$HOME/.local/bin"' >> ~/.bashrc
    source ~/.bashrc
    COMMAND_PATH="$(which crypSync || true)"
fi

if [ -n "$COMMAND_PATH" ]; then
    echo "✅ CrypSync установлен и доступен как команда:"
    echo "   $COMMAND_PATH"
else
    echo "❌ Ошибка: команда crypSync не найдена даже после установки."
    echo "   Проверь ~/.local/bin/crypSync вручную."
    exit 1
fi

echo
echo "✅ Установка завершена!"
echo "Теперь можно запускать CrypSync так:"
echo "👉 crypSync /путь/к/папке"
echo
echo "Пример:"
echo "   crypSync /home/tivan/testFolder"
echo

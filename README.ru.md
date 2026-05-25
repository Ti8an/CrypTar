[English](README.md) | [Русский](README.ru.md)

# CrypTar v1.1.3

**CrypTar** — Bash-инструмент для архивирования, GPG-шифрования и отправки резервных копий на удалённые серверы через SSH.

---

## Установка

```bash
git clone https://github.com/Ti8an/CrypTar.git
cd CrypTar/app
chmod +x install.sh
./install.sh
```

Установщик проверяет и при необходимости устанавливает: `tar`, `gnupg`, `openssh-client`, `sshpass`.

> **Примечание:** при установке `sshpass` выводится предупреждение — предпочтительна аутентификация по SSH-ключу.

---

## Команды

| Команда | Описание |
|---|---|
| `crypTar <путь>` | Архивировать и зашифровать файл или папку |
| `crypTar -s <путь>` | Архивировать, зашифровать и отправить на сервер |
| `crypTar -d <файл.tar.gz.gpg>` | Расшифровать и распаковать архив |
| `crypTar --server list` | Показать список настроенных серверов |
| `crypTar --server add` | Добавить новый сервер (интерактивный мастер) |
| `crypTar --server remove` | Удалить сервер |
| `crypTar --server push-key` | Отправить GPG-ключ на сервер |
| `crypTar --version` | Показать версию |
| `crypTar -h \| --help` | Показать справку |

---

## Примеры использования

```bash
# Зашифровать папку
crypTar ~/projects/myApp
# → myApp_25_05_2026_14_30_00.tar.gz.gpg

# Расшифровать
crypTar -d myApp_25_05_2026_14_30_00.tar.gz.gpg

# Зашифровать и сразу отправить на сервер
crypTar -s ~/projects/myApp

# Добавить удалённый сервер
crypTar --server add

# Посмотреть список серверов
crypTar --server list

# Отправить свой GPG-ключ на сервер (для расшифровки там)
crypTar --server push-key
```

---

## Структура проекта

```
app/
├── crypTar                  # Основной исполняемый файл
├── VERSION                  # Версия (2.0.0)
├── install.sh               # Установщик
├── src/
│   ├── lib/
│   │   ├── config.sh        # Зашифрованный INI-конфиг серверов
│   │   ├── creds.sh         # Загрузка/выгрузка учётных данных
│   │   └── transfer.sh      # Отправка файлов (rsync / scp)
│   ├── commands/
│   │   ├── encrypt.sh       # cmd_encrypt, cmd_archive_and_encrypt
│   │   ├── decrypt.sh       # cmd_decrypt
│   │   ├── send.sh          # cmd_send, cmd_send_all
│   │   └── server/
│   │       ├── add.sh       # srv_add
│   │       ├── list.sh      # srv_list
│   │       ├── remove.sh    # srv_remove
│   │       ├── push_key.sh  # srv_push_key
│   │       └── dispatch.sh  # Маршрутизация --server <подкоманда>
│   └── utils/
│       ├── log.sh           # log_ok / log_err / log_step / log_info
│       ├── ui.sh            # ui_prompt / ui_select / ui_confirm / ui_secret
│       └── ssh.sh           # ssh_exec / scp_send / ssh_test_conn
└── tests/
    ├── test_config.sh       # Unit-тесты config.sh
    ├── test_transfer.sh     # Unit-тесты transfer.sh
    └── test_commands.sh     # Интеграционные тесты CLI
```

---

## Тесты

### Установка bats-core

```bash
git submodule add https://github.com/bats-core/bats-core.git tests/bats
git submodule add https://github.com/bats-core/bats-support.git tests/test_helper/bats-support
git submodule add https://github.com/bats-core/bats-assert.git tests/test_helper/bats-assert
```

Или глобально через пакетный менеджер:

```bash
# Debian / Ubuntu
sudo apt-get install bats

# macOS
brew install bats-core
```

### Запуск

```bash
# Все тесты
bats tests/

# Один файл
bats tests/test_config.sh
```

Тесты создают изолированный GPG-keyring во временной директории (`GNUPGHOME=$(mktemp -d)`) и не затрагивают реальный keyring разработчика.

---

## Безопасность

- **Шифрование**: только асимметричное (GPG public key). Симметричные пароли не используются.
- **Учётные данные серверов**: хранятся в зашифрованном INI-файле (`~/.config/cryptar/`), доступном только владельцу (chmod 700).
- **Временные файлы**: создаются в `/dev/shm` (RAM-диск) при наличии, чтобы минимизировать время жизни расшифрованных данных на диске.
- **sshpass**: пароль SSH передаётся через переменную среды `SSHPASS`, а не через аргументы командной строки (не виден в `ps aux`). Рекомендуется использовать аутентификацию по SSH-ключу.
- **Ротация ключей**: при смене GPG-ключа обновите его командой `crypTar --server push-key` на всех серверах.

---

## Автор

CrypTar — инструмент для автоматизации резервного копирования и защиты данных. Разработано с ❤️ на Bash.

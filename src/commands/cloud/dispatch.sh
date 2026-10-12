#!/usr/bin/env bash
[[ -n "${_CLOUD_DISPATCH_LOADED:-}" ]] && return 0
_CLOUD_DISPATCH_LOADED=1

cloud_usage() {
    cat <<'EOF'
Использование: crypTar --cloud <подкоманда> [аргументы]

  add                                   — добавить облачное подключение (мастер)
  list [--check]                        — список подключений (--check: проверить связь)
  remove [имя|номер]                    — удалить подключение (только локально)
  test [имя|номер|--all]                — проверить авторизацию и доступ к папке
  send [--to имя[,имя...]] <путь>       — загрузить в облако:
                                            *.gpg (зашифрованный архив) — как есть,
                                            иначе — архивировать, зашифровать, загрузить
  reauth [имя|номер]                    — повторная авторизация подключения

Коды выхода send: 0 — все загрузки успешны, 3 — часть не удалась, 1 — ошибка.
EOF
}

# Entry point receives "$@" from crypTar: $1="--cloud", $2=subcommand, rest=args.
cloud_dispatch() {
    # xtrace would print OAuth tokens and client secrets — keep it off here.
    { set +x; } 2>/dev/null
    local sub="${2:-}"
    if (( $# >= 2 )); then shift 2; else shift $#; fi

    case "$sub" in
        add)
            source "$SRC_DIR/commands/cloud/add.sh"
            cloud_add "$@"
            ;;
        list|ls)
            source "$SRC_DIR/commands/cloud/list.sh"
            cloud_list "$@"
            ;;
        remove|rm)
            source "$SRC_DIR/commands/cloud/remove.sh"
            cloud_remove "$@"
            ;;
        test)
            source "$SRC_DIR/commands/cloud/test.sh"
            cloud_test "$@"
            ;;
        send)
            source "$SRC_DIR/commands/cloud/send.sh"
            cloud_send "$@"
            ;;
        reauth)
            source "$SRC_DIR/commands/cloud/add.sh"
            cloud_reauth "$@"
            ;;
        -h|--help|help)
            cloud_usage
            ;;
        "")
            cloud_usage >&2
            return 1
            ;;
        *)
            log_err "Неизвестная подкоманда: '$sub'"
            cloud_usage >&2
            return 1
            ;;
    esac
}

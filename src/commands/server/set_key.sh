#!/usr/bin/env bash
[[ -n "${_SRV_SET_KEY_LOADED:-}" ]] && return 0
_SRV_SET_KEY_LOADED=1

srv_set_key() {
    # Step 1: show current key
    local current_key=""
    if [[ -f "$CFG_KEY_FILE" ]]; then
        current_key="$(cat "$CFG_KEY_FILE")"
        log_info "Текущий ключ шифрования: $current_key"
    else
        log_warn "Ключ шифрования ещё не задан."
    fi

    # Step 2: list available GPG keys
    local -a gpg_keys=()
    IFS=$'\n' read -r -d '' -a gpg_keys < <(cfg_list_gpg_keys && printf '\0')

    if [[ ${#gpg_keys[@]} -eq 0 || -z "${gpg_keys[0]}" ]]; then
        log_err "GPG-ключи не найдены. Создайте ключ: gpg --full-generate-key"
        return 1
    fi

    # Step 3: let user pick a new key
    local sel_gpg
    sel_gpg="$(ui_select "Выберите новый GPG-ключ для шифрования конфига" "${gpg_keys[@]}")"
    [[ -n "$sel_gpg" ]] || { log_info "Отменено."; return 0; }

    local new_key_id="${sel_gpg%% : *}"
    local new_key_uid="${sel_gpg#* : }"

    # Step 4: bail out if same key selected
    if [[ "$new_key_id" == "$current_key" ]]; then
        log_warn "Выбранный ключ уже используется. Изменений нет."
        return 0
    fi

    # Step 5: if no config exists yet — just update CFG_KEY_FILE
    if [[ ! -f "$CFG_FILE" ]]; then
        cfg_set_encrypt_key "$new_key_id"
        log_ok "Ключ шифрования установлен: $new_key_uid"
        return 0
    fi

    # Step 6: decrypt with old key, re-encrypt with new key
    # cfg_decrypt reads CFG_FILE using the current CFG_KEY_FILE implicitly
    # (GPG uses the key embedded in the ciphertext, not CFG_KEY_FILE).
    log_step "Расшифровываем конфиг старым ключом..."
    local tmp=""
    tmp="$(cfg_decrypt)" || {
        log_err "Не удалось расшифровать конфиг. Убедитесь что старый ключ доступен в keyring."
        return 1
    }
    trap '_cfg_shred "$tmp"; trap - EXIT INT TERM' EXIT INT TERM

    # Switch CFG_KEY_FILE to the new key before calling cfg_encrypt
    cfg_set_encrypt_key "$new_key_id"

    log_step "Перешифровываем конфиг новым ключом: $new_key_uid..."
    cfg_encrypt "$tmp"
    local rc=$?
    trap - EXIT INT TERM

    if [[ $rc -eq 0 ]]; then
        log_ok "Ключ шифрования успешно изменён на: $new_key_uid"
    else
        log_err "Не удалось перешифровать конфиг. Восстановите старый ключ вручную:"
        log_err "  cfg_set_encrypt_key $current_key"
        return 1
    fi
}

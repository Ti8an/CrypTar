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

    # Step 5: every encrypted config shares the key: servers.conf.gpg and,
    # when cloud connections exist, clouds.conf.gpg.
    local -a cfg_files=()
    [[ -f "$CFG_FILE" ]] && cfg_files+=("$CFG_FILE")
    [[ -n "${CLOUD_CFG_FILE:-}" && -f "$CLOUD_CFG_FILE" ]] && cfg_files+=("$CLOUD_CFG_FILE")

    # If no config exists yet — just update CFG_KEY_FILE
    if [[ ${#cfg_files[@]} -eq 0 ]]; then
        cfg_set_encrypt_key "$new_key_id"
        log_ok "Ключ шифрования установлен: $new_key_uid"
        return 0
    fi

    # Step 6: decrypt everything with the old key first (nothing is changed
    # if any file fails), then re-encrypt with the new key.
    # GPG uses the key embedded in the ciphertext, not CFG_KEY_FILE.
    log_step "Расшифровываем конфиг старым ключом..."
    local -a tmps=()
    local f t
    trap 'for t in "${tmps[@]}"; do _cfg_shred "$t"; done; trap - EXIT INT TERM' EXIT INT TERM
    for f in "${cfg_files[@]}"; do
        t="$(cfg_decrypt "$f")" || {
            for t in "${tmps[@]}"; do _cfg_shred "$t"; done
            trap - EXIT INT TERM
            log_err "Не удалось расшифровать $f. Убедитесь что старый ключ доступен в keyring."
            return 1
        }
        tmps+=("$t")
    done

    # Switch CFG_KEY_FILE to the new key before calling cfg_encrypt
    cfg_set_encrypt_key "$new_key_id"

    log_step "Перешифровываем конфиг новым ключом: $new_key_uid..."
    local rc=0 i
    for i in "${!cfg_files[@]}"; do
        cfg_encrypt "${tmps[$i]}" "${cfg_files[$i]}" || rc=1
    done
    trap - EXIT INT TERM

    if [[ $rc -eq 0 ]]; then
        log_ok "Ключ шифрования успешно изменён на: $new_key_uid"
    else
        log_err "Не удалось перешифровать конфиг. Восстановите старый ключ вручную:"
        log_err "  cfg_set_encrypt_key $current_key"
        return 1
    fi
}

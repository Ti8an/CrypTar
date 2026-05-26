#!/usr/bin/env bash
[[ -n "${_UI_LOADED:-}" ]] && return 0
_UI_LOADED=1

# ui_select <prompt> <item1> <item2> ...
# Prints a numbered list, prompts for index, echoes the chosen item.
ui_select() {
    local prompt="$1"; shift
    local items=("$@")
    local i choice

    for i in "${!items[@]}"; do
        echo "  [$i] ${items[$i]}" >&2
    done

    while true; do
        printf "%s: " "$prompt" >&2
        read -r choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 0 && choice < ${#items[@]} )); then
            echo "${items[$choice]}"
            return 0
        fi
        echo "  Invalid choice — enter a number between 0 and $(( ${#items[@]} - 1 ))" >&2
    done
}

# ui_confirm <question>
# Returns 0 for yes, 1 for no. Default is No.
ui_confirm() {
    local question="$1"
    local answer
    printf "%s [y/N]: " "$question" >&2
    read -r answer
    [[ "$answer" =~ ^[Yy]$ ]]
}

# ui_prompt <prompt> [default]
# Echoes the entered value, or default if input is empty.
ui_prompt() {
    local prompt="$1"
    local default="${2:-}"
    local value

    if [[ -n "$default" ]]; then
        printf "%s [%s]: " "$prompt" "$default" >&2
    else
        printf "%s: " "$prompt" >&2
    fi

    read -r value
    echo "${value:-$default}"
}

# ui_secret <prompt>
# Hidden input; echoes the entered value.
ui_secret() {
    local prompt="$1"
    local value
    printf "%s: " "$prompt" >&2
    read -rs value
    echo >&2
    echo "$value"
}

# ui_table <col_width> <col_width> ... -- <row1_col1> <row1_col2> ... <row2_col1> ...
# All args before "--" are column widths; args after are cell values (row-major order).
ui_table() {
    local widths=()
    while [[ "${1:-}" != "--" && $# -gt 0 ]]; do
        widths+=("$1"); shift
    done
    shift  # consume "--"

    local cells=("$@")
    local ncols=${#widths[@]}
    local i=0 col line

    while (( i < ${#cells[@]} )); do
        line=""
        for col in "${!widths[@]}"; do
            local cell="${cells[$i]:-}"
            printf -v padded "%-${widths[$col]}s" "$cell"
            line+="$padded  "
            (( i++ )) || true
        done
        echo "$line"
    done
}

# ui_separator
ui_separator() {
    printf '%0.s─' {1..60}
    echo
}

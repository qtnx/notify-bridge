#!/usr/bin/env zsh
# notify-bridge shell hook
# Auto-send notification when a command takes longer than NOTIFY_THRESHOLD seconds.
#
# Source this in ~/.zshrc:
#   source /path/to/notify-bridge/shell-hook.zsh
#
# Config (optional, set before sourcing):
#   NOTIFY_THRESHOLD=10        # seconds (default: 10)
#   NOTIFY_EXCLUDE_CMDS="vim|less|man|ssh|top|htop|watch|tail"

: "${NOTIFY_THRESHOLD:=10}"
: "${NOTIFY_EXCLUDE_CMDS:=vim|nvim|nano|less|more|man|ssh|mosh|top|htop|btop|watch|tail|tmux|screen}"

_nb_cmd=""
_nb_start=0

_nb_preexec() {
    _nb_cmd="$1"
    _nb_start=$EPOCHSECONDS
}

_nb_precmd() {
    local exit_code=$?
    [[ $_nb_start -eq 0 ]] && return
    [[ -z "$_nb_cmd" ]] && return

    local elapsed=$(( EPOCHSECONDS - _nb_start ))
    _nb_start=0

    [[ $elapsed -lt $NOTIFY_THRESHOLD ]] && return

    # Skip interactive/long-running commands
    local base_cmd="${_nb_cmd%% *}"
    [[ "$base_cmd" =~ ^($NOTIFY_EXCLUDE_CMDS)$ ]] && return

    local status_icon
    if [[ $exit_code -eq 0 ]]; then
        status_icon="OK"
    else
        status_icon="FAIL($exit_code)"
    fi

    local display_cmd="$_nb_cmd"
    [[ ${#display_cmd} -gt 80 ]] && display_cmd="${display_cmd:0:77}..."

    notify-bridge send \
        "$display_cmd" \
        "[$status_icon] finished in ${elapsed}s" \
        --app "shell" &>/dev/null &!
}

autoload -Uz add-zsh-hook
add-zsh-hook preexec _nb_preexec
add-zsh-hook precmd _nb_precmd

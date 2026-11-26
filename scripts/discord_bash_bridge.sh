#!/usr/bin/env bash
# Discord Bash Bridge
# Logs interactive shell commands to a Discord DM and displays incoming DMs
# from the configured Discord user in the terminal.
#
# Requirements: bash, curl, jq, base64, sed
#
# Load:
#   source ./discord_bash_bridge.sh
# Start:
#   discord_start BOT_TOKEN DISCORD_USER_ID
# Stop:
#   discord_stop
# Send a message:
#   discord_send "Hello from Bash"
# Wait for a DM:
#   await_discord

# Avoid resetting the bridge when this file is sourced more than once.
if [[ -n "${_DISCORD_BRIDGE_LOADED:-}" ]]; then
    return 0
fi
_DISCORD_BRIDGE_LOADED=1

DISCORD_API="https://discord.com/api/v10"
LOG_FILE="${DISCORD_BRIDGE_LOG:-$HOME/.discord_bash_bridge.log}"
STATE_DIR="${XDG_RUNTIME_DIR:-/tmp}/discord_bash_bridge_${UID}"
mkdir -p "$STATE_DIR"
chmod 700 "$STATE_DIR" 2>/dev/null || true

TOKEN_FILE="$STATE_DIR/token"
UID_FILE="$STATE_DIR/user_id"
PID_FILE="$STATE_DIR/daemon.pid"
LAST_MSG_FILE="$STATE_DIR/last_msg_id"
DM_CHAN_FILE="$STATE_DIR/dm_channel_id"
QUEUE_FILE="$STATE_DIR/incoming.queue"
LAST_CMD_FILE="$STATE_DIR/last_cmd.txt"
CMD_COUNT_FILE="$STATE_DIR/cmd_count.txt"
ACTIVE_FLAG="$STATE_DIR/active"
IN_PROMPT_FLAG="$STATE_DIR/in_prompt"

_discord_require_deps() {
    local missing=()
    command -v curl >/dev/null 2>&1 || missing+=(curl)
    command -v jq >/dev/null 2>&1 || missing+=(jq)
    command -v base64 >/dev/null 2>&1 || missing+=(base64)
    if ((${#missing[@]})); then
        printf 'Discord bridge: missing dependencies: %s\n' "${missing[*]}" >&2
        return 1
    fi
}

_discord_get_token() {
    if [[ -n "${DISCORD_BOT_TOKEN:-}" ]]; then
        printf '%s' "$DISCORD_BOT_TOKEN"
    elif [[ -s "$TOKEN_FILE" ]]; then
        cat "$TOKEN_FILE"
    fi
}

_discord_get_uid() {
    if [[ -n "${DISCORD_USER_ID:-}" ]]; then
        printf '%s' "$DISCORD_USER_ID"
    elif [[ -s "$UID_FILE" ]]; then
        cat "$UID_FILE"
    fi
}

_discord_api_error() {
    local response="$1"
    local message
    message=$(printf '%s' "$response" | jq -r '.message // empty' 2>/dev/null)
    [[ -n "$message" ]] && printf 'Discord API: %s\n' "$message" >&2
}

_discord_get_dm_channel() {
    local token="$1" uid="$2"
    local chan_id response

    if [[ -s "$DM_CHAN_FILE" ]]; then
        cat "$DM_CHAN_FILE"
        return 0
    fi

    response=$(curl -fsS -X POST "${DISCORD_API}/users/@me/channels" \
        -H "Authorization: Bot ${token}" \
        -H "Content-Type: application/json" \
        -d "$(jq -nc --arg id "$uid" '{recipient_id:$id}')" 2>/dev/null) || {
        printf 'Discord bridge: could not open DM channel. Check bot token and permissions.\n' >&2
        return 1
    }

    chan_id=$(printf '%s' "$response" | jq -r '.id // empty')
    if [[ -z "$chan_id" ]]; then
        _discord_api_error "$response"
        return 1
    fi

    printf '%s\n' "$chan_id" > "$DM_CHAN_FILE"
    chmod 600 "$DM_CHAN_FILE"
    printf '%s' "$chan_id"
}

_discord_send_dm() {
    local token="$1" uid="$2" message="$3"
    local channel_id chunk payload offset=0 chunk_size=1900
    [[ -z "$message" ]] && return 0

    channel_id=$(_discord_get_dm_channel "$token" "$uid") || return 1
    while ((offset < ${#message})); do
        chunk="${message:offset:chunk_size}"
        payload=$(jq -nc --arg content "$chunk" '{content:$content}')
        local response http_code
        response=$(curl -sS -X POST "${DISCORD_API}/channels/${channel_id}/messages" \
            -H "Authorization: Bot ${token}" \
            -H "Content-Type: application/json" \
            -d "$payload" -w $'\n%{http_code}') || {
            printf 'Discord bridge: message send FAILED (curl/network error) — NOT delivered.\n' >&2
            return 1
        }
        http_code=${response##*$'\n'}
        if ((http_code < 200 || http_code >= 300)); then
            printf 'Discord bridge: message send FAILED (HTTP %s) — NOT delivered.\n' "$http_code" >&2
            _discord_api_error "${response%$'\n'*}"
            return 1
        fi
        offset=$((offset + chunk_size))
    done
}

_discord_send_dm_files() {
    local token="$1" uid="$2" message="$3"
    shift 3
    local -a files=("$@")
    local channel_id payload_json idx=0 file
    if ((${#files[@]} == 0)); then
        _discord_send_dm "$token" "$uid" "$message"
        return $?
    fi

    channel_id=$(_discord_get_dm_channel "$token" "$uid") || return 1
    # Discord API wymaga w payload_json pól "attachments" (id = indeks pliku,
    # filename = nazwa pliku) przy wysyłce multipart; bez nich API zwraca 400.
    local -a names=()
    for file in "${files[@]}"; do
        names+=("$(basename "$file")")
    done
    if [[ -n "$message" ]]; then
        payload_json=$(jq -nc --arg content "$message" --args \
            '{content:$content, attachments:[$ARGS.positional|to_entries[]|{id:.key,filename:.value}]}' \
            "${names[@]}")
    else
        payload_json=$(jq -nc --args \
            '{attachments:[$ARGS.positional|to_entries[]|{id:.key,filename:.value}]}' \
            "${names[@]}")
    fi

    local -a args=(-sS -X POST "${DISCORD_API}/channels/${channel_id}/messages"
        -H "Authorization: Bot ${token}" --form-string "payload_json=${payload_json}")
    for file in "${files[@]}"; do
        [[ -f "$file" ]] || {
            printf 'Discord bridge: file not found: %s\n' "$file" >&2
            return 1
        }
        args+=(-F "files[${idx}]=@${file}")
        idx=$((idx + 1))
    done
    local response http_code
    response=$(curl "${args[@]}" -w $'\n%{http_code}') || {
        printf 'Discord bridge: file send FAILED (curl/network error) — NOT delivered.\n' >&2
        return 1
    }
    http_code=${response##*$'\n'}
    if ((http_code < 200 || http_code >= 300)); then
        printf 'Discord bridge: file send FAILED (HTTP %s) — NOT delivered.\n' "$http_code" >&2
        _discord_api_error "${response%$'\n'*}"
        return 1
    fi
}

_discord_react_eye() {
    local token="$1" channel_id="$2" message_id="$3"
    curl -fsS -X PUT \
        "${DISCORD_API}/channels/${channel_id}/messages/${message_id}/reactions/%F0%9F%91%81/@me" \
        -H "Authorization: Bot ${token}" \
        -H "Content-Length: 0" >/dev/null 2>&1 || true
}

_discord_init_last_msg() {
    local token="$1" uid="$2" channel_id latest_id
    channel_id=$(_discord_get_dm_channel "$token" "$uid") || return 1

    if [[ ! -s "$LAST_MSG_FILE" ]]; then
        latest_id=$(curl -fsS -H "Authorization: Bot ${token}" \
            "${DISCORD_API}/channels/${channel_id}/messages?limit=1" |
            jq -r '.[0].id // empty') || return 1
        [[ -n "$latest_id" ]] && printf '%s\n' "$latest_id" > "$LAST_MSG_FILE"
    fi
}

_discord_sync_queue() {
    local token="$1" uid="$2" channel_id last_id query response
    channel_id=$(_discord_get_dm_channel "$token" "$uid") || return 1
    last_id=$(cat "$LAST_MSG_FILE" 2>/dev/null || true)

    if [[ -n "$last_id" ]]; then
        query="after=${last_id}&limit=100"
    else
        query="limit=5"
    fi

    response=$(curl -fsS -H "Authorization: Bot ${token}" \
        "${DISCORD_API}/channels/${channel_id}/messages?${query}") || return 1

    # Discord returns newest first. Process oldest first and only accept the
    # configured user's messages.
    while IFS=$'\t' read -r msg_id content; do
        [[ -z "$msg_id" ]] && continue
        printf '%s\n' "$msg_id" > "$LAST_MSG_FILE"
        local encoded
        encoded=$(printf '%s' "$content" | base64 | tr -d '\n')
        printf '%s\t%s\n' "$msg_id" "$encoded" >> "$QUEUE_FILE"
    done < <(printf '%s' "$response" | jq -r --arg uid "$uid" '
        if type == "array" then
            reverse[] | select(.author.id == $uid) |
            [.id, .content] | @tsv
        else empty end
    ')
}

_discord_drain_queue_merged() {
    local token="$1" channel_id="$2"
    [[ -s "$QUEUE_FILE" ]] || return 1

    local merged="" msg_id encoded content
    while IFS=$'\t' read -r msg_id encoded; do
        [[ -z "$msg_id" ]] && continue
        _discord_react_eye "$token" "$channel_id" "$msg_id"
        content=$(printf '%s' "$encoded" | base64 -d 2>/dev/null || true)
        if [[ -z "$merged" ]]; then
            merged="$content"
        else
            merged+=$'\n'"$content"
        fi
    done < "$QUEUE_FILE"

    : > "$QUEUE_FILE"
    printf '%s' "$merged"
}

_discord_daemon_loop() {
    local token="$1" uid="$2" interval="${3:-2}"
    _discord_init_last_msg "$token" "$uid" || true
    while [[ -f "$ACTIVE_FLAG" ]]; do
        _discord_sync_queue "$token" "$uid" >/dev/null 2>&1 || true
        sleep "$interval"
    done
}

_discord_clean_prompt_command() {
    local pc="${PROMPT_COMMAND:-}"
    pc="${pc//_discord_bridge_precmd_enter/}"
    pc="${pc//_discord_bridge_precmd/}"
    # Collapse empty entries and trim separators.
    while [[ "$pc" == *";;"* ]]; do
        pc="${pc//;;/;}"
    done
    pc=$(printf '%s' "$pc" | sed -E \
        's/;[[:space:]]*;/;/g; s/^[;[:space:]]+//; s/[;[:space:]]+$//')
    PROMPT_COMMAND="$pc"
}

_discord_bridge_precmd_enter() {
    : > "$IN_PROMPT_FLAG"
}

_discord_bridge_preexec() {
    [[ -f "$ACTIVE_FLAG" ]] || return 0
    [[ -f "$IN_PROMPT_FLAG" ]] && return 0
    ((BASH_SUBSHELL > 0)) && return 0

    case "$BASH_COMMAND" in
        _discord_*|discord_start*|discord_stop*|discord_send*|await_discord*|"") return 0 ;;
    esac

    local command_text="$BASH_COMMAND"
    printf '%s\n' "$command_text" > "$LAST_CMD_FILE"
    printf '[%s] %s\n' "$(date '+%F %T')" "$command_text" >> "$LOG_FILE"

    # Send asynchronously so shell commands are not delayed by the API.
    local token uid
    token=$(_discord_get_token)
    uid=$(_discord_get_uid)
    if [[ -n "$token" && -n "$uid" ]]; then
        ( _discord_send_dm "$token" "$uid" "\`$command_text\`" >/dev/null 2>&1 ) &
        disown 2>/dev/null || true
    fi
}

_discord_bridge_precmd() {
    local exit_code=$?
    rm -f "$IN_PROMPT_FLAG"
    [[ -f "$ACTIVE_FLAG" ]] || return "$exit_code"

    local ran_command
    ran_command=$(cat "$LAST_CMD_FILE" 2>/dev/null || true)
    : > "$LAST_CMD_FILE"
    case "$ran_command" in
        await_discord*|discord_start*|discord_stop*|discord_send*) return "$exit_code" ;;
    esac
    [[ -n "$ran_command" ]] || return "$exit_code"

    local token uid channel_id merged
    token=$(_discord_get_token)
    uid=$(_discord_get_uid)
    [[ -n "$token" && -n "$uid" ]] || return "$exit_code"

    _discord_sync_queue "$token" "$uid" >/dev/null 2>&1 || true
    channel_id=$(_discord_get_dm_channel "$token" "$uid" 2>/dev/null || true)
    if [[ -n "$channel_id" ]] &&
       merged=$(_discord_drain_queue_merged "$token" "$channel_id"); then
        printf '\nNOWE POLECENIE OD UZYTKOWNIKA:\n%s\n' "$merged"
    fi

    local count=0
    [[ -f "$CMD_COUNT_FILE" ]] && count=$(cat "$CMD_COUNT_FILE" 2>/dev/null || echo 0)
    [[ "$count" =~ ^[0-9]+$ ]] || count=0
    count=$((count + 1))
    printf '%s\n' "$count" > "$CMD_COUNT_FILE"
    if ((count % 10 == 0)); then
        printf 'Pamiętaj, aby krótko opisać użytkownikowi na Discordzie, co teraz robisz.\n'
    fi
    return "$exit_code"
}

discord_start() {
    _discord_require_deps || return 1
    [[ $- == *i* ]] || {
        printf 'discord_start must be run in an interactive Bash shell.\n' >&2
        return 1
    }

    local token="${1:-$(_discord_get_token)}"
    local uid="${2:-$(_discord_get_uid)}"
    local interval="${3:-2}"

    if [[ -z "$token" || -z "$uid" ]]; then
        printf 'Usage: discord_start BOT_TOKEN DISCORD_USER_ID [interval_seconds]\n' >&2
        return 1
    fi
    [[ "$interval" =~ ^[0-9]+$ ]] && ((interval > 0)) || interval=2

    printf '%s' "$token" > "$TOKEN_FILE"
    printf '%s' "$uid" > "$UID_FILE"
    chmod 600 "$TOKEN_FILE" "$UID_FILE"
    : > "$QUEUE_FILE"
    : > "$LAST_CMD_FILE"
    printf '0\n' > "$CMD_COUNT_FILE"
    : > "$ACTIVE_FLAG"
    rm -f "$IN_PROMPT_FLAG"

    if [[ -s "$PID_FILE" ]]; then
        local old_pid
        old_pid=$(cat "$PID_FILE")
        if kill -0 "$old_pid" 2>/dev/null; then
            kill "$old_pid" 2>/dev/null || true
        fi
    fi

    rm -f "$DM_CHAN_FILE"
    _discord_init_last_msg "$token" "$uid" || {
        rm -f "$ACTIVE_FLAG"
        return 1
    }

    # Detached polling process.
    nohup bash -c '
        DISCORD_API="$1"
        STATE_DIR="$2"
        TOKEN_FILE="$STATE_DIR/token"
        UID_FILE="$STATE_DIR/user_id"
        PID_FILE="$STATE_DIR/daemon.pid"
        LAST_MSG_FILE="$STATE_DIR/last_msg_id"
        DM_CHAN_FILE="$STATE_DIR/dm_channel_id"
        QUEUE_FILE="$STATE_DIR/incoming.queue"
        ACTIVE_FLAG="$STATE_DIR/active"
        source "$3"
        _discord_daemon_loop "$(cat "$TOKEN_FILE")" "$(cat "$UID_FILE")" "$4"
    ' _ "$DISCORD_API" "$STATE_DIR" "$BASH_SOURCE" "$interval" \
        >/dev/null 2>&1 &
    local daemon_pid=$!
    printf '%s\n' "$daemon_pid" > "$PID_FILE"

    _discord_clean_prompt_command
    if [[ -n "${PROMPT_COMMAND:-}" ]]; then
        PROMPT_COMMAND="_discord_bridge_precmd_enter; ${PROMPT_COMMAND}; _discord_bridge_precmd"
    else
        PROMPT_COMMAND="_discord_bridge_precmd_enter; _discord_bridge_precmd"
    fi

    trap '_discord_bridge_preexec' DEBUG
    printf 'Discord bridge started in background (PID: %s).\n' "$daemon_pid"
}

discord_stop() {
    rm -f "$ACTIVE_FLAG" "$IN_PROMPT_FLAG"
    if [[ -s "$PID_FILE" ]]; then
        local pid
        pid=$(cat "$PID_FILE")
        kill "$pid" 2>/dev/null || true
        rm -f "$PID_FILE"
    fi
    trap - DEBUG
    _discord_clean_prompt_command
    unset _DISCORD_BRIDGE_LOADED
    printf 'Discord bridge stopped.\n'
}

discord_send() {
    _discord_require_deps || return 1
    local token uid arg message="" after_sep=0
    local -a files=()
    token=$(_discord_get_token)
    uid=$(_discord_get_uid)
    if [[ -z "$token" || -z "$uid" ]]; then
        printf 'Missing bot token or user ID. Run discord_start first.\n' >&2
        return 1
    fi

    for arg in "$@"; do
        if ((after_sep == 0)) && [[ "$arg" == "--" ]]; then
            after_sep=1
            continue
        fi
        if ((after_sep == 1)) || [[ -f "$arg" ]]; then
            [[ -f "$arg" ]] || {
                printf 'File not found: %s\n' "$arg" >&2
                return 1
            }
            files+=("$arg")
        else
            message+="${message:+ }$arg"
        fi
    done

    if [[ -z "$message" && ${#files[@]} -eq 0 && ! -t 0 ]]; then
        message=$(cat)
    fi
    if [[ -z "$message" && ${#files[@]} -eq 0 ]]; then
        printf 'Usage: discord_send "message" [-- file1 file2 ...]\n' >&2
        return 1
    fi
    _discord_send_dm_files "$token" "$uid" "$message" "${files[@]}"
}

await_discord() {
    _discord_require_deps || return 1
    local interval="${1:-1}" token uid channel_id merged
    token=$(_discord_get_token)
    uid=$(_discord_get_uid)
    if [[ -z "$token" || -z "$uid" ]]; then
        printf 'Missing bot token or user ID. Run discord_start first.\n' >&2
        return 1
    fi
    [[ "$interval" =~ ^[0-9]+$ ]] && ((interval > 0)) || interval=1
    channel_id=$(_discord_get_dm_channel "$token" "$uid") || return 1
    _discord_init_last_msg "$token" "$uid" || true
    printf 'Waiting for a DM from Discord user %s...\n' "$uid"

    while true; do
        _discord_sync_queue "$token" "$uid" >/dev/null 2>&1 || true
        if merged=$(_discord_drain_queue_merged "$token" "$channel_id"); then
            printf '%s\n' "$merged"
            return 0
        fi
        sleep "$interval"
    done
}

#!/bin/bash
set -e

deadline=$((SECONDS + 60))

request() {
    local path="$1" remaining max_time response status result
    shift

    while (( (remaining = deadline - SECONDS) > 0 )); do
        max_time=15
        if (( remaining < max_time )); then
            max_time=$remaining
        fi

        if response=$(curl --silent --show-error --noproxy brewq.localtest.me \
            --connect-timeout 2 --max-time "$max_time" --write-out '\n%{http_code}' \
            "$@" "http://brewq.localtest.me$path"); then
            status=${response##*$'\n'}
            if [[ $status == 2[0-9][0-9] ]]; then
                printf '%s\n' "${response%$'\n'*}"
                return 0
            fi
            printf '%s returned HTTP %s\n%s\n' "$path" "$status" "${response%$'\n'*}" >&2
            [[ $status == 503 ]] || return 1
        else
            result=$?
            # A DNS or connect failure occurred before the request could be sent.
            case "$result" in
                6|7) ;;
                *) return "$result" ;;
            esac
        fi

        (( deadline - SECONDS > 1 )) || break
        sleep 1
    done

    printf 'Smoke check timed out waiting for %s\n' "$path" >&2
    return 1
}

request /menu
request /version
request /orders --request POST --header 'Content-Type: application/json' \
    --data '{"name":"Sam","drink":"flat white"}'

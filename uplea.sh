# Plowshare uplea.com module
# Copyright (c) 2015 Plowshare team
#
# This file is part of Plowshare.
#
# Plowshare is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# Plowshare is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with Plowshare.  If not, see <http://www.gnu.org/licenses/>.

MODULE_UPLEA_REGEXP_URL='https\?://\(www\.\)\?uplea\.com/'

MODULE_UPLEA_DOWNLOAD_OPTIONS=""
MODULE_UPLEA_DOWNLOAD_RESUME=yes
MODULE_UPLEA_DOWNLOAD_FINAL_LINK_NEEDS_COOKIE=no
MODULE_UPLEA_DOWNLOAD_SUCCESSIVE_INTERVAL=

MODULE_UPLEA_PROBE_OPTIONS=""

# Output an Uplea file download URL
# $1: cookie file (unused here)
# $2: uplea url
# stdout: real file download link
uplea_download() {
    local -r COOKIE_FILE=$1
    local -r URL=$2
    local -r BASE_URL='https://uplea.com'
    local PAGE WAIT_URL WAIT_TIME FILE_URL FILE_NAME

    PAGE=$(curl -b "$COOKIE_FILE" -c "$COOKIE_FILE" "$URL") || return

    if match '>You followed an invalid or expired link\.<' "$PAGE"; then
        return $ERR_LINK_DEAD
    fi

    WAIT_URL=$(parse '>[[:space:]]*Free download[[:space:]]*<' '=.\([^"]*\)' -1 <<< "$PAGE") || return

    PAGE=$(curl -b "$COOKIE_FILE" "$BASE_URL$WAIT_URL") || return

    if match 'You need to have a Premium subscription to download this file' "$PAGE"; then
        return $ERR_LINK_NEED_PERMISSIONS
    fi

    # jQuery("DIV#timeBeforeNextUpload").jCountdown({
    WAIT_TIME=$(parse_quiet '#timeBeforeNextUpload' ':\([[:digit:]]\+\)' 1 <<< "$PAGE")
    if [[ $WAIT_TIME -gt 0 ]]; then
        echo $WAIT_TIME
        return $ERR_LINK_TEMP_UNAVAILABLE
    fi

    FILE_URL=$(parse_attr '=.button-download' href <<< "$PAGE") || return
    FILE_NAME=$(parse_tag '=.gold-text' span <<< "$PAGE")

    # Detect email protection (filename contains @)
    if match 'href="/cdn-cgi/l/email-protection"' "$FILE_NAME"; then
        FILE_NAME=
    fi

    # $('#ulCounter').ulCounter({'timer':10});
    WAIT_TIME=$(parse '#ulCounter' ':\([[:digit:]]\+\)' <<< "$PAGE") || WAIT_TIME=10
    wait $((WAIT_TIME)) || return

    echo "$FILE_URL"
    echo "$FILE_NAME"
}

# Probe a download URL. Use official API: http://uplea.com/api
# $1: cookie file (unused here)
# $2: Uplea url
# $3: requested capability list
# stdout: 1 capability per line
uplea_probe() {
    local -r URL=$2
    local -r REQ_IN=$3
    local JSON ERR REQ_OUT STATUS PAGE FILE_SIZE
    local -r BASE_URL='http://api.uplea.com/api/check-my-links'

    JSON=$(curl -F "json={ \"links\": [ \"$URL\" ] }" "$BASE_URL") || return

    if ! match_json_true 'status' "$JSON"; then
        ERR=$(parse_json_quiet 'error' <<< "$PAGE")
        log_error "Unexpected remote error: $ERR"
        return $ERR_FATAL
    fi

    JSON=$(parse_json 'result' <<< "$JSON")
    STATUS=$(parse_json 'status' <<< "$JSON")

    # 'DELETED'
    if [ "$STATUS" != 'OK' ]; then
        return $ERR_LINK_DEAD
    fi

    REQ_OUT=c

    # Note: Can't manage $ERR_LINK_NEED_PERMISSIONS with this link checker API.
    PAGE=$(curl -L "$URL")

    if [[ $REQ_IN = *f* ]]; then
        parse '^Download your file:' '>\([^<]\+\)' 3 <<< "$PAGE" && REQ_OUT="${REQ_OUT}f"
    fi

    if [[ $REQ_IN = *s* ]]; then
        FILE_SIZE=$(parse '^Download your file:' '>\([^<]\+\)' 4 <<< "$PAGE") && \
            translate_size "${FILE_SIZE/o/B}" && REQ_OUT="${REQ_OUT}s"
    fi

    if [[ $REQ_IN = *i* ]]; then
        parse . '/\([[:alnum:]]\+\)$' <<< "$URL" && REQ_OUT="${REQ_OUT}i"
    fi

    echo $REQ_OUT
}

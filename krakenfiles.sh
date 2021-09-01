# Plowshare krakenfiles.com module
# Copyright (c) 2021 Plowshare team
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

MODULE_KRAKENFILES_REGEXP_URL='https://krakenfiles\.com/'

MODULE_KRAKENFILES_DOWNLOAD_OPTIONS=""
MODULE_KRAKENFILES_DOWNLOAD_RESUME=yes
MODULE_KRAKENFILES_DOWNLOAD_FINAL_LINK_NEEDS_COOKIE=no
MODULE_KRAKENFILES_DOWNLOAD_SUCCESSIVE_INTERVAL=

MODULE_KRAKENFILES_PROBE_OPTIONS=""

# Output an krakenfiles.com file download URL
# $1: cookie file (unused here)
# $2: krakenfiles url
# stdout: real file download link
krakenfiles_download() {
    local -r COOKIE_FILE=$1
    local -r URL=$2
    local -r BASE_URL='https://krakenfiles.com'
    local PAGE FORM_HTML FORM_ACTION FORM_TOKEN HASH JSON STATUS

    PAGE=$(curl -b "$COOKIE_FILE" -c "$COOKIE_FILE" "$URL") || return

    # <img class="nk-error-gfx" src="/images/gfx/error-404.svg" alt="">
    # <h3 class="nk-error-title">Oops! Why you’re here?</h3>
    if match '="nk-error-title">' "$PAGE"; then
        return $ERR_LINK_DEAD
    fi

    FORM_HTML=$(grep_form_by_id "$PAGE" 'dl-form') || return
    FORM_ACTION=$(parse_form_action <<< "$FORM_HTML") || return
    FORM_TOKEN=$(parse_form_input_by_name 'token' <<< "$FORM_HTML") || return

    HASH=$(echo "$FORM_ACTION" | parse '' '.*/\([[:alnum:]]\+\)') || return
    log_debug "File ID: '$HASH'"

    JSON=$(curl -b "$COOKIE_FILE" \
        -H 'X-Requested-With: XMLHttpRequest' \
        -H "hash: $HASH" \
        -H "DNT: 1" \
        --referer "$URL" \
        -F "token=$FORM_TOKEN" \
        "$BASE_URL$FORM_ACTION") || return

    # {"status":"ok","url":"https:\/\/s3.krakenfiles.com\/force-download\/..."}

    STATUS=$(parse_json status <<< "$JSON") || return
    if [ "$STATUS" != 'ok' ]; then
        log_error "Unexpected status: $STATUS"
        return $ERR_FATAL
    fi

    echo $JSON | parse_json url || return
    echo "$PAGE" | parse_attr '=.og:title.' content
}

# Probe a download URL.
# $1: cookie file (unused here)
# $2: krakenfiles url
# $3: requested capability list
# stdout: 1 capability per line
krakenfiles_probe() {
    local -r URL=$2
    local -r REQ_IN=$3
    local PAGE RESP FILE_NAME FILE_SIZE REQ_OUT

    PAGE=$(curl -i "$URL") || return
    RESP=$(first_line <<< "$PAGE")

    if match '^HTTP/[[:digit:]]\(\.[[:digit:]]\)\?[[:space:]]404[[:space:]]' "$RESP"; then
        return $ERR_LINK_DEAD
    fi

    REQ_OUT=c

    if [[ $REQ_IN = *f* ]]; then
        # <meta property="og:title" content="... "
        FILE_NAME=$(echo "$PAGE" | parse_attr '=.og:title.' content) && \
            echo "${FILE_NAME% }" && REQ_OUT="${REQ_OUT}f"
    fi

    if [[ $REQ_IN = *s* ]]; then
        FILE_SIZE=$(echo "$PAGE" | parse '>File size<' '">\([^<]*\)</div>' 1) && \
            translate_size "$FILE_SIZE" && REQ_OUT="${REQ_OUT}s"
    fi

    echo $REQ_OUT
}

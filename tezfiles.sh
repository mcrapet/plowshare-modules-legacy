# Plowshare tezfiles.com module
# Copyright (c) 2016 Plowshare team
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

MODULE_TEZFILES_REGEXP_URL='https\?://\(www\.\)\?tezfiles\.com/'

MODULE_TEZFILES_DOWNLOAD_OPTIONS=""
MODULE_TEZFILES_DOWNLOAD_RESUME=yes
MODULE_TEZFILES_DOWNLOAD_FINAL_LINK_NEEDS_COOKIE=no
MODULE_TEZFILES_DOWNLOAD_SUCCESSIVE_INTERVAL=

MODULE_TEZFILES_PROBE_OPTIONS=""

# Output a tezfiles file download URL
# $1: cookie file
# $2: tezfiles url
# stdout: real file download link
tezfiles_download() {
    local -r COOKIE_FILE=$1
    local URL=$2
    local -r BASE_URL='http://tezfiles.com'
    local PAGE RESP FORM_HTML FORM_URL FORM_UID CAPTCHA_URL CAPTCHA_IMG FILE_URL FILE_NAME WAIT_TIME

    # Set-Cookie: sessid
    PAGE=$(curl -i -c "$COOKIE_FILE" -L "$URL") || return
    RESP=$(first_line <<< "$PAGE")

    if match '^HTTP/[[:digit:]]\.[[:digit:]][[:space:]]404[[:space:]][Nn]ot[[:space:]][Ff]ound' "$RESP"; then
        return $ERR_LINK_DEAD
    fi

    FORM_HTML=$(grep_form_by_order "$PAGE" 1) || return
    FORM_URL=$(parse_form_action <<<  "$FORM_HTML") || return
    FORM_UID=$(parse_form_input_by_type 'hidden' <<< "$FORM_HTML")

    PAGE=$(curl -b "$COOKIE_FILE" --referer "$BASE_URL$FORM_URL" \
        -d "slow_id=$FORM_UID" \
        -d 'yt0=' \
        "$BASE_URL$FORM_URL") || return

    if match '>Downloading is not possible<' "$PAGE"; then
        local HOUR MIN SEC
        WAIT_TIME=$(parse 'download this file' \
            'wait[[:space:]]\([[:digit:]]\{2\}:[[:digit:]]\{2\}:[[:digit:]]\{2\}\)[[:space:]]' <<< "$PAGE")
        HOUR=${WAIT_TIME%%:*}
        SEC=${WAIT_TIME##*:}
        MIN=${WAIT_TIME#*:}; MIN=${MIN%:*}

        echo $(( (( ${HOUR#0} * 60 ) + ${MIN#0} ) * 60 + ${SEC#0} ))
        return $ERR_LINK_TEMP_UNAVAILABLE
    fi

    # Check direct download
    if match '^[[:space:]]*window\.location\.href[[:space:]]=[[:space:]]'\''/file/url.html?file=' "$PAGE"; then
        FILE_URL=$(parse 'function download(){' "=[[:space:]]'\([^']\+\)" 2 <<< "$PAGE")
        FILE_URL=$(curl -I -b "$COOKIE_FILE" "$BASE_URL$FILE_URL" | grep_http_header_location) || return
        FILE_NAME=${FILE_URL##*name=}

        echo "$FILE_URL"
        uri_decode <<< "$FILE_NAME"
        return 0
    fi

    FORM_HTML=$(grep_form_by_order "$PAGE" 1) || return
    FORM_URL=$(parse_form_action <<<  "$FORM_HTML") || return
    FORM_UID=$(parse_form_input_by_name 'uniqueId' <<< "$FORM_HTML") || return

    CAPTCHA_URL=$(parse_attr '<img[[:space:]]' 'src' <<< "$FORM_HTML") || return
    CAPTCHA_IMG=$(create_tempfile '.png') || return
    curl -b "$COOKIE_FILE" -o "$CAPTCHA_IMG" "$BASE_URL$CAPTCHA_URL" || return

    local WI WORD ID
    WI=$(captcha_process "$CAPTCHA_IMG" letter 6 7) || return
    { read WORD; read ID; } <<<"$WI"
    rm -f "$CAPTCHA_IMG"

    if [ "${#WORD}" -lt 6 ]; then
        captcha_nack $ID
        log_debug 'captcha length invalid (should be at least 6 characters)'
        return $ERR_CAPTCHA
    fi

    log_debug "decoded captcha: $WORD"

    PAGE=$(curl -b "$COOKIE_FILE" --referer "$BASE_URL$FORM_URL" \
        -d 'free=1' \
        -d 'freeDownloadRequest=1' \
        -d "uniqueId=$FORM_UID" \
        -d "CaptchaForm[code]=$WORD" \
        "$BASE_URL$FORM_URL") || return

    if match '>The verification code is incorrect\.<' "$PAGE"; then
        captcha_nack $ID
        log_error 'Wrong captcha'
        return $ERR_CAPTCHA
    fi

    captcha_ack $ID
    log_debug 'Correct captcha'

    FORM_HTML=$(parse '{uniqueId:' ":[[:space:]]*'\([^']\+\)" -2 <<< "$PAGE") || return
    FORM_UID=$(parse '{uniqueId:' ":[[:space:]]*'\([^']\+\)" <<< "$PAGE") || return

    WAIT_TIME=$(parse 'id="download-wait-timer"' \
        '^[[:space:]]*\([[:digit:]]\+\)[[:space:]]*<' 1 <<< "$PAGE") || WAIT_TIME=30
    wait $WAIT_TIME || return

    PAGE=$(curl -v -b "$COOKIE_FILE" --referer "$BASE_URL$FORM_URL" \
        -d 'free=1' \
        -d "uniqueId=$FORM_UID" \
        "$BASE_URL$FORM_URL") || return

    # Oops... unknown download problem, please try again
    if match 'unknown download problem,' "$PAGE"; then
        log_error 'Unexpected remote answer, site updated?'
        return $ERR_FATAL
    fi

    FILE_URL=$(parse_attr 'class="link-to-file"' href <<< "$PAGE") || return
    FILE_URL=$(curl -I -b "$COOKIE_FILE" "$BASE_URL$FILE_URL" | grep_http_header_location) || return
    FILE_NAME=${FILE_URL##*name=}

    echo "$FILE_URL"
    uri_decode <<< "$FILE_NAME"
}

# Probe a download URL
# $1: cookie file (unused here)
# $2: tezfiles url
# $3: requested capability list
# stdout: 1 capability per line
tezfiles_probe() {
    local -r URL=$2
    local -r REQ_IN=$3
    local PAGE RESP REQ_OUT

    PAGE=$(curl -i -L "$URL") || return
    RESP=$(first_line <<< "$PAGE")

    if match '^HTTP/[[:digit:]]\.[[:digit:]][[:space:]]404[[:space:]][Nn]ot[[:space:]][Ff]ound' "$RESP"; then
        return $ERR_LINK_DEAD
    fi

    REQ_OUT=c

    if [[ $REQ_IN = *f* ]]; then
        FILE_NAME=$(parse '<h1' '^[[:space:]]*\([^<]\+\)' 1 <<< "$PAGE") && \
            echo ${FILE_NAME%% *} && REQ_OUT="${REQ_OUT}f"
    fi

    if [[ $REQ_IN = *s* ]]; then
        FILE_SIZE=$(parse_tag '#9b9b9b;' span <<< "$PAGE") && FILE_SIZE=${FILE_SIZE#(} && \
            translate_size "${FILE_SIZE%)}" && REQ_OUT="${REQ_OUT}s"
    fi

    echo $REQ_OUT
}

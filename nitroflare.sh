# Plowshare nitroflare.com module
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

MODULE_NITROFLARE_REGEXP_URL='https\?://\(www\.\)\?nitroflare\.com/'

MODULE_NITROFLARE_DOWNLOAD_OPTIONS=""
MODULE_NITROFLARE_DOWNLOAD_RESUME=no
MODULE_NITROFLARE_DOWNLOAD_FINAL_LINK_NEEDS_COOKIE=no
MODULE_NITROFLARE_DOWNLOAD_SUCCESSIVE_INTERVAL=

MODULE_NITROFLARE_PROBE_OPTIONS=""

# Output a nitroflare file download URL
# $1: cookie file
# $2: nitroflare url
# stdout: real file download link
nitroflare_download() {
    local -r COOKIE_FILE=$1
    local -r BASE_URL='http://nitroflare.com/'
    local URL PAGE RAND_HASH FREE_URL FILE_ID RESP WAIT_TIME FILE_URL

    # Get a canonical URL for this file.
    URL=$(curl -I "$2" | grep_http_header_location_quiet) || return
    [ -n "$URL" ] || URL=$2
    readonly URL

    PAGE=$(curl -c "$COOKIE_FILE" -i -L "$URL") || return

    if match "File doesn't exist\|This file has been removed\|404 Not Found" "$PAGE"; then
        return $ERR_LINK_DEAD
    fi

    # Register randHash in a cookie file.
    RAND_HASH=$(random 'H' 32) || return
    curl -b "$COOKIE_FILE" \
        -c "$COOKIE_FILE" \
        -d "randHash=$RAND_HASH" \
        "$BASE_URL/ajax/randHash.php"  > /dev/null || return

    FREE_URL=$(parse_attr '<form action=' 'action' <<< "$PAGE") || return
    PAGE=$(curl -b "$COOKIE_FILE" \
        -d 'goToFreePage=' \
        -L "$FREE_URL") || return

    # Start timer.
    FILE_ID=$(parse . 'view/\([^/]\+\)' <<< "$URL") || return
    RESP=$(curl -b "$COOKIE_FILE" \
        -d 'method=startTimer' \
        -d "fileId=$FILE_ID" \
        "$BASE_URL/ajax/freeDownload.php") || return

    # Warning! You have reached your downloads limit.
    if match 'Free downloading is not possible\. You have to wait' "$RESP"; then
        local HOURS MINS SECS
        HOURS=$(parse_quiet . '[^[:digit:]]\([[:digit:]]\+\) hours\?' <<< "$RESP")
        MINS=$(parse_quiet . '[^[:digit:]]\([[:digit:]]\+\) minutes\?' <<< "$RESP")
        SECS=$(parse_quiet . '[^[:digit:]]\([[:digit:]]\+\) seconds\?' <<< "$RESP")
        echo $((HOURS * 60 * 60 + MINS * 60 + SECS))
        return $ERR_LINK_TEMP_UNAVAILABLE
    # This file is available with Premium only. Reason: the file's owner disabled free downloads.
    elif match 'This file is available with Premium only\.' "$RESP"; then
        return $ERR_LINK_NEED_PERMISSIONS
    fi

    WAIT_TIME=$(parse_attr 'id="CountDownTimer"' 'data-timer' <<< "$PAGE") || return
    wait $WAIT_TIME || return

    local PUBKEY WCI CHALLENGE WORD ID
    PUBKEY='6Lenx_USAAAAAF5L1pmTWvWcH73dipAEzNnmNLgy'
    WCI=$(recaptcha_process $PUBKEY) || return
    { read WORD; read CHALLENGE; read ID; } <<< "$WCI"

    RESP=$(curl -b "$COOKIE_FILE" \
        -d 'method=fetchDownload' \
        -d "recaptcha_challenge_field=$CHALLENGE" \
        -d "recaptcha_response_field=$WORD" \
        "$BASE_URL/ajax/freeDownload.php") || return

    if match "The captcha wasn't entered correctly" "$RESP"; then
        captcha_nack $ID
        log_error 'Wrong captcha'
        return $ERR_CAPTCHA
    fi

    captcha_ack $ID
    log_debug 'Correct captcha'

    FILE_URL=$(parse_attr 'href' <<< "$RESP") || return
    echo "$FILE_URL"
}

# Probe a download URL
# $1: cookie file (unused here)
# $2: nitroflare url
# $3: requested capability list
# stdout: 1 capability per line
nitroflare_probe() {
    local -r URL=$2
    local -r REQ_IN=$3
    local PAGE FILE_SIZE REQ_OUT

    PAGE=$(curl -i -L "$URL") || return

    if match "File doesn't exist\|This file has been removed\|404 Not Found" "$PAGE"; then
        return $ERR_LINK_DEAD
    fi

    REQ_OUT=c

    if [[ $REQ_IN = *f* ]]; then
        parse_attr '<legend>' 'title'  <<< "$PAGE" && REQ_OUT="${REQ_OUT}f"
    fi

    if [[ $REQ_IN = *s* ]]; then
        FILE_SIZE=$(parse_tag '<legend>' 'span' <<< "$PAGE") \
            && FILE_SIZE=$(replace 'B' 'iB' <<< $FILE_SIZE) \
            && translate_size "$FILE_SIZE" && REQ_OUT="${REQ_OUT}s"
    fi

    if [[ $REQ_IN = *i* ]]; then
        parse '<form action=' 'view/\([^/]\+\)' <<< "$PAGE" && REQ_OUT="${REQ_OUT}i"
    fi

    echo $REQ_OUT
}

# Plowshare ulozto.net module
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

MODULE_ULOZ_TO_REGEXP_URL='https\?://\(www\.\)\?\(ulozto\.net\|uloz\.to\|ulozto\.sk\|zachowajto\.pl\)/'

MODULE_ULOZ_TO_DOWNLOAD_OPTIONS=""
MODULE_ULOZ_TO_DOWNLOAD_RESUME=yes
MODULE_ULOZ_TO_DOWNLOAD_FINAL_LINK_NEEDS_COOKIE=no
MODULE_ULOZ_TO_DOWNLOAD_SUCCESSIVE_INTERVAL=

MODULE_ULOZ_TO_PROBE_OPTIONS=""

# Output a uloz_to file download URL
# $1: cookie file
# $2: uloz_to url
# stdout: real file download link
uloz_to_download() {
    local -r COOKIE_FILE=$1
    local -r BASE_URL='http://ulozto.net'
    local URL REAL_URL PAGE JSON STATUS FILE_URL FILE_NAME

    # Be sure to use english version.
    URL=$(parse_quiet . '\.[^\/]*\/\(.*\)' <<< "$2")
    URL="$BASE_URL/$URL"

    # Get a canonical URL for this file.
    REAL_URL=$(curl -I "$URL" | grep_http_header_location_quiet) || return
    [ -n "$REAL_URL" ] && URL=$REAL_URL
    readonly URL

    PAGE=$(curl -c "$COOKIE_FILE" "$URL") || return

    if match '404 - Page not found\|File has been deleted' "$PAGE"; then
        return $ERR_LINK_DEAD
    fi

    FILE_NAME=$(parse_attr 'property="og:title"' 'content' <<< "$PAGE") || return

    # Get captcha.
    local DATE CAPTCHA_URL CAPTCHA_IMG
    DATE=$(date +%s) || return
    JSON=$(curl -L -e "$URL" -b "$COOKIE_FILE" "$BASE_URL/reloadXapca.php?rnd=$DATE") || return
    CAPTCHA_URL=$(parse_json 'image' <<< "$JSON") || return
    CAPTCHA_URL="http:$CAPTCHA_URL"
    CAPTCHA_IMG=$(create_tempfile '.gif') || return
    curl -o "$CAPTCHA_IMG" "$CAPTCHA_URL" || return

    local WI WORD ID
    WI=$(captcha_process "$CAPTCHA_IMG") || return
    { read WORD; read ID; } <<< "$WI"
    rm -f "$CAPTCHA_IMG"

    local FORM_LINE FORM_TIMESTAMP FORM_SALT FORM_HASH FORM_DO
    local FORM_TOKEN FORM_TS FORM_CID FORM_ADI FORM_SIGN_A FORM_SIGN
    FORM_LINE=$(parse 'id="frm-download-freeDownloadTab-freeDownloadForm-freeDownload"' \
        '^\(.*\)$' 2 <<< "$PAGE") || return
    FORM_TIMESTAMP=$(parse_json 'timestamp' <<< "$JSON") || return
    FORM_SALT=$(parse_json 'salt' <<< "$JSON") || return
    FORM_HASH=$(parse_json 'hash' <<< "$JSON") || return
    FORM_DO=$(parse . 'do" value="\([^"]*\)"' <<< "$FORM_LINE") || return
    FORM_TOKEN=$(parse . '_token_" value="\([^"]*\)"' <<< "$FORM_LINE") || return
    FORM_TS=$(parse . 'ts" value="\([^"]*\)"' <<< "$FORM_LINE") || return
    FORM_CID=$(parse_quiet . 'cid" value="\([^"]*\)"' <<< "$FORM_LINE")
    FORM_ADI=$(parse . 'adi" value="\([^"]*\)"' <<< "$FORM_LINE") || return
    FORM_SIGN_A=$(parse . 'sign_a" value="\([^"]*\)"' <<< "$FORM_LINE") || return
    FORM_SIGN=$(parse . 'sign" value="\([^"]*\)"' <<< "$FORM_LINE") || return

    JSON=$(curl -b "$COOKIE_FILE" \
        -H 'X-Requested-With: XMLHttpRequest' \
        -d "timestamp=$FORM_TIMESTAMP" \
        -d "salt=$FORM_SALT" \
        -d "hash=$FORM_HASH" \
        -d 'captcha_type=xapca' \
        -d "captcha_value=$WORD" \
        -d "do=$FORM_DO" \
        -d "_token_=$FORM_TOKEN" \
        -d "ts=$FORM_TS" \
        -d "cid=$FORM_CID" \
        -d "adi=$FORM_ADI" \
        -d "sign_a=$FORM_SIGN_A" \
        -d "sign=$FORM_SIGN" \
        "$URL") || return

    STATUS=$(parse_json 'status' <<< "$JSON") || return

    if [ "$STATUS" != 'ok' ]; then
        captcha_nack $ID
        log_error 'Wrong captcha'
        return $ERR_CAPTCHA
    fi

    captcha_ack $ID
    log_debug 'Correct captcha'

    FILE_URL=$(parse_json 'url' <<< "$JSON") || return

    # Be sure that we have the last link. For sure it redirects 1 time,
    # sometimes it may 2 times, maybe more times. Limit loop to max 5.
    local TRY FILE_REDIR
    TRY=0
    while (( TRY++ < 5 )); do
        log_debug "Redirect loop $TRY"

        FILE_REDIR=$(curl -b "$COOKIE_FILE" -I "$FILE_URL" \
            | grep_http_header_location_quiet)

        [ -z "$FILE_REDIR" ] && break
        FILE_URL="$FILE_REDIR"
    done

    echo "$FILE_URL"
    echo "$FILE_NAME"
}

# Probe a download URL
# $1: cookie file (unused here)
# $2: uloz_to url
# $3: requested capability list
# stdout: 1 capability per line
uloz_to_probe() {
    local -r REQ_IN=$3
    local -r BASE_URL='http://ulozto.net'
    local URL PAGE FILE_SIZE REQ_OUT

    # Be sure to use english version.
    URL=$(parse_quiet . '\.[^\/]*\/\(.*\)' <<< "$2")
    URL="$BASE_URL/$URL"
    readonly URL

    PAGE=$(curl -L "$URL") || return

    if match '404 - Page not found\|File has been deleted' "$PAGE"; then
        return $ERR_LINK_DEAD
    fi

    REQ_OUT=c

    if [[ $REQ_IN = *f* ]]; then
        parse_attr 'property="og:title"' 'content' <<< "$PAGE" && REQ_OUT="${REQ_OUT}f"
    fi

    if [[ $REQ_IN = *s* ]]; then
        FILE_SIZE=$(parse_quiet '>Size<' '>Size<.*[[:space:]]\([[:digit:]].*B\)' <<< "$PAGE") \
            && [ -n "$FILE_SIZE" ] && FILE_SIZE=$(replace 'B' 'iB' <<< $FILE_SIZE) \
            && translate_size "$FILE_SIZE" && REQ_OUT="${REQ_OUT}s"
    fi

    if [[ $REQ_IN = *i* ]]; then
        parse 'property="og:url"' '\.[^\/]*/\([^"]*\)"' <<< "$PAGE" \
            && REQ_OUT="${REQ_OUT}i"
    fi

    echo $REQ_OUT
}

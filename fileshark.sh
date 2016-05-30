# Plowshare fileshark.pl module
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

MODULE_FILESHARK_REGEXP_URL='https\?://\([[:alnum:]]\+\.\)\?fileshark\(\.xup\)\?\.pl/'

MODULE_FILESHARK_DOWNLOAD_OPTIONS="
AUTH,a,auth,a=USER:PASSWORD,User account"
MODULE_FILESHARK_DOWNLOAD_RESUME=no
MODULE_FILESHARK_DOWNLOAD_FINAL_LINK_NEEDS_COOKIE=no
MODULE_FILESHARK_DOWNLOAD_SUCCESSIVE_INTERVAL=

MODULE_FILESHARK_PROBE_OPTIONS=""

# Static function. Proceed with login
# $1: authentication
# $2: cookie file
# $3: base URL
# stdout: account type ("free" or "premium") on success
fileshark_login() {
    local -r AUTH=$1
    local -r COOKIE_FILE=$2
    local -r BASE_URL=$3

    local PAGE CSRF_TOKEN LOGIN_DATA JSON LOCATION NAME TYPE

    PAGE=$(curl -c "$COOKIE_FILE" "$BASE_URL/zaloguj" | break_html_lines) || return
    CSRF_TOKEN=$(parse_attr 'name="_csrf_token"' 'value' <<< "$PAGE") || return

    LOGIN_DATA='_username=$USER&_password=$PASSWORD&_csrf_token='$CSRF_TOKEN''

    JSON=$(post_login "$AUTH" "$COOKIE_FILE" "$LOGIN_DATA" "$BASE_URL/login_check" \
        -H 'X-Requested-With: XMLHttpRequest' -b "$COOKIE_FILE") || return

    # If successful an entry is added into a cookie file: session_id
    LOCATION=$(parse_json_quiet 'redirect' <<< "$JSON") || return
    if [ "$LOCATION" != "$BASE_URL/" ]; then
        return $ERR_LOGIN_FAILED
    fi

    PAGE=$(curl -b "$COOKIE_FILE" "$BASE_URL")
    NAME=$(parse_tag_quiet 'Witaj' 'a' <<< "$PAGE")
    TYPE=$(parse 'Rodzaj konta' '>\(Standardowe\|Premium\)' <<< "$PAGE") || return

    if [ "$TYPE" = 'Standardowe' ]; then
        TYPE='free'
    elif [ "$TYPE" = 'Premium' ]; then
        TYPE='premium'
    fi

    log_debug "Successfully logged in as '$TYPE' member '$NAME'"
    echo $TYPE
}

# Output a fileshark file download URL
# $1: cookie file
# $2: fileshark url
# stdout: real file download link
fileshark_download() {
    local -r COOKIE_FILE=$1
    local -r BASE_URL='http://fileshark.pl'
    local URL ACCOUNT PAGE FILE_ID FREE_URL WAIT_TIME FILE_URL
    local CAPTCHA_BASE64 CAPTCHA_IMG FORM_TOKEN

    if ! check_exec 'base64'; then
        log_error "'base64' is required but was not found in path."
        return $ERR_SYSTEM
    fi

    # Get a canonical URL for this file.
    URL=$(curl -I "$2" | grep_http_header_location_quiet) || return
    [ -n "$URL" ] || URL=$2
    readonly URL

    if [ -n "$AUTH" ]; then
        ACCOUNT=$(fileshark_login "$AUTH" "$COOKIE_FILE" "$BASE_URL") || return
    fi

    # Note: Save HTTP headers to catch premium users' "direct downloads".
    PAGE=$(curl -i -b "$COOKIE_FILE" -c "$COOKIE_FILE" "$URL") || return

    if match '404 Not Found' "$PAGE"; then
        return $ERR_LINK_DEAD
    elif match 'Strona jest dostępna wyłącznie .* na terenie wybranych Państw.' "$PAGE"; then
        log_error 'Free downloads are only allowed from Poland IP addresses.'
        return $ERR_LINK_NEED_PERMISSIONS
    elif match 'Osiągnięto maksymalną liczbę sciąganych jednocześnie plików.' "$PAGE"; then
        log_error 'No parallel download allowed.'
        echo 120
        return $ERR_LINK_TEMP_UNAVAILABLE
    elif match 'Proszę czekać. Kolejne pobranie możliwe za' "$PAGE"; then
        log_error 'Download limit reached.'
        parse 'var timeToDownload' ' = \([0-9]\+\);' <<< "$PAGE" || return
        return $ERR_LINK_TEMP_UNAVAILABLE
    fi

    # If this is a premium download, we already have a download link.
    if [ "$ACCOUNT" = 'premium' ]; then
        MODULE_FILESHARK_DOWNLOAD_RESUME=yes

        # Get a download link, if this was a direct download.
        FILE_URL=$(grep_http_header_location_quiet <<< "$PAGE")

        if [ -z "$FILE_URL" ]; then
            FILE_URL=$(parse_attr '>Pobierz<.*>bez ograniczeń<' 'href' <<< "$PAGE") || return
            # Redirects one time.
            FILE_URL=$(curl -i -b "$COOKIE_FILE" "$BASE_URL$FILE_URL" \
                | grep_http_header_location) || return
        fi

        echo "$FILE_URL"
        return 0
    fi

    FILE_ID=$(parse 'btn-upload-free' 'normal/\([[:digit:]]\+/[[:alnum:]]\+\)' <<< "$PAGE") || return
    FREE_URL="http://fileshark.pl/pobierz/normal/$FILE_ID/"

    PAGE=$(curl -b "$COOKIE_FILE" "$FREE_URL") || return

    # When captcha is reloaded then there is no wait time and new captcha is already on a page.
    WAIT_TIME=$(parse_quiet 'var timeToDownload' ' = \([0-9]\+\);' <<< "$PAGE")
    if [ -n "$WAIT_TIME" ]; then
        wait $WAIT_TIME || return
        PAGE=$(curl -b "$COOKIE_FILE" "$FREE_URL") || return
    fi

    CAPTCHA_BASE64=$(parse 'data:image/jpeg;base64' 'base64,\([^"]\+\)' <<< "$PAGE") || return
    CAPTCHA_IMG=$(create_tempfile '.jpeg') || return
    base64 --decode <<< "$CAPTCHA_BASE64" > "$CAPTCHA_IMG" || return

    local WI WORD ID
    WI=$(captcha_process "$CAPTCHA_IMG") || return
    { read WORD; read ID; } <<< "$WI"
    rm -f "$CAPTCHA_IMG"

    FORM_TOKEN=$(parse_attr 'form[_token]' 'value' <<< "$PAGE") || return

    PAGE=$(curl -b "$COOKIE_FILE" -i \
        -d "form[captcha]=$WORD" \
        -d 'form[start]=' \
        -d "form[_token]=$FORM_TOKEN" \
        "$FREE_URL") || return

    FILE_URL=$(grep_http_header_location_quiet <<< "$PAGE")

    if [ -z "$FILE_URL" ]; then
        captcha_nack $ID
        log_error 'Wrong captcha'
        return $ERR_CAPTCHA
    fi

    captcha_ack $ID
    log_debug 'Correct captcha'

    echo "$FILE_URL"
}

# Probe a download URL
# $1: cookie file (unused here)
# $2: fileshark url
# $3: requested capability list
# stdout: 1 capability per line
fileshark_probe() {
    local -r URL=$2
    local -r REQ_IN=$3
    local PAGE FILE_SIZE REQ_OUT

    PAGE=$(curl -i -L "$URL") || return

    if match '404 Not Found' "$PAGE"; then
        return $ERR_LINK_DEAD
    elif match 'Strona jest dostępna wyłącznie .* na terenie wybranych Państw.' "$PAGE"; then
        log_error 'Free downloads are only allowed from Poland IP addresses.'
        return $ERR_LINK_NEED_PERMISSIONS
    elif match 'Proszę czekać. Kolejne pobranie możliwe za' "$PAGE"; then
        log_error 'The link is temporarily unavailable.'
        return $ERR_LINK_TEMP_UNAVAILABLE
    fi

    REQ_OUT=c

    if [[ $REQ_IN = *f* ]]; then
        parse_tag 'name-file' 'h2' <<< "$PAGE" && REQ_OUT="${REQ_OUT}f"
    fi

    if [[ $REQ_IN = *s* ]]; then
        FILE_SIZE=$(parse_tag 'size-file' 'strong' <<< "$PAGE") \
            && FILE_SIZE=$(replace 'B' 'iB' <<< $FILE_SIZE) \
            && translate_size "$FILE_SIZE" && REQ_OUT="${REQ_OUT}s"
    fi

    if [[ $REQ_IN = *i* ]]; then
        parse 'btn-upload-free' 'normal/\([[:digit:]]\+/[[:alnum:]]\+\)' <<< "$PAGE" \
            && REQ_OUT="${REQ_OUT}i"
    fi

    echo $REQ_OUT
}

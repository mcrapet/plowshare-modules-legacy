# Plowshare sharehost.eu module
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

MODULE_SHAREHOST_REGEXP_URL='https\?://\([[:alnum:]]\+\.\)\?sharehost\.\(eu\|xup\.pl\)/'

MODULE_SHAREHOST_DOWNLOAD_OPTIONS="
AUTH,a,auth,a=USER:PASSWORD,User account"
MODULE_SHAREHOST_DOWNLOAD_RESUME=no
MODULE_SHAREHOST_DOWNLOAD_FINAL_LINK_NEEDS_COOKIE=no
MODULE_SHAREHOST_DOWNLOAD_SUCCESSIVE_INTERVAL=

MODULE_SHAREHOST_PROBE_OPTIONS=""

# Static function. Switch language to english
# $1: cookie file
# $2: base URL
sharehost_switch_lang() {
    curl "$2/language-en" -c "$1" -b "$1" > /dev/null || return
}

# Static function. Proceed with login
# $1: authentication
# $2: cookie file
# $3: base URL
# stdout: account type ("free" or "premium") on success
sharehost_login() {
    local -r AUTH=$1
    local -r COOKIE_FILE=$2
    local -r BASE_URL=$3

    local LOGIN_DATA PAGE STATUS NAME TYPE

    LOGIN_DATA='v=files\|main&c=aut&f=login&friendlyredir=1&usr_login=$USER&usr_pass=$PASSWORD'

    PAGE=$(post_login "$AUTH" "$COOKIE_FILE" "$LOGIN_DATA" \
        "$BASE_URL/index.php" -L -b "$COOKIE_FILE") || return

    # If successful, two entries are added into cookie file: PHPSESSID and utype.
    STATUS=$(parse_cookie_quiet 'utype' < "$COOKIE_FILE")
    [ -z "$STATUS" ] && return $ERR_LOGIN_FAILED

    NAME=$(parse_quiet 'Logged as:' '>\([^<]\+\)</' <<< "$PAGE")
    TYPE=$(parse 'Account status:' '\(free\|premium\)' <<< "$PAGE") || return

    log_debug "Successfully logged in as $TYPE member '$NAME'"
    echo $TYPE
}

# Output a sharehost file download URL
# $1: cookie file
# $2: sharehost url
# stdout: real file download link
sharehost_download() {
    local -r COOKIE_FILE=$1
    local -r BASE_URL='http://sharehost.eu'
    local URL ACCOUNT PAGE FREE_URL WAIT_TIME FILE_URL
    local FORM_HTML FORM_V FORM_C FORM_F FORM_CAP_ID FORM_FIL
    local CAPTCHA_URL CAPTCHA_IMG

    # Get a canonical URL for this file.
    URL=$(curl -I "$2" | grep_http_header_location_quiet) || return
    [ -n "$URL" ] || URL=$2
    readonly URL

    sharehost_switch_lang "$COOKIE_FILE" "$BASE_URL"

    if [ -n "$AUTH" ]; then
        ACCOUNT=$(sharehost_login "$AUTH" "$COOKIE_FILE" "$BASE_URL") || return
    fi

    # Note: Save HTTP headers to catch premium users' "direct downloads".
    PAGE=$(curl -i -b "$COOKIE_FILE" "$URL") || return

    if match 'File is unavailable' "$PAGE"; then
        return $ERR_LINK_DEAD
    fi

    FREE_URL=$(parse "id='main_content'" "href='\([^']*download_free[^']*\)" \
        <<< "$PAGE" | replace_all '&amp;' '&') || return
    FREE_URL="$BASE_URL$FREE_URL"

    # For anonymous downloads only here will be added into cookie a mandatory PHPSESSID.
    PAGE=$(curl -b "$COOKIE_FILE" -c "$COOKIE_FILE" "$FREE_URL" \
        | break_html_lines_alt) || return

    WAIT_TIME=$(parse 'const DOWNLOAD_WAIT' '=\([0-9]\+\);' <<< "$PAGE")
    wait $WAIT_TIME || return

    FORM_HTML=$(grep_form_by_id "$PAGE" 'dwn_free_captcha') || return
    FORM_V=$(parse_form_input_by_name 'v' <<< "$FORM_HTML") || return
    FORM_C=$(parse_form_input_by_name 'c' <<< "$FORM_HTML") || return
    FORM_F=$(parse_form_input_by_name 'f' <<< "$FORM_HTML") || return
    FORM_CAP_ID=$(parse_form_input_by_name 'cap_id' <<< "$FORM_HTML") || return
    FORM_FIL=$(parse_form_input_by_name 'fil' <<< "$FORM_HTML") || return

    CAPTCHA_URL=$(parse_attr "id='captcha_img'" 'src' \
        <<< "$PAGE" | replace_all '&amp;' '&') || return
    CAPTCHA_URL="$BASE_URL$CAPTCHA_URL"
    CAPTCHA_IMG=$(create_tempfile '.png') || return
    curl -o "$CAPTCHA_IMG" "$CAPTCHA_URL" || return

    local WI WORD ID
    WI=$(captcha_process "$CAPTCHA_IMG") || return
    { read WORD; read ID; } <<< "$WI"
    rm -f "$CAPTCHA_IMG"

    PAGE=$(curl -i -b "$COOKIE_FILE" \
        -d "v=$FORM_V" \
        -d "c=$FORM_C" \
        -d "f=$FORM_F" \
        -d "cap_id=$FORM_CAP_ID" \
        -d "fil=$FORM_FIL" \
        -d "cap_key=$WORD" \
        "$BASE_URL") || return

    if match "You can't download any more files at this moment" "$PAGE"; then
        log_error 'Download limit reached.'
        echo 300
        return $ERR_LINK_TEMP_UNAVAILABLE
    elif match 'Incorrect code from image has been entered' "$PAGE"; then
        captcha_nack $ID
        log_error 'Wrong captcha'
        return $ERR_CAPTCHA
    fi

    captcha_ack $ID
    log_debug 'Correct captcha'

    FILE_URL=$(grep_http_header_location <<< "$PAGE") || return

    # Redirects 1 time...
    FILE_URL=$(curl -b "$COOKIE_FILE" -I "$FILE_URL" \
        | grep_http_header_location) || return

    echo "$FILE_URL"
}

# Probe a download URL
# $1: cookie file (unused here)
# $2: sharehost url
# $3: requested capability list
# stdout: 1 capability per line
sharehost_probe() {
    local -r REQ_IN=$3
    local -r API_URL='http://sharehost.eu/fapi/fileInfo'
    local URL JSON STATUS REQ_OUT

    # Get a canonical URL for this file.
    URL=$(curl -I "$2" | grep_http_header_location_quiet) || return
    [ -n "$URL" ] || URL=$2
    readonly URL

    JSON=$(curl -d "url=$URL" "$API_URL") || return
    STATUS=$(parse_json 'success' <<< "$JSON") || return

    if [ "$STATUS" != 'true' ]; then
        return $ERR_LINK_DEAD
    fi

    REQ_OUT=c

    if [[ $REQ_IN = *f* ]]; then
        parse_json 'fileName' <<< "$JSON" && REQ_OUT="${REQ_OUT}f"
    fi

    if [[ $REQ_IN = *s* ]]; then
        parse_json 'fileSize' <<< "$JSON" && REQ_OUT="${REQ_OUT}s"
    fi

    if [[ $REQ_IN = *i* ]]; then
        parse_quiet . 'file/\([^/]\+\)' <<< "$URL" && REQ_OUT="${REQ_OUT}i"
    fi

    echo $REQ_OUT
}

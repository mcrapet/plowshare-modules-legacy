# Plowshare catshare.net module
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

MODULE_CATSHARE_REGEXP_URL='https\?://\([[:alnum:]]\+\.\)\?catshare\.\(net\|xup\.pl\)/'

MODULE_CATSHARE_DOWNLOAD_OPTIONS="
AUTH,a,auth,a=USER:PASSWORD,User account"
MODULE_CATSHARE_DOWNLOAD_RESUME=no
MODULE_CATSHARE_DOWNLOAD_FINAL_LINK_NEEDS_COOKIE=no
MODULE_CATSHARE_DOWNLOAD_SUCCESSIVE_INTERVAL=

MODULE_CATSHARE_PROBE_OPTIONS=""

# Static function. Proceed with login
# $1: authentication
# $2: cookie file
# $3: base URL
# stdout: account type ("free" or "premium") on success
catshare_login() {
    local -r AUTH=$1
    local -r COOKIE_FILE=$2
    local -r BASE_URL=$3

    local LOGIN_DATA PAGE STATUS NAME TYPE

    LOGIN_DATA='user_email=$USER&user_password=$PASSWORD&remindPassword=0'

    PAGE=$(post_login "$AUTH" "$COOKIE_FILE" "$LOGIN_DATA" \
        "$BASE_URL/login" -L) || return

    # If successful an entry is added into a cookie file: session_id
    STATUS=$(parse_cookie_quiet 'session_id' < "$COOKIE_FILE")
    [ -z "$STATUS" ] && return $ERR_LOGIN_FAILED

    NAME=$(parse_quiet '"/account"' 'i>\([^<]*\)</' 1 <<< "$PAGE")
    TYPE=$(parse '"/account"'  '>\([^<]*\)</' 5 <<< "$PAGE") || return

    if [ "$TYPE" = 'Darmowe' ]; then
        TYPE='free'
    elif [ "$TYPE" = 'Premium' ]; then
        TYPE='premium'
    fi

    log_debug "Successfully logged in as $TYPE member '$NAME'"
    echo $TYPE
}

# Output a catshare.net file download URL
# $1: cookie file
# $2: catshare.net url
# stdout: real file download link
catshare_download() {
    local -r COOKIE_FILE=$1
    local -r BASE_URL='http://catshare.net'
    local URL ACCOUNT PAGE WAIT_TIME FILE_URL

    # Get a canonical URL for this file.
    URL=$(curl -I "$2" | grep_http_header_location_quiet) || return
    [ -n "$URL" ] || URL=$2
    readonly URL

    if [ -n "$AUTH" ]; then
        ACCOUNT=$(catshare_login "$AUTH" "$COOKIE_FILE" "$BASE_URL") || return
    fi

    # Note: Save HTTP headers to catch premium users' "direct downloads".
    PAGE=$(curl -i -b "$COOKIE_FILE" "$URL") || return

    if match "Nasz serwis wykrył że Twój adres IP nie pochodzi z Polski." "$PAGE"; then
        log_error 'Free downloads are only allowed from Poland IP addresses.'
        return $ERR_LINK_NEED_PERMISSIONS
    elif match "Podany plik został usunięty\|<title>Error 404</title>" "$PAGE"; then
        return $ERR_LINK_DEAD
    fi

    # If this is a premium download, we already have a download link.
    if [ "$ACCOUNT" = 'premium' ]; then
        MODULE_CATSHARE_DOWNLOAD_RESUME=yes

        # Get a download link, if this was a direct download.
        FILE_URL=$(grep_http_header_location_quiet <<< "$PAGE")

        if [ -z "$FILE_URL" ]; then
            FILE_URL=$(parse_attr '<form.*method="GET">' 'action' <<< "$PAGE") || return
        fi

        echo "$FILE_URL"
        return 0
    fi

    WAIT_TIME=$(parse 'var count = ' 'var count = \([0-9]\+\)' <<< "$PAGE") || return
    # Note: If we wait more then 5 minutes then we definitely reached downloads limit.
    if [[ $WAIT_TIME -gt 300 ]]; then
        log_error 'Download limit reached.'
        echo $WAIT_TIME
        return $ERR_LINK_TEMP_UNAVAILABLE
    fi
    wait $WAIT_TIME || return

    local PUBKEY WCI CHALLENGE WORD ID
    # http://www.google.com/recaptcha/api/challenge?k=
    PUBKEY=$(parse 'recaptcha.*?k=' '?k=\([[:alnum:]_-.]\+\)' <<< "$PAGE") || return
    WCI=$(recaptcha_process $PUBKEY) || return
    { read WORD; read CHALLENGE; read ID; } <<< "$WCI"

    PAGE=$(curl -b "$COOKIE_FILE" \
        -d "recaptcha_challenge_field=$CHALLENGE" \
        -d "recaptcha_response_field=$WORD" \
        "$URL") || return

    FILE_URL=$(parse_attr_quiet '<form.*method="GET">' 'action' <<< "$PAGE")

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
# $2: catshare.net url
# $3: requested capability list
# stdout: 1 capability per line
catshare_probe() {
    local -r URL=$2
    local -r REQ_IN=$3
    local PAGE FILE_SIZE REQ_OUT

    PAGE=$(curl -L "$URL") || return

    if match "Nasz serwis wykrył że Twój adres IP nie pochodzi z Polski." "$PAGE"; then
        log_error 'Free downloads are only allowed from Poland IP addresses.'
        return $ERR_LINK_NEED_PERMISSIONS
    elif match "Podany plik został usunięty\|<title>Error 404</title>" "$PAGE"; then
        return $ERR_LINK_DEAD
    fi

    REQ_OUT=c

    if [[ $REQ_IN = *f* ]]; then
        parse_tag 'class="pull-left"' h3 <<< "$PAGE" && REQ_OUT="${REQ_OUT}f"
    fi

    if [[ $REQ_IN = *s* ]]; then
        FILE_SIZE=$(parse_tag 'class="pull-right"' h3 <<< "$PAGE") \
            && FILE_SIZE=$(replace 'B' 'iB' <<< $FILE_SIZE) \
            && translate_size "$FILE_SIZE" && REQ_OUT="${REQ_OUT}s"
    fi

    if [[ $REQ_IN = *i* ]]; then
        parse 'property="og:url"' '.*/\([[:alnum:]]\+\)"' <<< "$PAGE" \
            && REQ_OUT="${REQ_OUT}i"
    fi

    echo $REQ_OUT
}

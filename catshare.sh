# Plowshare catshare.net module
# Copyright (c) 2015 Raziel-23
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
MODULE_CATSHARE_DOWNLOAD_FINAL_LINK_NEEDS_COOKIE=yes
MODULE_CATSHARE_DOWNLOAD_SUCCESSIVE_INTERVAL=

MODULE_CATSHARE_PROBE_OPTIONS=""

# Static function. Proceed with login (free)
# $1: authentication
# $2: cookie file
# $3: base URL
catshare_login() {
    local -r AUTH=$1
    local -r COOKIE_FILE=$2
    local -r BASE_URL=$3

    local LOGIN_DATA PAGE STATUS NAME

    LOGIN_DATA='user_email=$USER&user_password=$PASSWORD&remindPassword=0'

    PAGE=$(post_login "$AUTH" "$COOKIE_FILE" "$LOGIN_DATA" \
        "$BASE_URL/login" -L) || return

    # If successful an entry is added into a cookie file: session_id
    STATUS=$(parse_cookie_quiet 'session_id' < "$COOKIE_FILE")
    [ -z "$STATUS" ] && return $ERR_LOGIN_FAILED

    NAME=$(echo "$PAGE" | parse 'Zalogowano' \
            'Zalogowano \(.\+\)</a>') || return

    log_debug "Successfully logged in as member '$NAME'"
}

# Output a catshare.net file download URL
# $1: cookie file
# $2: catshare.net url
# stdout: real file download link
catshare_download() {
    local -r COOKIE_FILE=$1
    local URL=$2
    local -r BASE_URL='http://catshare.net'
    local REAL_URL PAGE WAIT_TIME FILE_URL

    # Get a canonical URL for this file.
    REAL_URL=$(curl -I "$URL" | grep_http_header_location_quiet) || return
    if test "$REAL_URL"; then
        URL="$REAL_URL"
    fi
    readonly URL

    if [ -n "$AUTH" ]; then
        catshare_login "$AUTH" "$COOKIE_FILE" "$BASE_URL" || return
    fi

    PAGE=$(curl -c "$COOKIE_FILE" -b "$COOKIE_FILE" "$URL") || return

    if match "Nasz serwis wykrył że Twój adres IP nie pochodzi z Polski." "$PAGE"; then
        log_error 'Free downloads are only allowed from Poland IP addresses.'
        return $ERR_LINK_NEED_PERMISSIONS
    elif match "Podany plik został usunięty\|<title>Error 404</title>" "$PAGE"; then
        return $ERR_LINK_DEAD
    fi

    WAIT_TIME=$(parse 'var count = ' 'var count = \([0-9]\+\)' <<< "$PAGE") || return
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

    FILE_URL=$(parse_attr_quiet '<form.*method="GET">' 'action' <<< "$PAGE") || return

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

    if match "Podany plik został usunięty\|<title>Error 404</title>" "$PAGE"; then
        return $ERR_LINK_DEAD
    fi

    REQ_OUT=c

    if [[ $REQ_IN = *f* ]]; then
        parse_tag 'class="pull-left"' h3 <<< "$PAGE" && REQ_OUT="${REQ_OUT}f"
    fi

    if [[ $REQ_IN = *s* ]]; then
        FILE_SIZE=$(parse_tag 'class="pull-right"' h3 <<< "$PAGE") && \
            translate_size "$FILE_SIZE" && REQ_OUT="${REQ_OUT}s"
    fi

    if [[ $REQ_IN = *i* ]]; then
        parse 'property="og:url"' '.*/\([[:alnum:]]\+\)"' <<< "$PAGE" && \
            REQ_OUT="${REQ_OUT}i"
    fi

    echo $REQ_OUT
}

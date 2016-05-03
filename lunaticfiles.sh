# Plowshare lunaticfiles.com module
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

MODULE_LUNATICFILES_REGEXP_URL='https\?://\([[:alnum:]]\+\.\)\?lunaticfiles\.\(com\|xup\.pl\)/'

MODULE_LUNATICFILES_DOWNLOAD_OPTIONS="
AUTH,a,auth,a=USER:PASSWORD,User account"
MODULE_LUNATICFILES_DOWNLOAD_RESUME=no
MODULE_LUNATICFILES_DOWNLOAD_FINAL_LINK_NEEDS_COOKIE=no
MODULE_LUNATICFILES_DOWNLOAD_SUCCESSIVE_INTERVAL=

MODULE_LUNATICFILES_PROBE_OPTIONS=""

# Switch language to english
# $1: cookie file
# $2: base URL
lunaticfiles_switch_lang() {
    curl "$2" -c "$1" -b "$1" -d 'op=change_lang' \
        -d 'lang=english' > /dev/null || return
}

# Static function. Proceed with login (free)
# $1: authentication
# $2: cookie file
# $3: base URL
lunaticfiles_login() {
    local -r AUTH=$1
    local -r COOKIE_FILE=$2
    local -r BASE_URL=$3

    local LOGIN_DATA PAGE STATUS NAME

    LOGIN_DATA='op=login&redirect=&login=$USER&password=$PASSWORD'

    PAGE=$(post_login "$AUTH" "$COOKIE_FILE" "$LOGIN_DATA" \
        "$BASE_URL/login.html" -L -b "$COOKIE_FILE") || return

    # If successful, two entries are added into cookie file: login and xfss.
    STATUS=$(parse_cookie_quiet 'xfss' < "$COOKIE_FILE")
    [ -z "$STATUS" ] && return $ERR_LOGIN_FAILED

    NAME=$(parse_cookie_quiet 'login' < "$COOKIE_FILE")
    log_debug "Successfully logged in as member '$NAME'"
}

# Output a lunaticfiles file download URL
# $1: cookie file
# $2: lunaticfiles url
# stdout: real file download link
lunaticfiles_download() {
    local -r COOKIE_FILE=$1
    local -r BASE_URL='http://lunaticfiles.com/'
    local URL PAGE WAIT_TIME FILE_URL
    local FORM_HTML FORM_OP FORM_USR FORM_ID FORM_FNAME FORM_REF
    local FORM_METHOD_F FORM_METHOD_P FORM_RAND FORM_DS FORM_SUBMIT

    # Get a canonical URL for this file.
    URL=$(curl -I "$2" | grep_http_header_location_quiet) || return
    [ -n "$URL" ] || URL=$2
    readonly URL

    lunaticfiles_switch_lang "$COOKIE_FILE" "$BASE_URL"

    if [ -n "$AUTH" ]; then
        lunaticfiles_login "$AUTH" "$COOKIE_FILE" "$BASE_URL" || return
    fi

    PAGE=$(curl -b "$COOKIE_FILE" "$URL") || return

    if match 'File Not Found\|No such file with this filename' "$PAGE"; then
        return $ERR_LINK_DEAD
    fi

    FORM_HTML=$(grep_form_by_order "$PAGE" 3) || return
    FORM_OP=$(parse_form_input_by_name 'op' <<< "$FORM_HTML") || return
    FORM_USR=$(parse_form_input_by_name_quiet 'usr_login' <<< "$FORM_HTML")
    FORM_ID=$(parse_form_input_by_name 'id' <<< "$FORM_HTML") || return
    FORM_FNAME=$(parse_form_input_by_name 'fname' <<< "$FORM_HTML") || return
    FORM_REF=$(parse_form_input_by_name_quiet 'referer' <<< "$FORM_HTML")
    FORM_METHOD_F=$(parse_form_input_by_name_quiet 'method_free' <<< "$FORM_HTML")

    PAGE=$(curl -b "$COOKIE_FILE" \
        -d "op=$FORM_OP" \
        -d "usr_login=$FORM_USR" \
        -d "id=$FORM_ID" \
        -d "fname=$FORM_FNAME" \
        -d "referer=$FORM_REF" \
        -d "method_free=$FORM_METHOD_F" \
        "$URL") || return

    # Warning! You have reached your daily downloads limit.
    if match 'Przekroczono dobowy limit transferu.' "$PAGE"; then
        log_error 'Daily download limit reached.'
        echo 600
        return $ERR_LINK_TEMP_UNAVAILABLE

    # Warning! Without premium status, you can download only one file at a time.
    elif match 'Pobierasz już jeden plik z naszych serwerów!' "$PAGE"; then
        log_error 'No parallel download allowed.'
        echo 120
        return $ERR_LINK_TEMP_UNAVAILABLE
    fi

    FORM_HTML=$(grep_form_by_name "$PAGE" 'F1') || return
    FORM_OP=$(parse_form_input_by_name 'op' <<< "$FORM_HTML") || return
    FORM_ID=$(parse_form_input_by_name 'id' <<< "$FORM_HTML") || return
    FORM_RAND=$(parse_form_input_by_name 'rand' <<< "$FORM_HTML") || return
    FORM_REF=$(parse_form_input_by_name_quiet 'referer' <<< "$FORM_HTML")
    FORM_METHOD_F=$(parse_form_input_by_name_quiet 'method_free' <<< "$FORM_HTML")
    FORM_METHOD_P=$(parse_form_input_by_name_quiet 'method_premium' <<< "$FORM_HTML")
    FORM_DS=$(parse_form_input_by_name 'down_script' <<< "$FORM_HTML") || return

    WAIT_TIME=$(parse_tag countdown_str span <<< "$PAGE") || return
    wait $WAIT_TIME || return

    local PUBKEY WCI CHALLENGE WORD ID
    # http://www.google.com/recaptcha/api/challenge?k=
    PUBKEY=$(parse 'recaptcha.*?k=' '?k=\([[:alnum:]_-.]\+\)' <<< "$PAGE") || return
    WCI=$(recaptcha_process $PUBKEY) || return
    { read WORD; read CHALLENGE; read ID; } <<< "$WCI"

    PAGE=$(curl -i -b "$COOKIE_FILE" \
        -d "op=$FORM_OP" \
        -d "id=$FORM_ID" \
        -d "rand=$FORM_RAND" \
        -d "referer=$FORM_REF" \
        -d "method_free=$FORM_METHOD_F" \
        -d "method_premium=$FORM_METHOD_P" \
        -d "recaptcha_challenge_field=$CHALLENGE" \
        -d "recaptcha_response_field=$WORD" \
        -d "down_script=$FORM_DS" \
        "$URL") || return

    if match 'We are sorry, we allow downloads only from Poland.' "$PAGE"; then
        log_error 'Free downloads are only allowed from Poland IP addresses.'
        return $ERR_LINK_NEED_PERMISSIONS
    fi

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
# $2: lunaticfiles url
# $3: requested capability list
# stdout: 1 capability per line
lunaticfiles_probe() {
    local -r URL=$2
    local -r REQ_IN=$3
    local PAGE FILE_SIZE REQ_OUT

    PAGE=$(curl -L -b 'lang=english' "$URL") || return

    if match "File Not Found\|No such file with this filename" "$PAGE"; then
        return $ERR_LINK_DEAD
    fi

    REQ_OUT=c

    if [[ $REQ_IN = *f* ]]; then
        parse_form_input_by_name 'fname' <<< "$PAGE" && REQ_OUT="${REQ_OUT}f"
    fi

    if [[ $REQ_IN = *s* ]]; then
        FILE_SIZE=$(parse '<[Pp][[:space:]].*\[' '\[\(.*\)\]' <<< "$PAGE") \
            && FILE_SIZE=$(replace 'B' 'iB' <<< $FILE_SIZE) \
            && translate_size "$FILE_SIZE" && REQ_OUT="${REQ_OUT}s"
    fi

    if [[ $REQ_IN = *i* ]]; then
        parse_form_input_by_name 'id' <<< "$PAGE" && REQ_OUT="${REQ_OUT}i"
    fi

    echo $REQ_OUT
}

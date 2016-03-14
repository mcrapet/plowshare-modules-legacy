# Plowshare prefiles.com module
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

MODULE_PREFILES_REGEXP_URL='https\?://\(www\.\)\?prefiles\.com/'

MODULE_PREFILES_DOWNLOAD_OPTIONS="
AUTH_FREE,b,auth-free,a=USER:PASSWORD,Free account"
MODULE_PREFILES_DOWNLOAD_RESUME=yes
MODULE_PREFILES_DOWNLOAD_FINAL_LINK_NEEDS_COOKIE=no
MODULE_PREFILES_DOWNLOAD_SUCCESSIVE_INTERVAL=

MODULE_PREFILES_PROBE_OPTIONS=""

# Static function. Proceed with login
# $1: authentication
# $2: cookie file
# $3: base URL
# stdout: account type ("free" or "premium") on success.
prefiles_login() {
    local -r AUTH=$1
    local -r COOKIE_FILE=$2
    local -r BASE_URL=$3
    local CV PAGE SESS MSG LOGIN_DATA STATUS NAME TYPE

    if CV=$(storage_get 'cookie_file'); then
        echo "$CV" >"$COOKIE_FILE"

        # Check for expired session.
        PAGE=$(curl -b "$COOKIE_FILE" "$BASE_URL/settings") || return
        if ! match '>Membership:<' "$PAGE"; then
            storage_set 'cookie_file'
            return $ERR_EXPIRED_SESSION
        fi

        SESS=$(parse_cookie 'xfss' < "$COOKIE_FILE")
        log_debug "session (cached): '$SESS'"
        MSG='reused login for'
    else
        LOGIN_DATA='op=login&redirect=settings&login=$USER&password=$PASSWORD'

        PAGE=$(post_login "$AUTH" "$COOKIE_FILE" "$LOGIN_DATA" \
            "$BASE_URL/login" -L) || return

        # If successful, two entries are added into cookie file: login and xfss.
        STATUS=$(parse_cookie_quiet 'xfss' < "$COOKIE_FILE")
        [ -z "$STATUS" ] && return $ERR_LOGIN_FAILED

        storage_set 'cookie_file' "$(cat "$COOKIE_FILE")"

        SESS=$(parse_cookie 'xfss' < "$COOKIE_FILE")
        log_debug "session (new): '$SESS'"
        MSG='logged in as'
    fi

    NAME=$(parse_cookie_quiet 'login' < "$COOKIE_FILE")
    TYPE=$(parse '>Membership:<' '>\(Registered\|Premium\)' <<< "$PAGE") || return

    if [ "$TYPE" = 'Registered' ]; then
        TYPE='free'
    elif [ "$TYPE" = 'Premium' ]; then
        TYPE='premium'
    fi

    log_debug "Successfully $MSG '$TYPE' member '$NAME'"
    echo $TYPE
}

# Output a prefiles file download URL
# $1: cookie file
# $2: prefiles url
# stdout: real file download link
prefiles_download() {
    local -r COOKIE_FILE=$1
    local -r BASE_URL='http://prefiles.com/'
    local URL ACCOUNT PAGE WAIT_TIME CAPTCHA_DATA FILE_URL

    # Get a canonical URL for this file.
    URL=$(curl -I "$2" | grep_http_header_location_quiet) || return
    [ -n "$URL" ] || URL=$2
    readonly URL

    if [ -n "$AUTH_FREE" ]; then
        ACCOUNT=$(prefiles_login "$AUTH_FREE" "$COOKIE_FILE" "$BASE_URL") || return
    fi

    # Note: Save HTTP headers to catch premium users' "direct downloads".
    PAGE=$(curl -b "$COOKIE_FILE" -c "$COOKIE_FILE" -i "$URL") || return

    if match '>The file .* could not be found<\|404 Not Found' "$PAGE"; then
        return $ERR_LINK_DEAD
    fi

    # Note: (Untested) Premium download - we already have a download link.
    if [ "$ACCOUNT" = 'premium' ]; then
        # Get a download link, if this was a direct download.
        FILE_URL=$(grep_http_header_location_quiet <<< "$PAGE")

        if [ -z "$FILE_URL" ]; then
            FILE_URL=$(parse 'class="download_method' 'href="\(.*\)">' 2 <<< "$PAGE") || return
        fi

        echo "$FILE_URL"
        return 0
    fi

    local FORM_NUM FORM_HTML FORM_OP FORM_USR FORM_ID FORM_FNAME FORM_REFERER FORM_METHOD_F
    local FORM_RAND FORM_METHOD_P FORM_DD
    # Note: Anonymous download - the relevant form is the second one.
    [ -z "$ACCOUNT" ] && FORM_NUM=2
    FORM_HTML=$(grep_form_by_order "$PAGE" "$FORM_NUM") || return
    FORM_OP=$(parse_form_input_by_name 'op' <<< "$FORM_HTML") || return
    FORM_USR=$(parse_form_input_by_name_quiet 'usr_login' <<< "$FORM_HTML")
    FORM_ID=$(parse_form_input_by_name 'id' <<< "$FORM_HTML") || return
    FORM_FNAME=$(parse_form_input_by_name 'fname' <<< "$FORM_HTML") || return
    FORM_REFERER=$(parse_form_input_by_name_quiet 'referer' <<< "$FORM_HTML")
    FORM_METHOD_F=$(parse_attr 'id="method_free"' 'value' <<< "$FORM_HTML") || return

    PAGE=$(curl -b "$COOKIE_FILE" \
        -d "op=$FORM_OP" \
        -d "usr_login=$FORM_USR" \
        -d "id=$FORM_ID" \
        -d "fname=$FORM_FNAME" \
        -d "referer=$FORM_REFERER" \
        -d "method_free=$FORM_METHOD_F" \
        "$URL") || return

    if match '>This file is available for Premium Users only<' "$PAGE"; then
        log_error 'This file is available for Premium Users only.'
        return $ERR_LINK_NEED_PERMISSIONS
    elif match '>You have to wait .* until the next download.<' "$PAGE"; then
        local HOURS MINS SECS
        HOURS=$(parse_quiet '>You have to wait' \
            '[^[:digit:]]\([[:digit:]]\+\) hours\?' <<< "$PAGE")
        MINS=$(parse_quiet  '>You have to wait' \
            '[^[:digit:]]\([[:digit:]]\+\) minutes\?' <<< "$PAGE")
        SECS=$(parse_quiet  '>You have to wait' \
            '[^[:digit:]]\([[:digit:]]\+\) seconds\?' <<< "$PAGE")

        log_error 'Download limit reached.'
        # Note: Always use decimal base instead of octal if there are leading zeros.
        echo $(( (( 10#$HOURS * 60 ) + 10#$MINS ) * 60 + 10#$SECS ))
        return $ERR_LINK_TEMP_UNAVAILABLE
    fi

    FORM_HTML=$(grep_form_by_name "$PAGE" 'F1') || return
    FORM_OP=$(parse_form_input_by_name 'op' <<< "$FORM_HTML") || return
    FORM_ID=$(parse_form_input_by_name 'id' <<< "$FORM_HTML") || return
    FORM_RAND=$(parse_form_input_by_name 'rand' <<< "$FORM_HTML") || return
    FORM_REFERER=$(parse_form_input_by_name_quiet 'referer' <<< "$FORM_HTML")
    FORM_METHOD_F=$(parse_form_input_by_name 'method_free' <<< "$FORM_HTML") || return
    FORM_METHOD_P=$(parse_form_input_by_name_quiet 'method_premium' <<< "$FORM_HTML")
    FORM_DD=$(parse 'down_direct' 'down_direct" value="\([^"]\+\)"' <<< "$FORM_HTML") || return

    WAIT_TIME=$(parse_tag 'id="countdown_str"' 'span' <<< "$PAGE") || return
    wait $WAIT_TIME || return

    # Note: Anonymous download - we have to resolve recaptcha.
    if match 'recaptcha' "$FORM_HTML"; then
        local PUBKEY WCI CHALLENGE WORD ID
        PUBKEY='6LddPc8SAAAAAAEWe0qoJ4P7U_XSKtBoxj3OJ1OJ'
        WCI=$(recaptcha_process $PUBKEY) || return
        { read WORD; read CHALLENGE; read ID; } <<< "$WCI"
        CAPTCHA_DATA="-d recaptcha_challenge_field=$CHALLENGE -d recaptcha_response_field=$WORD"
    fi

    PAGE=$(curl -b "$COOKIE_FILE" \
        -d "op=$FORM_OP" \
        -d "id=$FORM_ID" \
        -d "rand=$FORM_RAND" \
        -d "referer=$FORM_REFERER" \
        -d "method_free=$FORM_METHOD_F" \
        -d "method_premium=$FORM_METHOD_P" \
        -d "down_direct=$FORM_DD" \
        $CAPTCHA_DATA \
        "$URL") || return

    # Note: Anonymous download - check if recaptcha was resolved correctly.
    if [ -n "$CAPTCHA_DATA" ]; then
        if match '>Wrong captcha<' "$PAGE"; then
            captcha_nack $ID
            log_error 'Wrong captcha'
            return $ERR_CAPTCHA
        fi

        captcha_ack $ID
        log_debug 'Correct captcha'
    fi

    FILE_URL=$(parse 'class="download_method' 'href="\(.*\)">' 2 <<< "$PAGE") || return
    echo "$FILE_URL"
}

# Probe a download URL
# $1: cookie file (unused here)
# $2: prefiles url
# $3: requested capability list
# stdout: 1 capability per line
prefiles_probe() {
    local -r URL=$2
    local -r REQ_IN=$3
    local PAGE FILE_SIZE REQ_OUT

    PAGE=$(curl -i -L "$URL") || return

    if match '>The file .* could not be found<\|404 Not Found' "$PAGE"; then
        return $ERR_LINK_DEAD
    fi

    REQ_OUT=c

    if [[ $REQ_IN = *f* ]]; then
        parse_form_input_by_name 'fname' <<< "$PAGE" && REQ_OUT="${REQ_OUT}f"
    fi

    if [[ $REQ_IN = *s* ]]; then
        FILE_SIZE=$(parse 'class="filename_bar"' '>(\(.*\))<' <<< "$PAGE") \
            && FILE_SIZE=$(replace 'B' 'iB' <<< $FILE_SIZE) \
            && translate_size "$FILE_SIZE" && REQ_OUT="${REQ_OUT}s"
    fi

    if [[ $REQ_IN = *i* ]]; then
        parse_form_input_by_name 'id' <<< "$PAGE" && REQ_OUT="${REQ_OUT}i"
    fi

    echo $REQ_OUT
}

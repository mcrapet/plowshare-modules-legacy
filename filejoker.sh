# Plowshare filejoker.net module
# by idleloop <idleloop@yahoo.com>, v1.2, Feb 2016
# Copyright (c) 2017 Plowshare team
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

MODULE_FILEJOKER_REGEXP_URL='https\?://\(www\.\)\?filejoker\.net/[[:alnum:]]\+'

MODULE_FILEJOKER_DOWNLOAD_OPTIONS="
AUTH,a,auth,a=EMAIL:PASSWORD,User account"
MODULE_FILEJOKER_DOWNLOAD_RESUME=no
MODULE_FILEJOKER_DOWNLOAD_FINAL_LINK_NEEDS_COOKIE=no
MODULE_FILEJOKER_DOWNLOAD_SUCCESSIVE_INTERVAL=

MODULE_FILEJOKER_PROBE_OPTIONS=""

# Static function. Proceed with login
# $1: authentication
# $2: cookie file
# $3: base URL
# stdout: account type ("free" or "premium") on success.
filejoker_login() {
    local -r AUTH=$1
    local -r COOKIE_FILE=$2
    local -r BASE_URL=$3
    local CV PAGE SESS MSG LOGIN_DATA DATA_STATUS DATA_CATPCHA NAME TYPE

    if CV=$(storage_get 'cookie_file'); then
        echo "$CV" >"$COOKIE_FILE"

        # Check for expired session.
        PAGE=$(curl -b "$COOKIE_FILE" "$BASE_URL/profile") || return
        if ! match '>Username:<' "$PAGE"; then
            storage_set 'cookie_file'
            return $ERR_EXPIRED_SESSION
        fi

        SESS=$(parse_cookie 'xfss' < "$COOKIE_FILE")
        log_debug "session (cached): '$SESS'"
        MSG='reused login for'
    else
        LOGIN_DATA='email=$USER&password=$PASSWORD&recaptcha_response_field=&op=login&redirect=&rand='

        PAGE=$(post_login "$AUTH" "$COOKIE_FILE" "$LOGIN_DATA" \
            "$BASE_URL/login" -H 'X-Requested-With: XMLHttpRequest') || return

        DATA_STATUS=$(parse_attr_quiet 'data-status' <<< "$PAGE")
        DATA_CATPCHA=$(parse_attr_quiet 'data-captcha' <<< "$PAGE")

        # During login we may encounter recaptcha, mainly because
        # we provide a couple of times incorrect username/password.
        if [ "$DATA_STATUS" == 'bad' -a "$DATA_CATPCHA" != 'yes' ]; then
            return $ERR_LOGIN_FAILED

        elif [ "$DATA_STATUS" == 'bad' -a "$DATA_CATPCHA" == 'yes' ]; then
            local USER PASSWORD FORM_RAND PUBKEY RESP WORD CHALL ID

            log_debug 'reCaptcha found during login'
            split_auth "$AUTH" USER PASSWORD || return

            # We have to get a random value from server by setting appropriate cookie.
            PAGE=$(curl -H 'X-Requested-With: XMLHttpRequest' \
                -H "Cookie: email=$USER" "$BASE_URL/login") || return

            FORM_RAND=$(parse_form_input_by_name 'rand' <<< "$PAGE") || return

            PUBKEY='6LetAu0SAAAAACCJkqZLvjNS4L7eSL8fGxr-Jzy2'
            RESP=$(recaptcha_process $PUBKEY) || return
            { read WORD; read CHALL; read ID; } <<< "$RESP"

            LOGIN_DATA='email=$USER&password=$PASSWORD&recaptcha_challenge_field='$CHALL'&recaptcha_response_field='$WORD'&op=login&redirect=&rand='$FORM_RAND''

            PAGE=$(post_login "$AUTH" "$COOKIE_FILE" "$LOGIN_DATA" \
                "$BASE_URL/login" -H 'X-Requested-With: XMLHttpRequest') || return

            DATA_STATUS=$(parse_attr_quiet 'data-status' <<< "$PAGE")
            DATA_CATPCHA=$(parse_attr_quiet 'data-captcha' <<< "$PAGE")

            if [ "$DATA_STATUS" == 'bad' -a "$DATA_CATPCHA" != 'yes' ]; then
                return $ERR_LOGIN_FAILED

            elif [ "$DATA_STATUS" == 'bad' -a "$DATA_CATPCHA" == 'yes' ]; then
                log_error 'Wrong login captcha'
                captcha_nack "$ID"
                return $ERR_CAPTCHA
            fi

            log_debug 'Correct login captcha'
            captcha_ack "$ID"
        fi

        storage_set 'cookie_file' "$(cat "$COOKIE_FILE")"

        SESS=$(parse_cookie 'xfss' < "$COOKIE_FILE")
        log_debug "session (new): '$SESS'"
        MSG='logged in as'

        PAGE=$(curl -b "$COOKIE_FILE" "$BASE_URL/profile") || return
    fi

    NAME=$(parse_cookie_quiet 'email' < "$COOKIE_FILE")

    if match '>Buy Premium<' "$PAGE"; then
        TYPE='free'
    else
        TYPE='premium'
    fi

    log_debug "Successfully $MSG '$TYPE' member '$NAME'"
    echo $TYPE
}

# Output a filejoker file download URL
# $1: cookie file (unused here)
# $2: filejoker url
# stdout: real file download link
filejoker_download() {
    local -r COOKIE_FILE=$1
    local -r BASE_URL='https://filejoker.net'
    local URL PAGE FILE_URL WAIT_TIME ERR FORM_HTML FORM_OP FORM_USR FORM_ID
    local FORM_FNAME FORM_REF FORM_METHOD_F FORM_METHOD_P FORM_RAND FORM_DD

    # Get a canonical URL for this file.
    URL=$(curl -I "$2" | grep_http_header_location_quiet) || return
    [ -n "$URL" ] || URL=$2
    readonly URL

    if [ -n "$AUTH" ]; then
        ACCOUNT=$(filejoker_login "$AUTH" "$COOKIE_FILE" "$BASE_URL") || return
    fi

    # Note: Save HTTP headers to catch premium users' "direct downloads".
    PAGE=$(curl -i -b "$COOKIE_FILE" -c "$COOKIE_FILE" "$URL") || return

    # The file link that you requested is not valid (anymore).
    if match 'File Not Found' "$PAGE"; then
        return $ERR_LINK_DEAD

    # The file link that you requested is incorrect.
    elif ! match 'div class="name-size"' "$PAGE"; then
        return $ERR_LINK_DEAD
    fi

    # If this is a premium download, we already have a download link.
    if [ "$ACCOUNT" = 'premium' ]; then
        MODULE_FILEJOKER_DOWNLOAD_RESUME=yes

        # Get a download link, if this was a direct download.
        FILE_URL=$(grep_http_header_location_quiet <<< "$PAGE")

        if [ -z "$FILE_URL" ]; then
            : # Not implemented.
        fi

        echo "$FILE_URL"
        return 0
    fi

    if match '<div class="premium-download-expand">' "$PAGE"; then
        return $ERR_LINK_NEED_PERMISSIONS
    fi

    FORM_HTML=$(grep_form_by_name "$PAGE" 'F22') || return
    FORM_OP=$(parse_form_input_by_name 'op' <<< "$FORM_HTML") || return
    FORM_USR=$(parse_form_input_by_name_quiet 'usr_login' <<< "$FORM_HTML")
    FORM_ID=$(parse_form_input_by_name 'id' <<< "$FORM_HTML") || return
    FORM_FNAME=$(parse_form_input_by_name 'fname' <<< "$FORM_HTML") || return
    FORM_REF=$(parse_form_input_by_name_quiet 'referer' <<< "$FORM_HTML")
    FORM_METHOD_F=$(parse_form_input_by_name 'method_free' <<< "$FORM_HTML") || return

    PAGE=$(curl -b "$COOKIE_FILE" \
        -F "op=$FORM_OP" \
        -F "usr_login=$FORM_USR" \
        -F "id=$FORM_ID" \
        -F "fname=$FORM_FNAME" \
        -F "referer=$FORM_REF" \
        -F "method_free=$FORM_METHOD_F" \
        "$URL") || return

    # Check for forced delay.
    if matchi 'Please wait .* until the next download' "$PAGE"; then
        local HOURS MINS SECS
        HOURS=$(parse_quiet 'Please wait .* until the next download' \
            ' \([[:digit:]]\+\) hour' <<< "$PAGE")
        MINS=$(parse_quiet 'Please wait .* until the next download' \
            ' \([[:digit:]]\+\) minute' <<< "$PAGE")
        SECS=$(parse_quiet 'Please wait .* until the next download' \
            ', \([[:digit:]]\+\) second' <<< "$PAGE")

        log_error 'Forced delay between downloads.'
        # Note: Always use decimal base instead of octal if there are leading zeros.
        echo $(( (( 10#$HOURS * 60 ) + 10#$MINS ) * 60 + 10#$SECS ))
        return $ERR_LINK_TEMP_UNAVAILABLE
    fi

    if match "Free user can't download large files" "$PAGE" ; then
        return $ERR_LINK_NEED_PERMISSIONS
    fi

    FORM_HTML=$(grep_form_by_name "$PAGE" 'F1') || return
    FORM_OP=$(parse_form_input_by_name 'op' <<< "$FORM_HTML") || return
    FORM_ID=$(parse_form_input_by_name 'id' <<< "$FORM_HTML") || return
    FORM_RAND=$(parse_form_input_by_name 'rand' <<< "$FORM_HTML") || return
    FORM_REF=$(parse_form_input_by_name_quiet 'referer' <<< "$FORM_HTML")
    FORM_METHOD_F=$(parse_form_input_by_name 'method_free' <<< "$FORM_HTML") || return
    FORM_METHOD_P=$(parse_form_input_by_name_quiet 'method_premium' <<< "$FORM_HTML")
    FORM_DD=$(parse_form_input_by_name 'down_direct' <<< "$FORM_HTML") || return

    WAIT_TIME=$(parse_quiet 'Please Wait ' \
        'Wait <.\+>\([[:digit:]]\+\)<.\+> seconds' <<< "$PAGE")

    if [ -n "$WAIT_TIME" ]; then
        wait $(( WAIT_TIME + 1 )) || return
    fi

    # Check for and handle CAPTCHA (if any).
    local PUBKEY RESP WORD CHALL ID CAPTCHA_DATA

    if match 'recaptcha_challenge_field' "$FORM_HTML"; then
        log_debug 'reCaptcha found'
        PUBKEY='6LetAu0SAAAAACCJkqZLvjNS4L7eSL8fGxr-Jzy2'

        RESP=$(recaptcha_process $PUBKEY) || return
        { read WORD; read CHALL; read ID; } <<< "$RESP"

        CAPTCHA_DATA="-F recaptcha_challenge_field=$CHALL -F recaptcha_response_field=$WORD"
    fi

    log_debug "Captcha data: $CAPTCHA_DATA"

    PAGE=$(curl -b "$COOKIE_FILE" \
        -F "op=$FORM_OP" \
        -F "id=$FORM_ID" \
        -F "rand=$FORM_RAND" \
        -F "referer=$FORM_REF" \
        -F "method_free=$FORM_METHOD_F" \
        -F "method_premium=$FORM_METHOD_P" \
        $CAPTCHA_DATA \
        -F "down_direct=$FORM_DD" \
        "$URL") || return

    if match 'Wrong Captcha' "$PAGE"; then
        log_error 'Wrong captcha'
        captcha_nack "$ID"
        return $ERR_CAPTCHA
    fi

    log_debug 'Correct captcha'
    captcha_ack "$ID"

    if match 'class="error_page"' "$PAGE"; then
        ERR=$(parse_quiet 'class="error_page"' '^\(.*\)$' 1 <<< "$PAGE")
        log_error "Unexpected error: $ERR"
        return $ERR_FATAL
    fi

    parse_attr 'Download File' 'href' <<< "$PAGE"
}

# Probe a download URL
# $1: cookie file (unused here)
# $2: filejoker.net url
# $3: requested capability list
filejoker_probe() {
    local -r REQ_IN=$3
    local PAGE REQ_OUT FILE_SIZE

    PAGE=$(curl -L "$URL") || return

    # The file link that you requested is not valid (anymore).
    if match 'File Not Found' "$PAGE"; then
        return $ERR_LINK_DEAD

    # The file link that you requested is incorrect.
    elif ! match 'div class="name-size"' "$PAGE"; then
        return $ERR_LINK_DEAD
    fi

    REQ_OUT=c

    if [[ $REQ_IN = *f* ]]; then
        parse_form_input_by_name 'fname' <<< "$PAGE" | html_to_utf8 && REQ_OUT="${REQ_OUT}f"
    fi

    if [[ $REQ_IN = *s* ]]; then
        FILE_SIZE=$(parse 'name-size' \
            '[^0-9\.]\([0-9\.]\+[[:space:]]\?[KkMG]\?[bB]\)' <<< "$PAGE") &&
            FILE_SIZE=$(replace 'b' 'B' <<< $FILE_SIZE) &&
            translate_size "${FILE_SIZE/,/}" && REQ_OUT="${REQ_OUT}s"
    fi

    if [[ $REQ_IN = *i* ]]; then
        parse_form_input_by_name 'id' <<< "$PAGE" && REQ_OUT="${REQ_OUT}i"
    fi

    echo $REQ_OUT
}

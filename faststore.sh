# Plowshare faststore.org module
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

MODULE_FASTSTORE_REGEXP_URL='https\?://\(www\.\)\?faststore\.org/'

MODULE_FASTSTORE_DOWNLOAD_OPTIONS="
AUTH,a,auth,a=USER:PASSWORD,User account
LINK_PASSWORD,p,link-password,S=PASSWORD,Used in password-protected files"
MODULE_FASTSTORE_DOWNLOAD_RESUME=yes
MODULE_FASTSTORE_DOWNLOAD_FINAL_LINK_NEEDS_COOKIE=no
MODULE_FASTSTORE_DOWNLOAD_SUCCESSIVE_INTERVAL=

MODULE_FASTSTORE_PROBE_OPTIONS=""

# Static function. It automatically get a code from captcha html.
# $1: captcha html
# stdout: code
faststore_captcha() {
    local CAPTCHA_HTML=$1
    local CAPTCHA_PROPERTIES CAPTCHA_NUMBERS CAPTCHA_LINES VAR1 VAR2 LINE CODE

    if ! check_exec 'sort'; then
        log_error "'sort' is required but was not found in path."
        return $ERR_SYSTEM
    fi

    CAPTCHA_HTML=$(break_html_lines <<< "$CAPTCHA_HTML" | html_to_utf8) || return

    # The captcha code contains numbers that are displayed according to
    # CSS padding-left properties. We have to get those property values
    # and corresponding numbers, sort according to property values and
    # send numbers to the server. So retrieve properties and their numbers.
    CAPTCHA_PROPERTIES=$(parse_all . 'left:\([[:digit:]]\+\)px' \
        <<< "$CAPTCHA_HTML") || return
    CAPTCHA_NUMBERS=$(parse_all_tag 'span' <<< "$CAPTCHA_HTML") || return

    # Concatenate two columns (properties and numbers) and
    # make ascending sorting according to the properties.
    CAPTCHA_LINES=$(while read -r VAR1 && read -r VAR2 <&3; do echo "$VAR1 $VAR2"; done \
        <<< "$CAPTCHA_PROPERTIES" 3<<< "$CAPTCHA_NUMBERS") || return
    CAPTCHA_LINES=$(while read -r LINE; do echo "$LINE"; done <<< "$CAPTCHA_LINES" \
        | sort -n -k1) || return

    # Concatenate numbers together in a single variable. This is our code.
    CODE=$(parse_all . ".* \(.*\)" <<< "$CAPTCHA_LINES" \
        | replace_all $'\n' '') || return

    echo $CODE
}

# Static function. Proceed with login
# $1: authentication
# $2: cookie file
# $3: base URL
# stdout: account type ("free" or "premium") on success.
faststore_login() {
    local -r AUTH=$1
    local -r COOKIE_FILE=$2
    local -r BASE_URL=$3
    local CV PAGE SESS MSG LOGIN_DATA STATUS NAME TYPE

    if CV=$(storage_get 'cookie_file'); then
        echo "$CV" >"$COOKIE_FILE"

        # Check for expired session.
        PAGE=$(curl -b "$COOKIE_FILE" "$BASE_URL") || return
        if ! match '>My Account<' "$PAGE"; then
            storage_set 'cookie_file'
            return $ERR_EXPIRED_SESSION
        fi

        SESS=$(parse_cookie 'xfss' < "$COOKIE_FILE")
        log_debug "session (cached): '$SESS'"
        MSG='reused login for'
    else
        local FORM_HTML FORM_RAND CAPTCHA_HTML CODE

        PAGE=$(curl "$BASE_URL/login.html") || return
        FORM_HTML=$(grep_form_by_name "$PAGE" 'FL') || return
        FORM_RAND=$(parse_form_input_by_name 'rand' <<< "$FORM_HTML") || return

        # In order to login we have to send to the server a captcha code.
        CAPTCHA_HTML=$(parse 'captcha_code' '^\(.*\)$' -1 <<< "$FORM_HTML") || return
        CODE=$(faststore_captcha "$CAPTCHA_HTML") || return

        LOGIN_DATA='op=login&redirect='$BASE_URL'&rand='$FORM_RAND'&login=$USER&password=$PASSWORD&code='$CODE''

        # Before login we have to wait at least 5 seconds, otherwise
        # when we login too fast login failed. It's some kind of an internal
        # countdown on the server (it's some kind of an anti-bot mechanism).
        wait 5 || return

        PAGE=$(post_login "$AUTH" "$COOKIE_FILE" "$LOGIN_DATA" "$BASE_URL" -L) || return

        # This check will never applied here, because when it's wrong captcha
        # then we immediately return from post_login function with error: no
        # entry was set (empty cookie file). Nevertheless I leave it with this
        # comment for the future. In order to check if it is something wrong
        # with a captcha function, please download a file as anonymous user.
        if match '>Wrong captcha<' "$PAGE"; then
            log_error 'Captcha was not resolved correctly.'
            log_error 'The faststore_captcha function not working anymore.'
            return $ERR_FATAL
        fi

        # If successful, two entries are added into cookie file: login and xfss.
        STATUS=$(parse_cookie_quiet 'xfss' < "$COOKIE_FILE")
        [ -z "$STATUS" ] && return $ERR_LOGIN_FAILED

        storage_set 'cookie_file' "$(cat "$COOKIE_FILE")"

        SESS=$(parse_cookie 'xfss' < "$COOKIE_FILE")
        log_debug "session (new): '$SESS'"
        MSG='logged in as'
    fi

    NAME=$(parse_cookie_quiet 'login' < "$COOKIE_FILE")

    if match 'Your are a regular account.' "$PAGE"; then
        TYPE='free'
    else
        TYPE='premium'
    fi

    log_debug "Successfully $MSG '$TYPE' member '$NAME'"
    echo $TYPE
}

# Output a faststore file download URL
# $1: cookie file
# $2: faststore url
# stdout: real file download link
faststore_download() {
    local -r COOKIE_FILE=$1
    local -r BASE_URL='http://faststore.org'
    local URL ACCOUNT PAGE WAIT_TIME PASSWORD_DATA
    local FORM_HTML FORM_OP FORM_USR FORM_ID FORM_FNAME FORM_REF
    local FORM_METHOD_F FORM_RAND FORM_RAND2 FORM_METHOD_P FORM_DD

    # Get a canonical URL for this file.
    URL=$(curl -I "$2" | grep_http_header_location_quiet) || return
    [ -n "$URL" ] || URL=$2
    readonly URL

    if [ -n "$AUTH" ]; then
        ACCOUNT=$(faststore_login "$AUTH" "$COOKIE_FILE" "$BASE_URL") || return
    fi

    PAGE=$(curl -b "$COOKIE_FILE" -c "$COOKIE_FILE" "$URL") || return

    if match 'File Not Found' "$PAGE"; then
        return $ERR_LINK_DEAD
    fi

    FORM_HTML=$(grep_form_by_order "$PAGE" 1) || return
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

    # Warning! You have reached your download limit.
    if match '>You have to wait .* till next download' "$PAGE"; then
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

    # Check for premium only files.
    elif match '>This file is available for Premium Users only' "$PAGE"; then
        log_error 'This file is available for Premium Users only.'
        return $ERR_LINK_NEED_PERMISSIONS

    # Check for files that need a password.
    elif match 'name="password"' "$PAGE"; then
        log_debug 'File is password protected.'

        if [ -z "$LINK_PASSWORD" ]; then
            LINK_PASSWORD=$(prompt_for_password) || return
        fi

        PASSWORD_DATA="-d password=$(replace_all ' ' '+' <<< "$LINK_PASSWORD")"
    fi

    FORM_HTML=$(grep_form_by_name "$PAGE" 'F1') || return
    FORM_OP=$(parse_form_input_by_name 'op' <<< "$FORM_HTML") || return
    FORM_ID=$(parse_form_input_by_name 'id' <<< "$FORM_HTML") || return
    FORM_RAND=$(parse_form_input_by_name 'rand' <<< "$FORM_HTML") || return
    FORM_RAND2=$(parse_form_input_by_name 'rand2' <<< "$FORM_HTML") || return
    FORM_REF=$(parse_form_input_by_name_quiet 'referer' <<< "$FORM_HTML")
    FORM_METHOD_F=$(parse_form_input_by_name_quiet 'method_free' <<< "$FORM_HTML")
    FORM_METHOD_P=$(parse_form_input_by_name_quiet 'method_premium' <<< "$FORM_HTML")
    FORM_DD=$(parse_form_input_by_name 'down_direct' <<< "$FORM_HTML") || return

    # We have to get a captcha code and send to the server.
    CAPTCHA_HTML=$(parse 'captcha_code' '^\(.*\)$' -1 <<< "$FORM_HTML") || return
    CODE=$(faststore_captcha "$CAPTCHA_HTML") || return

    WAIT_TIME=$(parse_tag countdown_str span <<< "$PAGE") || return
    wait $WAIT_TIME || return

    PAGE=$(curl -b "$COOKIE_FILE" \
        -d "op=$FORM_OP" \
        -d "id=$FORM_ID" \
        -d "rand=$FORM_RAND" \
        -d "rand2=$FORM_RAND2" \
        -d "referer=$FORM_REF" \
        -d "method_free=$FORM_METHOD_F" \
        -d "method_premium=$FORM_METHOD_P" \
        $PASSWORD_DATA \
        -d "code=$CODE" \
        -d "down_direct=$FORM_DD" \
        "$URL") || return

    if match '>Wrong captcha<' "$PAGE"; then
        log_error 'Captcha was not resolved correctly.'
        log_error 'The faststore_captcha function not working anymore.'
        return $ERR_FATAL

    elif match '>Wrong password<' "$PAGE"; then
        log_error 'Wrong password'
        return $ERR_LINK_PASSWORD_REQUIRED
    fi

    parse_attr '>CLICK TO DOWNLOAD<' 'href' <<< "$PAGE" || return
}

# Probe a download URL
# $1: cookie file (unused here)
# $2: faststore url
# $3: requested capability list
# stdout: 1 capability per line
faststore_probe() {
    local -r URL=$2
    local -r REQ_IN=$3
    local -r BASE_URL='http://faststore.org'
    local PAGE FILE_SIZE REQ_OUT

    # Check a file through a link checker.
    PAGE=$(curl \
        -d 'op=checkfiles' \
        -d "list=$URL" \
        "$BASE_URL/?op=checkfiles") || return

    if match ">Filename don't match!<" "$PAGE"; then
        log_error "Filename don't match!"
        return $ERR_FATAL

    elif ! match '>Found<' "$PAGE"; then
        return $ERR_LINK_DEAD
    fi

    REQ_OUT=c

    if [[ $REQ_IN = *f* ]]; then
        # We cannot check a file name through a link
        # checker, we have to get it from a file page.
        curl "$URL" | parse_form_input_by_name 'fname' && REQ_OUT="${REQ_OUT}f"
    fi

    if [[ $REQ_IN = *s* ]]; then
        FILE_SIZE=$(parse . '>Found</td><td>\([^<]*\)' <<< "$PAGE") \
            && FILE_SIZE=$(replace 'B' 'iB' <<< $FILE_SIZE) \
            && translate_size "$FILE_SIZE" && REQ_OUT="${REQ_OUT}s"
    fi

    if [[ $REQ_IN = *i* ]]; then
        parse . 'org/\([[:alnum:]]\+\)' <<< "$URL" && REQ_OUT="${REQ_OUT}i"
    fi

    echo $REQ_OUT
}

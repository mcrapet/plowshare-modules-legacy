# Plowshare uploadboy.com module
# Copyright (c) 2015 Plowshare team
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

MODULE_UPLOADBOY_REGEXP_URL='https\?://\(www\.\)\?uploadboy\.com/'

MODULE_UPLOADBOY_DOWNLOAD_OPTIONS="
AUTH,a,auth,a=USER:PASSWORD,Premium account"
MODULE_UPLOADBOY_DOWNLOAD_RESUME=yes
MODULE_UPLOADBOY_DOWNLOAD_FINAL_LINK_NEEDS_COOKIE=no
MODULE_UPLOADBOY_DOWNLOAD_SUCCESSIVE_INTERVAL=

MODULE_UPLOADBOY_PROBE_OPTIONS=""

# Static function. Proceed with login
# $1: credentials string
# $2: cookie file
# $3: base url
uploadboy_login() {
    local AUTH=$1
    local COOKIE_FILE=$2
    local BASE_URL=$3

    local LOGIN_DATA LOGIN_RESULT NAME ERR

    LOGIN_DATA='op=login&redirect=&login=$USER&password=$PASSWORD'
    LOGIN_RESULT=$(post_login "$AUTH" "$COOKIE_FILE" "$LOGIN_DATA" "$BASE_URL" -b 'lang=english') || return

    # Set-Cookie: login xfsts
    NAME=$(parse_cookie_quiet 'login' < "$COOKIE_FILE")
    if [ -n "$NAME" ]; then
        log_debug "Successfully logged in as $NAME member"
        return 0
    fi

    # <div id="loginErrorMsg" class="alert alert-danger"><span class="glyphicon glyphicon-exclamation-sign" aria-hidden="true"></span>
    # <span class="sr-only">Error:</span>Incorrect Login or Password</div>
    ERR=$(parse '=.loginErrorMsg' 'n>\(.*\)<' 1 <<< "$LOGIN_RESULT")
    [ -n "$ERR" ] && log_error "Unexpected remote error: $ERR"

    return $ERR_LOGIN_FAILED
}

# Output a yourvideohost file download URL
# $1: cookie file (unused here)
# $2: yourvideohost url
# stdout: real file download link
uploadboy_download() {
    local -r COOKIE_FILE=$1
    local -r URL=$2
    local -r BASE_URL='https://uploadboy.com'
    local PAGE CV SESS FILE_URL
    local FORM_HTML FORM_OP FORM_ID FORM_RAND FORM_REF FORM_USR_RES FORM_USR_OS
    local FORM_USR_BROWSER FORM_METHOD_F FORM_METHOD_P FORM_SCRIPT FORM_SUBMIT

    if CV=$(storage_get 'cookie_file'); then
        echo "$CV" >"$COOKIE_FILE"

        # Check for expired session
        PAGE=$(curl -b "$COOKIE_FILE" "$BASE_URL/?op=my_account") || return
        if ! match '>\(Username\|Account balance\):<' "$PAGE"; then
            log_debug 'expired session, delete cache entry'
            storage_set 'cookie_file'
            echo 1
            return $ERR_LINK_TEMP_UNAVAILABLE
        fi

        SESS=$(parse_cookie 'xfss' < "$COOKIE_FILE")
        log_debug "session (cached): '$SESS'"

    elif [ -n "$AUTH" ]; then
        uploadboy_login "$AUTH" "$COOKIE_FILE" "$BASE_URL" || return
        storage_set 'cookie_file' "$(cat "$COOKIE_FILE")"

        SESS=$(parse_cookie 'xfss' < "$COOKIE_FILE")
        log_debug "session (new): '$SESS'"
    else
        return $ERR_LINK_NEED_PERMISSIONS
    fi

    PAGE=$(curl -b "$COOKIE_FILE" -b 'lang=english' "$URL") || return

    # <b>File Not Found</b><br>
    if match '>File Not Found<' "$PAGE"; then
        return $ERR_LINK_DEAD
    fi

    FORM_HTML=$(grep_form_by_order "$PAGE" 1) || return
    FORM_OP=$(parse_form_input_by_name 'op' <<< "$FORM_HTML") || return
    FORM_ID=$(parse_form_input_by_name 'id' <<< "$FORM_HTML") || return
    FORM_RAND=$(parse_form_input_by_name 'rand' <<< "$FORM_HTML") || return
    FORM_REF=$(parse_form_input_by_name_quiet 'referer' <<< "$FORM_HTML")
    FORM_USR_RES=$(parse_form_input_by_name_quiet 'usr_resolution' <<< "$FORM_HTML")
    FORM_USR_OS=$(parse_form_input_by_name_quiet 'usr_os' <<< "$FORM_HTML")
    FORM_USR_BROWSER=$(parse_form_input_by_name_quiet 'usr_browser' <<< "$FORM_HTML")
    FORM_METHOD_F=$(parse_form_input_by_name_quiet 'method_free' <<< "$FORM_HTML")
    FORM_METHOD_P=$(parse_form_input_by_name_quiet 'method_premium' <<< "$FORM_HTML")
    FORM_SCRIPT=$(parse_form_input_by_name 'down_script' <<< "$FORM_HTML")
    FORM_SUBMIT=$(parse_form_input_by_id 'btn_download' <<< "$FORM_HTML") || return

    PAGE=$(curl -b "$COOKIE_FILE" -b 'lang=english' \
        -d "op=$FORM_OP" -d "id=$FORM_ID" -d "rand=$FORM_RAND" \
        -d "referer=$FORM_REF" \
        -d "usr_resolution=$FORM_USR_RES" -d "usr_os=$FORM_USR_OS" -d "usr_browser=$FORM_USR_BROWSER" \
        -d "method_free=$FORM_METHOD_F" -d "method_premium=$FORM_METHOD_P" \
        -d "down_script=$FORM_SCRIPT" -d "btn_download=$FORM_SCRIPT" \
        "$URL") || return

    FILE_URL=$(parse_attr '>[[:space:]]*DOWNLOAD[[:space:]]*<' href <<< "$PAGE") || return

    echo "$FILE_URL"
}

# Probe a download URL
# $1: cookie file (unused here)
# $2: yourvideohost url
# $3: requested capability list
# stdout: 1 capability per line
uploadboy_probe() {
    local -r URL=$2
    local -r REQ_IN=$3
    local PAGE REQ_OUT FILE_SIZE
    local -r BASE_URL='http://uploadboy.com/checkfiles.html'

    PAGE=$(curl -b 'lang=english' --referer "$BASE_URL" \
        -d 'op=checkfiles' -d 'process=check' \
        --data-urlencode "list=$URL" "$BASE_URL") || return

    if match 'color:red;.>Not found!<' "$PAGE"; then
        return $ERR_LINK_DEAD
    fi

    REQ_OUT=c

    echo $REQ_OUT
}

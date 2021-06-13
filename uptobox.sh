# Plowshare uptobox.com module
# Copyright (c) 2012-2017 Plowshare team
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

MODULE_UPTOBOX_REGEXP_URL='https\?://\(www\.\)\?uptobox\.com/'

MODULE_UPTOBOX_DOWNLOAD_OPTIONS="
AUTH,a,auth,a=USER:PASSWORD,User account"
MODULE_UPTOBOX_DOWNLOAD_RESUME=yes
MODULE_UPTOBOX_DOWNLOAD_FINAL_LINK_NEEDS_COOKIE=no
MODULE_UPTOBOX_DOWNLOAD_SUCCESSIVE_INTERVAL=

MODULE_UPTOBOX_UPLOAD_OPTIONS="
AUTH,a,auth,a=USER:PASSWORD,User account"
MODULE_UPTOBOX_UPLOAD_REMOTE_SUPPORT=no

MODULE_UPTOBOX_PROBE_OPTIONS=""

# Static function. Proceed with login
# $1: credentials string
# $2: cookie file
# $3: base url
uptobox_login() {
    local AUTH=$1
    local COOKIE_FILE=$2
    local POST_URL="$3?op=login"

    local LOGIN_DATA LOGIN_RESULT SID ERR

    LOGIN_DATA='login=$USER&password=$PASSWORD'
    LOGIN_RESULT=$(post_login "$AUTH" "$COOKIE_FILE" "$LOGIN_DATA" "$POST_URL") || return

    # {"success" : "OK", "msg" : "please wait..."}

    # Set-Cookie: xfss
    SID=$(parse_cookie_quiet 'xfss' < "$COOKIE_FILE")
    if [ -n "$SID" ]; then
        log_debug 'Successfully logged in'
        return 0
    fi
    # Try to parse error
    ERR=$(parse_all_tag_quiet 'class="errors mb-3"' 'li' <<< "$LOGIN_RESULT")
    [ -n "$ERR" ] || ERR=$(parse_all_tag_quiet "class='errors mb-3'" 'li' <<< "$LOGIN_RESULT")
    [ -n "$ERR" ] && log_error "Unexpected remote error: $ERR"
    return $ERR_LOGIN_FAILED
}

# Check for and handle "heavy-user captcha"
# $1: full content of initial page
# $2: cookie file
# $3: base url
# stdout: full content of actual download page
uptobox_cloudflare() {
    local -r COOKIE_FILE=$2
    local -r BASE_URL=$3
    local PAGE=$1

    # <title>Attention Required! | CloudFlare</title>
    if matchi 'Cloudflare' "$(parse_tag_quiet 'title' <<< "$PAGE")"; then
        log_error 'Cloudflare captcha request, plowshare does not handle new google captchas'
        # FIXME
        return $ERR_FATAL
    fi

    echo "$PAGE"
}

# Output a uptobox file download URL
# $1: cookie file (account only)
# $2: uptobox url
# stdout: real file download link
uptobox_download() {
    local -r COOKIE_FILE=$1
    local -r URL=$(replace '://www.' '://' <<< "$2" | replace 'http:' 'https:')
    local -r BASE_URL='http://uptobox.com'
    local PAGE WAIT_TIME CODE PREMIUM CAPTCHA_DATA CAPTCHA_ID
    local FORM_HTML FORM_OP FORM_ID FORM_RAND FORM_METHOD FORM_DD FORM_SZ FORM_WAITINGTOKEN

    if [ -n "$AUTH" ]; then
        uptobox_login "$AUTH" "$COOKIE_FILE" 'https://uptobox.com' || return

        # Distinguish acount type (free or premium)
        PAGE=$(curl -b "$COOKIE_FILE" "$BASE_URL/?op=my_account") || return
        
        # Opposite is: 'Upgrade to premium';
        if matchi 'Extend Premium' "$PAGE"; then
            local DIRECT_URL
            PREMIUM=1
            DIRECT_URL=$(curl -I -b "$COOKIE_FILE" "$URL" | grep_http_header_location_quiet)
            if [ -n "$DIRECT_URL" ]; then
                echo "$DIRECT_URL"
                return 0
            fi
            
            PAGE=$(curl -i -b "$COOKIE_FILE" -b 'lang=english' "$URL") || return
        else
            # Should wait 45s instead of 60s!
            PAGE=$(curl -b "$COOKIE_FILE" -b 'lang=english' "$URL") || return
        fi
    else
        PAGE=$(curl -b 'lang=english' "$URL") || return
    fi

    PAGE=$(uptobox_cloudflare "$PAGE" "$COOKIE_FILE" "$BASE_URL") || return
    # To give priority to premium users, you have to wait x minutes, x seconds
    if match '>To give priority to premium users, you have to wait' "$PAGE"; then
        local MINS
        MINS=$(parse_quiet 'you have to wait[[:space:]]' \
                '[[:space:]]\([[:digit:]]\+\) minute' <<< "$PAGE") || MINS=60
        echo $((MINS*60))
        return $ERR_LINK_TEMP_UNAVAILABLE
    # You need a PREMIUM account to download new files immediatly without waiting
    elif match '>You need a PREMIUM account to download' "$PAGE"; then
        MINS=$(parse_quiet 'you can wait[[:space:]]' \
                '[[:space:]]\([[:digit:]]\+\) minute' <<< "$PAGE") || MINS=60
        SECS=$(parse_quiet 'you can wait[[:space:]]' \
                '[[:space:]]\([[:digit:]]\+\) second' <<< "$PAGE") || SECS=1
        echo $((MINS * 60 + SECS))
        return $ERR_LINK_TEMP_UNAVAILABLE
    fi

    # The file you were looking for could not be found, sorry for any inconvenience
    if matchi '<span[[:space:]].*File Not Found' "$PAGE"; then
        return $ERR_LINK_DEAD
    elif match '<font class="err"><div class="page-top" align="center">Maintenance</div>' "$PAGE"; then
        log_error 'Remote error: maintenance'
        echo 3600
        return $ERR_LINK_TEMP_UNAVAILABLE
    fi
    
    # Retrive (post) form data if one is present
    FORM_HTML=$(grep_form_by_order "$PAGE" 1) || return

    WAIT_TIME=$(parse_attr_quiet 'data-remaining-time' <<< "$FORM_HTML")
    if [ -n "$WAIT_TIME" ]; then
        wait $((WAIT_TIME + 1)) || return
    fi

    if matchi 'waitingToken' "$FORM_HTML"; then
        FORM_WAITINGTOKEN=$(parse_form_input_by_name 'waitingToken' <<< "$FORM_HTML") || return
        PAGE=$(curl -b "$COOKIE_FILE" -b 'lang=english' \
         -F "waitingToken=$FORM_WAITINGTOKEN" \
         -F "referer=$URL" \
         "$URL") || return
    fi

    # Handle premium downloads
    # Have not premium account to test
    if [ "$PREMIUM" = '1' ]; then
        local FILE_URL

        FORM_OP=$(parse_form_input_by_name 'op' <<< "$FORM_HTML") || return
        FORM_ID=$(parse_form_input_by_name 'id' <<< "$FORM_HTML") || return
        FORM_DD=$(parse_form_input_by_name_quiet 'down_direct' <<< "$FORM_HTML")
        FORM_RAND=$(parse_form_input_by_name 'rand' <<< "$FORM_HTML") || return
        FORM_METHOD=$(parse_form_input_by_name_quiet 'method_free' <<< "$FORM_HTML")

        PAGE=$(curl -b "$COOKIE_FILE" -b 'lang=english' \
            -d "op=$FORM_OP" \
            -d "id=$FORM_ID" \
            -d "rand=$FORM_RAND" \
            -d 'method_free=' \
            -d "down_direct=${FORM_DD:+1}" \
            -d 'referer=' \
            -d "method_premium=$FORM_METHOD" "$URL") || return

        # Click here to start your download
        FILE_URL=$(parse_attr '/d/' 'href' <<< "$PAGE")
        if match_remote_url "$FILE_URL"; then
            echo "$FILE_URL"
            return 0
        fi
    fi

    # Check for enforced download limits
    if match '<p class="err">' "$PAGE"; then
        # You have reached the download-limit: 1024 Mb for last 1 days</p>
        if match 'reached the download.limit' "$PAGE"; then
            echo 3600
            return $ERR_LINK_TEMP_UNAVAILABLE
        # You have to wait X minutes, Y seconds till next download
        # You have to wait Y seconds till next download
        elif matchi 'You have to wait' "$PAGE"; then
            local HOURS MINS SECS
            HOURS=$(parse_quiet '>You have to wait' \
                '[[:space:]]\([[:digit:]]\+\) hour' <<< "$PAGE") || HOURS=0
            MINS=$(parse_quiet '>You have to wait' \
                '[[:space:]]\([[:digit:]]\+\) minute' <<< "$PAGE") || MINS=0
            SECS=$(parse '>You have to wait' \
                '[[:space:]]\([[:digit:]]\+\) second' 2>/dev/null <<< "$PAGE") || SECS=1

            echo $(( HOURS * 3600 + MINS * 60 + SECS ))
            return $ERR_LINK_TEMP_UNAVAILABLE

        elif match 'Expired download session' "$PAGE"; then
            log_error 'Remote error: expired session'
            return $ERR_LINK_TEMP_UNAVAILABLE
        elif match '>premium member<' "$PAGE"; then
            return $ERR_LINK_NEED_PERMISSIONS
        fi
    fi

    if match '[^-]Enter code above\|//api\.solvemedia\.com' "$PAGE"; then
        local RESP CHALL

        RESP=$(solvemedia_captcha_process 'dAlo2UnjILCt709UJOmCZvfUBFxms5vw') || return
        { read CHALL; read CAPTCHA_ID; } <<< "$RESP"

        CAPTCHA_DATA="-F adcopy_challenge=$CHALL -F adcopy_response=manual_challenge"
    fi

    # <p class="err">Invalid captcha</p>
    if match '<p class="err">' "$PAGE"; then
        local ERR=$(parse_tag 'class="err">' p <<< "$PAGE")
        if match 'Skipped countdown' "$ERR"; then
            # Can do a retry
            log_debug "Remote error: $ERR"
            return $ERR_NETWORK
        fi
        log_error "Unexpected remote error: $ERR"
        return $ERR_FATAL
    fi

    #test if you can download something
    if match 'start your download' "$PAGE"; then
        parse 'start your download' 'href="\([^"]\+\)"' -1 <<< "$PAGE" || return
        echo "$FORM_FNAME"
    else
        log_error "no matching link to download your file"
        return $ERR_FATAL
    fi
    
}

# Upload a file to uptobox.com
# $1: cookie file
# $2: input file (with full path)
# $3: remote filename
# stdout: download link + delete link
uptobox_upload() {
    local -r COOKIE_FILE=$1
    local -r FILE=$2
    local -r DESTFILE=$3
    local -r BASE_URL='https://uptobox.com'

    local PAGE URL UPLOAD_ID USER_TYPE DL_URL DEL_URL
    local FORM_HTML FORM_ACTION FORM_UTYPE FORM_TMP_SRV FORM_BUTTON FORM_SESS
    local FORM_FN FORM_ST FORM_OP

    if [ -n "$AUTH" ]; then
        uptobox_login "$AUTH" "$COOKIE_FILE" 'https://uptobox.com' || return
    fi

    PAGE=$(curl -L -b "$COOKIE_FILE" -b 'lang=english' "$BASE_URL") || return

    FORM_HTML=$(grep_form_by_id "$PAGE" 'fileupload') || return
    FORM_ACTION=$(parse_form_action <<< "$FORM_HTML") || return
    FORM_SESS=$(parse_form_input_by_name_quiet 'sess_id' <<< "$PAGE")
    log_debug $FORM_ACTION

    log_debug "debug html '$FORM_HTML'"
    JSON=$(curl_with_log \
        -F "sess_id=$FORM_SESS" \
        -F "files[]=@$FILE;type=application/octet-stream;filename=$DESTFILE" \
        "http:${FORM_ACTION}" | break_html_lines) || return

    echo $JSON | parse_json url || return
    echo $JSON | parse_json deleteUrl || return
}

# Probe a download URL
# $1: cookie file (unused here)
# $2: uptobox url
# $3: requested capability list
# stdout: 1 capability per line
uptobox_probe() {
    local -r URL=$2
    local -r REQ_IN=$3
    local PAGE REQ_OUT FILE_SIZE

    PAGE=$(curl -L -b 'lang=english' "$URL") || return
    PAGE=$(uptobox_cloudflare "$PAGE" "$COOKIE_FILE" "$BASE_URL") || return

    # <h1>File not found </h1>
    if matchi '<h1.*File not found' "$PAGE"; then
        return $ERR_LINK_DEAD
    fi

    REQ_OUT=c

    if [[ $REQ_IN = *f* ]]; then
        FILE=$(parse_tag 'h1'  <<< "$PAGE") && REQ_OUT="${REQ_OUT}"
    fi

    if [[ $REQ_IN = *s* ]]; then
        FILE_SIZE=$(echo "$FILE" | parse '[[:space:]](\([^)]\+\)') && translate_size "$FILE_SIZE" && \
            REQ_OUT="${REQ_OUT}s"
        log_debug $FILE_SIZE
    fi

    if [[ $REQ_IN = *i* ]]; then
        parse_form_input_by_name 'id' <<< "$PAGE" && REQ_OUT="${REQ_OUT}i"
    fi

    echo $REQ_OUT
}

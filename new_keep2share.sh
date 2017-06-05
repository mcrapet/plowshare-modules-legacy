# Plowshare new.keep2share.cc module
#   derived from keep2share.cc
# by idleloop <idleloop@yahoo.com>, Jun 2017
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
#
# Official API: https://github.com/keep2share/api

MODULE_NEW_KEEP2SHARE_REGEXP_URL='https\?://new\.\(keep2share\|k2s\|k2share\|keep2s\)\.cc/'

MODULE_NEW_KEEP2SHARE_DOWNLOAD_OPTIONS=""
MODULE_NEW_KEEP2SHARE_DOWNLOAD_RESUME=yes
MODULE_NEW_KEEP2SHARE_DOWNLOAD_FINAL_LINK_NEEDS_COOKIE=no
MODULE_NEW_KEEP2SHARE_DOWNLOAD_FINAL_LINK_NEEDS_EXTRA=
MODULE_NEW_KEEP2SHARE_DOWNLOAD_SUCCESSIVE_INTERVAL=

MODULE_NEW_KEEP2SHARE_UPLOAD_REMOTE_SUPPORT=no

MODULE_NEW_KEEP2SHARE_PROBE_OPTIONS=""

# Static function. Check query answer
# $1: JSON data (like {"status":"xxx","code":ddd, ...}
# $?: 0 for success
new_keep2share_status() {
    local STATUS=$(parse_json 'status' <<< "$1")
    if [ "$STATUS" != 'success' ]; then
        local CODE=$(parse_json 'code' <<< "$1")
        local MSG=$(parse_json 'message' <<< "$1")
        log_error "Remote status: '$STATUS' with code $CODE."
        [ -z "$MSG" ] || log_error "Message: $MSG"
        return $ERR_FATAL
    fi
}

# Output an new.keep2share file download URL
# $1: cookie file
# $2: new.keep2share url
# stdout: real file download link
new_keep2share_download() {
    local -r COOKIE_FILE=$1
    local -r API_URL='http://new.keep2share.cc/api/v1/'
    local URL BASE_URL ACCOUNT TOKEN FILE_NAME FILE_ID FILE_STATUS PRE_URL
    local AT JSON PAGE FORM_HTML FORM_ID FORM_ACTION WAIT FORCED_DELAY

    # get canonical URL and BASE_URL for this file
    URL=$(curl -I "$2" | grep_http_header_location_quiet) || return
    [ -n "$URL" ] || URL=$2
    BASE_URL=${URL%/file*}
    readonly URL BASE_URL

    if [ -n "$AUTH" ]; then
        AT=$(keep2share_login "$AUTH" "$API_URL") || return
        { read ACCOUNT; read TOKEN; } <<< "$AT"
    fi

    if [ "$ACCOUNT" = 'premium' ]; then
        log_error 'Not yet implemented'
        return

    elif [ "$ACCOUNT" = 'free' ]; then
        local CAPTCHA_CHALL CAPTCHA_URL CAPTCHA_IMG STATUS DOWNLOAD_KEY
        FILE_ID=$(parse . 'file/\([^/]\+\)' <<< "$URL") || return

        # Check a file status and get its filename from api
        JSON=$(curl --data '{"auth_token":"'$TOKEN'","ids":["'$FILE_ID'"]}' "${API_URL}GetFilesInfo") || return

        # {"status":"success","code":200,"files":[{"id":"c1672cfa4f357","name": ...}}
        new_keep2share_status "$JSON" || return

        FILE_STATUS=$(parse_json 'is_available' <<< "$JSON") || return
        if [ "$FILE_STATUS" != 'true' ]; then
            return $ERR_LINK_DEAD
        fi

        FILE_STATUS=$(parse_json 'access' <<< "$JSON") || return
        if [ "$FILE_STATUS" = 'premium' ]; then
            return $ERR_LINK_NEED_PERMISSIONS

        elif [ "$FILE_STATUS" = 'private' ]; then
            log_error 'This is a private file.'
            return $ERR_LINK_NEED_PERMISSIONS
        fi

        FILE_NAME=$(parse_json 'name' <<< "$JSON") || return

        # Get captcha from api
        JSON=$(curl --data '{"auth_token":"'$TOKEN'"}' "${API_URL}RequestCaptcha") || return

        # {"status":"success","code":200,"challenge":"c31a7a25d9d74","captcha_url": ...}
        new_keep2share_status "$JSON" || return

        CAPTCHA_CHALL=$(parse_json 'challenge' <<< "$JSON") || return
        CAPTCHA_URL=$(parse_json 'captcha_url' <<< "$JSON") || return

        CAPTCHA_IMG=$(create_tempfile '.jpg') || return
        curl -o "$CAPTCHA_IMG" "$CAPTCHA_URL" || return

        local WI WORD ID
        WI=$(captcha_process "$CAPTCHA_IMG") || return
        { read WORD; read ID; } <<< "$WI"
        rm -f "$CAPTCHA_IMG"

        # Check captcha and get free download key
        JSON=$(curl --data '{"auth_token":"'$TOKEN'","file_id":"'$FILE_ID'","captcha_challenge":"'$CAPTCHA_CHALL'","captcha_response":"'$WORD'"}' \
            "${API_URL}GetUrl") || return

        # {"status":"success","code":200,"message":"Captcha accepted, please wait","free_download_key": ...}
        # {"message":"Invalid captcha code","status":"error","code":406,"errorCode":31}
        # {"message":"Download not available","status":"error","code":406,"errorCode":42,"errors":[{"code":5,"timeRemaining":"1510.000000"}]}
        STATUS=$(parse_json 'status' <<< "$JSON") || return
        if [ "$STATUS" != 'success' ]; then
            STATUS=$(parse_json_quiet 'errorCode' <<< "$JSON")
            # ERROR_CAPTCHA_INVALID
            if [ "$STATUS" = 31 ]; then
                captcha_nack $ID
                log_error 'Wrong captcha'
                return $ERR_CAPTCHA
            # ERROR_DOWNLOAD_NOT_AVAILABLE
            elif [ "$STATUS" = 42 ]; then
                WAIT=$(parse_json_quiet 'timeRemaining' <<< "$JSON")
                [ -z "$WAIT" ] || echo "${WAIT%.*}"
                return $ERR_LINK_TEMP_UNAVAILABLE
            else
                STATUS=$(parse_json 'message' <<< "$JSON")
                log_error "Unexpected remote error: $STATUS"
                return $ERR_FATAL
            fi
        fi

        captcha_ack $ID
        log_debug 'Correct captcha'

        DOWNLOAD_KEY=$(parse_json 'free_download_key' <<< "$JSON") || return
        WAIT=$(parse_json 'time_wait' <<< "$JSON") || return
        wait $WAIT || return

        # Get a final link
        JSON=$(curl --data '{"auth_token":"'$TOKEN'","file_id":"'$FILE_ID'","free_download_key":"'$DOWNLOAD_KEY'"}' \
            "${API_URL}GetUrl") || return

        # {"status":"success","code":200,"url": ...}
        new_keep2share_status "$JSON" || return

        parse_json 'url' <<< "$JSON" || return
        echo "$FILE_NAME"
        return 0
    fi

    PAGE=$(curl -c "$COOKIE_FILE" "$URL") || return
    log_error "$PAGE"    
    # parse wait time
    WAIT=$(parse 'id=\"free-download-wait-timer\"' \
        '>[[:space:]]*\([[:digit:]]\+\)<' <<< "$PAGE") || return

    # File not found or deleted
    if match 'File not found or deleted\|This file is no longer available' "$PAGE"; then
        return $ERR_LINK_DEAD
    fi

    FILE_NAME=$(parse 'available for <em>PREMIUM<\/em> download' '<strong>\(.\+\) \?<\/strong>' 'span' <<< "$PAGE" | \
        html_to_utf8) || return
    readonly FILE_NAME

    # check for pre-unlocked link
    # <span id="temp-link">To download this file with slow speed, use <a href="/file/url.html?file=abcdefghi">this link</a><br>
    if match 'temp-link' "$PAGE"; then
        PRE_URL=$(parse_attr 'temp-link' 'href' <<< "$PAGE") || return
        PAGE=$(curl --head -b "$COOKIE_FILE" "$BASE_URL$PRE_URL") || return

        # output final url + file name
        grep_http_header_location <<< "$PAGE" || return
        echo "$FILE_NAME"
        return 0
    fi

    FORM_HTML=$(grep_form_by_order "$PAGE") || return
    FORM_ID=$(parse_form_input_by_name 'slow_id' <<< "$FORM_HTML") || return
    FORM_ACTION=$(parse_form_action <<< "$FORM_HTML") || return

    # request download
    PAGE=$(curl -b "$COOKIE_FILE" -d "slow_id=$FORM_ID" -d 'yt0' \
        "$BASE_URL$FORM_ACTION") || return

    # check for forced delay
    FORCED_DELAY=$(parse_quiet 'Please wait .* to download this file' \
        'wait \([[:digit:]:]\+\) to download' <<< "$PAGE")

    if [ -n "$FORCED_DELAY" ]; then
        local HOUR MIN SEC

        HOUR=${FORCED_DELAY%%:*}
        SEC=${FORCED_DELAY##*:}
        MIN=${FORCED_DELAY#*:}; MIN=${MIN%:*}
        log_error 'Forced delay between downloads.'
        # Note: Get rid of leading zeros so numbers will not be considered octal
        echo $(( (( ${HOUR#0} * 60 ) + ${MIN#0} ) * 60 + ${SEC#0} ))
        return $ERR_LINK_TEMP_UNAVAILABLE
    fi

    # Free user can't download large files.
    if match "Free user can't download large files" "$PAGE" ; then
        return $ERR_LINK_NEED_PERMISSIONS
    fi

    # check for and handle CAPTCHA (if any)
    # Note: emulate 'grep_form_by_id_quiet'
    FORM_HTML=$(grep_form_by_id "$PAGE" 'captcha-form' 2>/dev/null)

    if [ -n "$FORM_HTML" ]; then
        local RESP WORD ID CAPTCHA_DATA

        if match 'recaptcha' "$FORM_HTML"; then
            log_debug 'reCaptcha found'
            local CHALL
            local -r PUBKEY='6LcYcN0SAAAAABtMlxKj7X0hRxOY8_2U86kI1vbb'

            RESP=$(recaptcha_process $PUBKEY) || return
            { read WORD; read CHALL; read ID; } <<< "$RESP"

            CAPTCHA_DATA="-d CaptchaForm%5Bcode%5D -d recaptcha_challenge_field=$CHALL --data-urlencode recaptcha_response_field=$WORD"

        elif match 'captcha.html' "$FORM_HTML"; then
            log_debug 'Captcha found'
            local CAPTCHA_URL IMG_FILE

            # Get captcha image
            CAPTCHA_URL=$(parse_attr '<img' 'src' <<< "$FORM_HTML") || return
            IMG_FILE=$(create_tempfile '.new_keep2share.png') || return
            curl -b "$COOKIE_FILE" -o "$IMG_FILE" "$BASE_URL$CAPTCHA_URL" || return

            # Solve captcha
            # Note: Image is a 260x80 png file containing 6-7 characters
            RESP=$(captcha_process "$IMG_FILE" new_keep2share 6 7) || return
            { read WORD; read ID; } <<< "$RESP"
            rm -f "$IMG_FILE"

            CAPTCHA_DATA="-d CaptchaForm%5Bcode%5D=$WORD"

        else
            log_error 'Unexpected content/captcha type. Site updated?'
            return $ERR_FATAL
        fi

        log_debug "Captcha data: $CAPTCHA_DATA"

        FORM_ID=$(parse_form_input_by_name 'uniqueId' <<< "$FORM_HTML") || return
        FORM_ACTION=$(parse_form_action <<< "$FORM_HTML") || return

        PAGE=$(curl -b "$COOKIE_FILE" $CAPTCHA_DATA \
            -d 'free=1' -d 'freeDownloadRequest=1' \
            -d "uniqueId=$FORM_ID" \
            -d 'yt0' "$BASE_URL$FORM_ACTION") || return

        if match 'The verification code is incorrect' "$PAGE"; then
            log_error 'Wrong captcha'
            captcha_nack "$ID"
            return $ERR_CAPTCHA
        fi

        log_debug 'Correct captcha'
        captcha_ack "$ID"

        if [ -n "$WAIT" ]; then
            wait $(( WAIT + 1 )) || return
        fi

        PAGE=$(curl -b "$COOKIE_FILE" -d "uniqueId=$FORM_ID" \
            -d 'free=1' "$BASE_URL$FORM_ACTION") || return

        PRE_URL=$(parse_attr 'link-to-file' 'href' <<< "$PAGE") || return

    # direct download without captcha
    elif match 'btn-success.*Download' "$PAGE"; then
        PRE_URL=$(parse_attr 'btn-success.*Download' href <<< "$PAGE") || return
    else
        log_error 'Unexpected content. Site updated?'
        return $ERR_FATAL
    fi

    log_debug "Pre-URL: '$PRE_URL'"
    PAGE=$(curl --head -b "$COOKIE_FILE" "$BASE_URL$PRE_URL") || return

    # output final url + file name
    grep_http_header_location <<< "$PAGE" || return
    echo "$FILE_NAME"
}

# Probe a download URL
# $1: cookie file (unused here)
# $2: new.keep2share url
# $3: requested capability list
# stdout: 1 capability per line
#
# Official API does not provide a anonymous check-link feature :(
# $ curl --data '{"ids":["816bef5d35245"]}' http://new.keep2share.cc/api/v1/GetFilesInfo
new_keep2share_probe() {
    local -r URL=$2
    local -r REQ_IN=$3
    local PAGE REQ_OUT FILE_NAME

    PAGE=$(curl --location "$URL") || return

    # File not found or delete
    if match 'File not found or deleted\|This file is no longer available' "$PAGE"; then
        return $ERR_LINK_DEAD
    fi

    REQ_OUT=c

    if [[ $REQ_IN = *f* ]]; then
        parse 'available for <em>PREMIUM<\/em> download' '<strong>\(.\+\) \?<\/strong>' 'span' <<< "$PAGE" | html_to_utf8 && \
            REQ_OUT="${REQ_OUT}f"
    fi

    if [[ $REQ_IN = *s* ]]; then
        FILE_SIZE=$(parse '<em>' '<em>\([[:digit:]\.]\+ .\+\)</em>' <<< "$PAGE") && \
            translate_size "${FILE_SIZE#Size: }" && REQ_OUT="${REQ_OUT}s"
    fi

    if [[ $REQ_IN = *i* ]]; then
        parse . 'file/\([[:alnum:]]\+\)/\?' <<< "$URL" && REQ_OUT="${REQ_OUT}i"
    fi

    echo $REQ_OUT
}

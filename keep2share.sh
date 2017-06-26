# Plowshare keep2share.cc module
# Copyright (c) 2014 Plowshare team
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

MODULE_KEEP2SHARE_REGEXP_URL='https\?://\(www\.\)\?\(keep2share\|k2s\|k2share\|keep2s\)\.cc/'

MODULE_KEEP2SHARE_DOWNLOAD_OPTIONS="
AUTH,a,auth,a=EMAIL:PASSWORD,User account"
MODULE_KEEP2SHARE_DOWNLOAD_RESUME=yes
MODULE_KEEP2SHARE_DOWNLOAD_FINAL_LINK_NEEDS_COOKIE=no
MODULE_KEEP2SHARE_DOWNLOAD_FINAL_LINK_NEEDS_EXTRA=
MODULE_KEEP2SHARE_DOWNLOAD_SUCCESSIVE_INTERVAL=

MODULE_KEEP2SHARE_UPLOAD_OPTIONS="
AUTH,a,auth,a=EMAIL:PASSWORD,User account (mandatory)
FOLDER,,folder,s=FOLDER,Folder to upload files into. Leaf name, no hierarchy.
CREATE_FOLDER,,create,,Create (private) folder if it does not exist
FULL_LINK,,full-link,,Final link includes filename"
MODULE_KEEP2SHARE_UPLOAD_REMOTE_SUPPORT=no

MODULE_KEEP2SHARE_PROBE_OPTIONS=""

# Static function. Check query answer
# $1: JSON data (like {"status":"xxx","code":ddd, ...}
# $?: 0 for success
keep2share_status() {
    local STATUS=$(parse_json 'status' <<< "$1")
    if [ "$STATUS" != 'success' ]; then
        local CODE=$(parse_json 'code' <<< "$1")
        local MSG=$(parse_json 'message' <<< "$1")
        log_error "Remote status: '$STATUS' with code $CODE."
        [ -z "$MSG" ] || log_error "Message: $MSG"
        return $ERR_FATAL
    fi
}

# Static function. Proceed with login
# $1: authentication
# $2: API URL
# stdout: auth token
keep2share_login() {
    local -r API_URL=$2
    local TOKEN JSON MSG USER PASSWORD ACCOUNT_EXPIRES TYPE EPOCH

    if TOKEN=$(storage_get 'token'); then

        # Check for expired session
        JSON=$(curl --data '{"auth_token":"'$TOKEN'"}' "${API_URL}test") || return

        # {"status":"success","code":200,"message":"Test was successful!"}
        # {"status":"error","code":403,"message":"Authorization session was expired"}
        if ! keep2share_status "$JSON"; then
            storage_set 'token'
            return $ERR_EXPIRED_SESSION
        fi

        log_debug "token (cached): '$TOKEN'"
        MSG='reused login for'
    else
        split_auth "$1" USER PASSWORD || return
        JSON=$(curl --data '{"username":"'"$USER"'","password":"'"$PASSWORD"'"}' \
            "${API_URL}login") || return

        # {"status":"success","code":200,"auth_token":"li26v3nbhspn0tdth5hmd53j07"}
        # {"message":"Login attempt was exceed, wait...","status":"error","code":406}
        keep2share_status "$JSON" || return $ERR_LOGIN_FAILED

        TOKEN=$(parse_json 'auth_token' <<< "$JSON")
        storage_set 'token' "$TOKEN"

        log_debug "Successfully logged in as $USER member"
        MSG='logged in as'
    fi

    JSON=$(curl --data '{"auth_token":"'$TOKEN'"}' "${API_URL}AccountInfo") || return

    # {"status":"success","code":200,"available_traffic":10737418240,"account_expires":false}
    # {"message":"No allow from this network","status":"error","code":403,"errorCode":73}
    keep2share_status "$JSON" || return $ERR_LOGIN_FAILED

    ACCOUNT_EXPIRES=$(parse_json 'account_expires' <<< "$JSON") || return
    TYPE='free'
    if [ "$ACCOUNT_EXPIRES" != 'false' ]; then
        EPOCH=$(date +%s)
        if (( ACCOUNT_EXPIRES > EPOCH )); then
            TYPE='premium'
        fi
    fi

    log_debug "Successfully $MSG '$TYPE' member"
    echo $TYPE
    echo $TOKEN
}

# Output an keep2share file download URL
# $1: cookie file
# $2: keep2share url
# stdout: real file download link
keep2share_download() {
    local -r COOKIE_FILE=$1
    local -r API_URL='http://keep2share.cc/api/v1/'
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
        FILE_ID=$(parse . 'file/\([^/]\+\)' <<< "$URL") || return

        # Check a file status and get its filename from api
        JSON=$(curl --data '{"auth_token":"'$TOKEN'","ids":["'$FILE_ID'"]}' "${API_URL}GetFilesInfo") || return

        # {"status":"success","code":200,"files":[{"id":"c1672cfa4f357","name":
        keep2share_status "$JSON" || return

        FILE_STATUS=$(parse_json 'is_available' <<< "$JSON") || return
        if [ "$FILE_STATUS" != 'true' ]; then
            return $ERR_LINK_DEAD
        fi

        FILE_STATUS=$(parse_json 'access' <<< "$JSON") || return
        if [ "$FILE_STATUS" = 'private' ]; then
            log_error 'This is a private file.'
            return $ERR_LINK_NEED_PERMISSIONS
        fi

        FILE_NAME=$(parse_json 'name' <<< "$JSON") || return

        # Get a final link
        JSON=$(curl --data '{"auth_token":"'$TOKEN'","file_id":"'$FILE_ID'"}' "${API_URL}GetUrl") || return

        # {"status":"success","code":200,"url": ...}
        keep2share_status "$JSON" || return

        parse_json 'url' <<< "$JSON" || return
        echo "$FILE_NAME"
        return 0

    elif [ "$ACCOUNT" = 'free' ]; then
        local CAPTCHA_CHALL CAPTCHA_URL CAPTCHA_IMG STATUS DOWNLOAD_KEY
        FILE_ID=$(parse . 'file/\([^/]\+\)' <<< "$URL") || return

        # Check a file status and get its filename from api
        JSON=$(curl --data '{"auth_token":"'$TOKEN'","ids":["'$FILE_ID'"]}' "${API_URL}GetFilesInfo") || return

        # {"status":"success","code":200,"files":[{"id":"c1672cfa4f357","name": ...}}
        keep2share_status "$JSON" || return

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
        keep2share_status "$JSON" || return

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
        keep2share_status "$JSON" || return

        parse_json 'url' <<< "$JSON" || return
        echo "$FILE_NAME"
        return 0
    fi

    PAGE=$(curl -c "$COOKIE_FILE" "$URL") || return

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
            IMG_FILE=$(create_tempfile '.keep2share.png') || return
            curl -b "$COOKIE_FILE" -o "$IMG_FILE" "$BASE_URL$CAPTCHA_URL" || return

            # Solve captcha
            # Note: Image is a 260x80 png file containing 6-7 characters
            RESP=$(captcha_process "$IMG_FILE" keep2share 6 7) || return
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

# Upload a file to keep2share.
# $1: cookie file (unused)
# $2: input file (with full path)
# $3: remote filename
keep2share_upload() {
    local -r FILE=$2
    local -r DEST_FILE=$3
    local -r API_URL='http://keep2share.cc/api/v1/'
    local AT ACCOUNT MAX_SIZE SZ TOKEN JSON JSON2 FILE_ID FOLDER_ID

    if [ -n "$AUTH" ]; then
        AT=$(keep2share_login "$AUTH" "$API_URL") || return
        { read ACCOUNT; read TOKEN; } <<< "$AT"
    else
        return $ERR_LINK_NEED_PERMISSIONS
    fi

    # Sanity check
    if [ -n "$CREATE_FOLDER" -a -z "$FOLDER" ]; then
        log_error '--folder option required'
        return $ERR_BAD_COMMAND_LINE
    fi

    if [ "$ACCOUNT" = 'premium' ]; then
        MAX_SIZE=5368709120 # 5 GiB (premium account)
    else
        MAX_SIZE=524288000 # 500 MiB (free account)
    fi

    SZ=$(get_filesize "$FILE")
    if [ "$SZ" -gt "$MAX_SIZE" ]; then
        log_debug "file is bigger than $MAX_SIZE"
        return $ERR_SIZE_LIMIT_EXCEEDED
    fi

    # Check folder name
    if [ -n "$FOLDER" ]; then
        JSON=$(curl --data '{"auth_token":"'$TOKEN'","type":"folder"}' \
            "${API_URL}GetFilesList") || return

        # {"status":"success","code":200,"files":[{"id":"cdd2f2d78d4c6","name": ...}]}
        keep2share_status "$JSON" || return

        JSON2=$(parse_json 'files' <<< "$JSON" ) || return
        JSON2=${JSON2#[}
        JSON2=${JSON%]}

        local -i I=1
        while read -r; do
            if [ "$REPLY" == "$FOLDER" ]; then
                FOLDER_ID=$(parse_json 'id' split <<< "$JSON2" | nth_line $I)
                log_debug "found folder id='$FOLDER_ID'"
                break
            fi
            (( ++I ))
        done < <(parse_json 'name' split <<< "$JSON2")


        if [ -z "$FOLDER_ID" ]; then
            if [ -n "$CREATE_FOLDER" ]; then
                JSON=$(curl --data '{"auth_token":"'$TOKEN'","parent":"/","name":"'"$FOLDER"'","access":"private"}' \
                    "${API_URL}CreateFolder") || return

                # {"status":"success","code":201,"id":"552b574f449e9"}
                keep2share_status "$JSON" || return

                FOLDER_ID=$(parse_json 'id' <<< "$JSON")
                log_debug "new folder created id='$FOLDER_ID'"
            else
                log_error 'Folder does not seem to exist. Use --create switch.'
                return $ERR_FATAL
            fi
        fi
    fi

    JSON=$(curl --data '{"auth_token":"'$TOKEN'"}' \
        "${API_URL}GetUploadFormData") || return

    # {"status":"success","code":200,"form_action":"...","file_field":"Filedata", ...}
    keep2share_status "$JSON" || return

    local FORM_ACTION FILE_FIELD NODE_NAME USER_ID HMAC EXPIRES

    FORM_ACTION=$(parse_json 'form_action' <<< "$JSON" ) || return
    FILE_FIELD=$(parse_json 'file_field' <<< "$JSON" ) || return

    JSON2=$(parse_json 'form_data' <<< "$JSON" ) || return
    log_debug "json2: '$JSON2'"

    NODE_NAME=$(parse_json 'nodeName' <<< "$JSON2" ) || return
    USER_ID=$(parse_json 'userId' <<< "$JSON2" ) || return
    HMAC=$(parse_json 'hmac' <<< "$JSON2" ) || return
    EXPIRES=$(parse_json 'expires' <<< "$JSON2" ) || return

    [ -z "$FOLDER_ID" ] || FOLDER_ID="-F parent_id=$FOLDER_ID"
    JSON=$(curl_with_log \
        -F "$FILE_FIELD=@$FILE;filename=$DEST_FILE" \
        -F "nodeName=$NODE_NAME" \
        -F "userId=$USER_ID" \
        -F "hmac=$HMAC" \
        -F "expires=$EXPIRES" \
        -F 'api_request=true' \
        $FOLDER_ID "$FORM_ACTION") || return

    # Sanity check
    # <title>503 Service Temporarily Unavailable</title>
    if match '>503 Service Temporarily Unavailable<' "$JSON"; then
        log_error 'remote: service unavailable (HTTP 503)'
        return $ERR_LINK_TEMP_UNAVAILABLE
    fi

    # {"user_file_id":"3ef8d474ad919","status":"success","status_code":200}
    keep2share_status "$JSON" || return

    FILE_ID=$(parse_json 'user_file_id' <<< "$JSON" ) || return
    if [ -z "$FULL_LINK" ]; then
        echo "http://k2s.cc/file/$FILE_ID"
    else
        echo "http://k2s.cc/file/$FILE_ID/$DEST_FILE"
    fi
}

# Probe a download URL
# $1: cookie file (unused here)
# $2: keep2share url
# $3: requested capability list
# stdout: 1 capability per line
#
# Official API does not provide a anonymous check-link feature :(
# $ curl --data '{"ids":["816bef5d35245"]}' http://keep2share.cc/api/v1/GetFilesInfo
keep2share_probe() {
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

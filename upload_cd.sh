# Plowshare upload.cd module
# by idleloop <idleloop@yahoo.com>, v1.2, Feb 2016
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

MODULE_UPLOAD_CD_REGEXP_URL='http://\(www\.\)\?upload\.cd/[[:alnum:]]\+'

MODULE_UPLOAD_CD_DOWNLOAD_OPTIONS=""
MODULE_UPLOAD_CD_DOWNLOAD_RESUME=yes
MODULE_UPLOAD_CD_DOWNLOAD_FINAL_LINK_NEEDS_COOKIE=unused
MODULE_UPLOAD_CD_DOWNLOAD_SUCCESSIVE_INTERVAL=

MODULE_UPLOAD_CD_PROBE_OPTIONS=""

# Output a upload.cd file download URL
# $1: cookie file (unused here)
# $2: upload.cd url
# stdout: real file download link
upload_cd_download() {
    local -r COOKIE_FILE=$1
    local -r URL=$2
    local -r BASE_URL='http://upload.cd'
    local -r TIMER_URL='http://upload.cd/download/startTimer'
    local -r CHECK_TIMER_URL='http://upload.cd/download/checkTimer'
    local PAGE FILE_URL FILE_NAME FORM_HTML FORM_FILEID FORM_USID FORM_METHOD FORM_ACTION FILE_SID WAIT_TIME

    # no login support
    #if [ -n "$AUTH_FREE" ]; then
    #    upload.cd_login "$AUTH_FREE" "$COOKIE_FILE" "$BASE_URL" || return
    #    PAGE=$(curl -L -b "$COOKIE_FILE" -c "$COOKIE_FILE" "$URL") || return
    #else
        PAGE=$(curl -L -b "COOKIE_FILE" -c "$COOKIE_FILE" "$URL") || return
    #fi

    if match 'was not found' "$PAGE"; then
        return $ERR_LINK_DEAD
    fi

    # check for forced delay
    if match 'You have to wait' "$PAGE"; then
        local HOURS MINS SECS
        HOURS=$(echo "$PAGE" | \
            parse_quiet 'You have to wait' ' \([[:digit:]]\+\) hours\?')
        MINS=$(echo "$PAGE" | \
            parse_quiet 'You have to wait' ' \([[:digit:]]\+\) minutes\?')
        SECS=$(echo "$PAGE" | \
            parse_quiet 'You have to wait' ', \([[:digit:]]\+\) seconds\?')            
        log_error 'Forced delay between downloads.'
        echo $(( HOURS * 60 * 60 + MINS * 60 + SECS ))
        return $ERR_LINK_TEMP_UNAVAILABLE    
    fi

    FILE_NAME=$(parse_tag '<h3.\+</div>' h3 <<< "$PAGE") || return

    FORM_HTML=$(grep_form_by_order "$PAGE" 1) || return
    FORM_FILEID=$(parse_form_input_by_name 'fileid' <<< "$FORM_HTML") || return
    FORM_USID=$(parse_form_input_by_name_quiet 'usid' <<< "$FORM_HTML") || return
    FORM_METHOD=$(parse_form_input_by_name 'premium_dl' <<< "$FORM_HTML") || return
    FORM_ACTION=$(parse_form_action <<< "$FORM_HTML") || return

    # intermediate petition "1" to start timer on both sides:
    PAGE=$(curl -b "$COOKIE_FILE" -c "$COOKIE_FILE" -H "Referer: $URL" \
                                  --data-urlencode "fid=$FORM_FILEID" \
        "$TIMER_URL") || return

    # parse wait time
    WAIT_TIME=$(echo "$PAGE" | \
        parse 'seconds' '"seconds":[[:space:]]\?\([[:digit:]]\+\)[[:space:]]\?,') || return
    # parse compulsory SID
    FILE_SID=$(echo "$PAGE" | \
        parse 'sid' '"sid":[[:space:]]\?"\([^\"]\+\)"') || return

    if [ -n "$WAIT_TIME" ]; then
        wait $(( WAIT_TIME + 1 )) || return
    fi

    # intermediate petition "2" to stop timer on both sides:
    PAGE=$(curl -b "$COOKIE_FILE" -c "$COOKIE_FILE" -H "Referer: $URL" \
                                  -H "Origin: $BASE_URL" \
                                  -H "X-Requested-With: XMLHttpRequest" \
                                  --data-urlencode "sid=$FILE_SID" \
        "$CHECK_TIMER_URL") || return

    if match 'Your request is invalid.' "$PAGE"; then
        log_error 'Request refused.'
        return $ERR_FATAL
    fi

    # after the intermediate petitions for obtaining sid/usid ,
    # request download
    PAGE=$(curl -b "$COOKIE_FILE" -c "$COOKIE_FILE" -H "Referer: $URL" \
                                  --data-urlencode "fileid=$FORM_FILEID" \
                                  --data-urlencode "usid=$FILE_SID" \
                                  --data-urlencode "referer=" \
                                  --data-urlencode "premium_dl=$FORM_METHOD" \
        "$BASE_URL$FORM_ACTION") || return

    # check for and handle CAPTCHA (if any)
    # Note: emulate 'grep_form_by_id_quiet'
    FORM_HTML=$(grep_form_by_order "$PAGE" 1 2>/dev/null)

    if [ -n "$FORM_HTML" ]; then
        local RESP WORD ID CAPTCHA_DATA

        if match 'recaptcha_widget' "$FORM_HTML"; then
            log_debug 'reCaptcha found'
            local CHALL
            local -r PUBKEY='6Ldl-eESAAAAAC2KU1qbUj5JfdvU1_Voaqj9Rbcj'

            RESP=$(recaptcha_process $PUBKEY) || return
            { read WORD; read CHALL; read ID; } <<< "$RESP"

            CAPTCHA_DATA="-d recaptcha_challenge_field=$CHALL -d recaptcha_response_field=$WORD"

        else
            log_error 'Unexpected content/captcha type. Site updated?'
            return $ERR_FATAL
        fi

        log_debug "Captcha data: $CAPTCHA_DATA"

        PAGE=$(curl -b "$COOKIE_FILE" -c "$COOKIE_FILE" $CAPTCHA_DATA \
                                   -H "Referer: $BASE_URL$FORM_ACTION" \
                                   -d "fileid=$FORM_FILEID" \
            "$BASE_URL$FORM_ACTION") || return

        # Get error message, if any
        ERR=$(parse_tag_quiet '<div class="errorMessage"' 'div' <<< "$PAGE")

        if [ -n "$ERR" ]; then
            if match 'The verification code is incorrect' "$ERR"; then
                log_error 'Wrong captcha'
                captcha_nack "$ID"
                return $ERR_CAPTCHA
            fi

            log_debug 'Correct captcha'
            captcha_ack "$ID"
            log_error "Unexpected remote error: $ERR"
            return $ERR_FATAL
        fi

        log_debug 'Correct captcha'
        captcha_ack "$ID"

    else
        log_error 'Unexpected content. Site updated?'
        return $ERR_FATAL
    fi

    parse_attr 'download-btn' href <<< "$PAGE"
}

# Probe a download URL
# $1: cookie file (unused here)
# $2: upload.cd url
# $3: requested capability list
upload_cd_probe() {
    local -r REQ_IN=$3
    local PAGE REQ_OUT FILE_SIZE

    PAGE=$(curl --location "$URL") || return

    # The file link that you requested is not valid (anymore).
    if match 'was not found' "$PAGE"; then
        return $ERR_LINK_DEAD
    fi    

    REQ_OUT=c

    if [[ $REQ_IN = *f* ]]; then
        parse_tag '<h3.\+</div>' h3 <<< "$PAGE" && REQ_OUT="${REQ_OUT}f"
    fi

    if [[ $REQ_IN = *s* ]]; then
        FILE_SIZE=$(echo "$PAGE" | 
            parse '<h3.\+</div>' \
            '<p>\([0-9\.]\+[[:space:]]\?[KkMG]\?B\)</p>' ) &&
            translate_size "${FILE_SIZE/,/}" && REQ_OUT="${REQ_OUT}s"
    fi

    if [[ $REQ_IN = *i* ]]; then
        parse_form_input_by_name 'fileid' <<< "$PAGE" && REQ_OUT="${REQ_OUT}i"
    fi

    echo $REQ_OUT
}

# Plowshare fboom.me module
# by idleloop <idleloop@yahoo.com>, v1.1, Mar 2016
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
# (Official API probably similar to: https://github.com/keep2share/api)

MODULE_FBOOM_ME_REGEXP_URL='https\?://\(www\.\)\?fboom.me/'

MODULE_FBOOM_ME_DOWNLOAD_OPTIONS=""
MODULE_FBOOM_ME_DOWNLOAD_RESUME=yes
MODULE_FBOOM_ME_DOWNLOAD_FINAL_LINK_NEEDS_COOKIE=no
MODULE_FBOOM_ME_DOWNLOAD_FINAL_LINK_NEEDS_EXTRA=
MODULE_FBOOM_ME_DOWNLOAD_SUCCESSIVE_INTERVAL=

MODULE_FBOOM_ME_PROBE_OPTIONS=""

# Static function. Switch language to english
# $1: cookie file
# $2: base URL
fboom_me_switch_lang() {
    curl "$2/site/setLanguage" -b "$1" -c "$1" -d 'language=en' > /dev/null || return
}

# Output an fboom_me file download URL
# $1: cookie file
# $2: fboom_me url
# stdout: real file download link
fboom_me_download() {
    local -r COOKIE_FILE=$1
    local URL BASE_URL FILE_NAME PRE_URL
    local PAGE FORM_HTML FILE_ID WAIT

    # get canonical URL and BASE_URL for this file
    URL=$(curl -I "$2" | grep_http_header_location_quiet) || return
    [ -n "$URL" ] || URL=$2
    BASE_URL=${URL%/file*}
    readonly URL BASE_URL

    fboom_me_switch_lang "$COOKIE_FILE" "$BASE_URL"

    PAGE=$(curl -b "$COOKIE_FILE" -c "$COOKIE_FILE" "$URL") || return

    # Malformed url
    if match 'The system is unable to find the requested action' "$PAGE"; then
        log_error 'Invalid or malformed link! Check url.'
        return $ERR_LINK_DEAD
    fi

    # File not found or deleted
    if match 'File not found or deleted\|This file is no longer available' "$PAGE"; then
        return $ERR_LINK_DEAD
    fi

    # File only available to premium members
    if match 'only for premium members.' "$PAGE"; then
        return $ERR_LINK_NEED_PERMISSIONS
    fi

    FILE_NAME=$(parse 'Download file:' '^[[:blank:]]\+\([^<]\+\)[[:blank:]]\+<' '3' <<< "$PAGE" | \
        html_to_utf8) || return
    readonly FILE_NAME

    FILE_ID=$(parse 'data-slow-id' 'data-slow-id="\([^"]\+\)"' <<< "$PAGE") || return

    # request download
    PAGE=$(curl -b "$COOKIE_FILE" -d "slow_id=$FILE_ID" \
        "$URL") || return

    # check for forced delay
    WAIT=$(parse_quiet 'Please wait .* to download this file' \
        'wait \([[:digit:]:]\+\) to download' <<< "$PAGE")

    if [ -n "$WAIT" ]; then
        local HOUR MIN SEC

        HOUR=${WAIT%%:*}
        SEC=${WAIT##*:}
        MIN=${WAIT#*:}; MIN=${MIN%:*}
        log_error 'Forced delay between downloads.'
        # Note: Get rid of leading zeros so numbers will not be considered octal
        echo $(( (( ${HOUR#0} * 60 ) + ${MIN#0} ) * 60 + ${SEC#0} ))
        return $ERR_LINK_TEMP_UNAVAILABLE
    fi

    # Free user can't download large files.
    if match "Free user can't download large files" "$PAGE"; then
        log_error 'Free user cant download large files'
        return $ERR_LINK_NEED_PERMISSIONS
    fi

    # check for and handle CAPTCHA (if any)
    if match 'captcha.html' "$PAGE"; then
        log_debug 'Captcha found'
        local CAPTCHA_URL IMG_FILE
        local RESP WORD ID CAPTCHA_DATA

        # Get captcha image
        CAPTCHA_URL=$(parse_attr ' id="captcha_' 'src' <<< "$PAGE") || return
        IMG_FILE=$(create_tempfile '.fboom_me.png') || return
        curl -b "$COOKIE_FILE" -o "$IMG_FILE" "$BASE_URL$CAPTCHA_URL" || return

        # Solve captcha
        # Note: Image is a 260x80 png file containing 6-7 characters
        RESP=$(captcha_process "$IMG_FILE" fboom_me 6 7) || return
        { read WORD; read ID; } <<< "$RESP"
        rm -f "$IMG_FILE"

        CAPTCHA_DATA="-d CaptchaForm%5Bcode%5D=$WORD"

        log_debug "Captcha data: $CAPTCHA_DATA"

        FILE_ID=$(parse_form_input_by_name 'uniqueId' <<< "$PAGE") || return

        PAGE=$(curl -b "$COOKIE_FILE" $CAPTCHA_DATA \
            -d 'free=1' -d 'freeDownloadRequest=1' \
            -d "uniqueId=$FILE_ID" \
            -H 'X-Requested-With: XMLHttpRequest' \
            "$URL") || return

        if match 'The verification code is incorrect' "$PAGE"; then
            log_error 'Wrong captcha'
            captcha_nack "$ID"
            return $ERR_CAPTCHA
        fi

        log_debug 'Correct captcha'
        captcha_ack "$ID"

        # parse wait time
        WAIT=$(parse ' id="download-wait-timer"' \
            '.*>[[:blank:]]*\([[:digit:]]\+\)' 1 <<< "$PAGE") || return

        wait $(( WAIT + 1 )) || return

        PAGE=$(curl -b "$COOKIE_FILE" -d "uniqueId=$FILE_ID" \
            -d 'free=1' "$URL") || return

        PRE_URL=$(parse_attr 'id="temp-link"' 'href' <<< "$PAGE") || return

    # direct download without captcha
    elif match 'bottomDownloadButton' "$PAGE"; then
        PRE_URL=$(parse 'window.location.href' "'\([^']\+\)'" <<< "$PAGE") || return
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
# $2: fboom.me url
# $3: requested capability list
# stdout: 1 capability per line
#
# probable API (see this file's header) does not provide an anonymous check-link feature :(
# $ curl --data '{"ids"=["816bef5d35245"]}' http://fboom.me/api/v1/GetFilesInfo
fboom_me_probe() {
    local -r URL=$2
    local -r REQ_IN=$3
    local PAGE REQ_OUT FILE_NAME

    PAGE=$(curl --location -b 'language=en' "$URL") || return

    # File not found or delete
    if match 'File not found or deleted\|This file is no longer available' "$PAGE"; then
        return $ERR_LINK_DEAD
    fi

    REQ_OUT=c

    if [[ $REQ_IN = *f* ]]; then
        echo "$PAGE" | parse 'Download file:' '^[[:blank:]]\+\([^<]\+\)[[:blank:]]\+<' 3 | \
        sed -e 's/[[:space:]]*$//' && \
            REQ_OUT="${REQ_OUT}f"
    fi

    if [[ $REQ_IN = *s* ]]; then
        FILE_SIZE=$(parse_tag 'File size:' 'div' <<< "$PAGE") && \
            translate_size "${FILE_SIZE#File size: }" && REQ_OUT="${REQ_OUT}s"
    fi

    if [[ $REQ_IN = *i* ]]; then
        parse . 'file/\([[:alnum:]]\+\)/\?' <<< "$URL" && REQ_OUT="${REQ_OUT}i"
    fi

    echo $REQ_OUT
}

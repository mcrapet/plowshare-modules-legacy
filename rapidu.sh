# Plowshare rapidu.net module
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

MODULE_RAPIDU_REGEXP_URL='https\?://\([[:alnum:]]\+\.\)\?rapidu\.\(net\|xup\.pl\)/'

MODULE_RAPIDU_DOWNLOAD_OPTIONS="
AUTH,a,auth,a=USER:PASSWORD,User account"
MODULE_RAPIDU_DOWNLOAD_RESUME=yes
MODULE_RAPIDU_DOWNLOAD_FINAL_LINK_NEEDS_COOKIE=no
MODULE_RAPIDU_DOWNLOAD_SUCCESSIVE_INTERVAL=

MODULE_RAPIDU_PROBE_OPTIONS=""

# Static function. Switch language to english
# $1: cookie file
# $2: base URL
rapidu_switch_lang() {
    curl "$2/ajax.php?a=getChangeLang" -c "$1" -b "$1" -d 'lang=en' \
        -d '_go=' > /dev/null || return
}

# Static function. Proceed with login
# $1: authentication
# $2: cookie file
# $3: base URL
# stdout: account type ("free" or "premium") on success
rapidu_login() {
    local -r AUTH=$1
    local -r COOKIE_FILE=$2
    local -r BASE_URL=$3

    local LOGIN_DATA JSON STATUS PAGE NAME TYPE

    LOGIN_DATA='login=$USER&pass=$PASSWORD&remember=1&_go='

    JSON=$(post_login "$AUTH" "$COOKIE_FILE" "$LOGIN_DATA" \
        "$BASE_URL/ajax.php?a=getUserLogin" -L -b "$COOKIE_FILE") || return

    # If successful we get JSON data: {"message":"success","redirect":""}
    STATUS=$(parse_json 'message' <<< "$JSON") || return
    [ "$STATUS" != 'success' ] && return $ERR_LOGIN_FAILED

    PAGE=$(curl -b "$COOKIE_FILE" "$BASE_URL") || return
    NAME=$(parse_quiet 'Logged:' '>\([^<]\+\)</' <<< "$PAGE")
    TYPE=$(parse 'Account:' '\(Free\|Premium\)' <<< "$PAGE") || return

    if [ "$TYPE" = 'Free' ]; then
        TYPE='free'
    elif [ "$TYPE" = 'Premium' ]; then
        TYPE='premium'
    fi

    log_debug "Successfully logged in as $TYPE member '$NAME'"
    echo $TYPE
}


# Output a rapidu file download URL
# $1: cookie file
# $2: rapidu url
# stdout: real file download link
rapidu_download() {
    local -r COOKIE_FILE=$1
    local -r BASE_URL='https://rapidu.net'
    local URL ACCOUNT PAGE JSON WAIT_TIME FILE_ID STATUS FILE_URL

    # Get a canonical URL for this file.
    URL=$(curl -I "$2" | grep_http_header_location_quiet) || return
    [ -n "$URL" ] || URL=$2
    readonly URL

    rapidu_switch_lang "$COOKIE_FILE" "$BASE_URL"

    if [ -n "$AUTH" ]; then
        ACCOUNT=$(rapidu_login "$AUTH" "$COOKIE_FILE" "$BASE_URL") || return
    fi

    # Note: Save HTTP headers to catch premium users' "direct downloads".
    PAGE=$(curl -i -b "$COOKIE_FILE" "$URL") || return

    if match "404 - File not found\|404 Not Found" "$PAGE"; then
        return $ERR_LINK_DEAD
    fi

    # If this is a premium download, we already have a download link.
    if [ "$ACCOUNT" = 'premium' ]; then
        # Get a download link, if this was a direct download.
        FILE_URL=$(grep_http_header_location_quiet <<< "$PAGE")

        if [ -z "$FILE_URL" ]; then
            FILE_URL=$(parse_attr '>Premium Download<' 'href' <<< "$PAGE") || return
        fi

        echo "$FILE_URL"
        return 0
    fi

    JSON=$(curl -d '_go=' -e "$URL" "$BASE_URL/ajax.php?a=getLoadTimeToDownload") || return
    WAIT_TIME=$(($(parse_json 'timeToDownload' <<< "$JSON") - $(date +%s))) || return
    # Note: If we wait more then 5 minutes then we definitely reached downloads limit.
    if [[ $WAIT_TIME -gt 300 ]]; then
        log_error 'Download limit reached.'
        echo $WAIT_TIME
        return $ERR_LINK_TEMP_UNAVAILABLE
    fi
    wait $WAIT_TIME || return

    local PUBKEY WCI CHALLENGE WORD ID
    PUBKEY='6Ld12ewSAAAAAHoE6WVP_pSfCdJcBQScVweQh8Io'
    WCI=$(recaptcha_process $PUBKEY) || return
    { read WORD; read CHALLENGE; read ID; } <<< "$WCI"

    FILE_ID=$(parse . 'rapidu[^/]*/\([[:digit:]]\+\)' <<< "$URL") || return

    JSON=$(curl -e "$URL" \
        -b "$COOKIE_FILE" \
        -d "captcha1=$CHALLENGE" \
        -d "captcha2=$WORD" \
        -d "fileId=$FILE_ID" \
        -d '_go=' \
        "$BASE_URL/ajax.php?a=getCheckCaptcha") || return

    STATUS=$(parse_json 'message' <<< "$JSON") || return

    if [ "$STATUS" != 'success' ]; then
        captcha_nack $ID
        log_error 'Wrong captcha'
        return $ERR_CAPTCHA
    fi

    captcha_ack $ID
    log_debug 'Correct captcha'

    FILE_URL=$(parse_json 'url' <<< "$JSON") || return
    echo "$FILE_URL"
}

# Probe a download URL
# $1: cookie file (unused here)
# $2: rapidu url
# $3: requested capability list
# stdout: 1 capability per line
rapidu_probe() {
    local -r URL=$2
    local -r REQ_IN=$3
    local -r API_URL='http://rapidu.net/api/getFileDetails/'
    local FILE_ID JSON STATUS REQ_OUT

    FILE_ID=$(parse . 'rapidu[^/]*/\([[:digit:]]\+\)' <<< "$URL") || return
    JSON=$(curl -d "id=$FILE_ID" "$API_URL") || return
    STATUS=$(parse_json 'fileStatus' <<< "$JSON") || return

    if [ "$STATUS" != '1' ]; then
        return $ERR_LINK_DEAD
    fi

    REQ_OUT=c

    if [[ $REQ_IN = *f* ]]; then
        parse_json 'fileName' <<< "$JSON" && REQ_OUT="${REQ_OUT}f"
    fi

    if [[ $REQ_IN = *s* ]]; then
        parse_json 'fileSize' <<< "$JSON" && REQ_OUT="${REQ_OUT}s"
    fi

    if [[ $REQ_IN = *i* ]]; then
        parse_json 'fileId' <<< "$JSON" && REQ_OUT="${REQ_OUT}i"
    fi

    echo $REQ_OUT
}

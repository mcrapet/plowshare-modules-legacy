# Plowshare datafile.com module
# Copyright (c) 2016 Ben Zho
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

MODULE_DATAFILE_REGEXP_URL='http://\(www\.\)\?datafile\.com/d/'

MODULE_DATAFILE_DOWNLOAD_RESUME=yes
MODULE_DATAFILE_DOWNLOAD_FINAL_LINK_NEEDS_COOKIE=no

# Output a datafile.com file download URL
# $1: cookie file
# $2: datafile.com url
# stdout: real file download link
datafile_download() {
    local -r COOKIE_FILE=$1
    local -r URL=$2
    local -r BASE_URL='http://www.datafile.com'
    local PAGE LOCATION WAIT_SEC FILE_URL JSON FILEID TOKEN

    PAGE=$(curl -i -c "$COOKIE_FILE" -b "$COOKIE_FILE" "$URL") || return

    LOCATION=$(grep_http_header_location_quiet <<< "$PAGE")

    if [[ -n "$LOCATION" ]]; then
        ERROR_CODE=$(echo "$LOCATION" | parse '' 'download/error\.html?code=\([0-9]\+\)') || return
        case $ERROR_CODE in
            9)
                log_error "You're already downloading a file"
                return $ERR_LINK_TEMP_UNAVAILABLE
                ;;
            7)
                log_error "You exceeded your free daily download limit."
                echo 3600
                return $ERR_LINK_TEMP_UNAVAILABLE
                ;;
            *)
                log_error "Unknown error: $ERROR_CODE"
                return $ERR_FATAL
                ;;
        esac
        fi

    if match 'ErrorCode 0: Invalid Link' "$PAGE"; then
        return $ERR_LINK_DEAD
    fi

    FILEID=$(echo "$URL" | parse '' '/d/\([[:alnum:]]\+\)') || return
    local PUBKEY WCI CHALLENGE WORD ID
    PUBKEY='6LdWgNgSAAAAACXqFKE69ttVU-CfV-IruHtDKCUf'
    WCI=$(recaptcha_process $PUBKEY) || return
    { read WORD; read CHALLENGE; read ID; } <<<"$WCI"

    JSON=$(curl --location -H 'X-Requested-With: XMLHttpRequest' --referer "$URL" \
                -d "doaction=validateCaptcha" -d "recaptcha_response_field=$WORD" \
                -d "recaptcha_challenge_field=$CHALLENGE" -d "fileid=$FILEID" "$BASE_URL/files/ajax.html") || return
    if [[ $(parse_json 'success' <<<"$JSON") -ne 1 ]]; then
        log_error "captcha response didn't have success = 1 ($JSON)"
        captcha_nack $ID
        return $ERR_CAPTCHA
    fi
    captcha_ack $ID

    TOKEN=$(parse_json 'token' <<<"$JSON")
    if [[ -z "$TOKEN" ]]; then
        log_error "no token returned for successful captcha solution"
        return $ERR_FATAL
    fi
    WAIT_SEC=$(parse 'counter.contdownTimer(' "'\([0-9]\+\)'" <<<"$PAGE")
    if [[ -z "$WAIT_SEC" ]]; then
        log_debug "no wait sec"
    fi
    wait $WAIT_SEC || return
    JSON=$(curl --location -H 'X-Requested-With: XMLHttpRequest' --referer "$URL" \
                -d "doaction=getFileDownloadLink" -d "recaptcha_response_field=$WORD" \
                -d "recaptcha_challenge_field=$CHALLENGE" \
                -d "fileid=$FILEID" -d "token=$TOKEN" "$BASE_URL/files/ajax.html") || return
    if [[ $(parse_json 'success' <<<"$JSON") -ne 1 ]]; then
        log_error "fileDownloadLink response didn't have success = 1"
        return $ERR_FATAL
    fi
    FILE_URL=$(parse_json 'link' <<<"$JSON")
    echo $FILE_URL
    curl -I "$FILE_URL" | grep_http_header_content_disposition || return
}

# # Probe a download URL
# # $1: cookie file (unused here)
# # $2: datafile.com url
# # $3: requested capability list
# # stdout: 1 capability per line
datafile_probe() {
     local -r URL=$2
     local -r REQ_IN=$3
     local PAGE ERROR_CODE FILE_SIZE FILE_NAME LINK_ID REQ_OUT
     PAGE=$(curl -L "$URL") || return
     ERROR_CODE=$(parse_quiet '<div class="error-msg">' '^ \+ErrorCode \([0-9]\+\)' 1 <<<"$PAGE")
     case "$ERROR_CODE" in
          0)
              log_error "Invalid/malformed link"
              return $ERR_LINK_DEAD
              ;;
          3)
              return $ERR_LINK_DEAD
              ;;
          '')
              ;;
          *)
              log_error "Unknown error $ERROR_CODE"
              return $ERR_FATAL
              ;;
     esac
     REQ_OUT=c
     LINK_ID=$(parse_quiet '' 'datafile\.com/d/\([^/]\+\)' <<< "$URL")
     if [[ -n "$LINK_ID" ]]; then
         if [[ $REQ_IN = *i* ]]; then
             REQ_OUT="${REQ_OUT}i"
             echo "$LINK_ID"
         fi
         if [[ $REQ_IN = *v* ]]; then
             REQ_OUT="${REQ_OUT}v"
             echo "http://www.datafile.com/d/$LINK_ID"
         fi
     fi
     if [[ $REQ_IN = *f* ]]; then
         FILE_NAME=$(parse  '<div class="file-name">' '^ \+\([^ ].\+\) \+</div>' 1 <<<"$PAGE" | strip)
         REQ_OUT="${REQ_OUT}f"
         echo "$FILE_NAME"
     fi
     if [[ $REQ_IN = *s* ]]; then
         FILE_SIZE=$(translate_size $(parse_tag  '<div class="file-size">' 'span' <<<"$PAGE" | replace_all ' ' ''))
         REQ_OUT="${REQ_OUT}s"
         echo "$FILE_SIZE"
     fi
     echo $REQ_OUT
}

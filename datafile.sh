# Plowshare datafile.com module
# Copyright (c) 2016 Ben Zho
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

MODULE_DATAFILE_REGEXP_URL='https\?://\(www\.\)\?datafile\.com/d/'

MODULE_DATAFILE_DOWNLOAD_OPTIONS=""
MODULE_DATAFILE_DOWNLOAD_RESUME=yes
MODULE_DATAFILE_DOWNLOAD_FINAL_LINK_NEEDS_COOKIE=unused
MODULE_DATAFILE_DOWNLOAD_SUCCESSIVE_INTERVAL=

MODULE_DATAFILE_PROBE_OPTIONS=""

# Output a datafile.com file download URL
# $1: cookie file
# $2: datafile.com url
# stdout: real file download link
datafile_download() {
    local -r COOKIE_FILE=$1
    local -r URL=$2
    local -r API_URL='http://www.datafile.com/files/ajax.html'
    local PAGE REDIR ERR FID WAIT_TIME TOKEN JSON FILE_URL

    PAGE=$(curl -i -c "$COOKIE_FILE" -b "$COOKIE_FILE" "$URL") || return
    REDIR=$(grep_http_header_location_quiet <<< "$PAGE")
    ERR=$(parse_quiet . 'code=\([[:digit:]]\+\)' <<< "$REDIR")

    if [ -n "$REDIR" -a -n "$ERR" ]; then
        log_debug "Remote error: $ERR"
        if [ "$ERR" -eq 6 ]; then
            log_debug 'You exceeded your free daily download limit.'
            echo 3600
        elif [ "$ERR" -eq 9 ]; then
            log_debug 'You'\''re already downloading a file'
        else
            return $ERR_FATAL
        fi
        return $ERR_LINK_TEMP_UNAVAILABLE
    fi

    # Redirection https => http
    if [ -n "$REDIR" ]; then
        PAGE=$(curl -L "$URL") || return
    fi

    ERR=$(parse_quiet '"error-msg' '^[[:space:]]*\([^<]*\)' 1 <<< "$PAGE")
    if [ -n "$ERR" ]; then
      log_debug "Remote ${ERR% *}"
      return $ERR_LINK_DEAD
    fi

    FID=$(parse . '/d/\([[:alnum:]]\+\)' <<< "$URL") || return

    local PUBKEY WCI CHALLENGE WORD ID
    PUBKEY='6LdWgNgSAAAAACXqFKE69ttVU-CfV-IruHtDKCUf'
    WCI=$(recaptcha_process $PUBKEY) || return
    { read WORD; read CHALLENGE; read ID; } <<< "$WCI"

    JSON=$(curl --location --referer "$URL" \
        -H 'X-Requested-With: XMLHttpRequest' \
        -d 'doaction=validateCaptcha' \
        -d "recaptcha_response_field=$WORD" \
        -d "recaptcha_challenge_field=$CHALLENGE" \
        -d "fileid=$FID" \
        "$API_URL") || return

    # {"success":1,"token":"97d60d5038ca497fbfbcf731d97d09f6"}
    if [[ $(parse_json 'success' <<< "$JSON") -ne 1 ]]; then
        log_error 'Wrong captcha.'
        captcha_nack $ID
        return $ERR_CAPTCHA
    fi
    captcha_ack $ID

    TOKEN=$(parse_json 'token' <<< "$JSON") || return

    WAIT_TIME=$(parse 'counter.contdownTimer(' \
            "'\([0-9]\+\)'" <<< "$PAGE") || return
    wait $((WAIT_TIME)) || return

    # {"success":1,"link":"http:\/\/n85.datafile.com\/....html"}
    JSON=$(curl --location --referer "$URL" \
        -H 'X-Requested-With: XMLHttpRequest' \
        -d 'doaction=getFileDownloadLink' \
        -d "recaptcha_response_field=$WORD" \
        -d "recaptcha_challenge_field=$CHALLENGE" \
        -d "fileid=$FID" \
        -d "token=$TOKEN" \
        "$API_URL") || return

    if [[ $(parse_json 'success' <<< "$JSON") -ne 1 ]]; then
        log_error "Unexpected remote error: $JSON"
        return $ERR_FATAL
    fi

    FILE_URL=$(parse_json 'link' <<< "$JSON") || return

    echo $FILE_URL
    curl --head "$FILE_URL" | grep_http_header_content_disposition || return
}

# Probe a download URL
# $1: cookie file (unused here)
# $2: datafile.com url
# $3: requested capability list
# stdout: 1 capability per line
datafile_probe() {
    local -r URL=$2
    local -r REQ_IN=$3
    local PAGE ERR REDIR FILE_SIZE REQ_OUT

    PAGE=$(curl -i "$URL") || return
    REDIR=$(grep_http_header_location_quiet <<< "$PAGE")
    ERR=$(parse_quiet . 'code=\([[:digit:]]\+\)' <<< "$REDIR")

    if [ -n "$REDIR" -a -n "$ERR" ]; then
        log_debug "Remote error: $ERR"

        # We can only get link status & size using official API
        PAGE=$(curl -F "links=$URL" \
            'http://www.datafile.com/linkchecker.html') || return

        if match '^[[:space:]]*Ok[[:space:]]*</td' "$PAGE"; then
            echo c
            return $ERR_LINK_TEMP_UNAVAILABLE
        else
            return $ERR_LINK_DEAD
        fi
    fi

    # Redirection https => http
    if [ -n "$REDIR" ]; then
        PAGE=$(curl -L "$URL") || return
    fi

    ERR=$(parse_quiet '"error-msg' '^[[:space:]]*\([^<]*\)' 1 <<< "$PAGE")
    [ -z "$ERR" ] || return $ERR_LINK_DEAD

    REQ_OUT=c

    # FIXME: name can be truncated, see if URL contains filename
    if [[ $REQ_IN = *f* ]]; then
        parse_tag '="file-name">[[:alnum:]]' div <<< "$PAGE" && REQ_OUT="${REQ_OUT}f"
    fi

    if [[ $REQ_IN = *s* ]]; then
        FILE_SIZE=$(parse_tag '="file-size">' span <<< "$PAGE") && \
            translate_size "${FILE_SIZE/o/B}" && REQ_OUT="${REQ_OUT}s"
    fi

    if [[ $REQ_IN = *i* ]]; then
        parse . '/d/\([[:alnum:]]\+\)' <<< "$URL" && REQ_OUT="${REQ_OUT}i"
    fi

    if [[ $REQ_IN = *v* ]]; then
        echo ${URL/#https/http} && REQ_OUT="${REQ_OUT}v"
    fi

    echo $REQ_OUT
}

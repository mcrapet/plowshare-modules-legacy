# Plowshare tempsend.com module
# Copyright (c) 2014-2016 Plowshare team
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

MODULE_TEMPSEND_REGEXP_URL='https\?://\(www\.\)\?tempsend\.com/'

MODULE_TEMPSEND_DOWNLOAD_OPTIONS=""
MODULE_TEMPSEND_DOWNLOAD_RESUME=no
MODULE_TEMPSEND_DOWNLOAD_FINAL_LINK_NEEDS_COOKIE=unused
MODULE_TEMPSEND_DOWNLOAD_SUCCESSIVE_INTERVAL=

MODULE_TEMPSEND_UPLOAD_OPTIONS="
NOSSL,,nossl,,Use HTTP upload url instead of HTTPS
TTL,,ttl,n=SECS,Expiration period (in seconds). Default is 86400 (one day)."
MODULE_TEMPSEND_UPLOAD_REMOTE_SUPPORT=no

MODULE_TEMPSEND_PROBE_OPTIONS=""

# Output a tempsend.com file download URL
# $1: cookie file (unused here)
# $2: tempsend.com url
# stdout: real file download link
tempsend_download() {
    local URL=$2
    local PAGE FILE_URL

    PAGE=$(curl -L "$URL") || return
    FILE_URL=$(parse_attr 'title=.Download' 'href' <<< "$PAGE") || return

    echo "http://tempsend.com$FILE_URL"
}

# Upload a file to tempsend.com
# $1: cookie file (unused here)
# $2: input file (with full path)
# $3: remote filename
# stdout: download
tempsend_upload() {
    local -r FILE=$2
    local -r DESTFILE=$3
    local BASE_URL='https://tempsend.com/send'
    local PAGE FILE_URL DELAY V

    [ -n "$NOSSL" ] && BASE_URL='http://tempsend.com/send'

    if [ -n "$TTL" ]; then
        # curl http://tempsend.com | grep option
        local -a VALUES=(3600 86400 604800 2678400)

        DELAY=0

        for V in ${VALUES[@]}; do
        if [[ $V -eq $TTL ]]; then
            DELAY=$V
            break;
        fi
        done

        if [[ $DELAY -eq 0 ]]; then
            log_error 'Bad value to --ttl, allowed values are: '${VALUES[*]}'.'
            return $ERR_BAD_COMMAND_LINE
        fi
    else
        DELAY=2678400
    fi

    PAGE=$(curl_with_log -L \
        -F "file=@$FILE;filename=$DESTFILE" \
        -F "expire=$DELAY" "$BASE_URL") || return

    # Sanity check
    if [ "$PAGE" == 'Could not connect to database' ]; then
        log_error "Remote error: $PAGE"
        return $ERR_LINK_TEMP_UNAVAILABLE
    fi

    if FILE_URL=$(parse_tag 'title=.Link to' a <<< "$PAGE"); then
        echo "$FILE_URL"
        return 0
    fi

    if match '>Not Found</' "$PAGE" && test -z "$NOSSL"; then
        log_error 'Remote error: retry using --nossl switch'
    fi

    return $ERR_FATAL
}

# Probe a download URL.
# $1: cookie file (unused here)
# $2: tempsend.com url
# $3: requested capability list
# stdout: 1 capability per line
tempsend_probe() {
    local -r URL=$2
    local -r REQ_IN=$3
    local PAGE REQ_OUT FID FILE_NAME FILE_SIZE

    PAGE=$(curl -L "$URL") || return

    if ! match '<h1>Download</h1>' "$PAGE"; then
        return $ERR_LINK_DEAD
    fi

    REQ_OUT=c

    if [[ $REQ_IN = *f* ]]; then
        FILE_NAME=$(parse_tag '="Download[[:space:]]' a <<< "$PAGE") && \
            echo "$FILE_NAME" && REQ_OUT="${REQ_OUT}f"
    fi

    if [[ $REQ_IN = *i* ]]; then
        FID=$(parse . '/\([[:alnum:]]*\)$' <<< "$URL") && \
            echo "$FID" && REQ_OUT="${REQ_OUT}i"
    fi

    if [[ $REQ_IN = *s* ]]; then
        FILE_SIZE=$(parse '[[:digit:]][[:space:]]downloads<' '^[^[:space:]]*[[:space:]]-[[:space:]]*\([^-]\+\)' <<< "$PAGE") && \
        translate_size "$FILE_SIZE" && REQ_OUT="${REQ_OUT}s"
    fi

    echo $REQ_OUT
}

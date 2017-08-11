# Plowshare nippyfile.com module
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

MODULE_NIPPYFILE_REGEXP_URL='https\?://\(www\.\)\?nippyfile\.com/'

MODULE_NIPPYFILE_DOWNLOAD_OPTIONS=""
MODULE_NIPPYFILE_DOWNLOAD_RESUME=no
MODULE_NIPPYFILE_DOWNLOAD_FINAL_LINK_NEEDS_COOKIE=unused
MODULE_NIPPYFILE_DOWNLOAD_SUCCESSIVE_INTERVAL=

MODULE_NIPPYFILE_PROBE_OPTIONS=""

# Output a nippyfile.com file download URL
# $1: cookie file
# $2: nippyfile.com url
# stdout: real file download link
nippyfile_download() {
    local -r COOKIE_FILE=$1
    local URL=$2
    local PAGE FILE_URL FILE_NAME LOCATION

    # set-cookie: PHPSESSID
    PAGE=$(curl -c "$COOKIE_FILE" "$URL") || return

    FILE_NAME=$(parse_tag_quiet 'Name:' li <<< "$PAGE")
    FILE_NAME=${FILE_NAME#Name: }

    # https scheme only
    FILE_URL=https:$(parse_attr '>Download<' 'href' <<< "$PAGE") || return

    PAGE=$(curl -i --referer "$URL" -b "$COOKIE_FILE" "$FILE_URL") || return

    LOCATION=$(grep_http_header_location_quiet <<< "$PAGE")

    [ -n "$LOCATION" ] || return $ERR_LINK_DEAD

    if [ "$LOCATION" = "$FILE_URL" ]; then
        log_error 'Unexpected content, site updated?'
        return $ERR_FATAL
    fi

    echo "https:$LOCATION"
    echo "$FILE_NAME"
}

# Probe a download URL.
# $1: cookie file (unused here)
# $2: nippyfile.com url
# $3: requested capability list
# stdout: 1 capability per line
nippyfile_probe() {
    local -r URL=$2
    local -r REQ_IN=$3
    local PAGE REQ_OUT FID FILE_NAME FILE_SIZE

    PAGE=$(curl -L "$URL") || return

    if ! match '<h1>Download</h1>' "$PAGE"; then
        return $ERR_LINK_DEAD
    fi

    REQ_OUT=c

#    if [[ $REQ_IN = *f* ]]; then
#        FILE_NAME=$(parse_tag '="Download[[:space:]]' a <<< "$PAGE") && \
#            echo "$FILE_NAME" && REQ_OUT="${REQ_OUT}f"
#    fi
#
#    if [[ $REQ_IN = *i* ]]; then
#        FID=$(parse . '/\([[:alnum:]]*\)$' <<< "$URL") && \
#            echo "$FID" && REQ_OUT="${REQ_OUT}i"
#    fi
#
#    if [[ $REQ_IN = *s* ]]; then
#        FILE_SIZE=$(parse '[[:digit:]][[:space:]]downloads<' '^[^[:space:]]*[[:space:]]-[[:space:]]*\([^-]\+\)' <<< "$PAGE") && \
#        translate_size "$FILE_SIZE" && REQ_OUT="${REQ_OUT}s"
#    fi

    echo $REQ_OUT
}

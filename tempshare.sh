# Plowshare temp-share.com module
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

MODULE_TEMPSHARE_REGEXP_URL='https\?://temp-share\.com/'

MODULE_TEMPSHARE_DOWNLOAD_OPTIONS=""
MODULE_TEMPSHARE_DOWNLOAD_RESUME=yes
MODULE_TEMPSHARE_DOWNLOAD_FINAL_LINK_NEEDS_COOKIE=no
MODULE_TEMPSHARE_DOWNLOAD_FINAL_LINK_NEEDS_EXTRA=(--referer)
MODULE_TEMPSHARE_DOWNLOAD_SUCCESSIVE_INTERVAL=

MODULE_TEMPSHARE_PROBE_OPTIONS=""

# Output a tempshare file download URL
# $1: cookie file (unused here)
# $2: tempshare url
# stdout: real file download link
tempshare_download() {
    local URL PAGE FILE_URL FILE_NAME PUBKEY

    # Get a canonical URL for this file.
    URL=$(curl -I "$2" | grep_http_header_location_quiet) || return
    [ -n "$URL" ] || URL=$2
    readonly URL

    PAGE=$(curl "$URL" | break_html_lines) || return

    if ! match 'data-url' "$PAGE"; then
        return $ERR_LINK_DEAD
    fi

    FILE_URL=$(parse_attr 'data-url' <<< "$PAGE") || return
    FILE_NAME=$(parse_tag 'h1' <<< "$PAGE") || return
    PUBKEY=$(parse "id='publickey'" "value='\([^']\+\)" <<< "$PAGE") || return

    # Mandatory!
    MODULE_TEMPSHARE_DOWNLOAD_FINAL_LINK_NEEDS_EXTRA=(--referer "$URL")

    echo "$FILE_URL/$PUBKEY"
    echo "$FILE_NAME"
}

# Probe a download URL
# $1: cookie file (unused here)
# $2: tempshare url
# $3: requested capability list
# stdout: 1 capability per line
tempshare_probe() {
    local -r URL=$2
    local -r REQ_IN=$3
    local PAGE FILE_SIZE REQ_OUT

    PAGE=$(curl -L "$URL" | break_html_lines) || return

    if ! match 'data-url' "$PAGE"; then
        return $ERR_LINK_DEAD
    fi

    REQ_OUT=c

    if [[ $REQ_IN = *f* ]]; then
        parse_tag 'h1' <<< "$PAGE" && REQ_OUT="${REQ_OUT}f"
    fi

    if [[ $REQ_IN = *s* ]]; then
        FILE_SIZE=$(parse '<span>(.*)</span>' '(\([^)]\+\)' <<< "$PAGE") \
            && FILE_SIZE=$(replace 'B' 'iB' <<< $FILE_SIZE) \
            && translate_size "$FILE_SIZE" && REQ_OUT="${REQ_OUT}s"
    fi

    if [[ $REQ_IN = *i* ]]; then
        parse 'data-url' 'f/\(.\+\)/download' <<< "$PAGE" \
            && REQ_OUT="${REQ_OUT}i"
    fi

    echo $REQ_OUT
}

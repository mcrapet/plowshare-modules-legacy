# Plowshare espafiles.com module
# Copyright (c) 2016 dataoscar
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

MODULE_ESPAFILES_REGEXP_URL='https\?://\(www\.\)\?espafiles\.com/'

MODULE_ESPAFILES_DOWNLOAD_OPTIONS=""
MODULE_ESPAFILES_DOWNLOAD_RESUME=no
MODULE_ESPAFILES_DOWNLOAD_FINAL_LINK_NEEDS_COOKIE=unused
MODULE_ESPAFILES_DOWNLOAD_FINAL_LINK_NEEDS_EXTRA=()
MODULE_ESPAFILES_DOWNLOAD_SUCCESSIVE_INTERVAL=

MODULE_ESPAFILES_PROBE_OPTIONS=""

# Output a espafiles file download URL
# $1: cookie file (unused here)
# $2: url
# stdout: real file download link
espafiles_download() {
    local URL PAGE FILE_URL FILE_NAME FINAL_URL DL_LINE

    # Get a canonical URL for this file.
    URL=$(curl -I "$2" | grep_http_header_location_quiet) || return
    [ -n "$URL" ] || URL=$2
    readonly URL

    PAGE=$(curl "$URL" ) || return

    if ! match 'big_button' "$PAGE"; then
        return $ERR_LINK_DEAD
    fi

    FILE_NAME=$(parse '<span>Nombre:' 'span>\([^<]\+\)</li>' <<< "$PAGE") || return
    DL_LINE=$(parse 'big_button' '^\(.*\)$' <<< "$PAGE") || return
    FINAL_URL=$(parse_attr 'href' <<< "$DL_LINE") || return
    FILE_URL=$(curl --referer "$URL" -I "$FINAL_URL" | grep_http_header_location) || return

    # Mandatory!
    MODULE_ESPAFILES_DOWNLOAD_FINAL_LINK_NEEDS_EXTRA=(--referer "$URL")

    echo "$FILE_URL"
    echo "$FILE_NAME"
}

# Probe an espafiles download URL
# $1: cookie file (unused here)
# $2: url
# $3: requested capability list
# stdout: 1 capability per line
espafiles_probe() {
    local -r URL=$2
    local -r REQ_IN=$3
    local PAGE FILE_SIZE DL_LINE REQ_OUT

    PAGE=$(curl -L "$URL" ) || return

    if ! match 'big_button' "$PAGE"; then
        return $ERR_LINK_DEAD
    fi

    REQ_OUT=c

    if [[ $REQ_IN = *f* ]]; then
        parse '<span>Nombre:' 'span>\([^<]\+\)</li>' <<< "$PAGE" \
            && REQ_OUT="${REQ_OUT}f"
    fi

    if [[ $REQ_IN = *s* ]]; then
        FILE_SIZE=$(parse '<span>Size:' 'span>\([^<]\+\)</li>' <<< "$PAGE") \
            && translate_size "$FILE_SIZE" && REQ_OUT="${REQ_OUT}s"
    fi

    if [[ $REQ_IN = *i* ]]; then
        DL_LINE=$(parse 'big_button' '^\(.*\)$' <<< "$PAGE") \
            && parse . 'href=".*get\/\([^"]*\)' <<< "$DL_LINE" \
            && REQ_OUT="${REQ_OUT}i"
    fi

    echo $REQ_OUT
}

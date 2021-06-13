# Plowshare pixeldrain.com module
# Copyright (c) 2021 Eduardo Miguel Hernandez
# Copyright (c) 2012-2021 Plowshare team
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

MODULE_PIXELDRAIN_REGEXP_URL='https\?://\(www\.\)\?pixeldrain\.com/'

MODULE_PIXELDRAIN_DOWNLOAD_OPTIONS=""
MODULE_PIXELDRAIN_DOWNLOAD_RESUME=yes
MODULE_PIXELDRAIN_DOWNLOAD_FINAL_LINK_NEEDS_COOKIE=no
MODULE_PIXELDRAIN_DOWNLOAD_SUCCESSIVE_INTERVAL=


# Output a pixeldrain file download URL
# $2: pixeldrain url
# stdout: real file download link
pixeldrain_download() {
    # Pixeldrain hoster serve the files through a api
    # https://pixeldrain.com/api/file/<file_id>

    local -r URL=$2
    local PAGE FILE_URL FILENAME FILE_ID BASE_URL API_BASE_URL

    BASE_URL=$(basename_url $URL)
    API_BASE_URL="$BASE_URL/api/file/"

    PAGE=$(curl -L "$URL") || return

    # File does not exist on this server
    # File has expired and does not exist anymore on this server
    if match '404, File Not Found' "$PAGE"; then
        return $ERR_LINK_DEAD
    fi

    log_debug "File exists"

    FILENAME=$(parse_attr '=.og:title.' content <<< "$PAGE") || return

    FILE_ID=$(parse . 'https://pixeldrain.com/\w/\([[:alnum:]]\+\)' <<< "$URL") || return

    if [ -z "$FILE_ID" ]; then
        log_error 'Could not parse file ID.'
        return $ERR_FATAL
    fi

    log_debug "File/Folder ID: '$FILE_ID'"

    
    FILE_URL="$API_BASE_URL$FILE_ID"

    echo "$FILE_URL"
    echo "$FILENAME"
    return 0
}

# Probe a download URL
# $1: cookie file (unused here)
# $2: pixeldrain.com url
# $3: requested capability list
# stdout: 1 capability per line
pixeldrain_probe() {
    local -r URL=$2
    local -r REQ_IN=$3
    local -r BASE_URL=$(basename_url $URL)
    local -r API_URL="$BASE_URL/api/file/"
    local FILE_ID JSON RET REQ_OUT

    FILE_ID=$(parse . 'https://pixeldrain.com/\w/\([[:alnum:]]\+\)' <<< "$URL") || return

    if [ -z "$FILE_ID" ]; then
        log_error 'Could not parse file ID.'
        return $ERR_FATAL
    fi

    JSON=$(curl "${API_URL}/$FILE_ID/info") || return

    if ! match_json_true 'success' "$JSON"; then
        return $ERR_LINK_DEAD
    fi

    REQ_OUT=c

    if [[ $REQ_IN = *f* ]]; then
        parse_json_quiet 'name' <<< "$JSON" && REQ_OUT="${REQ_OUT}f"
    fi

    if [[ $REQ_IN = *s* ]]; then
        parse_json_quiet 'size' <<< "$JSON" && REQ_OUT="${REQ_OUT}s"
    fi

    echo $REQ_OUT
}
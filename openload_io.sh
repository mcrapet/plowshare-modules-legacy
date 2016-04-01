# Plowshare openload.io module
# Copyright (c) 2015 ljsdoug <sdoug@inbox.com>
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

MODULE_OPENLOAD_IO_REGEXP_URL='https\?://openload\.\(co\|io\)/'

MODULE_OPENLOAD_IO_DOWNLOAD_OPTIONS=""
MODULE_OPENLOAD_IO_DOWNLOAD_RESUME=yes
MODULE_OPENLOAD_IO_DOWNLOAD_FINAL_LINK_NEEDS_COOKIE=no
MODULE_OPENLOAD_IO_DOWNLOAD_SUCCESSIVE_INTERVAL=

MODULE_OPENLOAD_IO_PROBE_OPTIONS=""

# Output a openload_io file download URL
# $1: cookie file (unused here)
# $2: openload_io url
# stdout: real file download link
openload_io_download() {
    local -r URL=$2
    local PAGE WAIT FILE_URL FILE_NAME

    PAGE=$(curl -L "$URL") || return

    if match "<p class=\"lead\">We can't find the file you are looking for" "$PAGE"; then
        return $ERR_LINK_DEAD
    fi

    WAIT=$(parse_tag 'id="secondsleft"' span <<< "$PAGE") || return

    wait $(($WAIT)) seconds || return

    FILE_URL=$(parse_attr 'id="realdownload"' href <<< "$PAGE")
    FILE_NAME=$(parse_tag 'id="filename"' span <<< "$PAGE")

    echo "$FILE_URL"
    echo "$FILE_NAME"
}

# Probe a download URL
# $1: cookie file (unused here)
# $2: openload_io url
# $3: requested capability list
# stdout: 1 capability per line
openload_io_probe() {
    local -r URL=$2
    local -r REQ_IN=$3
    local PAGE REQ_OUT FILE_SIZE

    PAGE=$(curl -L "$URL") || return

    if match "<p class=\"lead\">We can't find the file you are looking for" "$PAGE"; then
        return $ERR_LINK_DEAD
    fi

    REQ_OUT=c

    if [[ $REQ_IN = *f* ]]; then
        parse_tag 'class="other-title-bold"' h3 <<< "$PAGE" && REQ_OUT="${REQ_OUT}f"
    fi

    if [[ $REQ_IN = *s* ]]; then
        FILE_SIZE=$(parse 'class="content-text"' 'size:\([^<]*\)' <<< "$PAGE") && \
            translate_size "$FILE_SIZE" && REQ_OUT="${REQ_OUT}s"
    fi

    echo $REQ_OUT
}

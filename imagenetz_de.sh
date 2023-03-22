# Plowshare imagenetz.de module
# Copyright (c) 2023 Plowshare team
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

MODULE_IMAGENETZ_DE_REGEXP_URL='https://www.imagenetz.de/[[:alnum:]]\+'

MODULE_IMAGENETZ_DE_DOWNLOAD_OPTIONS=""
MODULE_IMAGENETZ_DE_DOWNLOAD_RESUME=no
MODULE_IMAGENETZ_DE_DOWNLOAD_FINAL_LINK_NEEDS_COOKIE=yes
MODULE_IMAGENETZ_DE_DOWNLOAD_SUCCESSIVE_INTERVAL=

# Output a imagenetz.de file download URL
# $1: cookie file
# $2: imagenetz.de url
# stdout: real file download link
imagenetz_de_download() {
    local COOKIEFILE=$1
    local URL=$2
    local PAGE WAIT_TIME FILE_URL FILE_NAME
    local -r BASE_URL=$(basename_url "$URL")

    PAGE=$(curl -L -c "$COOKIEFILE" "$URL") || return

    # Get wait time
    # <span class='dwnin'>Download in <span id='dlCD'><span>5</span></span> Sekunden</span>
    WAIT_TIME=$(parse_quiet 'dlCD' 'dlCD.><span>\([[:digit:]]\+\)</span>' <<< "$PAGE")
    if [ -n "$WAIT_TIME" ]; then
        wait $((WAIT_TIME + 1)) || return
    fi

    FILE_URL=$(parse_attr 'btn-download' href <<< "$PAGE") || return
    FILE_NAME=$(parse_attr 'social-likes' 'data-title' <<< "$PAGE") || return

    echo "$BASE_URL/${FILE_URL#/}"
    echo "$FILE_NAME"
}

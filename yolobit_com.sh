# Plowshare yolobit.com module
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

MODULE_YOLOBIT_COM_REGEXP_URL='https://yolobit.com/v/[[:alnum:]]\+'

MODULE_YOLOBIT_COM_DOWNLOAD_OPTIONS=""
MODULE_YOLOBIT_COM_DOWNLOAD_RESUME=no
MODULE_YOLOBIT_COM_DOWNLOAD_FINAL_LINK_NEEDS_COOKIE=no
MODULE_YOLOBIT_COM_DOWNLOAD_SUCCESSIVE_INTERVAL=

# Output a yolobit.com file download URL
# $1: cookie file
# $2: yolobit.com url
# stdout: real file download link
yolobit_com_download() {
    local COOKIEFILE=$1
    local URL=$2
    local PAGE FILE_URL FILE_NAME FILE_REDIR
    local -r BASE_URL=$(basename_url "$URL")

    PAGE=$(curl -L -c "$COOKIEFILE" "$URL") || return

    FILE_URL=$(echo "$PAGE" | break_html_lines | parse_attr '>Download<' href) || return
    FILE_NAME=$(parse '<li>Name:' 'Name:[[:space:]]\+\([^<]\+\)<' <<< "$PAGE") || return

    FILE_REDIR=$(curl -i -b "$COOKIE_FILE" "https:$FILE_URL" | grep_http_header_location_quiet)

    echo "https:$FILE_REDIR"
    echo "$FILE_NAME"
}

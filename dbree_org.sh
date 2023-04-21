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

MODULE_DBREE_ORG_REGEXP_URL='https://dbree.org/v/[[:alnum:]]\+'

MODULE_DBREE_ORG_DOWNLOAD_OPTIONS=""
MODULE_DBREE_ORG_DOWNLOAD_RESUME=no
MODULE_DBREE_ORG_DOWNLOAD_FINAL_LINK_NEEDS_COOKIE=no
MODULE_DBREE_ORG_DOWNLOAD_SUCCESSIVE_INTERVAL=

#https://dbree.org/.well-known/ddos-guard/check?context=free_splash
#https://check.ddos-guard.net/check.js
#https://dbree.org/.well-known/ddos-guard/id/AHhwnrcNLiABTMiu
#https://check.ddos-guard.net/set/id/AHhwnrcNLiABTMiu
#https://dbree.org/.well-known/ddos-guard/mark/

# Output a dbree.org file download URL
# $1: cookie file
# $2: dbree.com url
# stdout: real file download link
dbree_org_download() {
    local COOKIEFILE=$1
    local URL=$2
    local PAGE FILE_URL FILE_NAME FILE_REDIR
    local -r BASE_URL=$(basename_url "$URL")

    PAGE=$(curl -L -c "$COOKIEFILE" "$URL") || return

    if match '<title>DDoS-Guard</title>' "$PAGE"; then
        local -r DDOS_GUARD_URL='https://check.ddos-guard.net'
        local P2 P3 DDOS_ID SET_URL

        log_debug "Fake ddos-guard"

        # Obfuscated javascript
        P2=$(curl -b "$COOKIEFILE" "$BASE_URL/.well-known/ddos-guard/check?context=free_splash") || return
        P3=$(curl -c "$COOKIEFILE" -b "$COOKIEFILE" "$DDOS_GUARD_URL/check.js" | sed -e 's/;/&\n/g') || return

        # (function(){new Image().src = '/.well-known/ddos-guard/id/qJSVbxHkYgBWc84j'; new Image().src='https://check.ddos-guard.net/set/id/
        DDOS_ID=$(parse_all . "src[[:space:]]*=[[:space:]]*'\([^']\+\)';" <<< "$P3" | first_line) || return
        SET_URL=$(parse_all . "src[[:space:]]*=[[:space:]]*'\([^']\+\)';" <<< "$P3" | last_line) || return

        # Dummy 1x1 png
        curl -c "$COOKIEFILE" -b "$COOKIEFILE" "$BASE_URL$DDOS_ID" >/dev/null
        curl -c "$COOKIEFILE" -b "$COOKIEFILE" "$SET_URL"          >/dev/null

        P4=$(curl -c "$COOKIEFILE" -b "$COOKIEFILE" "$BASE_URL/ddos-guard/mark/") || return

        PAGE=$(curl -L -b "$COOKIEFILE" "$URL") || return
    fi

    echo "$PAGE" | break_html_lines >/tmp/a

    FILE_URL=$(echo "$PAGE" | break_html_lines | parse_attr '>Download<' href) || return
    FILE_NAME=$(parse '<li>Name:' 'Name:[[:space:]]\+\([^<]\+\)<' <<< "$PAGE") || return

    FILE_REDIR=$(curl -i -b "$COOKIE_FILE" "https:$FILE_URL" | grep_http_header_location_quiet)

    echo "https:$FILE_REDIR"
    echo "$FILE_NAME"
}

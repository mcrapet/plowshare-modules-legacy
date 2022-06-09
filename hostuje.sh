# Plowshare hostuje.net module
# Copyright (c) 2022 Plowshare team
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

MODULE_HOSTUJE_REGEXP_URL='http://hostuje.net/file.php?id=[[:xdigit:]]\+'

MODULE_HOSTUJE_DOWNLOAD_OPTIONS=""
MODULE_HOSTUJE_DOWNLOAD_RESUME=no
MODULE_HOSTUJE_DOWNLOAD_FINAL_LINK_NEEDS_COOKIE=unused
MODULE_HOSTUJE_DOWNLOAD_SUCCESSIVE_INTERVAL=

# Output a hostuje.net file download URL
# $1: cookie file
# $2: hostuje.net url
# stdout: real file download link
hostuje_download() {
    local COOKIEFILE=$1
    local URL=$2
    local PAGE JSON LINKS HEADERS DIRECT FILENAME U1 U2

    PAGE=$(curl -L -c "$COOKIEFILE" "$URL") || return

    if match '404 Nie odnaleziono pliku' "$PAGE"; then
        return $ERR_LINK_DEAD
    fi

    FORM_HTML=$(grep_form_by_order "$PAGE" 1 | break_html_lines_alt) || return
    FORM_ACTION=$(parse_form_action <<< "$FORM_HTML") || return
    FORM_REG=$(parse_form_input_by_name 'REG' <<< "$FORM_HTML") || return
    FORM_OK=$(parse_form_input_by_name 'OK' <<< "$FORM_HTML") || return
    FORM_HASZ=$(parse_form_input_by_name 'hasz' <<< "$FORM_HTML") || return
    FORM_ID=$(parse_form_input_by_name 'id' <<< "$FORM_HTML") || return
    FORM_NAME=$(parse_form_input_by_name 'name' <<< "$FORM_HTML") || return
    FORM_MIME=$(parse_form_input_by_name 'mime' <<< "$FORM_HTML") || return
    FORM_K=$(parse_form_input_by_name 'k' <<< "$FORM_HTML") || return
    FORM_FILEA=$(parse_form_input_by_id 'filea' <<< "$FORM_HTML") || return

    # Before calling form post we need to perform 2 HTTP GET
    # to avoid "expired session" error

    PHP=$(parse '\.php"></' 'src="\([[:xdigit:]]\+[^"]\+\)' <<< "$PAGE") || return
    JS_CODE=$(curl -b "$COOKIEFILE" --referer "$URL" \
        "http://hostuje.net/$PHP") || return

    PHP=$(parse . "('\(I.*\)'" <<< "$JS_CODE") || return
    PHP2=${PHP%\?*}
    ARG=${PHP#*=}

    RES=$(curl --get -b "$COOKIEFILE" --referer "$URL" \
        -d "i=$ARG" \
        "http://hostuje.net/$PHP2") || return

    # Post urlencoded form
    PAGE=$(curl -i -b "$COOKIE_FILE" --referer "$URL" \
        --user-agent 'Mozilla/5.0 (X11; Linux x86_64; rv:66.0) Gecko/20100101 Firefox/66.0' \
        -H 'Upgrade-Insecure-Requests: 1' \
        -d "REG=$FORM_REG" \
        -d "OK=$FORM_OK" \
        -d "hasz=$FORM_HASZ" \
        -d "id=$FORM_ID" \
        -d "name=$FORM_NAME" \
        --data-urlencode "mime=$FORM_MIME" \
        -d "k=$FORM_K" \
        -d "filea=$FORM_FILEA" \
        "http://hostuje.net/$FORM_ACTION") || return

    LOCATION=$(echo "$PAGE" | grep_http_header_location) || return

    echo "$LOCATION"
    echo "$FORM_NAME"
}

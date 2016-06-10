# Plowshare hexupload.com module
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

MODULE_HEXUPLOAD_REGEXP_URL='https\?://\(www\.\)\?hexupload\.com/'

MODULE_HEXUPLOAD_DOWNLOAD_OPTIONS=""
MODULE_HEXUPLOAD_DOWNLOAD_RESUME=yes
MODULE_HEXUPLOAD_DOWNLOAD_FINAL_LINK_NEEDS_COOKIE=no
MODULE_HEXUPLOAD_DOWNLOAD_SUCCESSIVE_INTERVAL=

MODULE_HEXUPLOAD_PROBE_OPTIONS=""

# Output a hexupload file download URL
# $1: cookie file
# $2: hexupload url
# stdout: real file download link
hexupload_download() {
    local -r COOKIE_FILE=$1
    local URL PAGE
    local FORM_HTML FORM_OP FORM_USR FORM_ID FORM_FNAME
    local FORM_REF FORM_METHOD_F FORM_RAND FORM_METHOD_P FORM_DD

    # Get a canonical URL for this file.
    URL=$(curl -I "$2" | grep_http_header_location_quiet) || return
    [ -n "$URL" ] || URL=$2
    readonly URL

    PAGE=$(curl -b "$COOKIE_FILE" -c "$COOKIE_FILE" "$URL") || return

    if match ">File Not Found<" "$PAGE"; then
        return $ERR_LINK_DEAD
    fi

    FORM_HTML=$(grep_form_by_order "$PAGE" 4) || return
    FORM_OP=$(parse_form_input_by_name 'op' <<< "$FORM_HTML") || return
    FORM_USR=$(parse_form_input_by_name_quiet 'usr_login' <<< "$FORM_HTML")
    FORM_ID=$(parse_form_input_by_name 'id' <<< "$FORM_HTML") || return
    FORM_FNAME=$(parse_form_input_by_name 'fname' <<< "$FORM_HTML") || return
    FORM_REF=$(parse_form_input_by_name_quiet 'referer' <<< "$FORM_HTML")
    FORM_METHOD_F=$(parse_form_input_by_name_quiet 'method_free' <<< "$FORM_HTML")

    PAGE=$(curl -b "$COOKIE_FILE" \
        -d "op=$FORM_OP" \
        -d "usr_login=$FORM_USR" \
        -d "id=$FORM_ID" \
        -d "fname=$FORM_FNAME" \
        -d "referer=$FORM_REF" \
        -d "method_free=$FORM_METHOD_F" \
        "$URL") || return

    FORM_HTML=$(grep_form_by_name "$PAGE" 'F1') || return
    FORM_OP=$(parse_form_input_by_name 'op' <<< "$FORM_HTML") || return
    FORM_ID=$(parse_form_input_by_name 'id' <<< "$FORM_HTML") || return
    FORM_RAND=$(parse_form_input_by_name 'rand' <<< "$FORM_HTML") || return
    FORM_REF=$(parse_form_input_by_name_quiet 'referer' <<< "$FORM_HTML")
    FORM_METHOD_F=$(parse_form_input_by_name_quiet 'method_free' <<< "$FORM_HTML")
    FORM_METHOD_P=$(parse_form_input_by_name_quiet 'method_premium' <<< "$FORM_HTML")
    FORM_DD=$(parse_form_input_by_name_quiet 'down_direct' <<< "$FORM_HTML")

    PAGE=$(curl -b "$COOKIE_FILE" \
        -d "op=$FORM_OP" \
        -d "id=$FORM_ID" \
        -d "rand=$FORM_RAND" \
        -d "referer=$FORM_REF" \
        -d "method_free=$FORM_METHOD_F" \
        -d "method_premium=$FORM_METHOD_P" \
        -d "down_direct=$FORM_DD" \
        "$URL") || return

    parse_attr 'dl-last\.png' 'href' <<< "$PAGE" || return
}

# Probe a download URL
# $1: cookie file (unused here)
# $2: hexupload url
# $3: requested capability list
# stdout: 1 capability per line
hexupload_probe() {
    local -r URL=$2
    local -r REQ_IN=$3
    local PAGE FILE_SIZE REQ_OUT

    PAGE=$(curl -L "$URL") || return

    if match ">File Not Found<" "$PAGE"; then
        return $ERR_LINK_DEAD
    fi

    REQ_OUT=c

    if [[ $REQ_IN = *f* ]]; then
        parse 'File:' 'File:[^>]*>\([^<]*\)<' <<< "$PAGE" && REQ_OUT="${REQ_OUT}f"
    fi

    if [[ $REQ_IN = *s* ]]; then
        FILE_SIZE=$(parse 'File:' '\[.*>\([[:digit:]].*B\)<.*\]' <<< "$PAGE") \
            && FILE_SIZE=$(replace 'B' 'iB' <<< $FILE_SIZE) \
            && translate_size "$FILE_SIZE" && REQ_OUT="${REQ_OUT}s"
    fi

    if [[ $REQ_IN = *i* ]]; then
        parse . 'com/\([[:alnum:]]\+\)' <<< "$URL" && REQ_OUT="${REQ_OUT}i"
    fi

    echo $REQ_OUT
}

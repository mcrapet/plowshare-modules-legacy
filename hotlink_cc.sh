# Plowshare hotlink.cc module
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

MODULE_HOTLINK_CC_REGEXP_URL='https\?://\(www\.\)\?hotlink\.cc/'

MODULE_HOTLINK_CC_DOWNLOAD_OPTIONS=""
MODULE_HOTLINK_CC_DOWNLOAD_RESUME=yes
MODULE_HOTLINK_CC_DOWNLOAD_FINAL_LINK_NEEDS_COOKIE=no
MODULE_HOTLINK_CC_DOWNLOAD_SUCCESSIVE_INTERVAL=

MODULE_HOTLINK_CC_PROBE_OPTIONS=""

# Output a hotlink.cc file download URL
# $1: cookie file
# $2: hotlink.cc url
# stdout: real file download link
hotlink_cc_download() {
    local -r COOKIE_FILE=$1
    local URL=$2
    local PAGE WAIT_TIME FORM_HTML FORM_OP FORM_ID FORM_RAND FORM_REFERER FORM_METHOD_F FORM_METHOD_P
    local CAPTCHA CODE DIGIT XCOORD LINE ERR

    PAGE=$(curl -c "$COOKIE_FILE" -b 'lang=english' "$URL") || return

    # <div class="err textq"><p style="font-size:20px;">You have to wait ... till next download<br>
    if match '>You have to wait .* till next download<' "$PAGE"; then
        local HOURS MINS SECS
        HOURS=$(parse_quiet '>You have to wait' \
            '[^[:digit:]]\([[:digit:]]\+\) hours\?' <<< "$PAGE")
        MINS=$(parse_quiet  '>You have to wait' \
            '[^[:digit:]]\([[:digit:]]\+\) minutes\?' <<< "$PAGE")
        SECS=$(parse_quiet  '>You have to wait' \
            '[^[:digit:]]\([[:digit:]]\+\) seconds\?' <<< "$PAGE")

        log_error 'Download limit reached.'
        # Note: Always use decimal base instead of octal if there are leading zeros.
        echo $(( (( 10#$HOURS * 60 ) + 10#$MINS ) * 60 + 10#$SECS ))
        return $ERR_LINK_TEMP_UNAVAILABLE

    elif match '>File Not Found</' "$PAGE"; then
        return $ERR_LINK_DEAD
    fi

    # <span id="countdown" style="display:none;font-size:25px">Wait: <span class="seconds yellow"><b>60</b>
    WAIT_TIME=$(parse_tag 'id="countdown"' 'b' <<< "$PAGE")
    wait $((WAIT_TIME)) || return

    FORM_HTML=$(grep_form_by_name "$PAGE" 'F1') || return
    FORM_OP=$(parse_form_input_by_name 'op' <<< "$FORM_HTML") || return
    FORM_ID=$(parse_form_input_by_name 'id' <<< "$FORM_HTML") || return
    FORM_RAND=$(parse_form_input_by_name 'rand' <<< "$FORM_HTML") || return
    FORM_REFERER=$(parse_form_input_by_name_quiet 'referer' <<< "$FORM_HTML")
    FORM_METHOD_F=$(parse_form_input_by_name_quiet 'method_free' <<< "$FORM_HTML")
    FORM_METHOD_P=$(parse_form_input_by_name_quiet 'method_premium' <<< "$FORM_HTML")

    # Funny captcha, this is text (4 digits)!
    CODE=0
    CAPTCHA=$(echo "$FORM_HTML" | parse_tag 'direction:ltr' div | \
            replace_all '/span>' '/span>'$'\n') || return
    while read LINE; do
        DIGIT=$(parse 'padding-' '>&#\([[:digit:]]\+\);<' <<< "$LINE") || return
        XCOORD=$(parse 'padding-' '-left:\([[:digit:]]\+\)p' <<< "$LINE") || return

        # Depending x, guess digit rank
        if (( XCOORD < 15 )); then
            (( CODE = CODE + 1000 * (DIGIT-48) ))
        elif (( XCOORD < 30 )); then
            (( CODE = CODE + 100 * (DIGIT-48) ))
        elif (( XCOORD < 50 )); then
            (( CODE = CODE + 10 * (DIGIT-48) ))
        else
            (( CODE = CODE + (DIGIT-48) ))
        fi
    done <<< "$CAPTCHA"

    PAGE=$(curl -b "$COOKIE_FILE" -b 'lang=english' --referer "$URL" \
        -d "op=$FORM_OP" \
        -d "id=$FORM_ID" \
        -d "rand=$FORM_RAND" \
        -d "referer=$FORM_REFERER" \
        -d "method_free=$FORM_METHOD_F" \
        -d "method_premium=$FORM_METHOD_P" \
        -d "code=$CODE" \
        "$URL") || return

    # Get error message, if any
    # <div class="err textq"><p style="font-size:20px;"> ... </p></div><br>
    ERR=$(parse_tag_quiet '<div class="err ' p <<< "$PAGE")
    if [ -n "$ERR" ]; then
        if match 'Skipped countdown\|Expired download session\|Wrong captcha' "$ERR"; then
            log_error "Remote error: $ERR"
            return $ERR_LINK_TEMP_UNAVAILABLE
        else
            log_error "Remote error: $ERR"
            return $ERR_FATAL
        fi
    fi

    # <h2>File Download Link Generated</h2>
    # This direct link will be available for your IP next 8 hours<br><br>
    parse_attr 'hotlink.cc:' href <<< "$PAGE"
    parse_tag '>Filename:[[:space:]]*<' b <<< "$PAGE"
}

# Probe a download URL
# $1: cookie file (unused here)
# $2: hotlink.cc url
# $3: requested capability list
# stdout: 1 capability per line
hotlink_cc_probe() {
    local -r URL=$2
    local -r REQ_IN=$3
    local PAGE FILE_NAME REQ_OUT

    PAGE=$(curl "$URL") || return

    if match '>File Not Found</' "$PAGE"; then
        return $ERR_LINK_DEAD
    fi

    REQ_OUT=c

    # FIXME: Filenames with more than 55 characters are truncated
    if [[ $REQ_IN = *f* ]]; then
        FILE_NAME=$(parse 'class="dfilename"' '>\([^<]\+\)<' <<< "$PAGE") &&
            echo "${FILE_NAME/%&#133;/.truncatedname}" && REQ_OUT="${REQ_OUT}f"
    fi

    if [[ $REQ_IN = *i* ]]; then
        parse_form_input_by_name 'id' <<< "$PAGE" && REQ_OUT="${REQ_OUT}i"
    fi

    echo $REQ_OUT
}

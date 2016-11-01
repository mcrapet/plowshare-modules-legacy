# Plowshare filecrypt.cc module
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

MODULE_FILECRYPT_CC_REGEXP_URL='https\?://filecrypt\.cc/'

MODULE_FILECRYPT_CC_LIST_OPTIONS=""
MODULE_FILECRYPT_CC_LIST_HAS_SUBFOLDERS=no

# ---
# Note: plowlist does not have captcha command line switches.
# As this list module function uses captcha functions, it is not supported.
# ---

# List links from filecrypt_cc link
# $1: filecrypt_cc url
# $2: recurse subfolders (ignored here)
# stdout: list of links
filecrypt_cc_list() {
    local -r URL=$1
    local CV COOKIE_FILE PAGE LINKS NAMES ENC_URL SESS REDIR_URL FILE_NAME
    local -r BASE_URL='http://filecrypt.cc'

# TEMP HACK!!!
CACHE=shared

    # Set-Cookie: PHPSESSID=
    COOKIE_FILE=$(create_tempfile) || return

    if CV=$(storage_get 'cookie_file'); then
        echo "$CV" >"$COOKIE_FILE"

        # Check for expired session
        PAGE=$(curl -b "$COOKIE_FILE" "$URL") || return

        if match '>Security prompt<' "$PAGE"; then
            log_error 'Expired session, delete cache entry'
            storage_set 'cookie_file'
            return $ERR_EXPIRED_SESSION
        fi
    else
        PAGE=$(curl -c "$COOKIE_FILE" "$URL") || return

        if match 'api\.solvemedia\.com' "$PAGE"; then
            local RESP CHALL ID WAIT_TIME
            local -r PUBKEY='B8Aouhctcf.W59906aUSJQb1Qqjuz.-e'

            RESP=$(solvemedia_captcha_process $PUBKEY) || return
            { read CHALL; read ID; } <<< "$RESP"

            PAGE=$(curl -b "$COOKIE_FILE" \
                -d "adcopy_response=$RESP" \
                -d "adcopy_challenge=$CHALL" "$URL") || return

            if match '>Security prompt<' "$PAGE"; then
                captcha_nack $ID
                return $ERR_CAPTCHA
            else
               captcha_ack $CAPTCHA_ID
               log_debug 'Correct captcha'
            fi

            storage_set 'cookie_file' "$(cat "$COOKIE_FILE")"
            SESS=$(parse_cookie 'PHPSESSID' < "$COOKIE_FILE")
            log_debug "session (new): '$SESS'"

        elif match '/captcha/captcha\.php?namespace=container' "$PAGE"; then
            local WI WORD ID CAPTCHA_IMG

            CAPTCHA_IMG=$(create_tempfile '.jpg') || return
            # new Date();
            curl --get -b "$COOKIE_FILE" -o "$CAPTCHA_IMG" \
                --referer "$URL" \
                -d 'namespace=container' \
                -d "c=$(LANG=C date +'%a %b %d %Y %T GMT%z (CEST)')" \
                "$BASE_URL/captcha/captcha.php" || return

            WI=$(captcha_process "$CAPTCHA_IMG") || return
            { read WORD; read ID; } <<<"$WI"
            rm -f "$CAPTCHA_IMG"

            PAGE=$(curl -b "$COOKIE_FILE" \
                -d "recaptcha_response_field=$WORD" "$URL") || return

            if match '>Security prompt<' "$PAGE"; then
                captcha_nack $ID
                return $ERR_CAPTCHA
            else
               captcha_ack $CAPTCHA_ID
               log_debug 'Correct captcha'
            fi

            storage_set 'cookie_file' "$(cat "$COOKIE_FILE")"
            SESS=$(parse_cookie 'PHPSESSID' < "$COOKIE_FILE")
            log_debug "session (new): '$SESS'"

        else
            if match '/captcha/circle.php' "$PAGE"; then
                # FIXME: try blindly: curl -d "button.x=256" -d "button.y=145" "$URL"
                log_error "circle captcha not handled"
            elif match '/recaptcha/' "$PAGE"; then
                log_error "advanced recaptcha not handled"
            fi

            rm -f "$COOKIE_FILE"
            return $ERR_CAPTCHA
        fi
    fi

    # Don't take the first two links
    LINKS=$(break_html_lines <<< "$PAGE" | \
        parse_all 'openLink(' "k('\([^']\+\)" | delete_first_line 2) || return
    # Note: assume first two openLink occurrences does not match
    NAMES=$(break_html_lines <<< "$PAGE" | \
        parse_all 'openLink(' 'title="\([^"]\+\)' -4 ) || return

    while read -r -u 3 ENC_URL && read -r -u 4 FILE_NAME; do
        PAGE=$(curl -b "$COOKIE_FILE" "$BASE_URL/Link/$ENC_URL.html") || break
        if ! match '<iframe' "$PAGE"; then
            log_error 'Unexpected content. Session timeout or site updated?'
            #log_error "[$PAGE]"
            #storage_set 'cookie_file'
            return $ERR_EXPIRED_SESSION
        fi
        REDIR_URL=$(parse_attr '<iframe' src <<< "$PAGE") || break
        curl -i -b "$COOKIE_FILE" "$REDIR_URL" | grep_http_header_location || break
        echo "$FILE_NAME"
    done 3< <(echo "$LINKS") 4< <(echo "$NAMES")

    rm -f "$COOKIE_FILE"
    return 0
}

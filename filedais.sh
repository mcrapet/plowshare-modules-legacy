# Plowshare filedais.com/anafile.com module
# Copyright (c) 2013 Plowshare team
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

MODULE_FILEDAIS_REGEXP_URL='http://\(www\.\)\?\(filedais\|anafile\)\.com/.\+.html\?'

# Output a filedais/anafile.com file download URL
# $1: cookie file
# $2: filedais/anafile.com url
# stdout: real file download link
filedais_download() {
    local -r COOKIE_FILE=$1
    local -r URL=$2
    local -r BASE_URL=$(basename_url "$URL")
    local PAGE LOCATION WAIT_TIME FILE_URL

    PAGE=$(curl -L -i -c "$COOKIE_FILE" -b "$COOKIE_FILE" "$URL") || return
    if match '<h1>Software error:</h1>'; then
	return $ERR_LINK_TEMP_UNAVAILABLE
    fi
    if match '<b>File Not Found</b>' "$PAGE"; then
	return $ERR_LINK_DEAD
    fi

    LOCATION=$(grep_http_header_location_quiet <<< "$PAGE")
    if [[ "$LOCATION" = http* ]]; then
	PHP_URL="$LOCATION"
    else
	PHP_URL=${BASE_URL}$(grep_http_header_location_quiet <<< "$PAGE")
    fi

    FORM_HTML=$(grep_form_by_order "$PAGE" 1) || return
    FILE_ID=$(echo "$FORM_HTML" | parse_form_input_by_name 'id')
    FILE_NAME=$(echo "$FORM_HTML" | parse_form_input_by_name 'fname')
    FORM_METHOD=$(echo "$FORM_HTML" | parse_form_input_by_name 'method_free')

    PAGE=$(curl -i -c "$COOKIE_FILE" -b "$COOKIE_FILE" -d"op=download1" -d"id=$FILE_ID" -d"fname=$FILE_NAME" -d"method_free=$FORM_METHOD" $PHP_URL)

    DANGER_DIV=$(parse_tag_quiet 'class="alert alert-danger"' 'div' <<<"$PAGE")
    if [[ -n "$DANGER_DIV" ]]; then
	if match 'You have to wait' "$DANGER_DIV"; then
	    WAIT_TIME=$(parse_quiet '.' ' ([0-9]+) seconds' <<<"$DANGER_DIV")
	    if [[ -n "$WAIT_TIME" ]]; then
		echo $WAIT_TIME
	    fi
	    return $ERR_LINK_TEMP_UNAVAILABLE
	else
	    log_debug "unexpected alert-danger: $DANGER_DIV"
	fi
    fi

    FORM_HTML=$(grep_form_by_order "$PAGE" 1) || return
    RAND=$(echo "$FORM_HTML" | parse_form_input_by_name 'rand') || return

    WAIT_TIME=$(parse_tag '<span id="countdown_str">Wait' 'span' <<<"$PAGE") || return
    wait $WAIT_TIME || return

    local PUBKEY WCI CHALLENGE WORD ID
    CHALLENGE_URL=$(parse_attr 'google\.com\/recaptcha\/api\/challenge?k=' 'src' <<<"$PAGE")
    PUBKEY=$(parse '.' '?k=\([^&]\+\)' <<<"$CHALLENGE_URL" )
    WCI=$(recaptcha_process $PUBKEY) || return
    { read WORD; read CHALLENGE; read ID; } <<<"$WCI"
    PAGE=$(curl -i -c "$COOKIE_FILE" -b "$COOKIE_FILE" -d"op=download2" -d"id=$FILE_ID" -d "referer=$PHP_URL" \
		-d"recaptcha_challenge_field=$CHALLENGE" -d"recaptcha_response_field=$WORD" -d"down_script=1" \
		-d"rand=$RAND" -d"method_free=$FORM_METHOD" $PHP_URL)
    if match '>Wrong captcha</div>' "$PAGE"; then
	captcha_nack "$ID"
	return $ERR_CAPTCHA
    fi
    captcha_ack "$ID"
    echo $(parse_attr 'id="download1"' 'href' <<<"$PAGE")
    return 0
}

# # Probe a download URL
# # $1: cookie file
# # $2: filedais.com/anafile.com url
# # $3: requested capability list
# # stdout: 1 capability per line
filedais_probe() {
    local -r COOKIE_FILE=$1
    local -r URL=$2
    local -r REQ_IN=$3
    local PAGE LOCATION FILE_SIZE REQ_OUT

    PAGE=$(curl -L -i -c "$COOKIE_FILE" -b "$COOKIE_FILE" "$URL") || return
    
    if matchi '>File Not Found<' "$PAGE"; then
	echo 'c'
	return $ERR_LINK_DEAD
    fi
    # TODO: use op=checkfiles if we need size
    FORM_HTML=$(grep_form_by_order "$PAGE" 1)
    if [[ -z "$FORM_HTML" ]]; then
	return $ERR_FATAL
    fi

    echo "$FORM_HTML" | parse_form_input_by_name 'id'
    echo "$FORM_HTML" | parse_form_input_by_name 'fname'
    echo 'if'
    return 0
}

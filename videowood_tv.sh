# Plowshare videowood.tv module
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

MODULE_VIDEOWOOD_TV_REGEXP_URL='https\?://\(www\.\)\?videowood\.tv/'

MODULE_VIDEOWOOD_TV_UPLOAD_OPTIONS="
AUTH,a,auth,a=USER:PASSWORD,User account"
MODULE_VIDEOWOOD_TV_UPLOAD_REMOTE_SUPPORT=no

# Static function. Proceed with login
# $1: authentication
# $2: cookie file
# $3: base URL
# stdout: account type ("free") on success or 'expired' to renew session.
videowood_tv_login() {
    local -r AUTH=$1
    local -r COOKIE_FILE=$2
    local -r BASE_URL=$3
    local CV LOCATION SESS MSG PAGE CSRF_TOKEN LOGIN_DATA NAME

    if CV=$(storage_get 'cookie_file'); then
        echo "$CV" >"$COOKIE_FILE"

        # Check for expired session.
        LOCATION=$(curl -i -b "$COOKIE_FILE" "$BASE_URL/my-videos" \
            | grep_http_header_location_quiet) || return

        if match "$BASE_URL/login" "$LOCATION"; then
            log_error 'Expired session, delete cache entry'
            storage_set 'cookie_file'
            echo 'expired'
            return 0
        fi

        SESS=$(parse_cookie 'videowood_sess' < "$COOKIE_FILE") || return
        log_debug "session (cached): '$SESS'"
        MSG='reused login for'
    else
        PAGE=$(curl -c "$COOKIE_FILE" "$BASE_URL/login") || return
        CSRF_TOKEN=$(parse_attr 'name="csrf_token"' 'content' <<< "$PAGE") || return

        LOGIN_DATA="_token=$CSRF_TOKEN&username=\$USER&password=\$PASSWORD"

        LOCATION=$(post_login "$AUTH" "$COOKIE_FILE" "$LOGIN_DATA" "$BASE_URL/login" \
            -i -b "$COOKIE_FILE" | grep_http_header_location_quiet) || return

        # If successful, then we should redirected to my-videos.
        if ! match "$BASE_URL/my-videos" "$LOCATION"; then
            return $ERR_LOGIN_FAILED
        fi

        storage_set 'cookie_file' "$(cat "$COOKIE_FILE")"

        SESS=$(parse_cookie 'videowood_sess' < "$COOKIE_FILE") || return
        log_debug "session (new): '$SESS'"
        MSG='logged in as'
    fi

    PAGE=$(curl -b "$COOKIE_FILE" "$BASE_URL/my-videos") || return
    NAME=$(parse_quiet 'alt="User"' '^\(.*\)$' 2 <<< "$PAGE")

    log_debug "Successfully $MSG 'free' member '$NAME'"
    echo 'free'
}

# Upload a file to videowood.tv
# $1: cookie file
# $2: input file (with full path)
# $3: remote filename
# stdout: download link
videowood_tv_upload() {
    local -r COOKIE_FILE=$1
    local -r FILE=$2
    local -r DESTFILE=$3
    local -r BASE_URL='http://videowood.tv'
    local -r UPLOAD_URL='http://upl.videowood.tv'

    local SIZE ACCOUNT PAGE UPLOAD_ID JSON STATUS

    # Check for allowed file extensions
    if [ "${DESTFILE##*.}" = "$DESTFILE" ]; then
        log_error 'Filename has no extension. It is not allowed by hoster, you must specify video file.'
        return $ERR_BAD_COMMAND_LINE
    elif ! match '\.\(avi\|rmvb\|mkv\|flv\|mp4\|wmv\|mpeg\|mpg\|mov\|srt\)$' "$DESTFILE"; then
        log_error '*** File extension is checked by hoster. There is a restricted "allowed list", see hoster.'
        log_debug '*** Allowed list (part): avi rmvb mkv flv mp4 wmv mpeg mpg mov srt.'
        return $ERR_BAD_COMMAND_LINE
    fi

    # Check for allowed file size
    local -r MAX_SIZE=5368709120 # 5GiB
    SIZE=$(get_filesize "$FILE")
    if [ $SIZE -gt $MAX_SIZE ]; then
        log_debug "File is bigger than $MAX_SIZE"
        return $ERR_SIZE_LIMIT_EXCEEDED
    fi

    if [ -n "$AUTH" ]; then
        ACCOUNT=$(videowood_tv_login "$AUTH" "$COOKIE_FILE" "$BASE_URL") || return
        # Note: If account session is expired then renew it.
        [ "$ACCOUNT" = 'expired' ] && echo 1 && return $ERR_LINK_TEMP_UNAVAILABLE
    fi

    PAGE=$(curl -b "$COOKIE_FILE" "$BASE_URL") || return
    UPLOAD_ID=$(parse "'upload_id':" "'upload_id':.*'\([^']*\)'" <<< "$PAGE") || return

    # Note: The website does an OPTIONS request to $UPLOAD_URL first,
    #       but without it uploading also works.
    JSON=$(curl_with_log \
        -F "name=$DESTFILE" \
        -F "upload_id=$UPLOAD_ID" \
        -F "file=@$FILE;filename=$DESTFILE" \
        "$UPLOAD_URL") || return

    STATUS=$(parse_json 'OK' <<< "$JSON") || return

    if [ "$STATUS" != '1' ]; then
        log_error "Unexpected status: $STATUS"
        return $ERR_FATAL
    fi

    JSON=$(curl "$BASE_URL/upload-urls/$UPLOAD_ID?format=json&names=false") || return
    parse_json 'url' <<< "$JSON" || return
}

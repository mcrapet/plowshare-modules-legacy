# Plowshare go4up.com module
# Copyright (c) 2012-2016 Plowshare team
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

MODULE_GO4UP_REGEXP_URL='https\?://\(www\.\)\?go4up\.com'

MODULE_GO4UP_UPLOAD_OPTIONS="
AUTH_FREE,b,auth-free,a=EMAIL:PASSWORD,Free account
INCLUDE,,include,l=LIST,Provide list of host names (comma separated)
COUNT,,count,n=COUNT,Take COUNT mirrors (hosters) from the available list. Default is 5.
API,,api,,Use public API (recommended)"
MODULE_GO4UP_UPLOAD_REMOTE_SUPPORT=yes

MODULE_GO4UP_DELETE_OPTIONS="
AUTH_FREE,b,auth-free,a=EMAIL:PASSWORD,Free account (mandatory)"

MODULE_GO4UP_LIST_OPTIONS="
PARTIAL_LINKS,,partial,,Don't wait for all available links. Report thoses currently available"
MODULE_GO4UP_LIST_HAS_SUBFOLDERS=no

# Switch language to english
# $1: cookie file
# $2: base URL
go4up_switch_lang() {
    curl "$2/home/lang/en" -c "$1" > /dev/null || return
}

# Static function. Proceed with login
# $1: authentication
# $2: cookie file
# $3: base URL
go4up_login() {
    local AUTH_FREE=$1
    local COOKIE_FILE=$2
    local BASE_URL=$3
    local CV PAGE MSG LOGIN_DATA JSON STATUS NAME

    if CV=$(storage_get 'cookie_file'); then
        echo "$CV" >"$COOKIE_FILE"

        # Check for expired session.
        PAGE=$(curl -b "$COOKIE_FILE" "$BASE_URL/account") || return
        if ! match 'id="oldEmail"' "$PAGE"; then
            storage_set 'cookie_file'
            return $ERR_EXPIRED_SESSION
        fi

        log_debug 'session (cached)'
        MSG='reused login for'
    else
        LOGIN_DATA='email=$USER&password=$PASSWORD&remember-me=remember-me'
        JSON=$(post_login "$AUTH_FREE" "$COOKIE_FILE" "$LOGIN_DATA" \
            "$BASE_URL/login/process" -b "$COOKIE_FILE") || return

        # If successful we get JSON: {"status":1,"redirect":"home","msg":"Success !"}
        STATUS=$(parse_json 'status' <<< "$JSON") || return
        [ "$STATUS" != '1' ] && return $ERR_LOGIN_FAILED

        storage_set 'cookie_file' "$(cat "$COOKIE_FILE")"

        PAGE=$(curl -b "$COOKIE_FILE" "$BASE_URL/account") || return
        log_debug 'session (new)'
        MSG='logged in as'
    fi

    NAME=$(parse_attr_quiet 'id="oldEmail"' 'value' <<< "$PAGE")
    log_debug "Successfully $MSG 'free' member '$NAME'"
}

# Upload a file to go4up.com
# $1: cookie file (for account only)
# $2: input file (with full path)
# $3: remote filename
# stdout: go4up.com download link
go4up_upload() {
    local COOKIE_FILE=$1
    local FILE=$2
    local DESTFILE=$3
    local BASE_URL='http://go4up.com'
    local UPLOAD_URL PAGE ERR USER PASSWORD

    # Upload by using public API: http://go4up.com/misc/apidoc
    if [ -n "$API" ]; then
        log_debug 'using public API'

        # Check if API can handle this upload
        if [ -z "$AUTH_FREE" ]; then
            log_error 'Public API is only available for registered users.'
            return $ERR_BAD_COMMAND_LINE
        fi

        if [ -n "$COUNT" -o "${#INCLUDE[@]}" -gt 0 ]; then
            log_error 'Public API does not support hoster selection.'
            return $ERR_BAD_COMMAND_LINE
        fi

        split_auth "$AUTH_FREE" USER PASSWORD || return

        UPLOAD_URL=$(curl "$BASE_URL/api/getserver") || return

        # Upload local file
        if ! match_remote_url "$FILE"; then
            PAGE=$(curl_with_log -F "user=$USER" -F "pass=$PASSWORD" \
                -F "filedata=@$FILE" "$UPLOAD_URL") || return

        # Upload remote file
        else
            PAGE=$(curl_with_log -F "user=$USER" -F "pass=$PASSWORD" \
                --form-string "url=$FILE" "$UPLOAD_URL") || return
        fi

        if match '<error>' "$PAGE"; then
            ERR=$(parse_tag 'error' <<< "$PAGE")
            log_error "Remote error: $ERR"
            return $ERR_FATAL
        fi

        parse_tag 'link' <<< "$PAGE" || return
        return 0
    fi

    # Upload by using WWW.
    local FORM UPLOAD_ID USER_ID HOSTS_NAMES HOSTS_NUMS
    local NAME NUM HOSTS_SEL HOST_FOUND FORM_HOSTS

    # Note: This is out first contact with Go4Up, so we need -c in curl command.
    go4up_switch_lang "$COOKIE_FILE" "$BASE_URL"

    # Login needs to go before retrieving hosters because accounts
    # have a individual host list
    if [ -n "$AUTH_FREE" ]; then
        go4up_login "$AUTH_FREE" "$COOKIE_FILE" "$BASE_URL" || return
    fi

    # Retrieve form with data and with complete hosting list
    if ! match_remote_url "$FILE"; then
        PAGE=$(curl -b "$COOKIE_FILE" "$BASE_URL") || return
        FORM=$(grep_form_by_id "$PAGE" 'myformupload' | break_html_lines) || return
    else
        PAGE=$(curl -b "$COOKIE_FILE" "$BASE_URL/home/remote") || return
        FORM=$(grep_form_by_id "$PAGE" 'form_upload' | break_html_lines) || return
    fi

    UPLOAD_URL=$(parse_attr 'action' <<< "$FORM") || return
    log_debug "Upload base URL: $UPLOAD_URL"

    UPLOAD_ID=$(parse_form_input_by_name 'uploadID' <<< "$FORM") || return
    USER_ID=$(parse_form_input_by_name_quiet 'id_user' <<< "$FORM")

    # Prepare lists of hosts to mirror to
    HOSTS_NAMES=$(parse_all_attr 'checkbox' 'hostname' <<< "$FORM") || return
    HOSTS_NUMS=$(parse_all_attr 'checkbox' 'value' <<< "$FORM") || return

    if [ -z "$HOSTS_NAMES" ]; then
        log_error 'Empty list, site updated?'
        return $ERR_FATAL
    fi

    log_debug 'Available hosts:'
    while read -r NAME && read -r NUM <&3; do
        log_debug "  $NAME - $NUM"
    done <<< "$HOSTS_NAMES" 3<<< "$HOSTS_NUMS"

    if [ -n "$COUNT" ]; then
        for NUM in $HOSTS_NUMS; do
            (( COUNT-- > 0 )) || break
            HOSTS_SEL="$HOSTS_SEL $NUM"
        done
    elif [ "${#INCLUDE[@]}" -gt 0 ]; then
        for HOST in "${INCLUDE[@]}"; do
            HOST_FOUND='false'

            while read -r NAME && read -r NUM <&3; do
                if [ "$HOST" == "$NAME" ]; then
                    HOSTS_SEL="$HOSTS_SEL $NUM"
                    HOST_FOUND='true'
                    break
                fi
            done <<< "$HOSTS_NAMES" 3<<< "$HOSTS_NUMS"

            if [ "$HOST_FOUND" == 'true' ]; then
                log_debug "Added to the host list: $HOST"
            else
                log_error "Host not supported and ignored: $HOST"
            fi
        done
    else
        # Default hosting sites selection
        HOSTS_SEL=$(parse_all_attr 'checked' 'value' <<< "$FORM") || return
    fi

    if [ -z "$HOSTS_SEL" ]; then
        log_debug 'Empty host selection. Nowhere to upload!'
        return $ERR_FATAL
    fi

    # Convert prepared lists of hosts to form
    for NUM in $HOSTS_SEL; do
        log_debug "Selected host number: $NUM"
        FORM_HOSTS="$FORM_HOSTS -F box[]=$NUM"
    done

    local UPLOAD_ID_RND SERVER FORM_NAMES FORM_VALUES
    local FORM_POST FILE_ID JSON STATUS PARAMS

    # Upload local file
    if ! match_remote_url "$FILE"; then
        UPLOAD_ID_RND=$(random dec 12) || return
        SERVER=$(parse_form_input_by_name 'server' <<< "$FORM") || return

        PAGE=$(curl_with_log \
            -F "uploadID=$UPLOAD_ID" \
            -F "id_user=$USER_ID" \
            -F "server=$SERVER" \
            -F "file_0=@$FILE;filename=$DESTFILE" \
            -F 'file_1=;filename=' \
            $FORM_HOSTS \
            "$UPLOAD_URL?upload_id=$UPLOAD_ID_RND&js_on=1&xpass=&xmode=1" \
            | break_html_lines) || return

        FORM_NAMES=$(parse_all_attr 'textarea' 'name' <<< "$PAGE") || return
        FORM_VALUES=$(parse_all_tag_quiet 'textarea' <<< "$PAGE")

        # Note: Form must be send in a multipart manner. Using an array we
        #       are confident that values with spaces will be treat properly.
        while read -r NAME && read -r VALUE <&3; do
            FORM_POST=("${FORM_POST[@]}" "-F $NAME=$VALUE")
        done <<< "$FORM_NAMES" 3<<< "$FORM_VALUES"

        PAGE=$(curl -b "$COOKIE_FILE" \
            "${FORM_POST[@]}" \
            -L "$BASE_URL/home/upload_process") || return

    # Upload remote file
    else
        FILE_ID=$(parse_form_input_by_name 'FILEID' <<< "$FORM") || return

        # Note: We cannot force curl to send a POST and not wait for a response,
        #       so asynchronous uploads are not possible.
        JSON=$(curl \
            -F "uploadID=$UPLOAD_ID" \
            -F "FILEID=$FILE_ID" \
            -F "id_user=$USER_ID" \
            -F "url[]=$FILE" \
            -F 'rename[]=' \
            $FORM_HOSTS \
            "$UPLOAD_URL/upload/remote") || return

        STATUS=$(parse_json 'status' <<< "$JSON") || return
        if [ "$STATUS" != '1' ]; then
            ERR=$(parse_json_quiet 'msg' <<< "$JSON")
            log_error "Remote error: $ERR"
            return $ERR_FATAL
        fi

        PARAMS=$(parse_json 'params' <<< "$JSON") || return

        PAGE=$(curl -b "$COOKIE_FILE" \
            -F 'params='$PARAMS'' \
            -L "$BASE_URL/home/upload_process/remote") || return
    fi

    parse_attr '/dl/' 'href' <<< "$PAGE" || return
}

# List links from a go4up link
# $1: go4up link
# $2: recurse subfolders (ignored here)
# stdout: list of links
go4up_list() {
    local URL=$1
    local BASE_URL='http://go4up.com'
    local PAGE INFO_URL LINKS FILE_NAME JSON

    go4up_switch_lang "$COOKIE_FILE" "$BASE_URL"

    PAGE=$(curl -b "$COOKIE_FILE" -L "$URL") || return

    if match 'The file is being uploaded on mirror websites' "$PAGE"; then
        return $ERR_LINK_TEMP_UNAVAILABLE
    elif match 'File not Found' "$PAGE"; then
        return $ERR_LINK_DEAD
    fi

    # url: "/download/gethosts/<ID>/<Name>",
    INFO_URL=$(parse '^[[:space:]]*url:' '"\(.\+\)"' <<< "$PAGE") || return
    FILE_NAME=$(parse '<h3' '<h3[[:space:]]*>\(.\+\)[[:space:]]\+([[:alnum:]]\+' \
        <<< "$PAGE") || return

    JSON=$(curl -b "$COOKIE_FILE" "$BASE_URL$INFO_URL") || return

    # status: ok dead queued checking failed uploading
    PAGE=$(parse_json status split <<< "$JSON") || return
    if match 'queued\|uploading' "$PAGE"; then
        # Is there at least a link available ?
        [ -n "$PARTIAL_LINKS" ] || return $ERR_LINK_TEMP_UNAVAILABLE
        match 'ok\|checking' "$PAGE" || return $ERR_LINK_TEMP_UNAVAILABLE
        log_debug 'all links are not available yet, but continue anyway (--partial)'
    fi

    # "File currently in queue." will be dropped
    PAGE=$(parse_json link split <<< "$JSON") || return
    LINKS=$(parse_all_attr href <<< "$PAGE") || return

    while read INFO_URL; do
        PAGE=$(curl -b "$COOKIE_FILE" "$BASE_URL$INFO_URL") || return
        parse_attr '<b>' 'href' <<< "$PAGE" || return
        echo "$FILE_NAME"
    done <<< "$LINKS"
}

# Delete a file on go4up.com
# $1: cookie file
# $2: file URL
go4up_delete() {
    local COOKIE_FILE=$1
    local URL=$2
    local BASE_URL='http://go4up.com'
    local PAGE FILE_ID FILE_NAME

    test "$AUTH_FREE" || return $ERR_LINK_NEED_PERMISSIONS

    # Parse URL
    # http://go4up.com/link.php?id=1Ddupi2qxbwl
    # http://go4up.com/dl/1Ddupi2qxbwl
    FILE_ID=$(echo "$URL" | parse . '[=/]\([[:alnum:]]\+\)$') || return
    log_debug "File ID: $FILE_ID"

    go4up_switch_lang "$COOKIE_FILE" "$BASE_URL"

    # Check link
    PAGE=$(curl -b "$COOKIE_FILE" "$URL") || return
    if match 'File not Found' "$PAGE"; then
        return $ERR_LINK_DEAD
    fi

    FILE_NAME=$(parse '<h3' '<h3[[:space:]]*>\(.\+\)[[:space:]]\+([[:alnum:]]\+' \
        <<< "$PAGE") || return

    go4up_login "$AUTH_FREE" "$COOKIE_FILE" "$BASE_URL" || return

    PAGE=$(curl -b "$COOKIE_FILE" -F "FILEID=$FILE_ID" -F "filename=$FILE_NAME" \
        "$BASE_URL/manager/filemanager/delete") || return

    # Note: Go4up will *always* send this reply, 1 - success, 2 - failed.
    #       Nevertheless it also return success for anonymous files,
    #       so we have to check if the link is really gone.
    if ! match '1' "$PAGE"; then
        return $ERR_FATAL
    fi

    # Check if link is really gone
    PAGE=$(curl -b "$COOKIE_FILE" "$URL") || return
    if ! match 'File not Found' "$PAGE"; then
        log_error 'File NOT removed. Are you the owner if this file?'
        return $ERR_LINK_NEED_PERMISSIONS
    fi
}

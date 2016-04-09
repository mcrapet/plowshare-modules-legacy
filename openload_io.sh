# Plowshare openload.io module
# Copyright (c) 2015 ljsdoug <sdoug@inbox.com>
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

MODULE_OPENLOAD_IO_REGEXP_URL='https\?://openload\.\(co\|io\)/'

MODULE_OPENLOAD_IO_DOWNLOAD_OPTIONS=""
MODULE_OPENLOAD_IO_DOWNLOAD_RESUME=yes
MODULE_OPENLOAD_IO_DOWNLOAD_FINAL_LINK_NEEDS_COOKIE=no
MODULE_OPENLOAD_IO_DOWNLOAD_SUCCESSIVE_INTERVAL=

MODULE_OPENLOAD_IO_UPLOAD_OPTIONS="
AUTH,a,auth,a=USER:PASSWORD,User account
FOLDER,,folder,s=FOLDER,Folder to upload files into (support subfolders)"
MODULE_OPENLOAD_IO_UPLOAD_REMOTE_SUPPORT=no

MODULE_OPENLOAD_IO_PROBE_OPTIONS=""

# Static function. Proceed with login
# $1: authentication
# $2: cookie file
# $3: base URL
# $4: API URL
# stdout: account type ("free") and api data ("$API_DATA") with login and key on success.
openload_io_login() {
    local -r AUTH=$1
    local -r COOKIE_FILE=$2
    local -r BASE_URL=$3
    local -r API_URL=$4
    local API_DATA JSON STATUS NAME MSG PAGE CSRF_TOKEN
    local LOGIN_DATA LOCATION USER PASSWORD API_LOGIN API_KEY

    if API_DATA=$(storage_get 'api_data'); then

        # Check for expired session for API Login and API Key.
        JSON=$(curl $API_DATA "$API_URL/account/info") || return
        STATUS=$(parse_json 'status' <<< "$JSON") || return
        if [ "$STATUS" != '200' ]; then
            storage_set 'api_data'
            return $ERR_EXPIRED_SESSION
        fi

        NAME=$(parse_json_quiet 'email' <<< "$JSON")
        log_debug "session (cached): checked API Login and API Key"
        MSG='reused login for'
    else
        PAGE=$(curl -c "$COOKIE_FILE" "$BASE_URL/login") || return
        CSRF_TOKEN=$(parse_attr 'name="csrf-token"' 'content' <<< "$PAGE") || return
        LOGIN_DATA="_csrf=$CSRF_TOKEN&LoginForm[email]=\$USER&LoginForm[password]=\$PASSWORD&LoginForm[rememberMe]=1"

        LOCATION=$(post_login "$AUTH" "$COOKIE_FILE" "$LOGIN_DATA" "$BASE_URL/login" \
            -i -b "$COOKIE_FILE" | grep_http_header_location_quiet) || return

        # If successful, then we should redirected to account.
        if ! match "$BASE_URL/account" "$LOCATION"; then
            return $ERR_LOGIN_FAILED
        fi

        # Get API Login.
        PAGE=$(curl -b "$COOKIE_FILE" "$BASE_URL/account") || return
        CSRF_TOKEN=$(parse_attr 'name="csrf-token"' 'content' <<< "$PAGE") || return
        API_LOGIN=$(parse 'API Login:' 'API Login:</td><td>\([^<]*\)' \
            <<< "$PAGE") || return

        # Get API Key.
        split_auth "$AUTH" USER PASSWORD || return
        PAGE=$(curl -L -b "$COOKIE_FILE" -d "_csrf=$CSRF_TOKEN" \
            -d "FTPKey[password]=$PASSWORD" "$BASE_URL/account") || return
        API_KEY=$(parse 'API Key is:' 'API Key is:[[:space:]]*\([^[:space:]]*\)' \
            <<< "$PAGE") || return

        API_DATA="-d login=$API_LOGIN -d key=$API_KEY"
        storage_set 'api_data' "$API_DATA"

        NAME=$(parse_quiet '>E-mail:<' '>E-mail:</td><td>\([^<]*\)' <<< "$PAGE")
        log_debug "session (new)"
        MSG='logged in as'
    fi

    log_debug "Successfully $MSG 'free' member '$NAME'"
    echo 'free'
    echo "$API_DATA"
}

# Output a openload_io file download URL
# $1: cookie file (unused here)
# $2: openload_io url
# stdout: real file download link
openload_io_download() {
    local -r URL=$2
    local PAGE WAIT FILE_URL FILE_NAME

    PAGE=$(curl -L "$URL") || return

    if match "<p class=\"lead\">We can't find the file you are looking for" "$PAGE"; then
        return $ERR_LINK_DEAD
    fi

    WAIT=$(parse_tag 'id="secondsleft"' span <<< "$PAGE") || return

    wait $(($WAIT)) seconds || return

    FILE_URL=$(parse_attr 'id="realdownload"' href <<< "$PAGE")
    FILE_NAME=$(parse_tag 'id="filename"' span <<< "$PAGE")

    echo "$FILE_URL"
    echo "$FILE_NAME"
}

# Static function. Check if a cookie doesn't expired.
# $1: cookie file
# $2: base URL
openload_io_check_cookie() {
    local -r COOKIE_FILE=$1
    local -r BASE_URL=$2
    local LOCATION

    LOCATION=$(curl -I -b "$COOKIE_FILE" "$BASE_URL/account" \
        | grep_http_header_location_quiet) || return

    if [ "$LOCATION" == "$BASE_URL/login" ]; then
        storage_set 'api_data'
        return $ERR_EXPIRED_SESSION
    fi
}

# Static function. Check if specified folder name is valid.
# If folder not found then create it. Support subfolders.
# $1: folder name selected by user
# $2: cookie file (logged into account)
# $3: base URL
# $4: API URL
# $5: API Data
# stdout: folder data
openload_io_check_folder() {
    local -r NAME=$1
    local -r COOKIE_FILE=$2
    local -r BASE_URL=$3
    local -r API_URL=$4
    local -r API_DATA=$5
    local FOLDER_NAMES FOLDER JSON FOLDER_DATA
    local FOLDER_ID FOLDER_LINE PARENT_ID STATUS

    # Only backslashes in a folder name cause problems.
    if match "[\\]" "$NAME"; then
        log_error 'Folder should not contains backslash characters: \\'
        return $ERR_FATAL
    fi

    # Convert subfolders names into an array.
    IFS='/' read -ra FOLDER_NAMES <<< "$NAME"

    for FOLDER in "${FOLDER_NAMES[@]}"; do
        # Skip empty names.
        [ -z "$FOLDER" ] && continue

        # Grab only folder names with their ids and insert a newline between them.
        JSON=$(curl $API_DATA $FOLDER_DATA "$API_URL/file/listfolder" \
            | parse . '"folders":\(\[.*\]\),"files"' | replace_all '"},' '"},'$'\n') || return

        # Find a folder name with its id.
        FOLDER_ID=''
        while read -r FOLDER_LINE; do
            if [ "$FOLDER" == "$(parse_json_quiet 'name' <<< "$FOLDER_LINE")" ]; then
                FOLDER_ID="$(parse_json_quiet 'id' <<< "$FOLDER_LINE")"
                log_debug "Successfully found: '$FOLDER' with ID '$FOLDER_ID'"
                break
            fi
        done <<< "$JSON"

        # If a folder name was not found then create it.
        if [ -z "$FOLDER_ID" ]; then
            # Note: API doesn't have ability to create a new folder, so we have to do
            # this through WWW. We need only a valid cookie. Normally we don't need it,
            # but for the safety check if it's valid, otherwise renew session. This
            # check is only relevant when --cache=shared, otherwise we will have
            # always a valid cookie file during folder creation.
            openload_io_check_cookie "$COOKIE_FILE" "$BASE_URL" || return

            JSON=$(curl -b "$COOKIE_FILE" -d "name=$(uri_encode_strict <<< "$FOLDER")" \
                -d "id=$PARENT_ID" "$BASE_URL/filemanager/createfolder" \
                | replace_all '\"' '"') || return
            STATUS=$(parse_json 'success' <<< "$JSON") || return
            if [ "$STATUS" == '1' ]; then
                FOLDER_ID=$(parse_json 'id' <<< "$JSON") || return
                log_debug "Successfully created: '$FOLDER' with ID '$FOLDER_ID'"
            else
                log_error "Could not create folder: '$FOLDER'"
                return $ERR_FATAL
            fi
        fi

        # Perverse data for the next loop.
        FOLDER_DATA="-d folder=$FOLDER_ID"
        PARENT_ID="$FOLDER_ID"
    done

    log_debug "FOLDER ID: '$FOLDER_ID'"
    echo $FOLDER_DATA
}

# Upload a file to openload_io
# $1: cookie file
# $2: input file (with full path)
# $3: remote filename
# stdout: download link
openload_io_upload() {
    local -r COOKIE_FILE=$1
    local -r FILE=$2
    local -r DESTFILE=$3
    local -r BASE_URL='https://openload.co'
    local -r API_URL='https://api.openload.co/1'
    local MAX_SIZE MSG SIZE AA ACCOUNT API_DATA FOLDER_DATA UPLOAD_URL JSON STATUS

    if [ -z "$AUTH" ]; then
        if [ -n "$FOLDER" ]; then
            log_error 'You must be registered to use folders.'
            return $ERR_LINK_NEED_PERMISSIONS
        fi
    fi

    # Note: Media files are autoconverted and they are limited to max 10 GiB size,
    #       normal files are limited to max 1 GiB size. Extensions for media files
    #       were taken arbitrary.
    if match '\.\(avi\|mkv\|mpg\|mpeg\|vob\|wmv\|flv\|mp4\|mov\|m2v\|divx\|xvid\|3gp\|webm\|og[vg]\)$' "$DESTFILE"; then
        MAX_SIZE=10737418240 # 10GiB
        MSG='Media file'
    else
        MAX_SIZE=1073741824 # 1GiB
        MSG='Normal file'
    fi

    SIZE=$(get_filesize "$FILE")
    if [ $SIZE -gt $MAX_SIZE ]; then
        log_debug "$MSG is bigger than $MAX_SIZE"
        return $ERR_SIZE_LIMIT_EXCEEDED
    fi

    if [ -n "$AUTH" ]; then
        AA=$(openload_io_login "$AUTH" "$COOKIE_FILE" "$BASE_URL" "$API_URL") || return
        { read ACCOUNT; read API_DATA; } <<< "$AA"

        if [ -n "$FOLDER" ]; then
            FOLDER_DATA=$(openload_io_check_folder "$FOLDER" "$COOKIE_FILE" \
                "$BASE_URL" "$API_URL" "$API_DATA") || return
        fi
    fi

    # Note: Anonymous and free accounts uploading are the same. They only differ
    #       in absence of $API_DATA and $FOLDER_DATA.
    UPLOAD_URL=$(curl $API_DATA $FOLDER_DATA "$API_URL/file/ul" \
        | parse_json 'url') || return

    JSON=$(curl_with_log \
        -F "file1=@$FILE;filename=$DESTFILE" \
        "$UPLOAD_URL") || return

    STATUS=$(parse_json 'status' <<< "$JSON") || return

    if [ "$STATUS" != '200' ]; then
        MSG=$(parse_json_quiet 'msg' <<< "$JSON")
        log_error "Unexpected status ($STATUS): $MSG"
        return $ERR_FATAL
    fi

    parse_json 'url' <<< "$JSON" || return
}

# Probe a download URL
# $1: cookie file (unused here)
# $2: openload_io url
# $3: requested capability list
# stdout: 1 capability per line
openload_io_probe() {
    local -r URL=$2
    local -r REQ_IN=$3
    local PAGE REQ_OUT FILE_SIZE

    PAGE=$(curl -L "$URL") || return

    if match "<p class=\"lead\">We can't find the file you are looking for" "$PAGE"; then
        return $ERR_LINK_DEAD
    fi

    REQ_OUT=c

    if [[ $REQ_IN = *f* ]]; then
        parse_tag 'class="other-title-bold"' h3 <<< "$PAGE" && REQ_OUT="${REQ_OUT}f"
    fi

    if [[ $REQ_IN = *s* ]]; then
        FILE_SIZE=$(parse 'class="content-text"' 'size:\([^<]*\)' <<< "$PAGE") && \
            translate_size "$FILE_SIZE" && REQ_OUT="${REQ_OUT}s"
    fi

    echo $REQ_OUT
}

# Plowshare bigfile.to module
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

MODULE_BIGFILE_REGEXP_URL='https\?://\(www\.\)\?\(bigfile\.to\|uploadable\.ch\)/'

MODULE_BIGFILE_DOWNLOAD_OPTIONS="
AUTH,a,auth,a=USER:PASSWORD,User account"
MODULE_BIGFILE_DOWNLOAD_RESUME=no
MODULE_BIGFILE_DOWNLOAD_FINAL_LINK_NEEDS_COOKIE=no
MODULE_BIGFILE_DOWNLOAD_SUCCESSIVE_INTERVAL=

MODULE_BIGFILE_UPLOAD_OPTIONS="
AUTH,a,auth,a=USER:PASSWORD,User account
FOLDER,,folder,s=FOLDER,Folder to upload files into"
MODULE_BIGFILE_UPLOAD_REMOTE_SUPPORT=yes

MODULE_BIGFILE_LIST_OPTIONS=""
MODULE_BIGFILE_LIST_HAS_SUBFOLDERS=no

MODULE_BIGFILE_PROBE_OPTIONS=""

MODULE_BIGFILE_DELETE_OPTIONS=""

# Static function. Proceed with login
# $1: authentication
# $2: cookie file
# $3: base URL
# stdout: account type ("free" or "premium") on success.
bigfile_login() {
    local -r AUTH=$1
    local -r COOKIE_FILE=$2
    local -r BASE_URL=$3

    local CV PAGE MSG LOGIN_DATA NAME TYPE

    if CV=$(storage_get 'cookie_file'); then
        echo "$CV" >"$COOKIE_FILE"

        # Check for expired session.
        PAGE=$(curl -b "$COOKIE_FILE" "$BASE_URL/indexboard.php") || return
        if ! match '>Dashboard<' "$PAGE"; then
            storage_set 'cookie_file'
            return $ERR_EXPIRED_SESSION
        fi

        log_debug 'session (cached)'
        MSG='reused login for'
    else
        LOGIN_DATA='userName=$USER&userPassword=$PASSWORD&autoLogin=on&action__login=normalLogin'
        PAGE=$(post_login "$AUTH" "$COOKIE_FILE" "$LOGIN_DATA" \
            "$BASE_URL/login.php") || return

        if ! match 'Logging in' "$PAGE"; then
            return $ERR_LOGIN_FAILED
        fi

        storage_set 'cookie_file' "$(cat "$COOKIE_FILE")"
        PAGE=$(curl -b "$COOKIE_FILE" "$BASE_URL/indexboard.php") || return

        log_debug 'session (new)'
        MSG='logged in as'
    fi

    NAME=$(parse_quiet 'id="dashboard_box"' '>\([^<]*\)<' 4 <<< "$PAGE")

    if match '>Upgrade Now<' "$PAGE"; then
        TYPE='free'
    else
        TYPE='premium'
    fi

    log_debug "Successfully $MSG '$TYPE' member '$NAME'"
    echo $TYPE
}

# Output a bigfile file download URL and name
# $1: cookie file
# $2: bigfile url
# stdout: file download link
bigfile_download() {
    local -r COOKIE_FILE=$1
    local URL=$2
    local -r BASE_URL='https://www.bigfile.to'
    local FILE_ID ACCOUNT PAGE JSON FILE_URL WAIT_TIME

    FILE_ID=$(parse . '/file/\([^/]\+\)' <<< "$URL") || return
    URL="$BASE_URL/file/$FILE_ID"
    readonly URL

    if [ -n "$AUTH" ]; then
        ACCOUNT=$(bigfile_login "$AUTH" "$COOKIE_FILE" "$BASE_URL") || return
    fi

    # Note: Save HTTP headers to catch premium users' "direct downloads".
    PAGE=$(curl -i -c "$COOKIE_FILE" -b "$COOKIE_FILE" "$URL") || return

    if match 'File not available\|cannot be found on the server\|no longer available\|Page not found' "$PAGE"; then
        return $ERR_LINK_DEAD
    fi

    # If this is a premium download, we already have a download link.
    if [ "$ACCOUNT" = 'premium' ]; then
        MODULE_BIGFILE_DOWNLOAD_RESUME=yes

        # Get a download link, if this was a direct download.
        FILE_URL=$(grep_http_header_location_quiet <<< "$PAGE")

        if [ -z "$FILE_URL" ]; then
            PAGE=$(curl -b "$COOKIE_FILE" \
                -d 'download=premium' \
                -i "$URL") || return

            FILE_URL=$(grep_http_header_location <<< "$PAGE") || return
        fi

        echo "$FILE_URL"
        return 0
    fi

    if match 'var reCAPTCHA_publickey' "$PAGE"; then
        local PUBKEY WCI CHALLENGE WORD ID
        # http://www.google.com/recaptcha/api/challenge?k=
        PUBKEY=$(parse 'var reCAPTCHA_publickey' "var reCAPTCHA_publickey='\([^']\+\)" <<< "$PAGE") || return
    fi

    JSON=$(curl -b "$COOKIE_FILE" \
        -d 'downloadLink=wait' \
        "$URL") || return

    WAIT_TIME=$(parse_json 'waitTime' <<< "$JSON") || return
    wait $WAIT_TIME || return

    JSON=$(curl -b "$COOKIE_FILE" \
        -d 'checkDownload=check' \
        "$URL") || return

    if match '"fail":"timeLimit"' "$JSON"; then
        local HOURS MINS SECS

        PAGE=$(curl -b "$COOKIE_FILE" \
            -d 'checkDownload=showError' \
            -d 'errorType=timeLimit' \
            "$URL") || return

        HOURS=$(parse_quiet '>Please wait' \
            '[^[:digit:]]\([[:digit:]]\+\) hours\?' <<< "$PAGE")
        MINS=$(parse_quiet  '>Please wait' \
            '[^[:digit:]]\([[:digit:]]\+\) minutes\?' <<< "$PAGE")
        SECS=$(parse_quiet  '>Please wait' \
            '[^[:digit:]]\([[:digit:]]\+\) seconds\?' <<< "$PAGE")

        log_error 'Download limit reached.'
        # Note: Always use decimal base instead of octal if there are leading zeros.
        echo $(( (( 10#$HOURS * 60 ) + 10#$MINS ) * 60 + 10#$SECS ))
        return $ERR_LINK_TEMP_UNAVAILABLE

    elif ! match '"success":"showCaptcha"' "$JSON"; then
        log_error "Unexpected response: $JSON"
        return $ERR_FATAL
    fi

    if [ -n "$PUBKEY" ]; then
        WCI=$(recaptcha_process $PUBKEY) || return
        { read WORD; read CHALLENGE; read ID; } <<<"$WCI"

        JSON=$(curl -b "$COOKIE_FILE" \
            -d "recaptcha_challenge_field=$CHALLENGE" \
            -d "recaptcha_response_field=$WORD" \
            -d "recaptcha_shortencode_field=$FILE_ID" \
            "$BASE_URL/checkReCaptcha.php") || return

        if ! match '"success":1' "$JSON"; then
            captcha_nack $ID
            log_error 'Wrong captcha'
            return $ERR_CAPTCHA
        fi

        captcha_ack $ID
        log_debug 'Correct captcha'
    fi

    PAGE=$(curl -b "$COOKIE_FILE" \
        -d 'downloadLink=show' \
        "$URL") || return

    PAGE=$(curl -b "$COOKIE_FILE" \
        -d 'download=normal' \
        -i "$URL") || return

    grep_http_header_location <<< "$PAGE" || return
}

# Check if specified folder name is valid.
# $1: folder name selected by user
# $2: cookie file (logged into account)
# $3: base url
# stdout: folder ID
bigfile_check_folder() {
    local -r NAME=$1
    local -r COOKIE_FILE=$2
    local -r BASE_URL=$3
    local JSON FOLDERS FOLDERS_N FOLDER_ID

    log_debug 'Getting folder data'

    JSON=$(curl -b "$COOKIE_FILE" \
        -d 'current_page=1' \
        -d 'extra=folderPanel' \
        "$BASE_URL/file-manager-expand-folder.php") || return

    FOLDERS=$(replace_all '{', $'\n{' <<< "$JSON") || return
    FOLDERS=$(replace_all '}', $'}\n' <<< "$FOLDERS") || return

    FOLDERS_N=$(parse_all_quiet '"folderName":"' '"folderName":"\([^"]\+\)' <<< "$FOLDERS")

    if ! match "^$NAME$" "$FOLDERS_N"; then
        log_debug "Creating folder: '$NAME'"

        JSON=$(curl -b "$COOKIE_FILE" \
            -d "newFolderName=$NAME" \
            -d 'createFolderDest=0' \
            "$BASE_URL/file-manager-action.php") || return

        if ! match '"success":true' "$JSON"; then
            log_error 'Failed to create folder.'
            return $ERR_FATAL
        fi

        JSON=$(curl -b "$COOKIE_FILE" \
            -d 'current_page=1' \
            -d 'extra=folderPanel' \
            "$BASE_URL/file-manager-expand-folder.php") || return

        FOLDERS=$(replace_all '{', $'\n{' <<< "$JSON") || return
        FOLDERS=$(replace_all '}', $'}\n' <<< "$FOLDERS") || return
    fi

    FOLDER_ID=$(parse "\"folderName\":\"$NAME\"" '"folderId":"\([^"]\+\)' <<< "$FOLDERS") || return

    log_debug "Folder ID: '$FOLDER_ID'"
    echo "$FOLDER_ID"
}

# Upload a file to bigfile
# $1: cookie file
# $2: file path or remote url
# $3: remote filename
# stdout: download link + delete link
bigfile_upload() {
    local -r COOKIE_FILE=$1
    local -r FILE=$2
    local -r DESTFILE=$3
    local -r BASE_URL='https://www.bigfile.to'
    local ACCOUNT PAGE JSON UPLOAD_URL FILE_ID FILE_NAME DEL_CODE

    # Sanity checks
    if [ -z "$AUTH" ]; then
        if [ -n "$FOLDER" ]; then
            log_error 'You must be registered to use folders.'
            return $ERR_LINK_NEED_PERMISSIONS

        elif match_remote_url "$FILE"; then
            log_error 'You must be registered to do remote uploads.'
            return $ERR_LINK_NEED_PERMISSIONS
        fi
    fi

    if match_remote_url "$FILE"; then
        if [ -n "$FOLDER" ]; then
            log_error 'You cannot choose folder for remote link.'
            return $ERR_LINK_NEED_PERMISSIONS
        fi
    fi

    if [ -n "$AUTH" ]; then
        ACCOUNT=$(bigfile_login "$AUTH" "$COOKIE_FILE" "$BASE_URL") || return
    fi

    if [ -n "$FOLDER" ]; then
        FOLDER_ID=$(bigfile_check_folder "$FOLDER" "$COOKIE_FILE" "$BASE_URL") || return
    fi

    PAGE=$(curl -c "$COOKIE_FILE" -b "$COOKIE_FILE" \
        "$BASE_URL/index.php") || return

    if ! match_remote_url "$FILE"; then
        local MAX_SIZE SZ

        SZ=$(get_filesize "$FILE")

        if [ "$ACCOUNT" = 'premium' ]; then
            MAX_SIZE='5368709120' # 5 GiB
        else
            MAX_SIZE='2147483648' # 2 GiB
        fi

        log_debug "Max size: $MAX_SIZE"

        if [ "$SZ" -gt "$MAX_SIZE" ]; then
            log_debug "File is bigger than $MAX_SIZE."
            return $ERR_SIZE_LIMIT_EXCEEDED
        fi
    fi

    # Upload remote file
    if match_remote_url "$FILE"; then
        if ! match '^https\?://' "$FILE" && ! match '^ftp://' "$FILE"; then
            log_error 'Unsupported protocol for remote upload.'
            return $ERR_BAD_COMMAND_LINE
        fi

        PAGE=$(curl -b "$COOKIE_FILE" \
            -d "urls=$FILE" \
            -d 'remoteUploadFormType=web' \
            -d 'showPage=remoteUploadFormWeb.tpl' \
            "$BASE_URL/uploadremote.php") || return

        if ! match 'Upload Successful' "$PAGE"; then
            log_error 'Remote upload failed.'
            return $ERR_FATAL
        fi

        log_error 'Once remote upload completed, check your account for link.'
        return $ERR_ASYNC_REQUEST

    # Upload local file
    else
        UPLOAD_URL=$(parse 'var uploadUrl' "var uploadUrl = '\([^']\+\)" <<< "$PAGE") || return

        JSON=$(curl_with_log -X PUT \
            -H "X-File-Name: $DESTFILE" \
            -H "X-File-Size: $SZ" \
            -H "Origin: $BASE_URL" \
            --data-binary "@$FILE" \
            "$UPLOAD_URL") || return

        DEL_CODE=$(parse_json 'deleteCode' <<< "$JSON") || return
        FILE_NAME=$(parse_json 'fileName' <<< "$JSON") || return
        FILE_ID=$(parse_json 'shortenCode' <<< "$JSON") || return
    fi

    if [ -n "$FOLDER" ]; then
        local UPLOAD_ID

        log_debug "Moving file to folder '$FOLDER'..."

        # Get root folder content dorted by upload date DESC
        # Last uploaded file will be on top
        JSON=$(curl -b "$COOKIE_FILE" \
            -d 'parent_folder_id=0' \
            -d 'current_page=1' \
            -d 'sort_field=2' \
            -d 'sort_order=DESC' \
            "$BASE_URL/file-manager-expand-folder.php") || return

        JSON=$(replace_all '{', $'\n{' <<< "$JSON") || return
        JSON=$(replace_all '}', $'}\n' <<< "$JSON") || return

        UPLOAD_ID=$(parse "$FILE_ID" '"uploadId":"\([^"]\+\)' <<< "$JSON") || return

        log_debug "Upload ID: '$UPLOAD_ID'"

        JSON=$(curl -b "$COOKIE_FILE" \
            -d "moveFolderId=$UPLOAD_ID" \
            -d "moveFolderDest=$FOLDER_ID" \
            -d 'CurrentFolderId=0' \
            "$BASE_URL/file-manager-action.php") || return

        if ! match '"successCount":1' "$JSON"; then
            log_error 'Could not move file into folder.'
        fi
    fi

    echo "${BASE_URL}/file/$FILE_ID/$FILE_NAME"
    echo "${BASE_URL}/file/$FILE_ID/delete/$DEL_CODE"
}

# Probe a download URL
# $1: cookie file (unused here)
# $2: bigfile url
# $3: requested capability list
# stdout: 1 capability per line
bigfile_probe() {
    local -r URL=$2
    local -r REQ_IN=$3
    local PAGE FILE_NAME FILE_SIZE REQ_OUT

    PAGE=$(curl -L "$URL") || return

    if match 'File not available\|cannot be found on the server\|no longer available\|Page not found' "$PAGE"; then
        return $ERR_LINK_DEAD
    fi

    REQ_OUT=c

    if [[ $REQ_IN = *f* ]]; then
        parse_attr '"file_name"' 'title' <<< "$PAGE" &&
            REQ_OUT="${REQ_OUT}f"
    fi

    if [[ $REQ_IN = *s* ]]; then
        FILE_SIZE=$(parse '"filename_normal"' '>(\([^)]\+\)' <<< "$PAGE") && \
            translate_size "$FILE_SIZE" && REQ_OUT="${REQ_OUT}s"
    fi

    echo $REQ_OUT
}

# List a bigfile web folder URL
# $1: folder URL
# $2: recurse subfolders (null string means not selected)
# stdout: list of links and file names (alternating)
bigfile_list() {
    local -r URL=$1
    local -r REC=$2
    local PAGE LINKS NAMES

    PAGE=$(curl -L "$URL") || return

    if match 'File not available\|cannot be found on the server\|no longer available\|Page not found' "$PAGE"; then
        return $ERR_LINK_DEAD
    fi

    NAMES=$(parse_all_quiet 'filename_normal' '">\(.*\) <span' <<< "$PAGE")
    LINKS=$(parse_all_attr_quiet 'filename_normal' 'href' <<< "$PAGE")

    list_submit "$LINKS" "$NAMES"
}

# Delete a file uploaded to bigfile
# $1: cookie file (unused here)
# $2: delete url
bigfile_delete() {
    local URL=$2
    local PAGE

    PAGE=$(curl -L "$URL") || return

    if match 'File not available\|cannot be found on the server\|no longer available\|Page not found\|File Delete Fail' "$PAGE"; then
        return $ERR_LINK_DEAD
    fi

    if ! match 'File Deleted' "$PAGE"; then
        return $ERR_FATAL
    fi
}

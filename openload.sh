# Plowshare openload.co module
# Copyright (c) 2015 ljsdoug <sdoug@inbox.com>
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

MODULE_OPENLOAD_REGEXP_URL='https\?://openload\.\(co\|io\)/'

MODULE_OPENLOAD_DOWNLOAD_OPTIONS=""
MODULE_OPENLOAD_DOWNLOAD_RESUME=yes
MODULE_OPENLOAD_DOWNLOAD_FINAL_LINK_NEEDS_COOKIE=no
MODULE_OPENLOAD_DOWNLOAD_SUCCESSIVE_INTERVAL=

MODULE_OPENLOAD_UPLOAD_OPTIONS="
AUTH,a,auth,a=API_LOGIN:API_KEY,User's API login and API key
FOLDER,,folder,s=FOLDER,Folder to upload files into (support subfolders)
ASYNC,,async,,Asynchronous remote upload (only start upload, don't wait for link)
HEADER,,header,l=LIST,Header for a remote link (comma separated)"
MODULE_OPENLOAD_UPLOAD_REMOTE_SUPPORT=yes

MODULE_OPENLOAD_PROBE_OPTIONS=""

# Static function. Check query answer
# $1: JSON data (like {"status":"200","msg":"Message", ...}
# $?: 0 for success
openload_status() {
    local STATUS=$(parse_json 'status' <<< "$1")
    if [ "$STATUS" != '200' ]; then
        local MSG=$(parse_json 'msg' <<< "$1")
        log_error "Remote status code: '$STATUS'."
        [ -z "$MSG" ] || log_error "Message: $MSG"
        return $ERR_FATAL
    fi
}

# Static function. Proceed with login
# $1: authentication
# $2: API URL
# stdout: account type ("free") and api data ("$API_DATA") with login and key on success.
openload_login() {
    local -r AUTH=$1
    local -r API_URL=$2
    local USER PASSWORD API_DATA JSON NAME

    split_auth "$AUTH" USER PASSWORD || return
    API_DATA="-d login=$USER -d key=$PASSWORD"
    JSON=$(curl $API_DATA "$API_URL/account/info") || return

    # {"status":200,"msg":"OK","result":{"extid": ...}}
    openload_status "$JSON" || return $ERR_LOGIN_FAILED

    NAME=$(parse_json_quiet 'email' <<< "$JSON")
    log_debug "Successfully logged in as 'free' member '$NAME'"

    echo 'free'
    echo "$API_DATA"
}

# Output a openload file download URL
# $1: cookie file (unused here)
# $2: openload url
# stdout: real file download link
openload_download() {
    local -r URL=$2
    local API_URL='https://api.openload.co/1/file/'
    local PAGE WAIT
    local FILE_ID FILE_NAME FILE_URL
    local DL_TICKET CAPTCHA_URL

    # Take FILE_ID from URL if we use embed link
    if match 'embed' "$URL" ; then
      log_debug 'Grab FILE_ID from URL because we use embed link that must finish with /'
      FILE_ID=$(parse '.' 'embed/\(.*\)/' <<< "$URL") || return
    else
      PAGE=$(curl -L "$URL") || return
      FILE_ID=$(parse 'fid=' '"\(.*\)"' <<< "$PAGE") || return
    fi
    log_debug "FILE_ID: $FILE_ID"

    # Request a download ticket
    JSON=$(curl "$API_URL/dlticket?file=$FILE_ID") || return

    # {"status":200,"msg":"OK","result":{"ticket": ...}}
    openload_status "$JSON" || return

    # Grab the download ticket
    DL_TICKET=$(parse_json 'ticket' <<< "$JSON") || return
    log_debug "DL_TICKET: $DL_TICKET"

    # Waiting
    WAIT=$(parse_json 'wait_time' <<< "$JSON") || return
    wait $(($WAIT)) seconds || return

    # Get captcha
    CAPTCHA_URL=$(parse_json 'captcha_url' <<< "$JSON")
    log_debug "CAPTCHA_URL: $CAPTCHA_URL"
    if [[ "$CAPTCHA_URL" != 'false' ]] ; then
        CAPTCHA_IMG=$(create_tempfile '.gif') || return
        curl -o "$CAPTCHA_IMG" "$CAPTCHA_URL" || return

        local WI WORD ID
        WI=$(captcha_process "$CAPTCHA_IMG") || return
        { read WORD; read ID; } <<< "$WI"
        rm -f "$CAPTCHA_IMG"

        # Request download link
        JSON=$(curl "$API_URL/dl?file=$FILE_ID&ticket=$DL_TICKET&captcha_response=$WORD") || return

        # {"status":200,"msg":"OK","result":{"url": ...}}
        if ! openload_status "$JSON" ; then
            captcha_nack $ID
            log_error 'Wrong captcha'
            return $ERR_CAPTCHA
        fi

        captcha_ack $ID
    else
        # Request download link
        JSON=$(curl "$API_URL/dl?file=$FILE_ID&ticket=$DL_TICKET") || return

        # {"status":200,"msg":"OK","result":{"url": ...}}
        openload_status "$JSON" || return
    fi

    # Get FILE_URL
    FILE_URL=$(parse_json 'url' <<< "$JSON") || return
    log_debug "FILE_URL: $FILE_URL"

    # Get FILE_NAME
    FILE_NAME=$(parse_json 'name' <<< "$JSON") || return
    log_debug "FILE_NAME: $FILE_NAME"

    echo "$FILE_URL"
    echo "$FILE_NAME"
}

# Static function. Check if specified folder name is valid.
# If folder not found then create it. Support subfolders.
# $1: folder name selected by user
# $2: API URL
# $3: API Data
# stdout: folder data
openload_check_folder() {
    local -r NAME=$1
    local -r API_URL=$2
    local -r API_DATA=$3
    local FOLDER_NAMES FOLDER JSON FOLDER_DATA
    local FOLDER_ID FOLDER_LIST FOLDER_LINE PARENT_ID

    # Only backslashes in a folder name cause problems.
    if match '\\' "$NAME"; then
        log_error 'Folder should not contains backslash characters: \\'
        return $ERR_FATAL
    fi

    # Convert subfolders names into an array.
    IFS='/' read -ra FOLDER_NAMES <<< "$NAME"

    for FOLDER in "${FOLDER_NAMES[@]}"; do
        # Skip empty names.
        [ -z "$FOLDER" ] && continue

        # Get folders for the current FOLDER_ID.
        JSON=$(curl $API_DATA $FOLDER_DATA "$API_URL/file/listfolder") || return

        # {"status":200,"msg":"OK","result":{"folders": ...}}
        openload_status "$JSON" || return

        # Grab only folder names with their ids and insert a newline between them.
        FOLDER_LIST=$(parse . '"folders":\(\[.*\]\),"files"' <<< "$JSON" \
            | replace_all '"},' '"},'$'\n') || return

        # Find a folder name with its id.
        FOLDER_ID=''
        while read -r FOLDER_LINE; do
            if [ "$FOLDER" == "$(parse_json_quiet 'name' <<< "$FOLDER_LINE")" ]; then
                FOLDER_ID="$(parse_json_quiet 'id' <<< "$FOLDER_LINE")"
                log_debug "Successfully found: '$FOLDER' with ID '$FOLDER_ID'"
                break
            fi
        done <<< "$FOLDER_LIST"

        # If a folder name was not found then create it.
        if [ -z "$FOLDER_ID" ]; then
            log_error "API doesn't have function to create a folder."
            log_error "Could not found a folder: '$FOLDER'."
            return $ERR_FATAL
        fi

        # Perverse data for the next loop.
        FOLDER_DATA="-d folder=$FOLDER_ID"
        PARENT_ID="$FOLDER_ID"
    done

    log_debug "FOLDER ID: '$FOLDER_ID'"
    echo $FOLDER_DATA
}

# Upload a file to openload
# $1: cookie file (unused)
# $2: input file (with full path)
# $3: remote filename
# stdout: download link
openload_upload() {
    local -r FILE=$2
    local -r DESTFILE=$3
    local -r API_URL='https://api.openload.co/1'
    local MAX_SIZE MSG SIZE SHA1_DATA AA ACCOUNT
    local API_DATA FOLDER_DATA UPLOAD_URL JSON

    # Sanity checks
    if [ -z "$AUTH" ]; then
        if [ -n "$FOLDER" ]; then
            log_error 'You must be registered to use folders.'
            return $ERR_LINK_NEED_PERMISSIONS

        elif match_remote_url "$FILE"; then
            log_error 'You must be registered to do remote uploads.'
            return $ERR_LINK_NEED_PERMISSIONS

        elif [ -n "$HEADER" ]; then
            log_error 'You must be registered to use header for remote link.'
            return $ERR_LINK_NEED_PERMISSIONS
        fi
    fi

    if [ -n "$ASYNC" ]; then
        if ! match_remote_url "$FILE"; then
            log_error 'Cannot upload local files asynchronously.'
            return $ERR_BAD_COMMAND_LINE
        fi
    fi

    # File size check, compute sha1 sum.
    if ! match_remote_url "$FILE"; then
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

        # If appropriate API version is available then compute sha1 sum.
        if [ $PLOWSHARE_API_VERSION -ge 4 ]; then
            SHA1_DATA=$(sha1_file "$FILE") || return
            SHA1_DATA="-d sha1=$SHA1_DATA"
        fi
    fi

    if [ -n "$AUTH" ]; then
        AA=$(openload_login "$AUTH" "$API_URL") || return
        { read ACCOUNT; read API_DATA; } <<< "$AA"

        if [ -n "$FOLDER" ]; then
            FOLDER_DATA=$(openload_check_folder "$FOLDER" \
                "$API_URL" "$API_DATA") || return
        fi
    fi

    # Upload local file
    if ! match_remote_url "$FILE"; then
        # Note: Anonymous and free accounts uploading are the same. They only differ
        #       in absence of $API_DATA and $FOLDER_DATA.
        UPLOAD_URL=$(curl $API_DATA $FOLDER_DATA $SHA1_DATA "$API_URL/file/ul" \
            | parse_json 'url') || return

        JSON=$(curl_with_log \
            -F "file1=@$FILE;filename=$DESTFILE" \
            "$UPLOAD_URL") || return

        # {"status":200,"msg":"OK","result":{"name": ...}}
        openload_status "$JSON" || return

        parse_json 'url' <<< "$JSON" || return

    # Upload remote file
    else
        local HEADER_DATA FILE_ID TRY STATUS BYTES_LOADED BYTES_TOTAL

        # Header data don't have to be send, but I need to enclose it in double quotes
        # in curl command, otherwise it won't work. Here is just empty dummy header.
        HEADER_DATA="-d headers="

        if [ -n "$HEADER" ]; then
            # Header entries must be separated by newline
            HEADER_DATA="$(IFS=$'\n'; echo "${HEADER[*]}")"
            HEADER_DATA="-d headers=$HEADER_DATA"
        fi

        # Add remote upload to queue
        JSON=$(curl $API_DATA $FOLDER_DATA "$HEADER_DATA" \
            -d "url=$FILE" "$API_URL/remotedl/add") || return

        # {"status":200,"msg":"OK","result":{"id": ...}}
        openload_status "$JSON" || return

        # If this is an async upload, we are done
        if [ -n "$ASYNC" ]; then
            log_error 'Once remote upload completed, check your account for link.'
            return $ERR_ASYNC_REQUEST
        fi

        FILE_ID=$(parse_json 'id' <<< "$JSON") || return

        # Keep checking progress, arbitrary 10000 times if not finished.
        TRY=0
        while (( TRY++ < 10000 )); do
            JSON=$(curl $API_DATA "$API_URL/remotedl/status" \
                -d 'limit=1' -d "id=$FILE_ID") || return
            JSON=$(parse . '"result":\({.*}\)' <<< "$JSON") || return
            STATUS=$(parse_json 'status' <<< "$JSON") || return

            if [ "$STATUS" == 'new' -o "$STATUS" == 'downloading' ]; then
                log_debug "Wait for server to download the file... [$TRY]"
                BYTES_LOADED=$(parse_json_quiet 'bytes_loaded' <<< "$JSON")
                BYTES_TOTAL=$(parse_json_quiet 'bytes_total' <<< "$JSON")
                if [[ $BYTES_LOADED =~ ^[0-9]+$ && $BYTES_TOTAL =~ ^[0-9]+$ ]]; then
                    log_debug "Downloaded $(( BYTES_LOADED * 100 / BYTES_TOTAL ))% : $BYTES_LOADED / $BYTES_TOTAL bytes"
                fi
                wait 15 || return # arbitrary, short wait time
            elif [ "$STATUS" == 'finished' ]; then
                parse_json 'url' <<< "$JSON" || return
                break
            else
                log_error "Unexpected status: $STATUS"
                return $ERR_FATAL
            fi
        done
    fi
}

# Probe a download URL
# $1: cookie file (unused here)
# $2: openload url
# $3: requested capability list
# stdout: 1 capability per line
openload_probe() {
    local URL=$2
    local -r REQ_IN=$3
    local -r BASE_URL='https://openload.co'
    local FILE_ID PAGE REQ_OUT FILE_SIZE

    FILE_ID=$(parse_quiet . 'f/\([[:alnum:]]*\)' <<< "$URL")
    if [ -n "$FILE_ID" ] && [ "$FILE_ID" != "$BASE_URL" ]; then
        URL="$BASE_URL/f/$FILE_ID"
    fi

    PAGE=$(curl "$URL") || return

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

    if [[ $REQ_IN = *v* ]]; then
        echo "$URL"
        REQ_OUT="${REQ_OUT}v"
    fi

    echo $REQ_OUT
}

# Plowshare uploadrocket.net module
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

MODULE_UPLOADROCKET_REGEXP_URL='https\?://\(www\.\)\?uploadrocket\.net/'

MODULE_UPLOADROCKET_DOWNLOAD_OPTIONS="
AUTH,a,auth,a=USER:PASSWORD,User account
LINK_PASSWORD,p,link-password,S=PASSWORD,Used in password-protected files"
MODULE_UPLOADROCKET_DOWNLOAD_RESUME=yes
MODULE_UPLOADROCKET_DOWNLOAD_FINAL_LINK_NEEDS_COOKIE=no
MODULE_UPLOADROCKET_DOWNLOAD_SUCCESSIVE_INTERVAL=

MODULE_UPLOADROCKET_UPLOAD_OPTIONS="
AUTH,a,auth,a=USER:PASSWORD,User account
LINK_PASSWORD,p,link-password,S=PASSWORD,Protect a link with a password
FOLDER,,folder,s=FOLDER,Folder to upload files into (support subfolders)
DESCRIPTION,d,description,S=DESCRIPTION,Set file description
TOEMAIL,,email-to,e=EMAIL,<To> field for notification email
PREMIUM_FILE,,premium,,Make file inaccessible to non-premium users
PUBLISH_FILE,,publish,,Mark file to be published
PROXY,,proxy,s=PROXY,Proxy for a remote link"
MODULE_UPLOADROCKET_UPLOAD_REMOTE_SUPPORT=yes

MODULE_UPLOADROCKET_DELETE_OPTIONS=""
MODULE_UPLOADROCKET_PROBE_OPTIONS=""

# Switch language to english
# $1: cookie file
# $2: base URL
uploadrocket_switch_lang() {
    curl "$2" -c "$1" -d 'op=change_lang' \
        -d 'lang=english' > /dev/null || return
}

# Static function. Proceed with login
# $1: authentication
# $2: cookie file
# $3: base URL
# stdout: account type ("free" or "premium") on success.
uploadrocket_login() {
    local -r AUTH=$1
    local -r COOKIE_FILE=$2
    local -r BASE_URL=$3
    local CV PAGE SESS MSG LOGIN_DATA STATUS NAME TYPE

    if CV=$(storage_get 'cookie_file'); then
        echo "$CV" >"$COOKIE_FILE"

        # Check for expired session.
        PAGE=$(curl -b "$COOKIE_FILE" "$BASE_URL/?op=my_account") || return
        if ! match '>Username:<' "$PAGE"; then
            storage_set 'cookie_file'
            return $ERR_EXPIRED_SESSION
        fi

        SESS=$(parse_cookie 'xfss' < "$COOKIE_FILE")
        log_debug "session (cached): '$SESS'"
        MSG='reused login for'
    else
        LOGIN_DATA='op=login&redirect=my_account&login=$USER&password=$PASSWORD'

        PAGE=$(post_login "$AUTH" "$COOKIE_FILE" "$LOGIN_DATA" \
            "$BASE_URL" -L -b "$COOKIE_FILE") || return

        # If successful, two entries are added into cookie file: login and xfss.
        STATUS=$(parse_cookie_quiet 'xfss' < "$COOKIE_FILE")
        [ -z "$STATUS" ] && return $ERR_LOGIN_FAILED

        storage_set 'cookie_file' "$(cat "$COOKIE_FILE")"

        SESS=$(parse_cookie 'xfss' < "$COOKIE_FILE")
        log_debug "session (new): '$SESS'"
        MSG='logged in as'
    fi

    NAME=$(parse_cookie_quiet 'login' < "$COOKIE_FILE")

    if match '>Upgrade to premium<' "$PAGE"; then
        TYPE='free'
    else
        TYPE='premium'
    fi

    log_debug "Successfully $MSG '$TYPE' member '$NAME'"
    echo $TYPE
}

# Output a uploadrocket file download URL
# $1: cookie file
# $2: uploadrocket url
# stdout: real file download link
uploadrocket_download() {
    local -r COOKIE_FILE=$1
    local -r BASE_URL='http://uploadrocket.net'
    local URL ACCOUNT PAGE PASSWORD_DATA ERR FORM_HTML FORM_OP FORM_USR
    local FORM_ID FORM_REF FORM_METHOD_F FORM_METHOD_P FORM_RAND FORM_DS

    # Get a canonical URL for this file.
    URL=$(curl -I "$2" | grep_http_header_location_quiet) || return
    [ -n "$URL" ] || URL=$2
    readonly URL

    uploadrocket_switch_lang "$COOKIE_FILE" "$BASE_URL"

    if [ -n "$AUTH" ]; then
        ACCOUNT=$(uploadrocket_login "$AUTH" "$COOKIE_FILE" "$BASE_URL") || return
    fi

    PAGE=$(curl -b "$COOKIE_FILE" -c "$COOKIE_FILE" "$URL" \
        | strip_html_comments) || return

    if match '>\(File Not Found\|No such file with this filename\|The file was removed by administrator\)<' "$PAGE"; then
        return $ERR_LINK_DEAD
    fi

    FORM_HTML=$(grep_form_by_id "$PAGE" 'ID_freeorpremium') || return
    FORM_OP=$(parse_form_input_by_name 'op' <<< "$FORM_HTML") || return
    FORM_USR=$(parse_form_input_by_name_quiet 'usr_login' <<< "$FORM_HTML")
    FORM_ID=$(parse_form_input_by_name_quiet 'id' <<< "$FORM_HTML") || return
    FORM_REF=$(parse_form_input_by_name_quiet 'referer' <<< "$FORM_HTML")
    FORM_METHOD_F=$(parse_form_input_by_name_quiet 'method_isfree' <<< "$FORM_HTML")

    if [ -z "$FORM_ID" ]; then
        return $ERR_LINK_DEAD
    fi

    PAGE=$(curl -b "$COOKIE_FILE" \
        -d "op=$FORM_OP" \
        -d "usr_login=$FORM_USR" \
        -d "id=$FORM_ID" \
        -d "referer=$FORM_REF" \
        --data-urlencode "method_isfree=$FORM_METHOD_F" \
        "$URL") || return

    # Check for premium only files.
    if match '>This file is available for Premium Users only' "$PAGE"; then
        log_error 'This file is available for Premium Users only.'
        return $ERR_LINK_NEED_PERMISSIONS

    # Check for files that need a password.
    elif match 'Password:.*name="password"' "$PAGE"; then
        log_debug 'File is password protected.'

        if [ -z "$LINK_PASSWORD" ]; then
            LINK_PASSWORD=$(prompt_for_password) || return
        fi

        PASSWORD_DATA="-d password=$(replace_all ' ' '+' <<< "$LINK_PASSWORD")"
    fi

    FORM_HTML=$(grep_form_by_id "$PAGE" 'ID_F1') || return
    FORM_OP=$(parse_form_input_by_name 'op' <<< "$FORM_HTML") || return
    FORM_ID=$(parse_form_input_by_name 'id' <<< "$FORM_HTML") || return
    FORM_RAND=$(parse_form_input_by_name 'rand' <<< "$FORM_HTML") || return
    FORM_REF=$(parse_form_input_by_name_quiet 'referer' <<< "$FORM_HTML")
    FORM_METHOD_F=$(parse_form_input_by_name_quiet 'method_isfree' <<< "$FORM_HTML")
    FORM_METHOD_P=$(parse_form_input_by_name_quiet 'method_ispremium' <<< "$FORM_HTML")
    FORM_DS=$(parse_form_input_by_name_quiet 'down_script' <<< "$FORM_HTML")

    local PUBKEY RESP CHALLENGE ID
    PUBKEY='mC2C7c.3-sHSuvEpXYQrUJ-TQy3PH2ET'
    RESP=$(solvemedia_captcha_process $PUBKEY) || return
    { read CHALLENGE; read ID; } <<< "$RESP"

    PAGE=$(curl -b "$COOKIE_FILE" \
        -d "op=$FORM_OP" \
        -d "id=$FORM_ID" \
        -d "rand=$FORM_RAND" \
        -d "referer=$FORM_REF" \
        $PASSWORD_DATA \
        --data-urlencode "method_isfree=$FORM_METHOD_F" \
        --data-urlencode "method_ispremium=$FORM_METHOD_P" \
        --data-urlencode 'adcopy_response=manual_challenge' \
        --data-urlencode "adcopy_challenge=$CHALLENGE" \
        -d "down_script=$FORM_DS" \
        "$URL") || return

    ERR=$(parse_quiet '<div class="err">' '^\(.*\)$' 1 <<< "$PAGE" | strip)

    if [ -n "$ERR" ]; then
        if [ "$ERR" = 'Wrong captcha' ]; then
            captcha_nack $ID
            log_error 'Wrong captcha'
            return $ERR_CAPTCHA

        elif [ "$ERR" = 'Wrong password' ]; then
            log_error 'Wrong password'
            return $ERR_LINK_PASSWORD_REQUIRED
        fi

        log_error "Unexpected error: $ERR"
        return $ERR_FATAL
    fi

    captcha_ack $ID
    log_debug 'Correct captcha'

    parse_attr 'Direct Download Link' 'href' <<< "$PAGE" || return
}

# Static function. Check if specified folder name is valid.
# If folder not found then create it. Support subfolders.
# $1: folder name selected by user
# $2: cookie file (logged into account)
# $3: base URL
# stdout: folder id
uploadrocket_check_folder() {
    local -r NAME=$1
    local -r COOKIE_FILE=$2
    local -r BASE_URL=$3
    local -r API_URL=$4
    local -r API_DATA=$5
    local FOLDER_NAMES FOLDER PAGE FOLDER_ID
    local FORM_HTML FORM_OP FORM_TOKEN FORM_FLD_ID FORM_KEY

    # The following characters cannot be used with parse.
    if match '["\\\[\]<>]' "$NAME"; then
        log_error 'Folder name should not contain the following characters: "\\\[\]<>'
        return $ERR_FATAL
    fi

    # Convert subfolders names into an array.
    IFS='/' read -ra FOLDER_NAMES <<< "$NAME"

    FOLDER_ID=0

    for FOLDER in "${FOLDER_NAMES[@]}"; do
        # Skip empty names.
        [ -z "$FOLDER" ] && continue

        PAGE=$(curl -b "$COOKIE_FILE" "$BASE_URL/?op=my_files&fld_id=$FOLDER_ID") || return
        FOLDER_ID=$(parse_quiet . 'fld_id=\([^"]\+\)".*>'"$FOLDER"'<' <<< "$PAGE")

        # Create new folder.
        if [ -z "$FOLDER_ID" ]; then
            FORM_HTML=$(grep_form_by_name "$PAGE" 'F1') || return
            FORM_OP=$(parse_form_input_by_name 'op' <<< "$FORM_HTML") || return
            FORM_TOKEN=$(parse_form_input_by_name 'token' <<< "$FORM_HTML") || return
            FORM_FLD_ID=$(parse_form_input_by_name 'fld_id' <<< "$FORM_HTML") || return
            FORM_KEY=$(parse_form_input_by_name_quiet 'key' <<< "$FORM_HTML")

            PAGE=$(curl -b "$COOKIE_FILE" \
                -d "op=$FORM_OP" \
                -d "token=$FORM_TOKEN" \
                -d "fld_id=$FORM_FLD_ID" \
                -d "key=$FORM_KEY" \
                -d "create_new_folder=$FOLDER" \
                -d 'to_folder=' \
                -L "$BASE_URL") || return

            FOLDER_ID=$(parse . 'fld_id=\([^"]\+\)".*>'"$FOLDER"'<' <<< "$PAGE") || return
            log_debug "Successfully created: '$FOLDER' with ID '$FOLDER_ID'"
        else
            log_debug "Successfully found: '$FOLDER' with ID '$FOLDER_ID'"
        fi
    done

    log_debug "FOLDER ID: '$FOLDER_ID'"
    echo $FOLDER_ID
}

# Upload a file to uploadrocket
# $1: cookie file
# $2: input file (with full path)
# $3: remote filename
# stdout: download link + delete link
uploadrocket_upload() {
    local -r COOKIE_FILE=$1
    local -r FILE=$2
    local -r DESTFILE=$3
    local -r BASE_URL='http://uploadrocket.net'
    local MAX_SIZE MSG SIZE ACCOUNT FOLDER_ID PAGE USER_TYPE UPLOAD_ID

    # Sanity checks
    if [ -z "$AUTH" ]; then
        if [ -n "$FOLDER" ]; then
            log_error 'You must be registered to use folders.'
            return $ERR_LINK_NEED_PERMISSIONS

        elif match_remote_url "$FILE"; then
            log_error 'You must be registered to do remote uploads.'
            return $ERR_LINK_NEED_PERMISSIONS

        elif [ -n "$PREMIUM_FILE" ]; then
            log_error 'You must be registered to mark premium file.'
            return $ERR_LINK_NEED_PERMISSIONS

        elif [ -n "$PUBLISH_FILE" ]; then
            log_error 'You must be registered to mark publish file.'
            return $ERR_LINK_NEED_PERMISSIONS
        fi
    fi

    if match_remote_url "$FILE"; then
        if [ -n "$DESCRIPTION" ]; then
            log_error 'You cannot set description for remote link.'
            return $ERR_LINK_NEED_PERMISSIONS
        fi
    else
        if [ -n "$PROXY" ]; then
            log_error 'You can use proxy only with remote link.'
            return $ERR_LINK_NEED_PERMISSIONS
        fi
    fi

    # File size check.
    if ! match_remote_url "$FILE"; then
        # Note: Max upload file size for anonymous is limited to 2000 MiB,
        #       for 'free' and 'premium' accounts is limited to 6144 MiB.
        if [ -n "$AUTH" ]; then
            MAX_SIZE=6442450944 # 6144 MiB
            MSG='registered'
        else
            MAX_SIZE=2097152000 # 2000 MiB
            MSG='anonymous'
        fi

        SIZE=$(get_filesize "$FILE")
        if [ $SIZE -gt $MAX_SIZE ]; then
            log_debug "File is bigger than $MAX_SIZE for $MSG user."
            return $ERR_SIZE_LIMIT_EXCEEDED
        fi
    fi

    uploadrocket_switch_lang "$COOKIE_FILE" "$BASE_URL"

    if [ -n "$AUTH" ]; then
        ACCOUNT=$(uploadrocket_login "$AUTH" "$COOKIE_FILE" "$BASE_URL") || return

        if [ -n "$FOLDER" ]; then
            FOLDER_ID=$(uploadrocket_check_folder "$FOLDER" "$COOKIE_FILE" \
                "$BASE_URL") || return
        fi
    fi

    PAGE=$(curl -b "$COOKIE_FILE" "$BASE_URL") || return

    # "reg"
    USER_TYPE=$(parse 'var utype' "='\([^']*\)" <<< "$PAGE") || return
    log_debug "User type: '$USER_TYPE'"

    UPLOAD_ID=$(random dec 12) || return

    local FORM_HTML FORM_ACTION FORM_SESS FORM_UTYPE FORM_SRV_TMP FORM_BUTTON FORM_TOS
    local FORM_FN FORM_ST FORM_OP TOEMAIL_DATA FILE_URL FILE_DEL_URL FILE_ID RND

    # Upload local file
    if ! match_remote_url "$FILE"; then
        FORM_HTML=$(grep_form_by_name "$PAGE" 'file') || return
        FORM_ACTION=$(parse_form_action <<< "$FORM_HTML") || return
        FORM_SESS=$(parse_form_input_by_name_quiet 'sess_id' <<< "$FORM_HTML")
        FORM_UTYPE=$(parse_form_input_by_name 'upload_type' <<< "$FORM_HTML") || return
        FORM_SRV_TMP=$(parse_form_input_by_name 'srv_tmp_url' <<< "$FORM_HTML") || return
        FORM_BUTTON=$(parse_form_input_by_name 'submit_btn' <<< "$FORM_HTML") || return

        PAGE=$(curl_with_log \
            -F "upload_type=$FORM_UTYPE" \
            -F "sess_id=$FORM_SESS" \
            -F "srv_tmp_url=$FORM_SRV_TMP" \
            -F 'file_0=;filename=' \
            -F "file_0=@$FILE;filename=$DESTFILE" \
            --form-string "file_0_descr=$DESCRIPTION" \
            --form-string "link_rcpt=$TOEMAIL" \
            --form-string "link_pass=$LINK_PASSWORD" \
            -F "to_folder=$FOLDER_ID" \
            -F 'file_1=;filename=' \
            --form-string "submit_btn=$FORM_BUTTON" \
            "${FORM_ACTION}${UPLOAD_ID}&js_on=1&utype=${USER_TYPE}&upload_type=${FORM_UTYPE}" \
            | break_html_lines) || return

    # Upload remote file
    else
        FORM_HTML=$(grep_form_by_name "$PAGE" 'url') || return
        FORM_ACTION=$(parse_form_action <<< "$FORM_HTML") || return
        FORM_SESS=$(parse_form_input_by_name_quiet 'sess_id' <<< "$FORM_HTML")
        FORM_UTYPE=$(parse_form_input_by_name 'upload_type' <<< "$FORM_HTML") || return
        FORM_SRV_TMP=$(parse_form_input_by_name 'srv_tmp_url' <<< "$FORM_HTML") || return
        FORM_TOS=$(parse_form_input_by_name 'tos' <<< "$FORM_HTML") || return
        FORM_BUTTON=$(parse_form_input_by_name 'submit_btn' <<< "$FORM_HTML") || return

        # Note: We cannot force curl to send a POST and not wait for a response,
        #       so asynchronous uploads are not possible.
        PAGE=$(curl \
            -F "sess_id=$FORM_SESS" \
            -F "upload_type=$FORM_UTYPE" \
            -F "srv_tmp_url=$FORM_SRV_TMP" \
            -F "url_mass=$FILE" \
            --form-string "url_proxy=$PROXY" \
            --form-string "link_rcpt=$TOEMAIL" \
            --form-string "link_pass=$LINK_PASSWORD" \
            -F "to_folder=$FOLDER_ID" \
            -F 'tos=1' \
            --form-string "submit_btn=$FORM_BUTTON" \
            "${FORM_ACTION}${UPLOAD_ID}&js_on=1&utype=${USER_TYPE}&upload_type=${FORM_UTYPE}" \
            | break_html_lines) || return
    fi

    # Note: The following code is the same for local and remote uploads.
    FORM_ACTION=$(parse_form_action <<< "$PAGE") || return
    FORM_FN=$(parse_tag "name='fn'" textarea <<< "$PAGE") || return
    FORM_ST=$(parse_tag "name='st'" textarea <<< "$PAGE") || return
    FORM_OP=$(parse_tag "name='op'" textarea <<< "$PAGE") || return
    [ -n "$TOEMAIL" ] && TOEMAIL_DATA="-d link_rcpt=$TOEMAIL"

    if [ "$FORM_ST" != 'OK' ]; then
        log_error "Unexpected status: $FORM_ST"
        return $ERR_FATAL
    fi

    PAGE=$(curl \
        -d "fn=$FORM_FN" \
        -d "st=$FORM_ST" \
        -d "op=$FORM_OP" \
        $TOEMAIL_DATA \
        "$FORM_ACTION") || return

    FILE_URL=$(parse_tag 'id="ic0-"' textarea <<< "$PAGE") || return
    FILE_DEL_URL=$(parse_tag 'id="ic3-"' textarea <<< "$PAGE") || return

    # Note: Set premium and publish flag after uploading a file.
    if [ -n "$PREMIUM_FILE" -o -n "$PUBLISH_FILE" ]; then

        PAGE=$(curl -b "$COOKIE_FILE" "$BASE_URL/?op=my_files&fld_id=$FOLDER_ID") || return
        FILE_ID=$(parse "$FILE_URL" 'value="\(.*\)"' -1 <<< "$PAGE") || return

        if [ -n "$PREMIUM_FILE" ]; then
            log_debug 'Setting premium flag...'

            RND=$(random js) || return
            PAGE=$(curl -b "$COOKIE_FILE" \
                "$BASE_URL/?op=my_files&file_id=$FILE_ID&set_premium_only=true&rnd=$RND") || return

            if ! match "className='pub'" "$PAGE"; then
                log_error 'Could not set premium flag.'
            fi
        fi

        if [ -n "$PUBLISH_FILE" ]; then
            log_debug 'Setting publish flag...'

            RND=$(random js) || return
            PAGE=$(curl -b "$COOKIE_FILE" \
                "$BASE_URL/?op=my_files&file_id=$FILE_ID&set_public=true&rnd=$RND") || return

            if ! match "className='pub'" "$PAGE"; then
                log_error 'Could not set publish flag.'
            fi
        fi
    fi

    echo "$FILE_URL"
    echo "$FILE_DEL_URL"
}

# Delete a file uploaded to uploadrocket
# $1: cookie file (unused here)
# $2: delete url
uploadrocket_delete() {
    local -r URL=$2
    local -r BASE_URL='http://uploadrocket.net'
    local FILE_ID FILE_DEL_ID PAGE

    FILE_ID=$(parse . "^$BASE_URL/\([[:alnum:]]\+\)" <<< "$URL") || return
    FILE_DEL_ID=$(parse . 'killcode=\([[:alnum:]]\+\)$' <<< "$URL") || return

    PAGE=$(curl -b 'lang=english' -e "$URL" \
        -d "op=del_file" \
        -d "id=$FILE_ID" \
        -d "del_id=$FILE_DEL_ID" \
        -d "confirm=yes" \
        "$BASE_URL") || return

    if match 'File deleted successfully' "$PAGE"; then
        return 0
    elif match 'No such file exist' "$PAGE"; then
        return $ERR_LINK_DEAD
    elif match 'Wrong Delete ID' "$PAGE"; then
        log_error 'Wrong delete ID'
    fi

    return $ERR_FATAL
}

# Probe a download URL
# $1: cookie file (unused here)
# $2: uploadrocket url
# $3: requested capability list
# stdout: 1 capability per line
uploadrocket_probe() {
    local -r URL=$2
    local -r REQ_IN=$3
    local -r BASE_URL='http://uploadrocket.net'
    local PAGE FILE_SIZE REQ_OUT

    # Check a file through a link checker.
    PAGE=$(curl -b 'lang=english' \
        -d 'op=checkfiles' \
        -d "list=$URL" \
        -d 'process=Check URLs' \
        "$BASE_URL/?op=checkfiles") || return

    if match '>Not found!<' "$PAGE"; then
        return $ERR_LINK_DEAD

    elif match ">Filename don't match!<" "$PAGE"; then
        log_error "Filename don't match!"
        return $ERR_FATAL
    fi

    REQ_OUT=c

    if [[ $REQ_IN = *f* ]]; then
        parse_quiet . '/[[:alnum:]]\+/\([^/]*\)' <<< "$URL" \
            | replace '.html' '' | replace '.htm' '' \
            && REQ_OUT="${REQ_OUT}f"
    fi

    if [[ $REQ_IN = *s* ]]; then
        FILE_SIZE=$(parse . '>Found</td><td>\([^<]*\)' <<< "$PAGE") \
            && FILE_SIZE=$(replace 'B' 'iB' <<< $FILE_SIZE) \
            && translate_size "$FILE_SIZE" && REQ_OUT="${REQ_OUT}s"
    fi

    if [[ $REQ_IN = *i* ]]; then
        parse . 'net/\([[:alnum:]]\+\)' <<< "$URL" && REQ_OUT="${REQ_OUT}i"
    fi

    echo $REQ_OUT
}

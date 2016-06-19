# Plowshare Rockfile.eu module
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

MODULE_ROCKFILE_EU_REGEXP_URL='https\?://\(www\.\)\?rockfile\.eu/'

MODULE_ROCKFILE_EU_UPLOAD_OPTIONS="
AUTH,a,auth,a=USER:PASSWORD,User account (mandatory)
LINK_PASSWORD,p,link-password,S=PASSWORD,Protect a link with a password
FOLDER,,folder,s=FOLDER,Folder to upload files into (support subfolders)
DESCRIPTION,d,description,S=DESCRIPTION,Set file description
TOEMAIL,,email-to,e=EMAIL,<To> field for notification email
PREMIUM_FILE,,premium,,Make file inaccessible to non-premium users
PUBLISH_FILE,,publish,,Mark file to be published
PROXY,,proxy,s=PROXY,Proxy for a remote link"
MODULE_ROCKFILE_EU_UPLOAD_REMOTE_SUPPORT=yes

# Static function. Check for and handle "DDoS protection"
# $1: full content of initial page
# $2: cookie file
# $3: url (base url or file url)
rockfile_eu_cloudflare() {
    local PAGE=$1
    local -r COOKIE_FILE=$2
    local -r BASE_URL="$(basename_url "$3")"

    # check for DDoS protection
    # <title>Just a moment...</title>
    if [[ $(parse_tag 'title' <<< "$PAGE") = *Just\ a\ moment* ]]; then
        local TRY FORM_HTML FORM_VC FORM_PASS FORM_ANSWER JS

        detect_javascript || return

        # Note: We may not pass DDoS protection for the first time.
        #       Limit loop to max 5.
        TRY=0
        while (( TRY++ < 5 )); do
            log_debug "CloudFlare DDoS protection found - try $TRY"

            wait 5 || return

            FORM_HTML=$(grep_form_by_id "$PAGE" 'challenge-form') || return
            FORM_VC=$(parse_form_input_by_name 'jschl_vc' <<< "$FORM_HTML") || return
            FORM_PASS=$(parse_form_input_by_name 'pass' <<< "$FORM_HTML") || return

            # Obfuscated javascript code
            JS=$(grep_script_by_order "$PAGE") || return
            JS=${JS#*<script type=\"text/javascript\">}
            JS=${JS%*</script>}

            FORM_ANSWER=$(echo "
                function a_obj() {
                    this.style = new Object();
                    this.style.display = new Object();
                };
                function form_obj() {
                    this.submit = function () {
                        return;
                    }
                };
                function href_obj() {
                    this.firstChild = new Object();
                    this.firstChild.href = '$BASE_URL/';
                };
                var elts = new Array();
                var document = {
                    attachEvent: function(name,value) {
                        return value();
                    },
                    createElement: function(id) {
                        return new href_obj();
                    },
                    getElementById: function(id) {
                        if (! elts[id] && id == 'cf-content') {
                            elts[id] = new a_obj();
                        }
                        if (! elts[id] && id == 'challenge-form') {
                            elts[id] = new form_obj();
                        }
                        if (! elts[id]) {
                            elts[id] = {};
                        }
                        return elts[id];
                    }
                };
                var final_fun;
                function setTimeout(value,time) {
                    final_fun = value;
                };
                $JS
                final_fun();
                if (typeof console === 'object' && typeof console.log === 'function') {
                    console.log(elts['jschl-answer'].value);
                } else {
                    print(elts['jschl-answer'].value);
                }" | javascript) || return

                # Set-Cookie: cf_clearance
                PAGE=$(curl -L -b "$COOKIE_FILE" -c "$COOKIE_FILE" \
                    "$BASE_URL/cdn-cgi/l/chk_jschl?jschl_vc=$FORM_VC&pass=$FORM_PASS&jschl_answer=$FORM_ANSWER") || return

                if [[ $(parse_tag 'title' <<< "$PAGE") != *Just\ a\ moment* ]]; then
                    break
                fi
            done
        fi
}

# Switch language to english
# $1: cookie file
# $2: base URL
rockfile_eu_switch_lang() {
    # Set-Cookie: lang
    curl "$2" -b "$1" -c "$1" -d 'op=change_lang' \
        -d 'lang=english' > /dev/null || return
}

# Static function. Proceed with login
# $1: authentication
# $2: cookie file
# $3: base URL
# stdout: account type ("free" or "premium") on success.
rockfile_eu_login() {
    local -r AUTH=$1
    local -r COOKIE_FILE=$2
    local -r BASE_URL=$3
    local CV PAGE SESS MSG LOGIN_DATA STATUS NAME TYPE

    if CV=$(storage_get 'cookie_file'); then
        echo "$CV" >"$COOKIE_FILE"

        # Check for expired session.
        PAGE=$(curl -b "$COOKIE_FILE" "$BASE_URL/account") || return
        if ! match '>Used space:<' "$PAGE"; then
            storage_set 'cookie_file'
            return $ERR_EXPIRED_SESSION
        fi

        SESS=$(parse_cookie 'xfss' < "$COOKIE_FILE")
        log_debug "session (cached): '$SESS'"
        MSG='reused login for'
    else
        PAGE=$(curl -c "$COOKIE_FILE" "$BASE_URL") || return
        rockfile_eu_cloudflare "$PAGE" "$COOKIE_FILE" "$BASE_URL" || return
        rockfile_eu_switch_lang "$COOKIE_FILE" "$BASE_URL" || return

        LOGIN_DATA='op=login&redirect=account&login=$USER&password=$PASSWORD'

        PAGE=$(post_login "$AUTH" "$COOKIE_FILE" "$LOGIN_DATA" \
            "$BASE_URL" -L -b "$COOKIE_FILE") || return

        # If successful Set-Cookie: login xfss
        STATUS=$(parse_cookie_quiet 'xfss' < "$COOKIE_FILE")
        [ -z "$STATUS" ] && return $ERR_LOGIN_FAILED

        storage_set 'cookie_file' "$(cat "$COOKIE_FILE")"

        SESS=$(parse_cookie 'xfss' < "$COOKIE_FILE")
        log_debug "session (new): '$SESS'"
        MSG='logged in as'
    fi

    NAME=$(parse_cookie_quiet 'login' < "$COOKIE_FILE")

    if match 'Go premium<' "$PAGE"; then
        TYPE='free'
    else
        TYPE='premium'
    fi

    log_debug "Successfully $MSG '$TYPE' member '$NAME'"
    echo $TYPE
}

# Static function. Check if specified folder name is valid.
# If folder not found then create it. Support subfolders.
# $1: folder name selected by user
# $2: cookie file (logged into account)
# $3: base URL
# stdout: folder id
rockfile_eu_check_folder() {
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

# Upload a file to rockfile.eu
# $1: cookie file
# $2: input file (with full path)
# $3: remote filename
# stdout: download link + delete link
rockfile_eu_upload() {
    local -r COOKIE_FILE=$1
    local -r FILE=$2
    local -r DESTFILE=$3
    local -r BASE_URL='https://rockfile.eu'
    local ACCOUNT MAX_SIZE SIZE FOLDER_ID PAGE USER_TYPE UPLOAD_ID

    # User account is mandatory
    if [ -n "$AUTH" ]; then
        ACCOUNT=$(rockfile_eu_login "$AUTH" "$COOKIE_FILE" "$BASE_URL") || return
    else
        return $ERR_LINK_NEED_PERMISSIONS
    fi

    # Sanity checks
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

    # File size check
    if ! match_remote_url "$FILE"; then
        # Note: Max upload file size for 'free' users is limited to 2 GiB,
        #       for 'premium' accounts is limited to 6 GiB.
        if [ "$ACCOUNT" = 'free' ]; then
            MAX_SIZE=2147483648 # 2 GiB
        else
            MAX_SIZE=6442450944 # 6 MiB
        fi

        SIZE=$(get_filesize "$FILE")
        if [ $SIZE -gt $MAX_SIZE ]; then
            log_debug "File is bigger than $MAX_SIZE for $ACCOUNT user."
            return $ERR_SIZE_LIMIT_EXCEEDED
        fi
    fi

    # Choose a folder
    if [ -n "$FOLDER" ]; then
        FOLDER_ID=$(rockfile_eu_check_folder "$FOLDER" "$COOKIE_FILE" \
            "$BASE_URL") || return
    fi

    PAGE=$(curl -b "$COOKIE_FILE" "$BASE_URL/upload_files") || return

    # "reg"
    USER_TYPE=$(parse 'var utype' "='\([^']*\)" <<< "$PAGE") || return
    log_debug "User type: '$USER_TYPE'"

    UPLOAD_ID=$(random dec 12) || return

    local FORM_HTML FORM_ACTION FORM_SESS FORM_UTYPE FORM_SRV_TMP FORM_BUTTON FORM_TOS
    local FORM_FN FORM_ST FORM_OP TOEMAIL_DATA FILE_URL FILE_DEL_URL FILE_ID

    # Upload local file
    if ! match_remote_url "$FILE"; then
        FORM_HTML=$(grep_form_by_name "$PAGE" 'file') || return
        FORM_ACTION=$(parse_form_action <<< "$PAGE") || return
        FORM_UTYPE=$(parse_form_input_by_name 'upload_type' <<< "$PAGE") || return
        FORM_SESS=$(parse_form_input_by_name_quiet 'sess_id' <<< "$PAGE")
        FORM_SRV_TMP=$(parse_form_input_by_name 'srv_tmp_url' <<< "$PAGE") || return
        FORM_BUTTON=$(parse_form_input_by_name 'submit_btn' <<< "$PAGE") || return

        PAGE=$(curl_with_log \
            -F "upload_type=$FORM_UTYPE" \
            -F "sess_id=$FORM_SESS" \
            -F "srv_tmp_url=$FORM_TMP_SRV" \
            -F 'file_0=;filename=' \
            -F "file_0=@$FILE;filename=$DESTFILE" \
            --form-string "file_0_descr=$DESCRIPTION" \
            --form-string "link_rcpt=$TOEMAIL" \
            --form-string "link_pass=$LINK_PASSWORD" \
            -F "to_folder=$FOLDER_ID" \
            -F 'file_1=;filename=' \
            --form-string "submit_btn=$FORM_BUTTON" \
            "${FORM_ACTION}${UPLOAD_ID}&utype=${USER_TYPE}&js_on=1&upload_type=${FORM_UTYPE}" \
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

    PAGE=$(curl -b "$COOKIE_FILE" \
        -d "fn=$FORM_FN" \
        -d "st=$FORM_ST" \
        -d "op=$FORM_OP" \
        $TOEMAIL_DATA \
        "$FORM_ACTION") || return

    FILE_URL=$(parse '>Download Link<' '">\(.*\)$' 1 <<< "$PAGE") || return
    FILE_DEL_URL=$(parse '>Delete Link<' '">\(.*\)$' 1 <<< "$PAGE") || return

    # Note: Set premium and publish flag after uploading a file.
    if [ -n "$PREMIUM_FILE" -o -n "$PUBLISH_FILE" ]; then

        PAGE=$(curl -b "$COOKIE_FILE" "$BASE_URL/?op=my_files&fld_id=$FOLDER_ID") || return
        FILE_ID=$(parse "$FILE_URL" 'value="\(.*\)"' -1 <<< "$PAGE") || return

        if [ -n "$PREMIUM_FILE" ]; then
            log_debug 'Setting premium flag...'

            PAGE=$(curl -b "$COOKIE_FILE" \
                "$BASE_URL/?op=my_files&set_flag=file_premium_only&value=true&file_id\[\]=$FILE_ID") || return

            if ! match 'OK' "$PAGE"; then
                log_error 'Could not set premium flag.'
            fi
        fi

        if [ -n "$PUBLISH_FILE" ]; then
            log_debug 'Setting publish flag...'

            PAGE=$(curl -b "$COOKIE_FILE" \
                "$BASE_URL/?op=my_files&set_flag=file_public&value=true&file_id\[\]=$FILE_ID") || return

            if ! match 'OK' "$PAGE"; then
                log_error 'Could not set publish flag.'
            fi
        fi
    fi

    echo "$FILE_URL"
    echo "$FILE_DEL_URL"
}

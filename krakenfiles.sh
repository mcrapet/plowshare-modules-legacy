# Plowshare krakenfiles.com module
# Copyright (c) 2021 Plowshare team
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

MODULE_KRAKENFILES_REGEXP_URL='https://krakenfiles\.com/'

MODULE_KRAKENFILES_DOWNLOAD_OPTIONS=""
MODULE_KRAKENFILES_DOWNLOAD_RESUME=yes
MODULE_KRAKENFILES_DOWNLOAD_FINAL_LINK_NEEDS_COOKIE=no
MODULE_KRAKENFILES_DOWNLOAD_SUCCESSIVE_INTERVAL=

MODULE_KRAKENFILES_UPLOAD_OPTIONS=""
MODULE_KRAKENFILES_UPLOAD_REMOTE_SUPPORT=no

MODULE_KRAKENFILES_PROBE_OPTIONS=""

# Output an KrakenFiles.com file download URL
# $1: cookie file (unused here)
# $2: krakenfiles url
# stdout: real file download link
krakenfiles_download() {
    local -r COOKIE_FILE=$1
    local -r URL=$2
    local -r BASE_URL='https://krakenfiles.com'
    local PAGE FORM_HTML FORM_ACTION FORM_TOKEN HASH JSON STATUS

    PAGE=$(curl -b "$COOKIE_FILE" -c "$COOKIE_FILE" "$URL") || return

    # <img class="nk-error-gfx" src="/images/gfx/error-404.svg" alt="">
    # <h3 class="nk-error-title">Oops! Why you’re here?</h3>
    if match '="nk-error-title">' "$PAGE"; then
        return $ERR_LINK_DEAD
    fi

    FORM_HTML=$(grep_form_by_id "$PAGE" 'dl-form') || return
    FORM_ACTION=$(parse_form_action <<< "$FORM_HTML") || return
    FORM_TOKEN=$(parse_form_input_by_name 'token' <<< "$FORM_HTML") || return

    HASH=$(echo "$FORM_ACTION" | parse '' '.*/\([[:alnum:]]\+\)') || return
    log_debug "File ID: '$HASH'"

    JSON=$(curl -b "$COOKIE_FILE" \
        -H 'X-Requested-With: XMLHttpRequest' \
        -H "hash: $HASH" \
        -H "DNT: 1" \
        --referer "$URL" \
        -F "token=$FORM_TOKEN" \
        "$BASE_URL$FORM_ACTION") || return

    # {"status":"ok","url":"https:\/\/s3.krakenfiles.com\/force-download\/..."}

    STATUS=$(parse_json status <<< "$JSON") || return
    if [ "$STATUS" != 'ok' ]; then
        log_error "Unexpected status: $STATUS"
        return $ERR_FATAL
    fi

    echo $JSON | parse_json url || return
    echo "$PAGE" | parse_attr '=.og:title.' content
}

# Upload a file to KrakenFiles.com
# $1: cookie file (unused)
# $2: input file (with full path)
# $3: remote filename
# stdout: krakenfiles download link
krakenfiles_upload() {
    local -r COOKIE_FILE=$1
    local -r FILE=$2
    local -r DEST_FILE=$3
    local -r BASE_URL='https://krakenfiles.com'
    local PAGE SERVER MAX_SIZE CHUNK_SIZE JSON JSON2 FILE_URL STATUS
    local NUM_CHUNKS CHUNK OFFSET OFFSET_PREV TMP_FILE PART_FILE

    PAGE=$(curl "$BASE_URL") || return

    SERVER=$(parse '\s\+url:\s*"' ':\s*"\([^"]*\)"' <<< "$PAGE") || return
    log_debug "Upload server $SERVER"

    MAX_SIZE=$(parse . '\s\+maxFileSize:\s*\([[:digit:]]\+\),' <<< "$PAGE") || return

    local SZ=$(get_filesize "$FILE")
    if [ "$SZ" -gt "$MAX_SIZE" ]; then
        log_debug 'file is bigger than '$(( MAX_SIZE / 1048576 ))' MB'
        return $ERR_SIZE_LIMIT_EXCEEDED
    fi

    CHUNK_SIZE=$(parse . '\s\+maxChunkSize:\s*\([[:digit:]]\+\),' <<< "$PAGE") || return
    if [ "$SZ" -lt "$CHUNK_SIZE" ]; then

      # {"files":[{"name":"5MiB.bin","size":"5.00 MB","error":"","url":"\/view\/40zFezYgbD\/file.html","hash":"40zFezYgbD"}]}
      JSON=$(curl_with_log -H "Origin: $BASE_URL" \
          --referer "$BASE_URL" \
          -F "files[]=@${FILE};type=application/octet-stream;filename=${DEST_FILE}" \
          "https:$SERVER") || return

    else
      NUM_CHUNKS=$(( (SZ + CHUNK_SIZE - 1) / CHUNK_SIZE ))
      log_debug "NC=$NUM_CHUNKS"

      if ! check_exec 'split'; then
          log_error "'split' is required but was not found in path."
          return $ERR_SYSTEM
      fi

      TMP_FILE=$(create_tempfile) || return
      split -d -b "$CHUNK_SIZE" "$FILE" "$TMP_FILE"

      CHUNK=0
      OFFSET=$(( CHUNK_SIZE - 1 ))
      OFFSET_PREV=0
      while (( CHUNK < NUM_CHUNKS )); do
        log_debug "Processing chunk $((CHUNK+1))/$NUM_CHUNKS [${OFFSET_PREV}-${OFFSET}/$SZ]"

        PART_FILE=$TMP_FILE$(printf "%02d" $CHUNK) # -a 2 of split

        # curl's --range doesn't seem to work :(
        JSON=$(curl_with_log -H "Origin: $BASE_URL" -H 'DNT: 1' \
            --referer "$BASE_URL/" \
            -H "Content-Range: bytes ${OFFSET_PREV}-${OFFSET}/$SZ" \
            -H "Content-Disposition: attachment; filename=\"$DEST_FILE\"" \
            -F "files[]=@$PART_FILE;filename=\"$DEST_FILE\"" \
            "https:$SERVER") || return

        rm -f "$PART_FILE"

        OFFSET_PREV=$((OFFSET + 1))
        (( OFFSET += CHUNK_SIZE ))
        OFFSET=$((OFFSET >= SZ ? SZ - 1 : OFFSET))
        (( ++CHUNK ))
      done

    fi

    JSON2=$(parse_json 'files' <<< "$JSON" ) || return
    JSON2=${JSON2#[}
    JSON2=${JSON2%]}

    STATUS=$(parse_json_quiet 'error' <<< "$JSON2") || return
    if [ -n "$STATUS" ]; then
        log_error "Unexpected status: $STATUS"
        return $ERR_FATAL
    fi

    FILE_URL=$(parse_json 'url' <<< "$JSON2") || return
    echo "$BASE_URL$FILE_URL"
}

# Probe a download URL.
# $1: cookie file (unused here)
# $2: krakenfiles url
# $3: requested capability list
# stdout: 1 capability per line
krakenfiles_probe() {
    local -r URL=$2
    local -r REQ_IN=$3
    local PAGE RESP FILE_NAME FILE_SIZE REQ_OUT

    PAGE=$(curl -i "$URL") || return
    RESP=$(first_line <<< "$PAGE")

    if match '^HTTP/[[:digit:]]\(\.[[:digit:]]\)\?[[:space:]]404[[:space:]]' "$RESP"; then
        return $ERR_LINK_DEAD
    fi

    REQ_OUT=c

    if [[ $REQ_IN = *f* ]]; then
        # <meta property="og:title" content="... "
        FILE_NAME=$(echo "$PAGE" | parse_attr '=.og:title.' content) && \
            echo "${FILE_NAME% }" && REQ_OUT="${REQ_OUT}f"
    fi

    if [[ $REQ_IN = *s* ]]; then
        FILE_SIZE=$(echo "$PAGE" | parse '>File size<' '">\([^<]*\)</div>' 1) && \
            translate_size "$FILE_SIZE" && REQ_OUT="${REQ_OUT}s"
    fi

    echo $REQ_OUT
}

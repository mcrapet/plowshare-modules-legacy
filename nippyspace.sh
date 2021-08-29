# Plowshare nippyspace.com module
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

MODULE_NIPPYSPACE_REGEXP_URL='https\?://nippyspace\.com/'

MODULE_NIPPYSPACE_UPLOAD_OPTIONS=""
MODULE_NIPPYSPACE_UPLOAD_REMOTE_SUPPORT=no

MODULE_NIPPYSPACE_PROBE_OPTIONS=""

# Upload a file to nippyspace.com
# $1: cookie file
# $2: input file (with full path)
# $3: remote filename
# stdout: nippyspace.com download link
nippyspace_upload() {
    local -r COOKIE_FILE=$1
    local -r FILE=$2
    local -r DESTFILE=$3
    local -r BASE_URL='https://nippyspace.com'
    local PAGE SERVER FILE_HASH TMP_FILE NUM_CHUNKS CHUNK JSON STATUS HTTP_CODE FILE_URL

    local SZ=$(get_filesize "$FILE")
    if [ "$SZ" -gt 314572800 ]; then
        log_debug 'file is bigger than 300MB'
        return $ERR_SIZE_LIMIT_EXCEEDED
    fi

    if ! check_exec 'split'; then
        log_error "'split' is required but was not found in path."
        return $ERR_SYSTEM
    fi

    # Cookie is not used
    PAGE=$(curl -L -b "$COOKIE_FILE" "$BASE_URL/v1.html") || return

    SERVER=$(parse "'maxFileSize':" "'url':\s*'\([^']*\)'" <<< "$PAGE") || return
    log_debug "Upload server $SERVER"

    FILE_HASH='o_'$(random a 25)

    # Chunk size is 50MiB
    NUM_CHUNKS=$(( (SZ + 52428799) / 52428800 ))
    log_debug "NC=$NUM_CHUNKS"

    TMP_FILE=$(create_tempfile) || return
    split -d -b 50M "$FILE" "$TMP_FILE"

    CHUNK=0
    while (( CHUNK < NUM_CHUNKS )); do
      log_debug "Processing chunk $CHUNK/$NUM_CHUNKS"

      JSON=$(curl_with_log -H "Origin: $BASE_URL" \
          --referer "$BASE_URL" \
          -F "fileHash=$FILE_HASH" \
          -F "name=$DESTFILE" \
          -F "chunk=$CHUNK" -F "chunks=$NUM_CHUNKS" \
          -F "file=@${TMP_FILE}0$CHUNK;type=application/octet-stream;filename=blob" \
          "$SERVER") || return

      rm -f "${TMP_FILE}0$CHUNK"

      # Can return HTTP 413 Request Entity Too Large
      STATUS=$(echo "$JSON" | parse_json 'OK') || return
      HTTP_CODE=$(echo "$JSON" | parse_json 'code') || return

      if [ "$STATUS" != '1' ]; then
          log_error "Unexpected status: $STATUS ($HTTP_CODE)"
          return $ERR_FATAL
      fi

      (( ++CHUNK ))
    done

    FILE_URL=$(echo "$JSON" | parse_json 'message') || return

    echo "$FILE_URL"
}

# Probe a download URL
# $1: cookie file (unused here)
# $2: nippyspace url
# $3: requested capability list
# stdout: 1 capability per line
nippyspace_probe() {
    local -r URL=$2
    local -r REQ_IN=$3
    local PAGE FILE_NAME REQ_OUT

    PAGE=$(curl -i "$URL") || return

    # If we get redirected to index.html this is not good!
    if match '\s\+302\s\?' "$PAGE"; then
        return $ERR_LINK_DEAD
    fi

    REQ_OUT=c

    if [[ $REQ_IN = *f* ]]; then
        #<li>Name: Foobar.zip</li>
        FILE_NAME=$(echo "$PAGE" | parse '<li>Name:' 'Name: \([^<]*\)</li') && \
            echo "${FILE_NAME% }" && REQ_OUT="${REQ_OUT}f"
    fi

    if [[ $REQ_IN = *s* ]]; then
        FILE_SIZE=$(echo "$PAGE" | parse '<li>Size:' 'Size: \([^<]*\)</li') && \
            translate_size "$FILE_SIZE" && REQ_OUT="${REQ_OUT}s"
    fi

    echo $REQ_OUT
}

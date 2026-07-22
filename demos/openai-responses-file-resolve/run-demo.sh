#!/usr/bin/env bash
# Demo runner — file_id resolution + document extraction.
set -uo pipefail

PRAXIS="http://127.0.0.1:8080"
OGX="http://127.0.0.1:8321"
MODEL="Qwen/Qwen3-0.6B"
TYPE_DELAY=0.04

type_cmd() {
    local cmd="$1"
    printf "\n"
    printf '\033[1;32m$ \033[0m'
    for (( i=0; i<${#cmd}; i++ )); do
        printf '%s' "${cmd:$i:1}"
        sleep "$TYPE_DELAY"
    done
    printf "\n"
    sleep 0.3
}

banner() {
    printf "\n\033[1;36m## %s\033[0m\n" "$1"
    sleep 1.5
}

sleep 2

# ── Step 1: Upload a file to OGX ────────────────────────────────────

banner "1. Upload a text file to OGX"
printf "Upload a document to the OGX Files API. This returns a\n"
printf "file_id that we can reference in a Responses API request.\n"
sleep 1

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SAMPLE_FILE="$SCRIPT_DIR/sample-doc.txt"

CMD="curl -s $OGX/v1/files -F purpose=assistants -F \"file=@$SAMPLE_FILE\" | jq ."
type_cmd "$CMD"
UPLOAD_RESPONSE=$(curl -s "$OGX/v1/files" \
    -F purpose=assistants \
    -F "file=@$SAMPLE_FILE")
echo "$UPLOAD_RESPONSE" | jq . 2>/dev/null || echo "$UPLOAD_RESPONSE"
FILE_ID=$(echo "$UPLOAD_RESPONSE" | jq -r '.id' 2>/dev/null || echo "")

if [ "$FILE_ID" = "null" ] || [ -z "$FILE_ID" ]; then
    printf "\n\033[1;31mError: no file_id returned. Check OGX.\033[0m\n"
    sleep 3
    exit 1
fi

printf "\n\033[1;33mFile ID: %s\033[0m\n" "$FILE_ID"
sleep 3

# ── Step 2: Ask about the file via Responses API ────────────────────

banner "2. Ask about the file — file_id resolved by Praxis"
printf "Send a Responses API request with file_id in an input_file\n"
printf "content part. Praxis resolves it via OGX, extracts the text,\n"
printf "converts input_file → input_text, and forwards to vLLM.\n"
sleep 1

CMD='curl -s '"$PRAXIS"'/v1/responses -H "Content-Type: application/json" -d '\''{"model":"'"$MODEL"'","input":[{"type":"message","role":"user","content":[{"type":"input_file","file_id":"'"$FILE_ID"'"},{"type":"input_text","text":"What is this document about? Summarize it in one sentence."}]}]}'\'' | jq .'
type_cmd "$CMD"
RESPONSE=$(curl -s "$PRAXIS"/v1/responses \
    -H "Content-Type: application/json" \
    -d '{"model":"'"$MODEL"'","input":[{"type":"message","role":"user","content":[{"type":"input_file","file_id":"'"$FILE_ID"'"},{"type":"input_text","text":"What is this document about? Summarize it in one sentence."}]}]}')
echo "$RESPONSE" | jq . 2>/dev/null || echo "$RESPONSE"
ANSWER=$(echo "$RESPONSE" | jq -r '.output[] | select(.type == "message") | .content[] | select(.type == "output_text") | .text' 2>/dev/null || echo "")

if [ -n "$ANSWER" ]; then
    printf "\n\033[1;32m↳ Model answered:\033[0m %s\n" "$ANSWER"
    printf "\033[1;32m  vLLM received the extracted text from the file.\033[0m\n"
fi
sleep 3

# ── Step 3: Inline file_data (no OGX needed) ────────────────────────

banner "3. Inline file_data — no OGX call needed"
printf "Send a file with inline base64 file_data. The file_resolve\n"
printf "filter skips it (already resolved). doc_extract converts\n"
printf "the text content to input_text for vLLM.\n"
sleep 1

INLINE_DATA=$(printf '{"server":"praxis","version":"1.0","features":["file_resolve","doc_extract","rehydrate"]}' | base64 | tr -d '\n')

CMD='curl -s '"$PRAXIS"'/v1/responses -H "Content-Type: application/json" -d '\''{"model":"'"$MODEL"'","input":[{"type":"message","role":"user","content":[{"type":"input_file","filename":"config.json","file_data":"data:application/json;base64,'"$INLINE_DATA"'"},{"type":"input_text","text":"What features are listed in this JSON config?"}]}]}'\'' | jq .'
type_cmd "$CMD"
RESPONSE2=$(curl -s "$PRAXIS"/v1/responses \
    -H "Content-Type: application/json" \
    -d '{"model":"'"$MODEL"'","input":[{"type":"message","role":"user","content":[{"type":"input_file","filename":"config.json","file_data":"data:application/json;base64,'"$INLINE_DATA"'"},{"type":"input_text","text":"What features are listed in this JSON config?"}]}]}')
echo "$RESPONSE2" | jq . 2>/dev/null || echo "$RESPONSE2"
ANSWER2=$(echo "$RESPONSE2" | jq -r '.output[] | select(.type == "message") | .content[] | select(.type == "output_text") | .text' 2>/dev/null || echo "")

if [ -n "$ANSWER2" ]; then
    printf "\n\033[1;32m↳ Model answered:\033[0m %s\n" "$ANSWER2"
fi
sleep 3

# ── Step 4: Mixed content ───────────────────────────────────────────

banner "4. Mixed content — file + text question"
printf "Send a request with both a file_id reference and a plain\n"
printf "text question. Both are forwarded to vLLM as input_text.\n"
sleep 1

CMD='curl -s '"$PRAXIS"'/v1/responses -H "Content-Type: application/json" -d '\''{"model":"'"$MODEL"'","input":[{"type":"message","role":"user","content":[{"type":"input_file","file_id":"'"$FILE_ID"'"},{"type":"input_text","text":"List the key points from the document above. Be brief."}]}]}'\'' | jq .'
type_cmd "$CMD"
RESPONSE3=$(curl -s "$PRAXIS"/v1/responses \
    -H "Content-Type: application/json" \
    -d '{"model":"'"$MODEL"'","input":[{"type":"message","role":"user","content":[{"type":"input_file","file_id":"'"$FILE_ID"'"},{"type":"input_text","text":"List the key points from the document above. Be brief."}]}]}')
echo "$RESPONSE3" | jq . 2>/dev/null || echo "$RESPONSE3"
sleep 3

printf "\n\033[1;32mDone.\033[0m Praxis resolved file_id via OGX, extracted\n"
printf "document text, and forwarded input_text to vLLM.\n"
printf "No file handling needed in the backend.\n"
sleep 3

# File Resolve + Document Extraction

[![asciicast](https://asciinema.org/a/YjHEVBDZamRliaCQ.svg)](https://asciinema.org/a/YjHEVBDZamRliaCQ)

A demo of **Praxis** resolving `file_id` references via an external Files
API (OGX) and converting document content to `input_text` for vLLM. The
client sends a `file_id` in an `input_file` content part — Praxis fetches
the file from OGX, extracts the text, and forwards it as `input_text` so
vLLM can reason about the document.

## What it shows

| Step | What happens |
|------|--------------|
| 1 | Upload a text file to OGX via `POST /v1/files` |
| 2 | Send a Responses API request with `file_id` — Praxis resolves via OGX, extracts text, vLLM answers |
| 3 | Send inline `file_data` (base64) — no OGX call, doc_extract converts directly |
| 4 | Mixed content: `file_id` + `input_text` question in the same request |

### Key behaviors

- **File resolution**: the `openai_file_resolve` filter resolves `file_id`
  references by calling the OGX Files API, fetching file content and
  inlining it as `file_data` in the request
- **Document extraction**: the `openai_doc_extract` filter converts
  text-safe `input_file` parts (`text/*`, `application/json`,
  `application/xml`) to `input_text` with a `[Source: filename]` prefix
- **No backend changes**: vLLM receives standard `input_text` — no file
  handling needed in the inference backend
- **Unsupported types pass through**: PDFs, images, and other binary
  formats are left as `input_file` for backends that support them
- **Authorization forwarding**: the `forward_headers` config forwards
  the client's `Authorization` header to OGX

## Architecture

```text
┌────────┐       ┌──────────────────────────────────────────┐
│ client │──────▸│          Praxis (127.0.0.1:8080)         │
│ (curl) │       │                                          │
└────────┘       │  format → validate                       │
                 │    → file_resolve ─── GET /v1/files/{id} │──▸ OGX (:8321)
                 │    → doc_extract                         │
                 │    → openai_responses_proxy → router       │──▸ vLLM (:8000)
                 │                                          │
                 │  file_id → file_data → input_text        │
                 └──────────────────────────────────────────┘
```

## Prerequisites

- **Praxis AI** built from source (`cargo build -p praxis-ai-proxy --release`)
- **OGX** running on `:8321` with the Files API enabled
- **vLLM** running with an OpenAI-compatible model (e.g. `Qwen/Qwen3-0.6B`)
- **tmux** and **asciinema** (for recording only)

## Quick start

```bash
# Terminal 1: start OGX (Files API on :8321)
cd /path/to/ogx
uv run ogx run starter --insecure

# Terminal 2: start vLLM
podman run --name vllm -p 8000:8000 \
  vllm/vllm-openai:latest --model Qwen/Qwen3-0.6B

# Terminal 3: start Praxis AI
cd demos/openai-responses-file-resolve
RUST_LOG=praxis_filter=debug praxis-ai -c file-resolve.yaml

# Terminal 4: upload a file and ask about it
FILE_ID=$(curl -s http://127.0.0.1:8321/v1/files \
  -F purpose=assistants \
  -F "file=@sample-doc.txt" | jq -r '.id')

curl -s http://127.0.0.1:8080/v1/responses \
  -H "Content-Type: application/json" \
  -d '{"model":"Qwen/Qwen3-0.6B","input":[{"type":"message","role":"user","content":[{"type":"input_file","file_id":"'"$FILE_ID"'"},{"type":"input_text","text":"Summarize this document."}]}]}' | jq .
```

## Recording the demo

```bash
./record.sh
```

Play back:

```bash
asciinema play demo.cast
```

## What to look for

### Praxis logs

```
classified format=openai_responses                  # request classified
file_resolve resolved file_id=file_... filename=... # OGX fetch
doc_extract converted input_file → input_text       # text extracted
route matched cluster=vllm                          # forwarded to vLLM
```

### OGX logs

```
GET /v1/files/file_... → 200                        # file metadata
GET /v1/files/file_.../content → 200                # file content
```

### What vLLM receives

The backend gets standard `input_text` — no `input_file` or `file_id`:

```json
{
  "model": "Qwen/Qwen3-0.6B",
  "input": [{
    "type": "message",
    "role": "user",
    "content": [
      {"type": "input_text", "text": "[Source: sample-doc.txt]\nPraxis Reverse Proxy..."},
      {"type": "input_text", "text": "Summarize this document."}
    ]
  }]
}
```

## Files

| File | Description |
|------|-------------|
| `file-resolve.yaml` | Praxis config: file_resolve (OGX) + doc_extract + vLLM routing |
| `record.sh` | Set up tmux + asciinema recording (4-pane layout) |
| `run-demo.sh` | Demo runner: upload file, ask questions, inline data, mixed content |
| `sample-doc.txt` | Sample document uploaded to OGX for the demo |
| `demo.cast` | Recorded asciinema session |

# AuthPolicy → CEL, end-to-end on Praxis

Takes a Kuadrant `AuthPolicy`, runs it through the [`authpolicy-transpiler`](../authpolicy-transpiler),
and enforces the result on **Praxis + CPEX** as generic-HTTP (L7) authorization — proving the
transpiled CEL actually gates traffic against a real OIDC IdP.

The source policy is [`../authpolicy-transpiler/examples/jwt-cel-http.yaml`](../authpolicy-transpiler/examples/jwt-cel-http.yaml),
chosen because it **translates cleanly** (every authentication/authorization construct maps 1:1 to
CPEX, no approximations — only the inherent `spec.targetRef` binding is left to wire up here).

## What it shows

The AuthPolicy expresses two CEL rules over the HTTP request line and top-level JWT claims.
Kuadrant array-membership predicates transpile to CPEX's boolean identity namespaces (`role.*` /
`perm.*`), which is what the `standard` claim mapper populates:

- **reads** (`GET`) require the `tool_execute` permission
  — `'tool_execute' in auth.identity.permissions` → `has(perm.tool_execute) && perm.tool_execute`
- **writes** (`POST`/`DELETE`) require the `hr` role
  — `'hr' in auth.identity.roles` → `has(role.hr) && role.hr`

Transpiled to a CPEX `global` policy, loaded by the Praxis `policy` filter, and exercised with the
shared demo personas (alice = engineer, bob = hr; both carry `tool_execute`):

| Request | Persona | Result | Why |
|---|---|---|---|
| `GET /api/...`  | alice (engineer) | **200** | has `tool_execute` permission |
| `GET /api/...`  | bob (hr)         | **200** | has `tool_execute` permission |
| `POST /api/...` | alice (engineer) | **403** | CEL deny — alice is not `hr` |
| `POST /api/...` | bob (hr)         | **200** | CEL allow — bob is `hr` |
| `GET /api/...`  | (no token)       | **401** | identity gate |

An authorization denial returns Praxis's default L7 deny (HTTP 403); the AuthPolicy's custom
`denyWith` body is intentionally omitted because the transpiler does not yet carry it (it would be
reported as `approximated`, breaking the clean translation).

## Run

```console
./run-demo.sh
```

The script: starts Keycloak (via the [`../cpex`](../cpex) docker-compose), transpiles the AuthPolicy
into `./out/`, injects a localhost-dev `insecure_http` shim into the JWKS `decoding_key` (never
needed with an https JWKS), builds Praxis from the sibling `../../../praxis` checkout with
`--features cpex-policy-engine`, starts a tiny echo backend + the gateway, mints `alice`/`bob`
tokens with [`../cpex/mint-token.sh`](../cpex/mint-token.sh), and runs the four checks above.

Praxis runs on the host at `127.0.0.1:8095`; the echo backend at `127.0.0.1:9200`; Keycloak
(`cpex-demo` realm) at `127.0.0.1:8081`.

## Requirements

`docker` (compose), `cargo`, `python3`, `curl`, `jq`. Depends on the `../cpex` demo's Keycloak
realm and `mint-token.sh` (started/used automatically). Praxis source is resolved by
`../cpex/build-praxis.sh` — override with `PRAXIS_BIN` / `PRAXIS_DIR` / `PRAXIS_GIT_URL`.

## Files

| Path | Purpose |
|------|---------|
| `praxis-authpolicy.yaml` | Praxis L7 listener: `policy` → `router` → `load_balancer` (no `mcp` filter). |
| `echo-backend.py` | Trivial upstream that 200s any request that Praxis lets through. |
| `run-demo.sh` | Orchestrates transpile → build → run → curl. |
| `out/` | Transpiler output (gitignored): CPEX policy doc, filter block, coverage report. |

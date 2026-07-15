# AuthPolicy transpiler

A standalone CLI that converts a Kuadrant [`AuthPolicy`](https://docs.kuadrant.io/latest/kuadrant-operator/doc/overviews/auth/) into Praxis policy configuration: a `policy`-filter block plus a CPEX policy document. It is best-effort and prints a coverage report saying exactly what was translated, approximated, or skipped.

Use it to see how an existing Kuadrant `AuthPolicy` would look under Praxis + the CPEX policy engine, without hand-rewriting anything.

## What it shows

- Kuadrant `AuthPolicy` (`kuadrant.io/v1`, Authorino `v1beta3`) parsed and mapped to CPEX's canonical policy form.
- JWT authentication becomes a CPEX `identity/jwt` plugin; CEL authorization (`patternMatching` predicates, `when`, `patterns`, and the deprecated `selector`/`operator`/`value` form) becomes `cel: { expr }` PDP steps under the `global` policy's `authorization.pre_invocation` block, gated by a native `require(authenticated)` presence check.
- A coverage report that classifies every construct, so gaps are visible rather than silently dropped.
- Fail-closed behaviour: if a policy declares authorization but nothing translates, the output is a `require(false)` deny-all and the CLI exits non-zero.

## Quick start

```console
# Print the CPEX policy doc + Praxis filter block + coverage report to stdout
cargo run -- examples/jwt-rbac.yaml

# Or write the three artifacts to a directory
cargo run -- examples/jwt-rbac.yaml --out-dir ./out
```

The emitted CPEX policy uses the canonical block form:

```yaml
plugins:
  - name: keycloak-jwt
    kind: identity/jwt
    hooks: [identity.resolve]
    on_error: fail
    config: { ... }
global:
  authentication:
    - keycloak-jwt
  authorization:
    pre_invocation:
      - "require(authenticated)"          # native presence gate
      - cel: { expr: "<remapped CEL>" }   # one per Kuadrant rule
```

Kuadrant `patternMatching`/`when` predicates are CEL, so each translated rule is emitted as a `cel: { expr }` PDP step — dispatched to CPEX's bundled `cel` resolver, which evaluates full CEL (`startsWith`, `&&`/`||`, literal `in`). The APL-native `require(...)` form is used only for the `require(authenticated)` presence gate and the `require(false)` fail-closed sentinel, because `require(...)` parses APL's own predicate DSL, not CEL.

The coverage report summarises the mapping:

```text
AuthPolicy → Praxis coverage report
===================================
translated: 4   approximated: 4   skipped: 1

[INFO ] translated    authentication/keycloak-jwt
          JWT → identity/jwt ...
[WARN ] approximated  authentication (claims)
          a rule references a nested identity claim (Keycloak realm_access.roles) ...
[WARN ] skipped       authorization/via-opa
          authorization method `opa` is not supported ...
```

Per input policy, `--out-dir` writes `<name>-cpex-policy.yaml`, `<name>-policy-filter.yaml`, and `<name>-coverage.txt`. Multiple input files and multi-document (`---`) YAML are supported. The process exits non-zero if any policy fails closed.

Try the other samples to see the range: `examples/apikey-opa.yaml` (unsupported methods, fails closed) and `examples/gateway-defaults.yaml` (`defaults` block, metadata/callbacks reported as gaps).

## Scope and limitations

The transpiler covers the subset that maps cleanly to CEL. Everything else is reported, not dropped.

- **Authentication:** JWT only (JWKS, issuer, audiences). `apiKey`, `x509`/mTLS, `anonymous`, `oauth2Introspection`, and `kubernetesTokenReview` are reported as gaps. Multi-rule priority/fallback is reported, not preserved.
- **Authorization:** CEL only. `opa` (Rego), `spicedb`, and `kubernetesSubjectAccessReview` are reported as gaps.
- **Policy composition:** a single policy's rules. The `defaults`/`overrides` hierarchy and Gateway-to-route merge strategies (GEP-2649) are collapsed to a single flat policy and reported.
- **Response:** custom `denyWith` (status/body/headers) is **not** yet carried into the emitted policy — it is reported as `approximated`, and a denial uses CPEX's default (401 identity / 403 authorization). Success-response injection is best-effort and reported.
- **Metadata and callbacks:** reported as gaps.
- **Binding and lifecycle (out of scope):** no Gateway API translation (`targetRef` to listeners/routes), no CRD ingestion or operator, no reverse translation, no multi-version schema support.
- **Signing algorithms:** not expressible in a Kuadrant JWT block, so the emitted trusted issuer defaults to `RS256` (the OIDC default). Widen it in the emitted policy if the IdP signs with ES256/etc.
- **CEL namespaces:** predicates are lexically remapped from Kuadrant's vocabulary to CPEX's. The HTTP request line maps directly (`request.*` → `http.*`). Identity RBAC uses the membership idiom: `'<v>' in auth.identity.roles` / `.permissions` / `.groups`|`.teams` → CPEX's boolean namespaces `has(role.<v>) && role.<v>` / `perm.<v>` / `team.<v>`, which is what the `standard` claim mapper populates. Other identity references fall back to `auth.identity.* → claim.*` and are a runtime gap wherever `claim.*` is unpopulated (e.g. nested `realm_access.roles`, scalar claims). A reference that does not remap at all (e.g. `auth.metadata.*`) is reported as a gap and dropped rather than emitted as wrong-namespace CEL.

The emitted documents are checked by the golden corpus under `tests/` and the structural invariant assertions in `src/main.rs`. This demo depends only on `serde`, `serde_yaml`, and `clap`; it does not parse its output through the CPEX crate.

## Files

| Path | Purpose |
|------|---------|
| `src/main.rs` | CLI entry: parse args, transpile each input, emit artifacts, exit non-zero on fail-closed. |
| `src/authpolicy/model.rs` | Serde model for the supported `AuthPolicy` subset (best-effort parse). |
| `src/authpolicy/cel.rs` | Kuadrant to CPEX CEL namespace remap (`auth.identity.*` to `claim.*`, `request.*` to `http.*`). |
| `src/authpolicy/translate.rs` | Core translation to the canonical CPEX blocks; fail-closed logic. |
| `src/authpolicy/emit.rs` | Serializable shapes for the CPEX policy doc + Praxis filter block. |
| `src/authpolicy/report.rs` | Coverage report (translated / approximated / skipped). |
| `examples/*.yaml` | Sample `AuthPolicy` inputs. |
| `tests/fixtures/authpolicy/` | Golden corpus (`*.yaml` inputs + `*.golden` expected output). |

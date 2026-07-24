#!/usr/bin/env bash
# Bind an existing Keycloak client to SPIFFE federated client authentication, so
# a workload authenticates with its JWT-SVID instead of a client secret.
#
# This is the standards-track way an SVID enters OAuth
# (draft-ietf-oauth-spiffe-client-auth, profiling RFC 7523 client auth): the
# workload posts its SVID as `client_assertion` with
# client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-spiffe;
# Keycloak validates it against the SPIFFE trust bundle (via the `spiffe` IdP,
# see setup-spiffe-idp.sh) and resolves WHICH client from the SVID's `sub`.
#
# What it sets on the client:
#   clientAuthenticatorType = federated-jwt   ("Signed JWT - Federated")
#   attribute jwt.credential.issuer = <spiffe IdP alias>
#   attribute jwt.credential.sub    = <expected SPIFFE ID>
# The client's secret is thereby retired ("no more secrets").
#
# Verify (SVID aud MUST be exactly the realm issuer, per the draft):
#   SVID=$(docker compose -f docker-compose.yml -f docker-compose.spire.yml \
#     exec -T spire-server /opt/spire/bin/spire-server jwt mint \
#     -spiffeID spiffe://cpex.demo/agent/hr-copilot \
#     -audience http://localhost:8081/realms/cpex-demo | tr -d '[:space:]')
#   curl -s -X POST http://localhost:8081/realms/cpex-demo/protocol/openid-connect/token \
#     -d grant_type=client_credentials \
#     -d client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-spiffe \
#     -d client_assertion="$SVID"
#
# Idempotent: safe to re-run.
set -euo pipefail

KC="${KC:-http://localhost:8081}"
REALM="${REALM:-cpex-demo}"
ADMIN="${ADMIN:-admin}"
ADMIN_PW="${ADMIN_PW:-admin}"
IDP_ALIAS="${IDP_ALIAS:-spiffe}"
CLIENT_ID="${CLIENT_ID:-hr-copilot}"
EXPECTED_SUB="${EXPECTED_SUB:-spiffe://cpex.demo/agent/hr-copilot}"

echo "-> obtaining admin token"
TOKEN=$(curl -sf -X POST "$KC/realms/master/protocol/openid-connect/token" \
  -d grant_type=password -d client_id=admin-cli \
  -d username="$ADMIN" -d password="$ADMIN_PW" \
  | python3 -c 'import sys,json;print(json.load(sys.stdin)["access_token"])')

echo "-> binding client '$CLIENT_ID' to federated-jwt (sub=$EXPECTED_SUB)"
CID=$(curl -sf -H "Authorization: Bearer $TOKEN" \
  "$KC/admin/realms/$REALM/clients?clientId=$CLIENT_ID" \
  | python3 -c 'import sys,json;print(json.load(sys.stdin)[0]["id"])')

# Read-modify-write so we preserve the client's other attributes.
curl -sf -H "Authorization: Bearer $TOKEN" "$KC/admin/realms/$REALM/clients/$CID" \
  | IDP_ALIAS="$IDP_ALIAS" EXPECTED_SUB="$EXPECTED_SUB" python3 -c '
import sys, os, json
c = json.load(sys.stdin)
c["clientAuthenticatorType"] = "federated-jwt"
c.setdefault("attributes", {})
c["attributes"]["jwt.credential.issuer"] = os.environ["IDP_ALIAS"]
c["attributes"]["jwt.credential.sub"]    = os.environ["EXPECTED_SUB"]
json.dump(c, sys.stdout)
' \
  | curl -sf -X PUT -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
      "$KC/admin/realms/$REALM/clients/$CID" -d @-

echo "-> done: '$CLIENT_ID' now authenticates by SVID (secret retired)"

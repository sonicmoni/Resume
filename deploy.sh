#!/usr/bin/env bash
# Publish index.html + assets/ to Hostinger over FTPS.
set -euo pipefail

cd "$(dirname "$0")"

ENV_FILE=".deploy.env"
LOCAL_FILE="index.html"
SITE_URL="https://monicamohabansi.com"

if [[ ! -f "$ENV_FILE" ]]; then
  cat >&2 <<EOF
Missing $ENV_FILE. Create it with your Hostinger details:

  FTP_HOST=88.223.85.13
  FTP_USER=u123456789
  REMOTE_DIR=public_html

Defaults to SFTP on port 65002 and prompts for the password.
Host/user come from hPanel -> Files -> SSH Access. Then: chmod 600 $ENV_FILE
EOF
  exit 1
fi

# shellcheck source=/dev/null
source "$ENV_FILE"
: "${FTP_HOST:?not set in $ENV_FILE}"
: "${FTP_USER:?not set in $ENV_FILE}"
REMOTE_DIR="${REMOTE_DIR:-public_html}"
PROTOCOL="${PROTOCOL:-sftp}"
SSH_PORT="${SSH_PORT:-65002}"

# FTPS needs a stored password; SFTP prompts for one interactively.
[[ "$PROTOCOL" == "ftps" ]] && : "${FTP_PASS:?not set in $ENV_FILE}"

if [[ "$PROTOCOL" == "ftps" && "$FTP_HOST" =~ ^[0-9.]+$ ]]; then
  echo "FTPS to a bare IP will fail TLS verification (Hostinger's cert is *.hstgr.io)." >&2
  echo "Use the srvNNNN.hstgr.io hostname from hPanel, or leave PROTOCOL=sftp." >&2
  exit 1
fi

[[ -f "$LOCAL_FILE" ]] || { echo "No $LOCAL_FILE here." >&2; exit 1; }

# ./deploy.sh --find-root : show the remote layout so REMOTE_DIR can be set correctly.
if [[ "${1:-}" == "--find-root" ]]; then
  probe=$(mktemp)
  trap 'rm -f "$probe"' EXIT
  {
    echo "-ls -l ."
    echo "-ls -l domains"
    echo "-ls -l domains/monicamohabansi.com"
    echo "-ls -l domains/monicamohabansi.com/public_html"
  } >"$probe"
  sftp -P "$SSH_PORT" -o BatchMode=no -o StrictHostKeyChecking=accept-new \
    -b "$probe" "$FTP_USER@$FTP_HOST"
  echo
  echo "Set REMOTE_DIR in $ENV_FILE to whichever path above holds your live index.html."
  exit 0
fi

status_of() { curl -s -o /dev/null -w '%{http_code}' "$SITE_URL/$1"; }

# Every local asset the page actually references, so nothing ships half-broken.
# bash 3.2 on macOS has no mapfile, hence the read loop.
assets=()
while IFS= read -r a; do
  [[ -n "$a" ]] && assets+=("$a")
done < <(
  {
    grep -oE 'assets/[A-Za-z0-9._-]+' "$LOCAL_FILE"
    # og:image is an absolute URL; grep above already catches its path.
  } | sort -u
)

if (( ${#assets[@]} == 0 )); then
  echo "No assets/ references found in $LOCAL_FILE." >&2
  exit 1
fi

missing_local=()
for a in "${assets[@]}"; do [[ -f "$a" ]] || missing_local+=("$a"); done
if (( ${#missing_local[@]} > 0 )); then
  printf 'Referenced but not on disk: %s\n' "${missing_local[@]}" >&2
  exit 1
fi

local_sum=$(md5 -q "$LOCAL_FILE")
live_sum=$(curl -fsS "$SITE_URL/" | md5 -q) || live_sum="unreachable"

stale=()
for a in "${assets[@]}"; do
  [[ "$(status_of "$a")" == "200" ]] || stale+=("$a")
done

if [[ "$local_sum" == "$live_sum" ]] && (( ${#stale[@]} == 0 )); then
  echo "Live site already matches local. Nothing to publish."
  exit 0
fi

echo "index.html  local $local_sum"
echo "            live  $live_sum"
if (( ${#stale[@]} > 0 )); then
  printf 'Missing/unreachable live: %s\n' "${stale[@]}"
fi
echo
echo "Will upload ${#assets[@]} asset(s) + $LOCAL_FILE to $FTP_HOST:$REMOTE_DIR"
read -r -p "Proceed? [y/N] " reply
[[ "$reply" == [yY] ]] || { echo "Aborted."; exit 1; }

stamp=$(date +%Y%m%d-%H%M%S)

if [[ "$PROTOCOL" == "sftp" ]]; then
  # One session for everything, so you type the password once.
  # Assets go first: the HTML must never go live pointing at files that aren't there.
  batch=$(mktemp)
  trap 'rm -f "$batch"' EXIT
  {
    echo "-mkdir $REMOTE_DIR/assets"
    echo "-rename $REMOTE_DIR/$LOCAL_FILE $REMOTE_DIR/index.$stamp.bak.html"
    for a in "${assets[@]}"; do echo "put $a $REMOTE_DIR/$a"; done
    echo "put $LOCAL_FILE $REMOTE_DIR/$LOCAL_FILE"
  } >"$batch"

  echo "Connecting to $FTP_USER@$FTP_HOST:$SSH_PORT (you'll be asked for the SSH password)"
  # -b implies BatchMode=yes, which kills the password prompt. ssh honours the
  # first value for an option, so BatchMode=no must come before -b.
  sftp -P "$SSH_PORT" \
    -o BatchMode=no \
    -o StrictHostKeyChecking=accept-new \
    -o NumberOfPasswordPrompts=3 \
    -b "$batch" "$FTP_USER@$FTP_HOST"
else
  # Keep the password out of argv (ps can read it) by passing it via a temp netrc.
  netrc=$(mktemp)
  trap 'rm -f "$netrc"' EXIT
  chmod 600 "$netrc"
  printf 'machine %s login %s password %s\n' "$FTP_HOST" "$FTP_USER" "$FTP_PASS" >"$netrc"

  ftp_put() {
    curl -fsS --ssl-reqd --ftp-create-dirs --netrc-file "$netrc" \
      -T "$1" "ftp://$FTP_HOST/$REMOTE_DIR/$2"
  }

  if curl -fsS --ssl-reqd --netrc-file "$netrc" \
       -Q "-RNFR $REMOTE_DIR/$LOCAL_FILE" \
       -Q "-RNTO $REMOTE_DIR/index.$stamp.bak.html" \
       "ftp://$FTP_HOST/$REMOTE_DIR/" -o /dev/null 2>/dev/null; then
    echo "Backed up remote index.html -> index.$stamp.bak.html"
  else
    echo "Warning: could not back up remote index.html; continuing."
  fi

  for a in "${assets[@]}"; do
    echo "  uploading $a"
    ftp_put "$a" "$a"
  done

  echo "  uploading $LOCAL_FILE"
  ftp_put "$LOCAL_FILE" "$LOCAL_FILE"
fi

echo "Verifying..."
sleep 2
fail=0
new_sum=$(curl -fsS -H 'Cache-Control: no-cache' "$SITE_URL/" | md5 -q) || new_sum="unreachable"
if [[ "$new_sum" == "$local_sum" ]]; then
  echo "  index.html OK"
else
  echo "  index.html live hash $new_sum, expected $local_sum"
  fail=1
fi
for a in "${assets[@]}"; do
  code=$(status_of "$a")
  [[ "$code" == "200" ]] && echo "  $a OK" || { echo "  $a -> HTTP $code"; fail=1; }
done

if (( fail )); then
  echo
  echo "Some checks failed. LiteSpeed may be caching - purge cache in hPanel and recheck."
  echo "To roll back: rename index.$stamp.bak.html back to index.html in hPanel File Manager."
  exit 1
fi
echo "Published: $SITE_URL"

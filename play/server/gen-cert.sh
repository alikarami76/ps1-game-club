#!/bin/sh
# Make a self-signed HTTPS certificate for the club server (needs openssl).
#   ./gen-cert.sh [extra-host-or-ip ...]
# The certificate covers localhost, 127.0.0.1, this machine's host name and any extra names or
# IP addresses you pass (for example the address friends will type). Browsers warn once about
# a self-signed certificate; click through it, or use a real certificate (see README).
set -eu
cd "$(dirname "$0")"
command -v openssl >/dev/null 2>&1 || { echo "openssl is required"; exit 1; }
mkdir -p certs
san="DNS:localhost,IP:127.0.0.1,DNS:$(hostname)"
for n in "$@"; do
  case "$n" in
    *[!0-9.]*) san="$san,DNS:$n" ;;
    *) san="$san,IP:$n" ;;
  esac
done
openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days 825 \
  -keyout certs/club.key -out certs/club.crt \
  -subj "/CN=ps1-game-club" -addext "subjectAltName=$san" 2>/dev/null
chmod 600 certs/club.key
echo "Wrote certs/club.crt and certs/club.key (valid for: $san)"
echo "Restart the server. With CLUB_TLS=auto (default) it now serves HTTPS."

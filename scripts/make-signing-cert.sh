#!/bin/bash
# Creates the self-signed code-signing certificate "App Monitor Signing" (spec section 11) and
# adds it, with its private key, to a keychain. Builds signed with it keep the same designated
# requirement, so macOS keeps Full Disk Access across updates.
#
#   scripts/make-signing-cert.sh                          # into your login keychain
#   scripts/make-signing-cert.sh --p12 ~/Desktop/appmon-signing.p12
#                                                         # also export a .p12 for the release workflow
#   scripts/make-signing-cert.sh --keychain PATH          # into another keychain (testing)
#
# Then build with:  APPMON_SIGN_IDENTITY="App Monitor Signing" AppMonitor/build.sh
#
# Secrets: the private key exists only in a private temporary folder while the script runs, and
# in the keychain. The .p12 password is read from the terminal without echo and never printed or
# saved. Keep the .p12 out of the repo (the script refuses to write it there) and delete it once
# it is in GitHub secrets. macOS may ask for your login password or to allow access to the
# keychain: that prompt comes from macOS, not from this script.
set -euo pipefail

NAME="App Monitor Signing"
OPENSSL=/usr/bin/openssl   # LibreSSL: its .p12 files import with `security` on every macOS version
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
P12=""

usage() { sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }
while [ $# -gt 0 ]; do
  case "$1" in
    --p12) P12="${2:?--p12 needs a path}"; shift 2 ;;
    --keychain) KEYCHAIN="${2:?--keychain needs a path}"; shift 2 ;;
    -h|--help) usage 0 ;;
    *) echo "Unknown option: $1" >&2; usage 1 ;;
  esac
done

[ -f "$KEYCHAIN" ] || { echo "No keychain at $KEYCHAIN" >&2; exit 1; }
if security find-identity -p codesigning "$KEYCHAIN" 2>/dev/null | grep -q "\"$NAME\""; then
  echo "\"$NAME\" is already in $KEYCHAIN. Reuse it: a new certificate would make macOS forget" >&2
  echo "Full Disk Access again. Delete it in Keychain Access first if you really want a new one." >&2
  exit 1
fi

if [ -n "$P12" ]; then
  case "$P12" in /*) ;; *) P12="$PWD/$P12" ;; esac
  P12_DIR="$(cd "$(dirname "$P12")" && pwd -P)" || { echo "No folder for $P12" >&2; exit 1; }
  # Not inside this repo, nor any other git checkout or worktree, where it could be committed.
  if git -C "$P12_DIR" rev-parse --show-toplevel >/dev/null 2>&1; then
    echo "Refusing to write the .p12 inside a git repository ($P12_DIR)." >&2; exit 1
  fi
  P12="$P12_DIR/$(basename "$P12")"
  [ -e "$P12" ] && { echo "$P12 already exists." >&2; exit 1; }
  read -r -s -p "Password for the .p12 (you'll store it as a GitHub secret): " PW; echo
  read -r -s -p "Same password again: " PW2; echo
  [ "$PW" = "$PW2" ] || { echo "The passwords don't match." >&2; exit 1; }
  [ "${#PW}" -ge 12 ] || { echo "Use at least 12 characters." >&2; exit 1; }
  unset PW2
fi

umask 077
TMP="$(mktemp -d)"
trap 'rc=$?; rm -rf "$TMP"; exit $rc' EXIT

cat > "$TMP/cert.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
subjectKeyIdentifier = hash
EOF
# Ten years: release builds must keep using this one certificate.
"$OPENSSL" req -x509 -newkey rsa:2048 -nodes -sha256 -days 3650 -config "$TMP/cert.cnf" \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" 2>/dev/null

# Make the .p12 first, so a failed export never leaves a certificate in the keychain without one.
if [ -n "$P12" ]; then
  printf '%s\n' "$PW" | "$OPENSSL" pkcs12 -export -name "$NAME" \
    -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -out "$TMP/out.p12" -passout stdin
  unset PW
fi

# Import the certificate and key separately, so no password goes on a command line.
# -T lets codesign use the key without asking each time.
security import "$TMP/cert.pem" -k "$KEYCHAIN" -t cert >/dev/null
security import "$TMP/key.pem" -k "$KEYCHAIN" -t priv -T /usr/bin/codesign >/dev/null
echo "Added \"$NAME\" to $KEYCHAIN."

if [ -n "$P12" ]; then
  mv "$TMP/out.p12" "$P12"
  echo "Exported $P12 (readable only by you). Put it in GitHub secrets, then delete it."
fi

echo "SHA-1 of the certificate (identifies it in codesign -d -r- output):"
"$OPENSSL" x509 -in "$TMP/cert.pem" -noout -fingerprint -sha1 | sed 's/.*=//; s/://g'

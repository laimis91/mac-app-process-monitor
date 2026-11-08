#!/bin/bash
# Creates the self-signed code-signing certificate "App Monitor Signing" (spec section 11) and
# adds it, with its private key, to a keychain. Builds signed with it keep the same designated
# requirement, so macOS keeps Full Disk Access across updates.
#
#   K=~/Library/Keychains/appmon-signing.keychain-db
#   scripts/make-signing-cert.sh --keychain "$K"          # into a dedicated keychain (recommended)
#   D=$(mktemp -d); scripts/make-signing-cert.sh --keychain "$K" --p12 "$D/appmon.p12"
#                                                         # also export a .p12 for the release workflow
#   scripts/make-signing-cert.sh                          # into your login keychain
#
# The keychain is --keychain if given, else APPMON_SIGN_KEYCHAIN, else the login keychain. A
# dedicated keychain that doesn't exist yet is created (security asks for its new password) and
# set to lock on sleep and after 5 minutes, so other processes can't sign as App Monitor while
# you're away. Then build with:
#   APPMON_SIGN_KEYCHAIN="$K" APPMON_SIGN_IDENTITY="App Monitor Signing" AppMonitor/build.sh
#
# Secrets: the private key exists only in a private temporary folder while the script runs, and
# in the keychain. The .p12 password is read from the terminal without echo and never printed or
# saved. Keep the .p12 out of the repo and out of synced folders (the script refuses both) and
# delete it once it is in GitHub secrets. macOS may ask for a keychain password or to allow
# access to the keychain: that prompt comes from macOS, not from this script.
set -euo pipefail

NAME="App Monitor Signing"
OPENSSL=/usr/bin/openssl   # LibreSSL: its .p12 files import with `security` on every macOS version
LOGIN_KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
KEYCHAIN="${APPMON_SIGN_KEYCHAIN:-$LOGIN_KEYCHAIN}"
P12=""

usage() { sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }
while [ $# -gt 0 ]; do
  case "$1" in
    --p12) P12="${2:?--p12 needs a path}"; shift 2 ;;
    --keychain) KEYCHAIN="${2:?--keychain needs a path}"; shift 2 ;;
    -h|--help) usage 0 ;;
    *) echo "Unknown option: $1" >&2; usage 1 ;;
  esac
done

case "$KEYCHAIN" in /*) ;; *) KEYCHAIN="$PWD/$KEYCHAIN" ;; esac
if [ ! -f "$KEYCHAIN" ]; then
  [ "$KEYCHAIN" != "$LOGIN_KEYCHAIN" ] || { echo "No login keychain at $KEYCHAIN" >&2; exit 1; }
  [[ "$KEYCHAIN" == *.keychain-db ]] || { echo "A new keychain's name must end in .keychain-db: $KEYCHAIN" >&2; exit 1; }
  [ -d "$(dirname "$KEYCHAIN")" ] || { echo "No folder for $KEYCHAIN" >&2; exit 1; }
fi

# Check the .p12 path before creating or changing anything.
if [ -n "$P12" ]; then
  case "$P12" in /*) ;; *) P12="$PWD/$P12" ;; esac
  P12_DIR="$(cd "$(dirname "$P12")" && pwd -P)" || { echo "No folder for $P12" >&2; exit 1; }
  # Not inside this repo, nor any other git checkout or worktree, where it could be committed.
  if git -C "$P12_DIR" rev-parse --show-toplevel >/dev/null 2>&1; then
    echo "Refusing to write the .p12 inside a git repository ($P12_DIR)." >&2; exit 1
  fi
  # Nor in a folder that may sync to iCloud or another cloud service.
  for SYNCED in "$HOME/Desktop" "$HOME/Documents" "$HOME/Library/Mobile Documents" "$HOME/Library/CloudStorage"; do
    for S in "$SYNCED" "$(cd "$SYNCED" 2>/dev/null && pwd -P || true)"; do
      [ -n "$S" ] || continue
      case "$P12_DIR/" in "$S"/*)
        echo "Refusing to write the .p12 under $SYNCED, which may sync to the cloud. Use a private" >&2
        echo "temporary folder:  D=\$(mktemp -d); $0 --p12 \"\$D/appmon.p12\"" >&2
        exit 1 ;;
      esac
    done
  done
  P12="$P12_DIR/$(basename "$P12")"
  [ -e "$P12" ] && { echo "$P12 already exists." >&2; exit 1; }
fi

if [ ! -f "$KEYCHAIN" ]; then
  echo "Creating the dedicated keychain $KEYCHAIN. Choose a password for it (not your login password)."
  security create-keychain "$KEYCHAIN"   # asks for the new password itself; it never reaches this script
fi
if [ "$KEYCHAIN" != "$LOGIN_KEYCHAIN" ]; then
  # Lock on sleep (-l) and after 5 minutes (-u -t 300), so the key can be used only for a short
  # while after you unlock the keychain. Also applied to an existing dedicated keychain.
  security set-keychain-settings -l -u -t 300 "$KEYCHAIN"
fi
if security find-identity -p codesigning "$KEYCHAIN" 2>/dev/null | grep -q "\"$NAME\""; then
  echo "\"$NAME\" is already in $KEYCHAIN. Reuse it: a new certificate would make macOS forget" >&2
  echo "Full Disk Access again. Delete it in Keychain Access first if you really want a new one." >&2
  exit 1
fi

if [ -n "$P12" ]; then
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
# -T lets codesign use the key without asking each time: any time in the login keychain, which
# stays unlocked while you're logged in; only while it's unlocked in a dedicated keychain.
security import "$TMP/cert.pem" -k "$KEYCHAIN" -t cert >/dev/null
security import "$TMP/key.pem" -k "$KEYCHAIN" -t priv -T /usr/bin/codesign >/dev/null
echo "Added \"$NAME\" to $KEYCHAIN."
if [ "$KEYCHAIN" != "$LOGIN_KEYCHAIN" ]; then
  echo "It locks on sleep and after 5 minutes. To sign:  security unlock-keychain \"$KEYCHAIN\""
  echo "  APPMON_SIGN_KEYCHAIN=\"$KEYCHAIN\" APPMON_SIGN_IDENTITY=\"$NAME\" AppMonitor/build.sh"
fi

if [ -n "$P12" ]; then
  mv "$TMP/out.p12" "$P12"
  echo "Exported $P12 (readable only by you). Put it in GitHub secrets, then delete it."
fi

echo "SHA-1 of the certificate (identifies it in codesign -d -r- output):"
"$OPENSSL" x509 -in "$TMP/cert.pem" -noout -fingerprint -sha1 | sed 's/.*=//; s/://g'

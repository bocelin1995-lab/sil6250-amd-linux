#!/usr/bin/env bash
# setup-pam.sh — add fingerprint auth to sudo and GDM login
#
# Adds one line to /etc/pam.d/sudo and /etc/pam.d/gdm-password:
#     auth    sufficient    pam_fprintd.so timeout=10
# "sufficient" = fingerprint success grants access; failure/timeout falls back
# to password, so you can never lock yourself out.
#
# Keeps .bak backups. Run:  sudo ./setup-pam.sh
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "Run as root: sudo $0" >&2
    exit 1
fi

LINE="auth    sufficient    pam_fprintd.so timeout=10"

for f in sudo gdm-password; do
    p="/etc/pam.d/$f"
    [ -f "$p" ] || { echo "skip: $p not found" >&2; continue; }

    if grep -q 'pam_fprintd.so' "$p"; then
        echo "already configured: $p"
        continue
    fi

    cp -a "$p" "$p.bak"
    # insert before the first "@include common-auth" line
    awk -v line="$LINE" \
        '/^@include[[:space:]]+common-auth/ && !done { print line; done=1 } \
         { print }' "$p" > "$p.tmp"
    mv "$p.tmp" "$p"
    echo "configured: $p (backup: $p.bak)"
done

echo "PAM done. Restore with: sudo cp /etc/pam.d/{sudo,gdm-password}.bak /etc/pam.d/"

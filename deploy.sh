#!/usr/bin/env bash
set -euo pipefail

# Push rclone-helpers.sh to a remote host as ~/.rclone-helpers, then remind
# the user to source it from ~/.profile.
#
# On Synology DSM (BusyBox ash) you may prefer to paste the contents of
# rclone-helpers.sh directly into ~/.profile instead of sourcing a separate
# file — BusyBox's sh can be fussy about sourcing paths at login. In that
# case, change SRC to your local .profile and DEST to ~/.profile.

HOST="${1:-synology}"
SRC="rclone-helpers.sh"
DEST="~/.rclone-helpers"

if [[ ! -f "$SRC" ]]; then
  echo "Missing $SRC – run from the repo root." >&2
  exit 1
fi

# Backup the existing remote file (if any) and prune old backups
ssh "$HOST" "
  set -e
  if [ -f $DEST ]; then
    cp -a $DEST ${DEST}.bak.\$(date +%Y%m%d-%H%M%S)

    # Keep only the latest 10 backups
    ls -1t ${DEST}.bak.* 2>/dev/null \
      | awk 'NR>10' \
      | while IFS= read -r f; do
          [ -n \"\$f\" ] && rm -f \"\$f\"
        done
  fi
"

# Stream upload (bypasses DSM SFTP path quirks)
ssh "$HOST" "umask 022; cat > ${DEST}.new" < "$SRC"

# Atomic activate
ssh "$HOST" "set -e; mv ${DEST}.new $DEST; echo 'OK: $DEST deployed.'"

echo
echo "Done. Make sure ~/.profile sources the helpers:"
echo "  . $DEST"

#!/usr/bin/env bash
# ============================================================================
# terms-reset.sh – all users have to accept the terms of use again
#   Run after changing /opt/kira/config/terms-of-use.md: LibreChat only remembers "accepted yes/no",
#   not a version – without this script existing users do not see the new text.
#   Order: edit the text → bash /opt/kira/setup.sh (applies the text) → this script.
# ============================================================================
set -euo pipefail
KIRA_DIR=/opt/kira

[ "$(id -u)" = 0 ] || { echo "Error: please run as root." >&2; exit 1; }
[ "$(docker inspect -f '{{.State.Running}}' librechat-mongodb 2>/dev/null)" = "true" ] \
  || { echo "Error: container librechat-mongodb is not running." >&2; exit 1; }
MONGO_USER=$(sed -n 's/^MONGO_INITDB_ROOT_USERNAME=//p' "$KIRA_DIR/env/mongodb.env" | tr -d '"')
MONGO_PW=$(sed -n 's/^MONGO_INITDB_ROOT_PASSWORD=//p' "$KIRA_DIR/env/mongodb.env" | tr -d '"')

if [ "${1:-}" != "--yes" ]; then
  read -r -p "All users will have to accept the terms of use again on their next visit. Continue? [yes/no] " a
  case "${a,,}" in yes|y) ;; *) echo "Cancelled."; exit 0 ;; esac
fi

# Password passed into the container via an environment variable (no quoting issues with special characters)
n=$(docker exec -i -e MONGO_PW="$MONGO_PW" librechat-mongodb sh -c \
  'mongosh --quiet --username "$1" --password "$MONGO_PW" --authenticationDatabase admin LibreChat \
     --eval "const r = db.users.updateMany({termsAccepted: true}, {\$set: {termsAccepted: false}}); print(r.modifiedCount)"' \
  sh "$MONGO_USER" | tail -1) || { echo "Error: resetting in MongoDB failed." >&2; exit 1; }
echo "Reset: ${n:-0} users – they will see the terms of use on their next page load."

#!/usr/bin/env bash
# ============================================================================
# codeapi.sh – docker compose for the code interpreter with KIRA's settings (sources in src/, set up by setup.sh)
#   bash /opt/codeinterpreter/codeapi.sh ps | logs -f api | restart | down | build | up -d …
# Equivalent to: docker compose -p codeinterpreter -f src/docker-compose.yaml -f compose.kira.yml
#                  --env-file env/versions.env --env-file env/codeapi.env <command>
# ============================================================================
set -euo pipefail
DIR=/opt/codeinterpreter
[ -f "$DIR/src/docker-compose.yaml" ] || { echo "Error: $DIR/src is missing – run bash /opt/kira/setup.sh with CODE_INTERPRETER=true." >&2; exit 1; }
[ -f "$DIR/env/codeapi.env" ] || { echo "Error: $DIR/env/codeapi.env is missing – run bash /opt/kira/setup.sh." >&2; exit 1; }
exec docker compose -p codeinterpreter -f "$DIR/src/docker-compose.yaml" -f "$DIR/compose.kira.yml" \
  --env-file "$DIR/env/versions.env" --env-file "$DIR/env/codeapi.env" "$@"

#!/bin/sh
# ============================================================================
# Only on first start (empty volume): own role and database for Bifrost.
# ============================================================================
set -e
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" <<-EOSQL
	CREATE ROLE bifrost LOGIN PASSWORD '${BIFROST_DB_PASSWORD}';
	CREATE DATABASE bifrost OWNER bifrost ENCODING 'UTF8';
	REVOKE ALL ON DATABASE bifrost FROM PUBLIC;
EOSQL

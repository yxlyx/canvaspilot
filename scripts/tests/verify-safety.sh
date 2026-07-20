#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
PYTHON=${PYTHON:-python}
"$PYTHON" -c 'import sys; raise SystemExit(sys.version_info < (3, 12))'
# shellcheck source=../verify-mode.sh
source "$ROOT_DIR/scripts/verify-mode.sh"

expect_refusal() {
    local status
    if TEST_DATABASE_URL=$1 configure_database_mode "$PYTHON" >/dev/null 2>&1; then
        printf 'unsafe URL was accepted: %s\n' "$1" >&2
        exit 1
    else
        status=$?
    fi
    if ((status != 2)); then
        printf 'unsafe URL check did not execute correctly (status %d): %s\n' "$status" "$1" >&2
        exit 1
    fi
}

expect_refusal 'postgresql+asyncpg://user:pass@db/production'
expect_refusal 'postgresql+asyncpg://user:pass@db/wikibase_test?database=production'
expect_refusal 'postgresql+asyncpg://user:pass@db/wikibase_test?application_name=verify'
expect_refusal 'sqlite:///wikibase_test'
expect_refusal 'postgresql://user:pass@db/wikibase_test'
unset TEST_DATABASE_URL
DATABASE_URL='postgresql+asyncpg://user:pass@db/production'
expect_refusal ''

TEST_DATABASE_URL='postgresql+asyncpg://user:pass@db/wikibase_test'
configure_database_mode "$PYTHON"
[[ "$DATABASE_URL" == "$TEST_DATABASE_URL" ]]
[[ "$FAIL_ON_SKIPPED_TESTS" == 1 ]]
((${#PYTEST_MODE_ARGS[@]} == 0))

DATABASE_URL='postgresql+asyncpg://user:pass@db/production'
FAIL_ON_SKIPPED_TESTS=1
configure_no_database_mode
[[ "$DATABASE_URL" == *'/verify_no_db_test' ]]
[[ -z "${FAIL_ON_SKIPPED_TESTS:-}" ]]
[[ "${PYTEST_MODE_ARGS[*]}" == '-m not database' ]]

printf '%s\n' 'verify safety modes: passed'

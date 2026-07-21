#!/usr/bin/env bash

configure_database_mode() {
    local python=$1

    if [[ -z "${TEST_DATABASE_URL:-}" ]]; then
        printf '%s\n' 'verify: TEST_DATABASE_URL is required for database verification.' >&2
        printf '%s\n' 'verify: DATABASE_URL is never accepted because verification migrates and mutates its database.' >&2
        return 2
    fi
    (cd "$ROOT_DIR" && "$python" -m scripts.validate_test_database "$TEST_DATABASE_URL") || return
    export DATABASE_URL="$TEST_DATABASE_URL"
    export FAIL_ON_SKIPPED_TESTS=1
    PYTEST_MODE_ARGS=()
}

configure_no_database_mode() {
    unset FAIL_ON_SKIPPED_TESTS
    export DATABASE_URL='postgresql+asyncpg://invalid:invalid@127.0.0.1:1/verify_no_db_test'
    PYTEST_MODE_ARGS=(-m 'not database')
}

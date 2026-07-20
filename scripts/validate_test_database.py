#!/usr/bin/env python3
import re
import sys

from sqlalchemy.engine import make_url
from sqlalchemy.exc import ArgumentError


def validate_test_database_url(value: str) -> str:
    try:
        url = make_url(value)
    except ArgumentError as error:
        raise ValueError("TEST_DATABASE_URL must be a valid SQLAlchemy URL") from error
    if url.drivername != "postgresql+asyncpg":
        raise ValueError("TEST_DATABASE_URL must use the postgresql+asyncpg dialect")
    if url.query:
        raise ValueError("TEST_DATABASE_URL must not contain query parameters")

    _, connect_options = url.get_dialect()().create_connect_args(url)
    database = connect_options.get("database", connect_options.get("dbname", ""))
    if not database or not re.search(r"(^|[_-])test($|[_-])", database, re.IGNORECASE):
        raise ValueError(
            "TEST_DATABASE_URL database name must contain a distinct 'test' segment "
            "(for example, wikibase_test)"
        )
    return database


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: python -m scripts.validate_test_database URL", file=sys.stderr)
        return 2
    try:
        validate_test_database_url(sys.argv[1])
    except ValueError as error:
        print(f"verify: refusing unsafe TEST_DATABASE_URL: {error}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

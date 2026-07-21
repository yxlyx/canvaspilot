FROM python:3.14-slim@sha256:cea0e6040540fb2b965b6e7fb5ffa00871e632eef63719f0ea54bca189ce14a6 AS build

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build
COPY pyproject.toml requirements.lock ./
COPY app ./app
RUN python -m pip install --no-cache-dir --prefix=/install --require-hashes -r requirements.lock \
    && python -m pip install --no-cache-dir --prefix=/install --no-deps .

FROM python:3.14-slim@sha256:cea0e6040540fb2b965b6e7fb5ffa00871e632eef63719f0ea54bca189ce14a6 AS runtime

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

RUN useradd --system --uid 10001 --create-home wikibase
WORKDIR /app
COPY --from=build /install /usr/local
COPY alembic.ini ./
COPY app/db/migrations ./app/db/migrations

USER 10001
EXPOSE 8000

CMD ["python", "-m", "uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]

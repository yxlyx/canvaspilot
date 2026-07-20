FROM python:3.12-slim@sha256:57cd7c3a7a273101a6485ba99423ee568157882804b1124b4dd04266317710de AS build

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build
COPY pyproject.toml requirements.lock ./
COPY app ./app
RUN python -m pip install --no-cache-dir --prefix=/install --require-hashes -r requirements.lock \
    && python -m pip install --no-cache-dir --prefix=/install --no-deps .

FROM python:3.12-slim@sha256:57cd7c3a7a273101a6485ba99423ee568157882804b1124b4dd04266317710de AS runtime

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

FROM python:3.14-alpine@sha256:26730869004e2b9c4b9ad09cab8625e81d256d1ce97e72df5520e806b1709f92 AS build

WORKDIR /build
COPY pyproject.toml requirements.lock ./
COPY app ./app
RUN python -m pip install --no-cache-dir --prefix=/install --require-hashes -r requirements.lock \
    && python -m pip install --no-cache-dir --prefix=/install --no-deps .

FROM python:3.14-alpine@sha256:26730869004e2b9c4b9ad09cab8625e81d256d1ce97e72df5520e806b1709f92 AS runtime

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

RUN adduser -S -u 10001 -h /home/wikibase wikibase
WORKDIR /app
COPY --from=build /install /usr/local
COPY alembic.ini ./
COPY app/db/migrations ./app/db/migrations

USER 10001
EXPOSE 8000

CMD ["python", "-m", "uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]

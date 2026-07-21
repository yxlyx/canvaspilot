FROM python:3.12-alpine@sha256:6d43704baacd1bfbe7c295d7f13079d5d8104ed33568873133f8fc69980419df AS build

WORKDIR /build
COPY pyproject.toml requirements.lock ./
COPY app ./app
RUN python -m pip install --no-cache-dir --prefix=/install --require-hashes -r requirements.lock \
    && python -m pip install --no-cache-dir --prefix=/install --no-deps .

FROM python:3.12-alpine@sha256:6d43704baacd1bfbe7c295d7f13079d5d8104ed33568873133f8fc69980419df AS runtime

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

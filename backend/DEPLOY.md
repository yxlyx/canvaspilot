# Deploying the WikiBase backend on Fly.io

The backend runs from one immutable image as two independently supervised Fly
process groups:

- `app` serves the public FastAPI API;
- `worker` claims and executes durable processing stages.

Alembic runs once as Fly's release command before either process group is
updated. Do not prepend migrations to either process command, and do not start
the worker from the FastAPI process.

## Create and configure the app

Create a separate backend Fly application, then deploy this directory with its
actual app name:

```sh
cd backend
fly launch --no-deploy
fly deploy --app YOUR_BACKEND_APP
```

Set the required production configuration before the first deployment:

```sh
fly secrets set --app YOUR_BACKEND_APP \
  DATABASE_URL='postgresql+asyncpg://...' \
  SESSION_SECRET='...' \
  CANVAS_TOKEN_SECRET='...' \
  PROVIDER_ENCRYPTION_SECRET='...' \
  FRONTEND_URL='https://...' \
  BACKEND_URL='https://...' \
  CORS_ORIGINS='https://...'
```

Set provider credentials and OAuth configuration separately when those features
are enabled. `DATABASE_URL` must be reachable by the release Machine, API
Machines, and worker Machines.

## Verify the release

```sh
fly deploy --app YOUR_BACKEND_APP
fly status --app YOUR_BACKEND_APP
fly scale show --app YOUR_BACKEND_APP
fly logs --app YOUR_BACKEND_APP
```

Confirm that both `app` and `worker` have a running Machine. Import a small text
source, then verify that its processing run advances beyond `queued`. A release
must be treated as failed if the Alembic release command fails; do not serve a
new image against an older schema.

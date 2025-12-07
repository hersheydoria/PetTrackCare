# pettrackcare

A new Flutter project.

## Getting Started

This project is a starting point for a Flutter application.

A few resources to get you started if this is your first Flutter project:

- [Lab: Write your first Flutter app](https://docs.flutter.dev/get-started/codelab)
- [Cookbook: Useful Flutter samples](https://docs.flutter.dev/cookbook)

For help getting started with Flutter development, view the
[online documentation](https://docs.flutter.dev/), which offers tutorials,
samples, guidance on mobile development, and a full API reference.
# PetTrackCare

## Deploying the FastAPI backend on Render

1. Push `render.yaml` (shown above) to your repository so Render can autodetect the service and run `uvicorn app.main:app` on deploy.
2. In the Render dashboard create a new **Web Service** (or let the YAML create one) pointing at this repo and select the `backend/` directory if you keep FastAPI separate from the Flutter app.
3. Set the environment variables that FastAPI requires (`DATABASE_URL`, JWT secrets, `FASTAPI_BASE_URL`, etc.) using Render’s **Environment** tab. For `FASTAPI_BASE_URL` use the URL Render assigns to the backend, then configure the Flutter build to read that value (via `.env` or runtime config) so the mobile/web app hits the deployed API instead of `localhost`.
4. Add any Render-managed databases/storage (Postgres, S3) and update your FastAPI settings accordingly; Render exposes service connections via environment variables that you can reference in `backend/app/config` or `.env`.
5. Keep CORS and health-check paths updated (`/health` is configured in `render.yaml`) so Render can monitor the service and mobile/web clients can reach it from every origin.

Once the backend is live, rebuild/publish your Flutter app with the new `FASTAPI_BASE_URL` so the front end always targets the deployed API.

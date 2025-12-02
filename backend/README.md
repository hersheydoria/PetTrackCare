# FastAPI backend for PetTrackCare

This directory contains the new FastAPI + PostgreSQL backend that is being built to replace the Supabase project, while keeping media storage on Supabase for now.

## Quick start
1. Copy `.env.example` to `.env` and set the values (the default PostgreSQL password is `hershey`).
2. Install dependencies:
   ```bash
   python -m pip install -r requirements.txt
   ```
3. Run the FastAPI dev server:
   ```bash
   uvicorn app.main:app --reload
   ```

## Architecture highlights
- **SQLAlchemy models** mirror the Supabase tables (`users`, `pets`, `posts`, `notifications`, `location_history`, etc.).
- **Auth** is handled via JWT tokens; future work can plug in Supabase-compatible token issuance.
- **Routers** exist for each major feature set so the Flutter client can switch incrementally to HTTP calls.
- Media storage (profile/pet pictures) still relies on Supabase buckets; the new backend only manages metadata.
- Real-time behavior (notifications, location tracking) can be layered on via WebSocket endpoints once the core CRUD APIs are stable.

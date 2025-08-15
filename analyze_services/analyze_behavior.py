import os
from datetime import datetime, timedelta
from flask import Flask, request, jsonify, make_response
import pandas as pd
import numpy as np
from sklearn.ensemble import RandomForestClassifier
from sklearn.linear_model import LinearRegression
from sklearn.preprocessing import LabelEncoder
import tensorflow as tf
from supabase import create_client
from dotenv import load_dotenv
from apscheduler.schedulers.background import BackgroundScheduler
import json
import joblib

# Load environment variables
load_dotenv()
SUPABASE_URL = os.getenv("SUPABASE_URL")
SUPABASE_KEY = os.getenv("SUPABASE_KEY")
BACKEND_PORT = int(os.getenv("BACKEND_PORT", "5000"))

supabase = create_client(SUPABASE_URL, SUPABASE_KEY)
app = Flask(__name__)

# ------------------- Data Fetch & Model Logic -------------------

def fetch_logs_df(pet_id, limit=200):
    resp = supabase.table("behavior_logs").select("*").eq("pet_id", pet_id).order("log_date", desc=False).limit(limit).execute()
    data = resp.data or []
    if not data:
        return pd.DataFrame()
    df = pd.DataFrame(data)
    df['log_date'] = pd.to_datetime(df['log_date']).dt.date
    df['sleep_hours'] = pd.to_numeric(df['sleep_hours'], errors='coerce').fillna(0.0)
    df['mood'] = df['mood'].fillna('Unknown').astype(str)
    df['activity_level'] = df['activity_level'].fillna('Unknown').astype(str)
    return df

def train_illness_model(df, model_path="illness_model.pkl"):
    if df.shape[0] < 5:
        return None, None
    le_mood = LabelEncoder()
    le_activity = LabelEncoder()
    df['mood_enc'] = le_mood.fit_transform(df['mood'])
    df['act_enc'] = le_activity.fit_transform(df['activity_level'])
    X = df[['mood_enc', 'sleep_hours', 'act_enc']].values
    y = ((df['mood'].str.lower().isin(['lethargic','aggressive'])) | 
         (df['sleep_hours'] < 5) | 
         (df['activity_level'].str.lower()=='low')).astype(int).values
    clf = RandomForestClassifier(n_estimators=100, random_state=42)
    clf.fit(X, y)
    # Save model and encoders
    joblib.dump({'model': clf, 'le_mood': le_mood, 'le_activity': le_activity}, model_path)
    return clf, (le_mood, le_activity)

def load_illness_model(model_path="illness_model.pkl"):
    if os.path.exists(model_path):
        data = joblib.load(model_path)
        return data['model'], (data['le_mood'], data['le_activity'])
    return None, None

def forecast_sleep_with_tf(series, days_ahead=7, model_path="sleep_model.keras"):
    arr = np.array(series).astype(float)
    if len(arr) < 3:
        last = float(arr[-1]) if len(arr)>0 else 8.0
        return [last for _ in range(days_ahead)]
    window = 7
    X, y = [], []
    for i in range(len(arr)-window):
        X.append(arr[i:i+window])
        y.append(arr[i+window])
    if len(X) < 2:
        lr = LinearRegression()
        idx = np.arange(len(arr)).reshape(-1,1)
        lr.fit(idx, arr)
        next_idx = np.arange(len(arr), len(arr)+days_ahead).reshape(-1,1)
        return lr.predict(next_idx).clip(0,24).tolist()
    X, y = np.array(X), np.array(y)
    if os.path.exists(model_path):
        model = tf.keras.models.load_model(model_path)
    else:
        model = tf.keras.Sequential([
            tf.keras.layers.Input(shape=(X.shape[1],)),
            tf.keras.layers.Dense(32, activation='relu'),
            tf.keras.layers.Dense(16, activation='relu'),
            tf.keras.layers.Dense(1)
        ])
        model.compile(optimizer='adam', loss='mse')
    model.fit(X, y, epochs=50, batch_size=8, verbose=0)
    model.save(model_path)
    preds, last_window = [], arr[-window:].copy()
    for _ in range(days_ahead):
        p = float(model.predict(last_window.reshape(1, -1), verbose=0)[0,0])
        p = max(0.0, min(24.0, p))
        preds.append(p)
        last_window = np.concatenate([last_window[1:], [p]])
    return preds

def calc_mood_activity_trends(df, days=7):
    today = datetime.utcnow().date()
    all_days = [today - timedelta(days=i) for i in range(days-1, -1, -1)]
    mood_counts, activity_counts = {}, {}
    for _, row in df.iterrows():
        if row['log_date'] in all_days:
            mood = row['mood'].lower()
            act = row['activity_level'].lower()
            mood_counts[mood] = mood_counts.get(mood, 0) + 1
            activity_counts[act] = activity_counts.get(act, 0) + 1
    total_m, total_a = sum(mood_counts.values()) or 1, sum(activity_counts.values()) or 1
    mood_prob = {k: v/total_m for k,v in mood_counts.items()}
    activity_prob = {k: v/total_a for k,v in activity_counts.items()}
    return mood_prob, activity_prob

# ------------------- Core Analysis -------------------
def forecast_sleep_trend(df):
    # Example placeholder logic — replace with your real forecasting logic
    if df.empty:
        return "No sleep data available"

    avg_sleep = df["sleep_hours"].mean()
    if avg_sleep < 6:
        return "Pet might be sleep deprived"
    elif avg_sleep > 9:
        return "Pet is oversleeping"
    else:
        return "Pet sleep is normal"

def analyze_pet_df(pet_id, df, prediction_date=None, store=True):
    """Analyze provided DataFrame of logs for pet_id and (optionally) store prediction for prediction_date."""
    if df.empty:
        return {
            "trend": "No data available.",
            "recommendation": "Log more behavior data to get analysis.",
            "sleep_trend": "N/A",
            "mood_prob": None,
            "activity_prob": None
        }

    # Ensure dates are datetimes
    df = df.copy()
    df['log_date'] = pd.to_datetime(df['log_date'])

    # Calculate mood/activity probabilities
    mood_counts = df['mood'].str.lower().value_counts(normalize=True).to_dict()
    mood_prob = {m: round(p, 2) for m, p in mood_counts.items()}
    activity_counts = df['activity_level'].str.lower().value_counts(normalize=True).to_dict()
    activity_prob = {a: round(p, 2) for a, p in activity_counts.items()}

    # Trend and risk logic (same as before)
    trend = "Pet is doing well overall."
    risk_level = "low"
    recommendation = "Keep up the good work!"

    if mood_prob.get('aggressive', 0) > 0.3:
        trend = "Pet is showing aggressive behavior."
        risk_level = "high"
        recommendation = "Consult a professional if aggression persists."
    elif mood_prob.get('lethargic', 0) > 0.3:
        trend = "Pet is often lethargic."
        risk_level = "medium"
        recommendation = "Monitor pet's energy and consult a vet if needed."
    elif mood_prob.get('anxious', 0) > 0.3:
        trend = "Pet seems anxious frequently."
        risk_level = "medium"
        recommendation = "Provide a calm environment and reassurance."
    elif mood_prob.get('sad', 0) > 0.5:
        trend = "Pet seems sad often."
        risk_level = "medium"
        recommendation = "Spend more time with your pet."
    elif mood_prob.get('happy', 0) > 0.5:
        trend = "Pet is mostly happy."
        risk_level = "low"
        recommendation = "Keep up the good work!"
    elif mood_prob.get('calm', 0) > 0.5:
        trend = "Pet is calm and relaxed."
        risk_level = "low"
        recommendation = "Maintain current routine."

    # Activity level logic
    if activity_prob.get('low', 0) > 0.5:
        recommendation += " Increase pet activity through playtime."
        if risk_level == "low":
            risk_level = "medium"
    elif activity_prob.get('high', 0) > 0.5:
        recommendation += " Pet is very active."
    elif activity_prob.get('medium', 0) > 0.5:
        recommendation += " Activity level is moderate."

    # Sleep trend forecast
    sleep_trend = forecast_sleep_trend(df)
    avg_sleep = df["sleep_hours"].mean()
    if avg_sleep < 6:
        trend += " Possible sleep deprivation."
        risk_level = "high"
        recommendation += " Ensure your pet gets enough rest."
    elif avg_sleep > 9:
        trend += " Pet may be oversleeping."
        recommendation += " Monitor for signs of illness."

    # Determine prediction_date to store (default to today)
    pred_date = (pd.to_datetime(prediction_date).date().isoformat()
                 if prediction_date is not None
                 else datetime.utcnow().date().isoformat())

    payload = {
        "pet_id": pet_id,
        "prediction_date": pred_date,
        "prediction_text": trend,
        "risk_level": risk_level,
        "suggestions": recommendation,
        "activity_prob": activity_prob.get("high", 0)
    }

    if store:
        try:
            # check existing prediction for idempotency
            existing = supabase.table("predictions").select("id").eq("pet_id", pet_id).eq("prediction_date", pred_date).execute()
            if not (existing.data):
                resp = supabase.table("predictions").insert(payload).execute()
                if getattr(resp, "error", None):
                    print(f"[ERROR] Failed to insert prediction for pet {pet_id} date {pred_date}: {resp.error}")
                else:
                    print(f"[INFO] Inserted prediction for pet {pet_id} date {pred_date}")
            else:
                # optionally update? for now skip if existing
                print(f"[INFO] Prediction already exists for pet {pet_id} date {pred_date}; skipping insert.")
        except Exception as e:
            print(f"Error storing prediction for pet {pet_id} date {pred_date}: {e}")

    return {
        "trend": trend,
        "recommendation": recommendation,
        "sleep_trend": sleep_trend,
        # keep legacy (short) keys
        "mood_prob": mood_prob,
        "activity_prob": activity_prob,
        # add UI-friendly plural keys so pet_screen can read mood_probabilities / activity_probabilities
        "mood_probabilities": mood_prob,
        "activity_probabilities": activity_prob
    }

def analyze_pet(pet_id):
    """Backward-compatible wrapper: fetch logs then analyze & store prediction for today."""
    df = fetch_logs_df(pet_id)
    return analyze_pet_df(pet_id, df, prediction_date=datetime.utcnow().date().isoformat())

# ------------------- Migration: move behavior_logs into predictions -------------------
def migrate_behavior_logs_to_predictions(limit_per_pet=1000):
    """
    Fetch behavior_logs and generate/store predictions historically.
    For each pet, for each unique log_date, analyze logs up to that date and insert prediction if missing.
    This is idempotent: it checks predictions table for existence before inserting.
    """
    print("Starting migration of behavior_logs -> predictions...")
    try:
        resp = supabase.table("behavior_logs").select("*").order("log_date", desc=False).limit(100000).execute()
        logs = resp.data or []
        total_logs = len(logs)
        print(f"Found {total_logs} behavior_logs records.")
        if not logs:
            print("No behavior_logs to migrate.")
            return

        df_all = pd.DataFrame(logs)
        # normalize types
        df_all['log_date'] = pd.to_datetime(df_all['log_date']).dt.date
        df_all['sleep_hours'] = pd.to_numeric(df_all.get('sleep_hours', 0), errors='coerce').fillna(0.0)
        df_all['mood'] = df_all['mood'].fillna('Unknown').astype(str)
        df_all['activity_level'] = df_all['activity_level'].fillna('Unknown').astype(str)

        inserted_total = 0
        analyzed_total = 0
        pet_count = 0

        for pet_id, group in df_all.groupby('pet_id'):
            pet_count += 1
            # Unique sorted dates
            dates = sorted(group['log_date'].unique())
            print(f"Processing pet {pet_id} with {len(dates)} unique dates.")
            for d in dates[:limit_per_pet]:
                analyzed_total += 1
                # build df of logs up to and including d
                subset = group[group['log_date'] <= d].copy()
                # convert back to expected format for analyze_pet_df
                subset['log_date'] = pd.to_datetime(subset['log_date'])
                # train models on full pet logs (optional step - fine-tune)
                try:
                    train_illness_model(subset)
                    forecast_sleep_with_tf(subset['sleep_hours'].tolist())
                except Exception as e:
                    print(f"Model training error for pet {pet_id} on date {d}: {e}")

                # analyze and store prediction for that historic date
                try:
                    # analyze_pet_df will attempt to store (store=True)
                    analyze_pet_df(pet_id, subset, prediction_date=d.isoformat(), store=True)
                    # After analyze_pet_df runs, check if inserted by querying predictions
                    existing = supabase.table("predictions").select("id").eq("pet_id", pet_id).eq("prediction_date", d.isoformat()).execute()
                    if existing.data:
                        inserted_total += 1
                except Exception as e:
                    print(f"Analysis error for pet {pet_id} on date {d}: {e}")

        print(f"Migration completed. Pets processed: {pet_count}, dates analyzed: {analyzed_total}, predictions present/inserted: {inserted_total}.")
    except Exception as e:
        print(f"Unexpected error during migration: {e}")

# ------------------- Core Analysis -------------------
def forecast_sleep_trend(df):
    # Example placeholder logic — replace with your real forecasting logic
    if df.empty:
        return "No sleep data available"

    avg_sleep = df["sleep_hours"].mean()
    if avg_sleep < 6:
        return "Pet might be sleep deprived"
    elif avg_sleep > 9:
        return "Pet is oversleeping"
    else:
        return "Pet sleep is normal"

# ------------------- Flask API -------------------
 
@app.route("/analyze", methods=["POST"])
def analyze_endpoint():
    data = request.get_json()
    pet_id = data.get("pet_id")
    if not pet_id:
        return jsonify({"error": "pet_id required"}), 400

    # Core analysis (trend/recommendation/summaries) based on logs
    result = analyze_pet(pet_id)

    # Also provide a numeric 7-day sleep forecast (if possible) and an illness risk
    # using the latest log entry (if a trained illness model exists).
    df = fetch_logs_df(pet_id)

    # sleep_forecast: numeric list (uses predict_future_sleep which loads/trains the TF model)
    try:
        sleep_series = df["sleep_hours"].tolist() if not df.empty else []
        sleep_forecast = predict_future_sleep(sleep_series)
    except Exception:
        # fallback: empty or repeated last value
        last = sleep_series[-1] if sleep_series else 8.0
        sleep_forecast = [last for _ in range(7)]

    # illness_risk: try to get latest log and run predict_illness_risk (returns "high"/"low" or None)
    illness_risk = None
    try:
        if not df.empty:
            latest = df.sort_values("log_date", ascending=False).iloc[0]
            mood = str(latest.get("mood", "") or "")
            sleep_hours = float(latest.get("sleep_hours") or 0.0)
            activity_level = str(latest.get("activity_level", "") or "")
            illness_risk = predict_illness_risk(mood, sleep_hours, activity_level)
    except Exception:
        illness_risk = None

    # Merge into response
    merged = dict(result)
    merged["illness_risk"] = illness_risk
    merged["sleep_forecast"] = sleep_forecast
    return jsonify(merged)

@app.route("/predict", methods=["POST"])
def predict_endpoint():
    data = request.get_json()
    pet_id = data.get("pet_id")
    mood = data.get("mood")
    sleep_hours = data.get("sleep_hours")
    activity_level = data.get("activity_level")
    if not all([pet_id, mood, sleep_hours, activity_level]):
        return jsonify({"error": "Missing fields"}), 400

    # Illness risk prediction
    illness_risk = predict_illness_risk(mood, sleep_hours, activity_level)

    # Sleep forecast prediction
    df = fetch_logs_df(pet_id)
    sleep_series = df["sleep_hours"].tolist() if not df.empty else []
    sleep_forecast = predict_future_sleep(sleep_series)

    return jsonify({
        "illness_risk": illness_risk,
        "sleep_forecast": sleep_forecast
    })

# ------------------- Public pet info page -------------------
@app.route("/pet/<pet_id>", methods=["GET"])
def public_pet_page(pet_id):
    try:
        # fetch pet
        resp = supabase.table("pets").select("*").eq("id", pet_id).limit(1).execute()
        pet_rows = resp.data or []
        if not pet_rows:
            return make_response("<h3>Pet not found</h3>", 404)
        pet = pet_rows[0]

        # resolve owner using the app USERS table (schema: id, name, email, role)
        owner_name = None
        owner_email = None
        owner_role = None
        owner_id = pet.get("owner_id")

        if owner_id:
            try:
                # use app users table fields per your schema
                uresp = supabase.table("users").select("name, email, role").eq("id", owner_id).limit(1).execute()
                urows = uresp.data or []
                if urows:
                    u0 = urows[0]
                    owner_name = u0.get("name")
                    owner_email = u0.get("email") or owner_email
                    owner_role = u0.get("role") or owner_role
            except Exception:
                # ignore errors and continue to fallback attempts
                owner_name = owner_name or None

            # best-effort: if name missing, try to fetch auth users metadata (if available in your Supabase instance)
            if not owner_name:
                try:
                    # supabase.auth.api.get_user may be available in your client; wrapped in try/except
                    auth_user = None
                    if hasattr(supabase.auth, "api") and hasattr(supabase.auth.api, "get_user"):
                        auth_user = supabase.auth.api.get_user(owner_id)
                    elif hasattr(supabase.auth, "get_user"):
                        # alternative method name
                        auth_user = supabase.auth.get_user(owner_id)
                    if auth_user:
                        # auth_user may be dict-like or object; handle both
                        meta = {}
                        try:
                            # attempt multiple possible attribute / key names
                            meta = (auth_user.get("user_metadata") if isinstance(auth_user, dict) else getattr(auth_user, "user_metadata", None)) or \
                                   (auth_user.get("raw_user_meta_data") if isinstance(auth_user, dict) else getattr(auth_user, "raw_user_meta_data", None)) or {}
                        except Exception:
                            meta = {}
                        if isinstance(meta, str):
                            try:
                                meta = json.loads(meta)
                            except Exception:
                                meta = {}
                        if isinstance(meta, dict):
                            # prefer common keys
                            owner_name = owner_name or (meta.get("name") or meta.get("full_name") or meta.get("display_name"))
                except Exception:
                    pass

        # fallback: use email local-part or owner id or generic label
        if not owner_name:
            if owner_email:
                try:
                    owner_name = owner_email.split("@")[0]
                except Exception:
                    owner_name = owner_email
            else:
                owner_name = owner_id or "Owner"

        # prepare pet fields for display (added gender & health)
        pet_name = pet.get("name") or "Unnamed"
        pet_breed = pet.get("breed") or "Unknown"
        pet_age = pet.get("age") or ""
        pet_weight = pet.get("weight") or ""
        pet_gender = pet.get("gender") or "Unknown"
        pet_health = pet.get("health") or "Unknown"

        # fetch latest prediction for illness/risk info, if present
        latest_prediction_text = ""
        latest_suggestions = ""
        latest_risk = None
        try:
            presp = supabase.table("predictions").select("prediction_text, risk_level, suggestions, created_at").eq("pet_id", pet_id).order("created_at", desc=True).limit(1).execute()
            prows = presp.data or []
            if prows:
                p0 = prows[0]
                latest_prediction_text = p0.get("prediction_text") or p0.get("prediction") or ""
                latest_suggestions = p0.get("suggestions") or p0.get("recommendations") or ""
                latest_risk = (p0.get("risk_level") or p0.get("risk") or None)
        except Exception:
            latest_prediction_text = ""
            latest_suggestions = ""
            latest_risk = None

        # determine a simple color for risk badge
        if latest_risk:
            lr = str(latest_risk).lower()
            if "high" in lr:
                risk_color = "#B82132"  # deep red
            elif "medium" in lr:
                risk_color = "#FF8C00"  # orange
            elif "low" in lr:
                risk_color = "#2ECC71"  # green
            else:
                risk_color = "#666666"
        else:
            risk_color = "#2ECC71"  # healthy default (green)

        # Simple HTML with modal dialog - auto-open on load
        html = f"""
        <!doctype html>
        <html>
        <head>
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <title>Pet Info - {pet_name}</title>
          <style>
            body {{ font-family: Arial, sans-serif; background:#f6f6f6; padding:16px; }}
            .card {{ max-width: 520px; margin:24px auto; background:#fff; border-radius:8px; padding:16px; box-shadow:0 6px 18px rgba(0,0,0,0.08); }}
            .label {{ color:#666; font-size:13px; }}
            .value {{ color:#222; font-weight:600; font-size:18px; }}
            .badge {{ display:inline-block;padding:6px 10px;border-radius:12px;font-weight:600;color:#fff;font-size:13px; }}
            /* modal */
            .modal-backdrop{{position:fixed;inset:0;background:rgba(0,0,0,0.45);display:flex;align-items:center;justify-content:center;}}
            .modal{{background:#fff;border-radius:10px;padding:18px;max-width:420px;width:90%;box-shadow:0 10px 30px rgba(0,0,0,0.2);}}
            .close-btn{{background:#B82132;color:#fff;border:none;padding:8px 12px;border-radius:6px;cursor:pointer;}}
          </style>
        </head>
        <body>
          <div class="card">
            <h2>Pet Quick Info</h2>
            <p class="label">Name</p><p class="value">{pet_name}</p>
            <p class="label">Breed</p><p class="value">{pet_breed}</p>
            <p class="label">Age</p><p class="value">{pet_age}</p>
            <p class="label">Weight</p><p class="value">{pet_weight}</p>
            <p class="label">Gender</p><p class="value">{pet_gender}</p>
            <p class="label">Health</p><p class="value">{pet_health}</p>
            <p class="label">Owner</p><p class="value">{owner_name}</p>
            <div style="display:flex;gap:8px;align-items:center;justify-content:space-between;margin-top:8px;">
              <div>
                <span class="label">Illness Risk</span><br/>
                <span class="badge" style="background:{risk_color};">{(latest_risk or 'No risk detected').capitalize() if latest_risk else 'Healthy'}</span>
                <p style="margin-top:8px;color:#666;font-size:13px;">Scan opened this page — tap "More" for details.</p>
              </div>
              <div style="text-align:right;">
                <button onclick="openModal()" style="background:#eee;border-radius:6px;padding:8px 12px;border:none;cursor:pointer;">More</button>
              </div>
            </div>
          </div>

          <div id="modal" style="display:none;" class="modal-backdrop" onclick="closeModal()">
            <div class="modal" onclick="event.stopPropagation()">
              <h3>Detailed Pet Info</h3>
              <p><strong>Name:</strong> {pet_name}</p>
              <p><strong>Breed:</strong> {pet_breed}</p>
              <p><strong>Age:</strong> {pet_age}</p>
              <p><strong>Weight:</strong> {pet_weight}</p>
              <p><strong>Gender:</strong> {pet_gender}</p>
              <p><strong>Health:</strong> {pet_health}</p>
              <p><strong>Owner:</strong> {owner_name}</p>
              <hr/>
              <h4>Latest Analysis</h4>
              <p><strong>Risk:</strong> {(latest_risk or 'None')}</p>
              <p><strong>Summary:</strong> {latest_prediction_text or 'No analysis available'}</p>
              <p><strong>Recommendation:</strong> {latest_suggestions or 'No recommendations available'}</p>
              <div style="margin-top:12px;text-align:right;">
                <button class="close-btn" onclick="closeModal()">Close</button>
              </div>
            </div>
          </div>

          <script>
            function openModal() {{
              document.getElementById('modal').style.display = 'flex';
            }}
            function closeModal() {{
              document.getElementById('modal').style.display = 'none';
            }}
            // auto-open modal on page load so scanned users see pop-up immediately
            window.addEventListener('load', function() {{
              setTimeout(openModal, 400);
            }});
          </script>
        </body>
        </html>
        """
        return make_response(html, 200, {"Content-Type": "text/html"})
    except Exception as e:
        return make_response(f"<h3>Error: {str(e)}</h3>", 500)

# Alias route so URLs under /analyze/pet/<id> also resolve (compatible with QR payloads that include /analyze)
@app.route("/analyze/pet/<pet_id>", methods=["GET"])
def public_pet_page_alias(pet_id):
    return public_pet_page(pet_id)

# ------------------- Daily Scheduler -------------------

def daily_analysis_job():
    print(f"🔄 Running daily pet behavior analysis at {datetime.now()}")
    pets_resp = supabase.table("pets").select("id").execute()
    for pet in pets_resp.data or []:
        df = fetch_logs_df(pet["id"])
        if not df.empty:
            train_illness_model(df)  # retrain and persist illness model
            forecast_sleep_with_tf(df["sleep_hours"].tolist())  # retrain and persist sleep model
        result = analyze_pet(pet["id"])
        print(f"📊 Pet {pet['id']} analysis stored:", result)

scheduler = BackgroundScheduler()
scheduler.add_job(daily_analysis_job, 'interval', days=1)  # runs every 24h
scheduler.add_job(migrate_behavior_logs_to_predictions, 'interval', days=1)  # ensure daily migration/analysis
scheduler.start()

if __name__ == "__main__":
    # Run a one-time migration at startup (safe and idempotent)
    try:
        migrate_behavior_logs_to_predictions()
    except Exception as e:
        print(f"Startup migration error: {e}")
    app.run(host="0.0.0.0", port=BACKEND_PORT)

def store_prediction(pet_id, prediction, risk_level, recommendation):
    # kept for backward compatibility
    supabase.table("predictions").insert({
        "pet_id": pet_id,
        "prediction_date": datetime.utcnow().date().isoformat(),
        "prediction_text": prediction,
        "risk_level": risk_level,
        "suggestions": recommendation
    }).execute()

def predict_illness_risk(mood, sleep_hours, activity_level, model_path="illness_model.pkl"):
    model, encoders = load_illness_model(model_path)
    if model is None or encoders is None:
        return None  # Model not trained yet
    le_mood, le_activity = encoders
    # Encode inputs safely
    mood_enc = le_mood.transform([mood])[0] if mood in getattr(le_mood, "classes_", []) else 0
    act_enc = le_activity.transform([activity_level])[0] if activity_level in getattr(le_activity, "classes_", []) else 0
    X = np.array([[mood_enc, float(sleep_hours), act_enc]])
    pred = model.predict(X)[0]
    risk = "high" if pred == 1 else "low"
    return risk

def predict_future_sleep(sleep_series, days_ahead=7, model_path="sleep_model.keras"):
    arr = np.array(sleep_series).astype(float)
    window = 7
    if len(arr) < window:
        last = float(arr[-1]) if len(arr)>0 else 8.0
        return [last for _ in range(days_ahead)]
    model = tf.keras.models.load_model(model_path)
    preds, last_window = [], arr[-window:].copy()
    for _ in range(days_ahead):
        p = float(model.predict(last_window.reshape(1, -1), verbose=0)[0,0])
        p = max(0.0, min(24.0, p))
        preds.append(p)
        last_window = np.concatenate([last_window[1:], [p]])
    return preds
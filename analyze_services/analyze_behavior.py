import os
from datetime import datetime, timedelta
from flask import Flask, request, jsonify, make_response
import pandas as pd
import numpy as np
from sklearn.ensemble import RandomForestClassifier
from sklearn.linear_model import LinearRegression
from sklearn.preprocessing import LabelEncoder
from sklearn.model_selection import cross_val_score, StratifiedKFold
import tensorflow as tf
from supabase import create_client
from dotenv import load_dotenv
from apscheduler.schedulers.background import BackgroundScheduler
import json
import joblib
import subprocess
import sys
import argparse

# Load environment variables
load_dotenv()
SUPABASE_URL = os.getenv("SUPABASE_URL")
SUPABASE_KEY = os.getenv("SUPABASE_KEY")
BACKEND_PORT = int(os.getenv("BACKEND_PORT", "5000"))

supabase = create_client(SUPABASE_URL, SUPABASE_KEY)
app = Flask(__name__)

# Ensure a stable models directory
BASE_DIR = os.path.dirname(os.path.abspath(__file__))
MODELS_DIR = os.path.join(BASE_DIR, "models")
os.makedirs(MODELS_DIR, exist_ok=True)

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

def train_illness_model(df, model_path=os.path.join(MODELS_DIR, "illness_model.pkl"), min_auc_threshold: float = 0.6):
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

    # Guard: need both classes to train a classifier
    if len(np.unique(y)) < 2:
        return None, None
    # Use class balancing to mitigate imbalance
    clf = RandomForestClassifier(n_estimators=100, random_state=42, class_weight='balanced')
    clf.fit(X, y)

    # Try to evaluate model (cross-validated AUC) when we have enough samples
    auc_score = None
    try:
        if len(y) >= 10:
            cv = StratifiedKFold(n_splits=3, shuffle=True, random_state=42)
            scores = cross_val_score(clf, X, y, cv=cv, scoring='roc_auc')
            auc_score = float(np.mean(scores))
    except Exception:
        auc_score = None

    # If we have a CV AUC and it's below the minimum threshold, do NOT save the model.
    if auc_score is not None and auc_score < float(min_auc_threshold):
        print(f"[WARN] Trained model AUC={auc_score:.3f} below threshold {min_auc_threshold}; not saving model.")
        # Return None to indicate model was not persisted/accepted
        return None, None

    # Build mapping dictionaries to handle unseen labels at prediction time
    mood_map = {v: i for i, v in enumerate(getattr(le_mood, 'classes_', []))}
    act_map = {v: i for i, v in enumerate(getattr(le_activity, 'classes_', []))}

    # Determine most common classes seen during training for safe fallback
    mood_most_common = None
    act_most_common = None
    try:
        mood_most_common = df['mood'].mode().iloc[0] if not df['mood'].mode().empty else None
    except Exception:
        mood_most_common = None
    try:
        act_most_common = df['activity_level'].mode().iloc[0] if not df['activity_level'].mode().empty else None
    except Exception:
        act_most_common = None

    metadata = {
        'trained_at': datetime.utcnow().isoformat(),
        'n_samples': int(len(y)),
        'pos_rate': float(np.mean(y)),
        'auc': auc_score,
        'mood_most_common': (mood_most_common or '').lower() if mood_most_common else None,
        'act_most_common': (act_most_common or '').lower() if act_most_common else None,
    }

    joblib.dump({
        'model': clf,
        'le_mood': le_mood,
        'le_activity': le_activity,
        'mood_map': mood_map,
        'act_map': act_map,
        'metadata': metadata,
    }, model_path)

    return clf, (le_mood, le_activity)

def load_illness_model(model_path=os.path.join(MODELS_DIR, "illness_model.pkl")):
    if os.path.exists(model_path):
        data = joblib.load(model_path)
        model = data.get('model')
        le_mood = data.get('le_mood')
        le_activity = data.get('le_activity')
        mood_map = data.get('mood_map')
        act_map = data.get('act_map')
        metadata = data.get('metadata')
        return model, (le_mood, le_activity), mood_map, act_map, metadata
    return None, None

def is_illness_model_trained(model_path=os.path.join(MODELS_DIR, "illness_model.pkl")):
    """Return True if a trained illness model (with encoders) exists on disk."""
    try:
        if not os.path.exists(model_path):
            return False
        data = joblib.load(model_path)
        return bool(data and data.get("model") and data.get("le_mood") and data.get("le_activity"))
    except Exception:
        return False

def get_latest_prediction_risk(pet_id: str):
    """Read the latest risk_level from predictions table for a pet (prediction_date or created_at)."""
    try:
        resp = supabase.table("predictions").select("risk_level").eq("pet_id", pet_id).order("prediction_date", desc=True).limit(1).execute()
        rows = resp.data or []
        if not rows:
            resp = supabase.table("predictions").select("risk_level").eq("pet_id", pet_id).order("created_at", desc=True).limit(1).execute()
            rows = resp.data or []
        if rows:
            val = rows[0].get("risk_level") or rows[0].get("risk")
            return str(val).lower() if val else None
    except Exception:
        pass
    return None

def forecast_sleep_with_tf(series, days_ahead=7, model_path=os.path.join(MODELS_DIR, "sleep_model.keras")):
    """
    Backward-compatible wrapper that delegates to predict_future_sleep.
    Ensures migration and scheduler code that calls this keep working.
    """
    try:
        return predict_future_sleep(series, days_ahead=days_ahead, model_path=model_path)
    except Exception:
        # conservative fallback
        last = float(series[-1]) if series else 8.0
        return [last for _ in range(days_ahead)]

def build_care_recommendations(illness_risk, mood_prob, activity_prob, avg_sleep, sleep_trend):
    """Return structured care tips: actions to take and what to expect."""
    risk = (str(illness_risk or "low")).lower()
    mood_prob = mood_prob or {}
    activity_prob = activity_prob or {}
    avg_sleep = float(avg_sleep) if avg_sleep is not None else 8.0
    s_trend = (sleep_trend or "").lower()

    actions, expectations = [], []

    # Risk-based guidance
    if risk == "high":
        actions += [
            "Book a veterinary check within 24–48 hours.",
            "Provide a quiet, stress‑free resting area.",
            "Limit strenuous activity and supervise closely."
        ]
        expectations += [
            "Energy and appetite may fluctuate for 1–2 days.",
            "Behavior may be atypical while recovering/resting."
        ]
    elif risk == "medium":
        actions += [
            "Monitor behavior for 48 hours and reduce intense play.",
            "Prioritize calm enrichment (sniff walks, puzzle feeders)."
        ]
        expectations += [
            "Minor mood/activity changes may persist for a few days."
        ]
    else:
        actions += [
            "Maintain regular routine with daily exercise and enrichment."
        ]
        expectations += [
            "Normal behavior; continue routine monitoring."
        ]

    # Mood-focused tips
    top_mood = max(mood_prob, key=mood_prob.get) if mood_prob else None
    if top_mood == "lethargic":
        actions += [
            "Offer short, low‑impact play sessions (2–3× for 10–15 min).",
            "Encourage hydration and balanced meals."
        ]
        expectations += [
            "Lower play interest; energy should improve with rest and routine."
        ]
    elif top_mood == "aggressive":
        actions += [
            "Avoid triggers and high‑arousal games; use calm routines.",
            "Consult a trainer/behavior professional if aggression persists."
        ]
        expectations += [
            "Irritability around stressors; consistency reduces incidents."
        ]
    elif top_mood == "anxious":
        actions += [
            "Create a safe space (crate/quiet room) and predictable schedule.",
            "Use gradual exposure to stressors; avoid flooding."
        ]
        expectations += [
            "Anxiety may spike with change; tends to settle with routine."
        ]
    elif top_mood == "sad":
        actions += [
            "Increase engagement (gentle play, short training, sniff walks).",
            "Provide social time and novel but low‑stress enrichment."
        ]
        expectations += [
            "Mood should lift with stimulation and consistent interaction."
        ]

    # Activity level tips
    if activity_prob.get("low", 0) > 0.5:
        actions += [
            "Schedule 2–3 short play sessions spaced through the day.",
            "Mix physical and mental enrichment to boost motivation."
        ]
        expectations += [
            "Gradual energy improvement with consistent play."
        ]
    elif activity_prob.get("high", 0) > 0.5:
        actions += [
            "Build in calm downtime after exercise and ensure water access."
        ]
        expectations += [
            "Temporary restlessness can settle with a consistent routine."
        ]

    # Sleep tips
    if avg_sleep < 6 or ("depriv" in s_trend):
        actions += [
            "Set a consistent sleep routine; avoid late‑night stimulation."
        ]
        expectations += [
            "Sleep should normalize within 2–3 nights with routine."
        ]
    elif avg_sleep > 9 or ("oversleep" in s_trend):
        actions += [
            "Break up long naps with gentle activity and enrichment."
        ]
        expectations += [
            "Oversleeping often eases with more engaging daytime activity."
        ]

    # General best practices
    actions += [
        "Keep fresh water available at all times.",
        "Use puzzle feeders or sniff walks for mental enrichment.",
        "Continue logging mood, activity, and sleep daily."
    ]
    if risk == "high":
        actions += ["Contact your vet immediately if symptoms worsen."]

    # De‑duplicate while preserving order
    def _dedup(seq):
        seen, out = set(), []
        for item in seq:
            key = item.strip().lower()
            if key and key not in seen:
                out.append(item)
                seen.add(key)
        return out

    return {
        "actions": _dedup(actions)[:10],
        "expectations": _dedup(expectations)[:8]
    }

def compute_contextual_risk(df: pd.DataFrame) -> str:
    """
    Compute a smoothed illness risk ('low'/'medium'/'high') from recent logs
    by combining mood/activity proportions and recent sleep averages.
    De-escalates if the last few days look healthy.
    """
    if df is None or df.empty:
        return "low"
    try:
        recent = df.copy()
        recent['log_date'] = pd.to_datetime(recent['log_date'])
        recent = recent.sort_values('log_date').tail(14)

        mood_counts = recent['mood'].str.lower().value_counts(normalize=True)
        act_counts = recent['activity_level'].str.lower().value_counts(normalize=True)

        last7 = recent.tail(7)
        last3 = recent.tail(3)

        avg_sleep7 = float(last7['sleep_hours'].mean()) if not last7.empty else float(recent['sleep_hours'].mean())
        avg_sleep3 = float(last3['sleep_hours'].mean()) if not last3.empty else avg_sleep7

        p_aggr = float(mood_counts.get('aggressive', 0))
        p_leth = float(mood_counts.get('lethargic', 0))
        p_anx  = float(mood_counts.get('anxious', 0))
        p_low_act = float(act_counts.get('low', 0))

        last3_moods = [str(m).lower() for m in last3['mood'].tolist()]
        happy_calm_count = sum(1 for m in last3_moods if m in ('happy', 'calm'))

        risk = "low"
        # Strong signals -> high
        if (avg_sleep7 < 5.0) or (avg_sleep3 < 5.0) or (p_aggr > 0.25):
            risk = "high"
        # Moderate signals -> medium
        elif (p_leth > 0.35) or (p_anx > 0.35) or (p_low_act > 0.6) or (avg_sleep7 < 6.5):
            risk = "medium"

        # De-escalation: if most recent days are healthy, dial back
        if risk == "high":
            if (happy_calm_count >= 2) and (avg_sleep3 >= 6.0) and (p_aggr <= 0.25):
                risk = "medium"
        if risk == "medium":
            if (happy_calm_count >= 2) and (avg_sleep3 >= 6.0) and (p_low_act <= 0.6) and (p_leth <= 0.35) and (p_anx <= 0.35):
                risk = "low"

        return risk
    except Exception:
        return "low"

def blend_illness_risk(ml_risk: str, contextual_risk: str) -> str:
    """Pick the higher severity between ML and contextual ('low' < 'medium' < 'high')."""
    sev = {"low": 0, "medium": 1, "high": 2}
    a = str(ml_risk or "low").lower()
    b = str(contextual_risk or "low").lower()
    return a if sev.get(a, 0) >= sev.get(b, 0) else b

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

    # Include numeric sleep forecast (7-day) in stored payload so consumers can show it
    try:
        sleep_series = df['sleep_hours'].tolist() if not df.empty else []
        sleep_forecast = predict_future_sleep(sleep_series, days_ahead=7)
        # store as JSON string to be safe for different DB column types
        payload["sleep_forecast"] = json.dumps([float(x) for x in sleep_forecast])
    except Exception:
        payload["sleep_forecast"] = json.dumps([])

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
# Duplicate forecast_sleep_trend removed (the original one above analyze_pet_df is kept)

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
    df = fetch_logs_df(pet_id)

    # sleep_forecast
    try:
        sleep_series = df["sleep_hours"].tolist() if not df.empty else []
        sleep_forecast = predict_future_sleep(sleep_series)
    except Exception:
        last = sleep_series[-1] if sleep_series else 8.0
        sleep_forecast = [last for _ in range(7)]

    # ML illness_risk on latest log (or fallback)
    illness_risk_ml = None
    try:
        if not df.empty:
            latest = df.sort_values("log_date", ascending=False).iloc[0]
            mood = str(latest.get("mood", "") or "")
            sleep_hours = float(latest.get("sleep_hours") or 0.0)
            activity_level = str(latest.get("activity_level", "") or "")
            illness_risk_ml = predict_illness_risk(mood, sleep_hours, activity_level)
    except Exception:
        illness_risk_ml = None

    # fallback to latest stored prediction or "low"
    if illness_risk_ml is None:
        latest_pred_risk = get_latest_prediction_risk(pet_id)
        illness_risk_ml = latest_pred_risk if latest_pred_risk in ("high", "medium", "low") else "low"

    # Contextual risk from recent logs
    contextual_risk = compute_contextual_risk(df)

    # Blend: choose higher severity so spikes are not hidden
    illness_risk_final = blend_illness_risk(illness_risk_ml, contextual_risk)

    # model status and derived health status (based on blended risk)
    illness_model_trained = is_illness_model_trained()
    is_unhealthy = isinstance(illness_risk_final, str) and illness_risk_final.lower() in ("high", "medium")
    health_status = "unhealthy" if is_unhealthy else "healthy"

    # Care tips based on blended risk
    avg_sleep_val = float(df["sleep_hours"].mean()) if not df.empty else 8.0
    tips = build_care_recommendations(
        illness_risk_final,
        result.get("mood_probabilities") or result.get("mood_prob"),
        result.get("activity_probabilities") or result.get("activity_prob"),
        avg_sleep_val,
        result.get("sleep_trend"),
    )

    # Merge into response
    merged = dict(result)
    merged["illness_risk_ml"] = illness_risk_ml
    merged["illness_risk_contextual"] = contextual_risk
    merged["illness_risk_blended"] = illness_risk_final
    merged["illness_risk"] = illness_risk_final  # backward compatibility
    merged["sleep_forecast"] = sleep_forecast
    merged["illness_model_trained"] = illness_model_trained
    merged["health_status"] = health_status
    merged["illness_prediction"] = illness_risk_final
    merged["is_unhealthy"] = is_unhealthy
    merged["illness_status_text"] = "Unhealthy" if is_unhealthy else "Healthy"
    merged["care_recommendations"] = tips
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
    illness_model_trained = is_illness_model_trained()
    is_unhealthy = isinstance(illness_risk, str) and illness_risk.lower() in ("high", "medium")
    health_status = "unhealthy" if is_unhealthy else "healthy"

    # Sleep forecast prediction
    df = fetch_logs_df(pet_id)
    sleep_series = df["sleep_hours"].tolist() if not df.empty else []
    sleep_forecast = predict_future_sleep(sleep_series)

    # Build pseudo-probabilities from input to drive tips
    mood_prob = {str(mood).lower(): 1.0}
    activity_prob = {str(activity_level).lower(): 1.0}
    avg_sleep_val = float(sleep_hours) if sleep_hours is not None else 8.0
    tips = build_care_recommendations(illness_risk, mood_prob, activity_prob, avg_sleep_val, None)

    return jsonify({
        "illness_risk": illness_risk,
        "sleep_forecast": sleep_forecast,
        "illness_model_trained": illness_model_trained,
        "health_status": health_status,
        # aliases for UI
        "illness_prediction": illness_risk,
        "is_unhealthy": is_unhealthy,
        "illness_status_text": "Unhealthy" if is_unhealthy else "Healthy",
        "care_recommendations": tips
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

        illness_model_trained = is_illness_model_trained()
        status_text = "Healthy"
        try:
            lr = str(latest_risk).lower() if latest_risk else ""
            if ("high" in lr) or ("medium" in lr):
                status_text = "Unhealthy"
        except Exception:
            status_text = "Healthy"

        # Build care tips for display using recent logs + latest risk
        df_recent = fetch_logs_df(pet_id, limit=60)
        if df_recent.empty:
            mood_prob_recent, activity_prob_recent = {}, {}
            avg_sleep_recent = 8.0
            sleep_trend_recent = ""
        else:
            mood_prob_recent = df_recent['mood'].str.lower().value_counts(normalize=True).to_dict()
            activity_prob_recent = df_recent['activity_level'].str.lower().value_counts(normalize=True).to_dict()
            avg_sleep_recent = float(df_recent["sleep_hours"].mean())
            sleep_trend_recent = forecast_sleep_trend(df_recent)

        care_tips = build_care_recommendations(
            latest_risk or "low",
            mood_prob_recent,
            activity_prob_recent,
            avg_sleep_recent,
            sleep_trend_recent
        )
        actions_html = "".join(f"<li>{a}</li>" for a in (care_tips.get("actions") or [])[:6]) or "<li>Ensure fresh water and rest today.</li>"
        expectations_html = "".join(f"<li>{e}</li>" for e in (care_tips.get("expectations") or [])[:6]) or "<li>Expect normal behavior with routine care.</li>"

        # --- Fetch future predictions (next 7 days) for API consumers ---
        future_predictions = []
        today = datetime.utcnow().date()
        for i in range(1, 8):
            future_date = today + timedelta(days=i)
            presp = supabase.table("predictions").select(
                "prediction_date, prediction_text, risk_level, suggestions"
            ).eq("pet_id", pet_id).eq("prediction_date", future_date.isoformat()).limit(1).execute()
            prows = presp.data or []
            if prows:
                p0 = prows[0]
                future_predictions.append({
                    "date": p0.get("prediction_date"),
                    "text": p0.get("prediction_text") or "",
                    "risk": p0.get("risk_level") or "",
                    "suggestions": p0.get("suggestions") or ""
                })

        # If request is from browser, render HTML as before
        # Build small HTML block for future predictions to embed in modal
        if future_predictions:
            future_items = []
            for fp in future_predictions:
                fd = fp.get('date') or ''
                fr = fp.get('risk') or ''
                ft = fp.get('text') or ''
                future_items.append(f"<li><strong>{fd}</strong> — {fr}: {ft}</li>")
            future_html = f"<h4>Upcoming Predictions</h4><ul>{''.join(future_items)}</ul>"
        else:
            future_html = ""

        if "text/html" in request.headers.get("Accept", ""):
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
                    <span class="label">Health Status</span><br/>
                    <span class="badge" style="background:{risk_color};">{status_text}</span>
                    <p style="margin-top:6px;color:#666;font-size:12px;">Model: {"AI (trained)" if illness_model_trained else "Rules (not trained)"}</p>
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
                  <p><strong>Status:</strong> {status_text}</p>
                  <p><strong>Risk:</strong> {(latest_risk or 'None')}</p>
                  <p><strong>Model:</strong> {"AI (trained)" if illness_model_trained else "Rules (not trained)"}</p>
                  <p><strong>Summary:</strong> {latest_prediction_text or 'No analysis available'}</p>
                  <p><strong>Recommendation:</strong> {latest_suggestions or 'No recommendations available'}</p>
                  <!-- Care Tips -->
                  <h4>Care Tips</h4>
                  <p><strong>What to do</strong></p>
                  <ul>{actions_html}</ul>
                  <p><strong>What to expect</strong></p>
                  <ul>{expectations_html}</ul>
                  {future_html}
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

        # Otherwise, return JSON including future predictions
        return jsonify({
            "pet": {
                "id": pet.get("id"),
                "name": pet_name,
                "breed": pet_breed,
                "age": pet_age,
                "weight": pet_weight,
                "gender": pet_gender,
                "health": pet_health,
                "owner_name": owner_name,
                "owner_email": owner_email,
                "owner_role": owner_role,
            },
            "latest_prediction": {
                "text": latest_prediction_text,
                "risk": latest_risk,
                "suggestions": latest_suggestions,
                "status": status_text,
                "model_trained": illness_model_trained,
            },
            "future_predictions": future_predictions,
            "care_tips": care_tips,
            "health_status": status_text,
            "risk_color": risk_color,
        })
    except Exception as e:
        return make_response(f"<h3>Error: {str(e)}</h3>", 500)

# Alias route so URLs under /analyze/pet/<id> also resolve (compatible with QR payloads that include /analyze)
@app.route("/analyze/pet/<pet_id>", methods=["GET"])
def public_pet_page_alias(pet_id):
    return public_pet_page(pet_id)

@app.route("/", methods=["GET", "HEAD"])
def root():
    return "PetTrackCare API is running.", 200

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


def enqueue_task(task_name: str):
    """Spawn a separate Python process to run a named task.

    Keeps heavy CPU / I/O work out of the Flask worker process.
    The subprocess will invoke this same module with --task=<name>.
    """
    try:
        script = os.path.abspath(__file__)
        cmd = [sys.executable, script, f"--task={task_name}"]
        # Start detached subprocess; silence output by default
        subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        print(f"[INFO] Enqueued task '{task_name}' as subprocess: {cmd}")
    except Exception as e:
        print(f"[ERROR] Failed to enqueue task {task_name}: {e}")


def start_scheduler():
    """Schedule light-weight triggers that enqueue heavy work as subprocesses."""
    scheduler = BackgroundScheduler()
    scheduler.add_job(lambda: enqueue_task("daily_analysis"), 'interval', days=1)
    scheduler.add_job(lambda: enqueue_task("migrate"), 'interval', days=1)
    scheduler.start()


def backfill_future_sleep_forecasts(days_ahead: int = 7):
    """Backfill per-pet future sleep forecasts into the predictions table.

    For each pet, use logs up to the latest available date and compute a
    numeric forecast for the next `days_ahead` days. Insert a prediction row
    for each future date when no prediction exists.
    """
    print(f"Starting backfill of future sleep forecasts (next {days_ahead} days)...")
    try:
        pets_resp = supabase.table("pets").select("id").execute()
        for pet in pets_resp.data or []:
            pet_id = pet.get("id")
            if not pet_id:
                continue
            df = fetch_logs_df(pet_id, limit=10000)
            if df.empty:
                continue
            # ensure proper datetime
            df['log_date'] = pd.to_datetime(df['log_date'])
            last_date = max(df['log_date']).date()
            train_df = df[df['log_date'] <= pd.to_datetime(last_date)]
            sleep_series = train_df['sleep_hours'].tolist() if not train_df.empty else []
            forecasts = predict_future_sleep(sleep_series, days_ahead=days_ahead)

            # Serialize full 7-day forecast once and attach to each future-date row.
            # Consumers can read the full series from any of the future prediction rows.
            forecasts_json = json.dumps([float(x) for x in forecasts])
            for i, val in enumerate(forecasts, start=1):
                future_date = (last_date + timedelta(days=i)).isoformat()
                # idempotent insert: skip if a prediction already exists for that date
                existing = supabase.table("predictions").select("id").eq("pet_id", pet_id).eq("prediction_date", future_date).limit(1).execute()
                if existing.data:
                    continue
                payload = {
                    "pet_id": pet_id,
                    "prediction_date": future_date,
                    # Keep a human-friendly single-day summary, but store the full series in sleep_forecast
                    "prediction_text": f"Forecasted sleep: {round(float(val), 1)} hours",
                    "risk_level": "low",
                    "suggestions": "",
                    "activity_prob": 0,
                    # store full 7-day forecast as JSON string for backward-compatible storage
                    "sleep_forecast": forecasts_json
                }
                try:
                    supabase.table("predictions").insert(payload).execute()
                except Exception:
                    # don't fail the whole backfill for one insert
                    continue

        print("Backfill completed.")
    except Exception as e:
        print(f"Backfill error: {e}")


def migrate_legacy_sleep_forecasts(days_ahead: int = 7, batch_limit: int = 1000):
    """Migrate legacy prediction rows that have missing or single-element
    `sleep_forecast` values to a full `days_ahead`-length numeric forecast.

    The migration is idempotent: rows already containing a list of length >=
    `days_ahead` are skipped. For each candidate prediction we compute the
    forecast using historical behavior_logs up to the prediction_date to avoid
    data leakage, then update the prediction row's `sleep_forecast` field.
    """
    print(f"Starting migration of legacy sleep_forecast to {days_ahead}-day series...")
    try:
        resp = supabase.table("predictions").select("id, pet_id, prediction_date, sleep_forecast").limit(batch_limit).execute()
        rows = resp.data or []
        if not rows:
            print("No prediction rows found to inspect.")
            return

        updated = 0
        checked = 0
        for row in rows:
            checked += 1
            try:
                pred_id = row.get("id")
                pet_id = row.get("pet_id")
                pred_date_raw = row.get("prediction_date")
                sf = row.get("sleep_forecast")

                # Normalize prediction_date
                if not pred_date_raw:
                    # skip rows without a clear prediction date
                    continue
                try:
                    pred_date = pd.to_datetime(pred_date_raw).date()
                except Exception:
                    continue

                # Parse existing sleep_forecast
                parsed = None
                if sf is None:
                    parsed = []
                else:
                    # It's commonly stored as a JSON string
                    if isinstance(sf, str):
                        try:
                            parsed = json.loads(sf)
                        except Exception:
                            # maybe a numeric string
                            try:
                                parsed = [float(sf)]
                            except Exception:
                                parsed = []
                    elif isinstance(sf, (list, tuple)):
                        parsed = list(sf)
                    else:
                        # numeric or unknown
                        try:
                            parsed = [float(sf)]
                        except Exception:
                            parsed = []

                # If already full-length, skip
                if isinstance(parsed, list) and len(parsed) >= int(days_ahead):
                    continue

                # Build historical logs up to prediction_date to avoid leakage
                logs_resp = supabase.table("behavior_logs").select("*").eq("pet_id", pet_id).lte("log_date", pred_date.isoformat()).order("log_date", desc=False).limit(10000).execute()
                logs = logs_resp.data or []
                df_logs = pd.DataFrame(logs) if logs else pd.DataFrame()
                if not df_logs.empty:
                    df_logs['log_date'] = pd.to_datetime(df_logs['log_date']).dt.date
                    df_logs['sleep_hours'] = pd.to_numeric(df_logs.get('sleep_hours', 0), errors='coerce').fillna(0.0)
                    sleep_series = df_logs['sleep_hours'].tolist()
                else:
                    sleep_series = []

                # Compute forecast and update prediction row
                forecasts = predict_future_sleep(sleep_series, days_ahead=days_ahead)
                forecasts_json = json.dumps([float(x) for x in forecasts])
                update_resp = supabase.table("predictions").update({"sleep_forecast": forecasts_json}).eq("id", pred_id).execute()
                if getattr(update_resp, "error", None):
                    print(f"Failed to update prediction id={pred_id} pet={pet_id}: {getattr(update_resp, 'error', '')}")
                else:
                    updated += 1
            except Exception as e:
                print(f"Error processing prediction row {row.get('id')}: {e}")

        print(f"Migration complete. Checked {checked} rows, updated {updated} rows.")
    except Exception as e:
        print(f"Unexpected error during legacy sleep_forecast migration: {e}")

if __name__ == "__main__":
    # Run a one-time migration at startup (safe and idempotent)
    parser = argparse.ArgumentParser()
    parser.add_argument("--task", type=str, default=None,
                        help="Optional task to run directly: daily_analysis | migrate")
    args = parser.parse_args()

    # If invoked with --task, run that task directly (useful for subprocess workers)
    if args.task:
        task = args.task.lower()
        if task == "daily_analysis":
            daily_analysis_job()
        elif task in ("migrate", "migrate_behavior_logs_to_predictions"):
            migrate_behavior_logs_to_predictions()
        elif task in ("backfill_sleep", "backfill_future_sleep_forecasts"):
            backfill_future_sleep_forecasts()
        elif task in ("migrate_legacy_sleep_forecasts", "migrate_sleep_forecasts"):
            migrate_legacy_sleep_forecasts()
        else:
            print(f"Unknown task: {args.task}")
        sys.exit(0)

    # Otherwise run startup migration once and start the webserver with scheduler
    try:
        migrate_behavior_logs_to_predictions()
    except Exception as e:
        print(f"Startup migration error: {e}")

    # Start the lightweight scheduler that enqueues heavy jobs as subprocesses
    try:
        start_scheduler()
    except Exception as e:
        print(f"Failed to start scheduler: {e}")

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

def predict_illness_risk(mood, sleep_hours, activity_level, model_path=os.path.join(MODELS_DIR, "illness_model.pkl")):
    """
    Predict illness risk using a trained model if available. Returns 'low'/'medium'/'high'.
    - Uses predict_proba when possible and thresholds for medium/high.
    - Falls back to conservative rule-based logic when model or encoders are missing or when inputs are unseen.
    """
    # normalize inputs
    mood_in = str(mood or '').strip().lower()
    activity_in = str(activity_level or '').strip().lower()
    try:
        sleep_f = float(sleep_hours)
    except Exception:
        sleep_f = 0.0

    # conservative rule-based fallback
    rule_flag = (mood_in in ["lethargic", "aggressive"]) or (sleep_f < 5) or (activity_in == "low")

    loaded = load_illness_model(model_path)
    # load_illness_model returns (model, (le_mood, le_activity), mood_map, act_map, metadata) or (None, None)
    if not loaded or loaded[0] is None:
        return "high" if rule_flag else "low"

    try:
        model, encoders, mood_map, act_map, metadata = loaded
    except Exception:
        # unexpected shape, fallback
        return "high" if rule_flag else "low"

    le_mood, le_activity = encoders if encoders else (None, None)

    # Map or fallback for mood/activity encodings
    mood_enc = None
    act_enc = None
    try:
        if mood_map and mood_in in mood_map:
            mood_enc = int(mood_map[mood_in])
        elif le_mood is not None and mood_in in getattr(le_mood, 'classes_', []):
            mood_enc = int(np.where(getattr(le_mood, 'classes_', []) == mood_in)[0][0])
        else:
            # use most common seen during training if available
            mc = (metadata.get('mood_most_common') if metadata else None)
            if mc and mc in (mood_map or {}):
                mood_enc = int((mood_map or {})[mc])
    except Exception:
        mood_enc = None

    try:
        if act_map and activity_in in act_map:
            act_enc = int(act_map[activity_in])
        elif le_activity is not None and activity_in in getattr(le_activity, 'classes_', []):
            act_enc = int(np.where(getattr(le_activity, 'classes_', []) == activity_in)[0][0])
        else:
            ac = (metadata.get('act_most_common') if metadata else None)
            if ac and ac in (act_map or {}):
                act_enc = int((act_map or {})[ac])
    except Exception:
        act_enc = None

    # If encodings are missing, fallback to rule-based conservative decision
    if mood_enc is None or act_enc is None:
        return "high" if rule_flag else "low"

    X = np.array([[mood_enc, float(sleep_f), act_enc]])

    try:
        if hasattr(model, 'predict_proba'):
            proba = model.predict_proba(X)[0]
            # assume binary prob where index 1 is positive class
            p_pos = float(proba[1]) if len(proba) > 1 else float(proba[0])
        else:
            # fallback to raw prediction
            p_pos = float(model.predict(X)[0])
    except Exception:
        return "high" if rule_flag else "low"

    # Thresholds to convert probability into low/medium/high
    if p_pos >= 0.75:
        return "high"
    elif p_pos >= 0.40:
        return "medium"
    else:
        return "low"

def predict_future_sleep(sleep_series, days_ahead=7, model_path=os.path.join(MODELS_DIR, "sleep_model.keras")):
    # Robustified predictor that avoids returning flat/linear forecasts when data is sparse
    arr = np.array(sleep_series).astype(float) if (sleep_series is not None and len(sleep_series) > 0) else np.array([])
    days_ahead = int(days_ahead or 7)

    # Empty input -> sensible default
    if arr.size == 0:
        return [8.0 for _ in range(days_ahead)]

    # Useful statistics
    recent_mean = float(np.mean(arr[-7:])) if arr.size >= 1 else 8.0
    recent_std = float(np.std(arr[-7:])) if arr.size >= 2 else 0.5
    last_delta = float(arr[-1] - arr[-2]) if arr.size >= 2 else 0.0

    rng = np.random.default_rng(42)

    # Heuristic fallback generator (momentum + weekly pattern + jitter)
    def heuristic_preds(base_mean, delta, start_index, n):
        out = []
        for i in range(n):
            base = base_mean + delta * (i + 1) * 0.15
            day_of_week = (start_index + i) % 7
            weekly = 0.3 if day_of_week in (5, 6) else -0.1
            noise = float(rng.normal(0, max(0.15, recent_std * 0.2)))
            p = base + weekly + noise
            out.append(max(0.0, min(24.0, round(p, 1))))
        return out

    # Very small history: use heuristic only (no model fitting)
    if arr.size < 3:
        return heuristic_preds(recent_mean, last_delta, len(arr), days_ahead)

    # Build sliding-window training data (window=7)
    window = 7
    X, y = [], []
    for i in range(max(0, len(arr) - window)):
        X.append(arr[i:i + window])
        y.append(arr[i + window])

    # If insufficient windowed samples, fall back to heuristic
    if len(X) < 2:
        return heuristic_preds(recent_mean, last_delta, len(arr), days_ahead)

    X, y = np.array(X), np.array(y)

    # Train or load a small Keras model for sequence prediction
    try:
        if os.path.exists(model_path):
            model = tf.keras.models.load_model(model_path)
        else:
            model = tf.keras.Sequential([
                tf.keras.layers.Input(shape=(X.shape[1],)),
                tf.keras.layers.Dense(32, activation='relu'),
                tf.keras.layers.Dropout(0.15),
                tf.keras.layers.Dense(16, activation='relu'),
                tf.keras.layers.Dense(1)
            ])
            model.compile(optimizer='adam', loss='mse')

        # Train briefly (keeps runtime bounded) and persist
        model.fit(X, y, epochs=30, batch_size=8, verbose=0)
        try:
            model.save(model_path)
        except Exception:
            # non-fatal if save fails in restricted environments
            pass

        preds, last_window = [], arr[-window:].copy()
        for _ in range(days_ahead):
            p = float(model.predict(last_window.reshape(1, -1), verbose=0)[0, 0])
            p = max(0.0, min(24.0, p))
            preds.append(p)
            last_window = np.concatenate([last_window[1:], [p]])

        # If model outputs are suspiciously flat, blend with heuristic to add realistic variation
        rounded = [round(float(x), 1) for x in preds]
        if np.std(rounded) < 0.25 or len(set(rounded)) == 1:
            alt = heuristic_preds(recent_mean, last_delta, len(arr), days_ahead)
            blended = []
            for m, a in zip(preds, alt):
                # blend model and heuristic (favor model but add diversity)
                v = 0.7 * float(m) + 0.3 * float(a)
                blended.append(round(max(0.0, min(24.0, v)), 1))
            return blended

        return [round(float(x), 1) for x in preds]
    except Exception:
        # Final conservative fallback
        return heuristic_preds(recent_mean, last_delta, len(arr), days_ahead)

# Force-train endpoint (useful in dev)
@app.route("/train", methods=["POST"])
def train_endpoint():
    data = request.get_json(silent=True) or {}
    pet_id = data.get("pet_id")
    try:
        if pet_id:
            df = fetch_logs_df(pet_id, limit=10000)
            if df.empty:
                return jsonify({"status":"no_data","message":"No behavior_logs for pet_id"}), 200
            train_illness_model(df)  # saves models/models.pkl
            forecast_sleep_with_tf(df["sleep_hours"].tolist())  # saves models/sleep_model.keras
        else:
            # train on all pets combined
            resp = supabase.table("behavior_logs").select("*").order("log_date", desc=False).limit(100000).execute()
            logs = resp.data or []
            if not logs:
                return jsonify({"status":"no_data","message":"No behavior_logs found"}), 200
            df_all = pd.DataFrame(logs)
            df_all['log_date'] = pd.to_datetime(df_all['log_date']).dt.date
            df_all['sleep_hours'] = pd.to_numeric(df_all.get('sleep_hours', 0), errors='coerce').fillna(0.0)
            df_all['mood'] = df_all['mood'].fillna('Unknown').astype(str)
            df_all['activity_level'] = df_all['activity_level'].fillna('Unknown').astype(str)
            train_illness_model(df_all)
            forecast_sleep_with_tf(df_all["sleep_hours"].tolist())
        return jsonify({"status":"ok","message":"Models trained"}), 200
    except Exception as e:
        return jsonify({"status":"error","message":str(e)}), 500

# Debug endpoint to understand sleep data and predictions
@app.route("/debug_sleep", methods=["POST"])
def debug_sleep_forecast():
    """Debug endpoint to understand what sleep data is being used for predictions."""
    data = request.get_json(silent=True) or {}
    pet_id = data.get("pet_id")
    if not pet_id:
        return jsonify({"error": "pet_id required"}), 400

    try:
        # Fetch the actual sleep data
        df = fetch_logs_df(pet_id)
        if df.empty:
            return jsonify({
                "pet_id": pet_id,
                "error": "No behavior logs found for this pet",
                "suggestion": "Log some sleep data first"
            })

        sleep_series = df["sleep_hours"].tolist()
        sleep_dates = df["log_date"].tolist()
        
        # Generate predictions with debug info
        predictions = predict_future_sleep(sleep_series)
        
        # Calculate statistics
        avg_sleep = np.mean(sleep_series) if sleep_series else 0
        std_sleep = np.std(sleep_series) if len(sleep_series) > 1 else 0
        min_sleep = min(sleep_series) if sleep_series else 0
        max_sleep = max(sleep_series) if sleep_series else 0
        
        return jsonify({
            "pet_id": pet_id,
            "historical_data": {
                "dates": [str(d) for d in sleep_dates],
                "sleep_hours": sleep_series,
                "count": len(sleep_series),
                "statistics": {
                    "average": round(avg_sleep, 2),
                    "std_deviation": round(std_sleep, 2),
                    "min": min_sleep,
                    "max": max_sleep,
                    "variation_level": "low" if std_sleep < 0.5 else "normal" if std_sleep < 1.5 else "high"
                }
            },
            "predictions": {
                "next_7_days": [round(p, 2) for p in predictions],
                "prediction_method": "linear_regression" if len(sleep_series) < 8 else "neural_network",
                "explanation": "Predictions based on historical sleep patterns. Low variation in data may result in flat forecasts."
            }
        })
    except Exception as e:
        return jsonify({"error": str(e)}), 500

def add_behavior_log_and_retrain(pet_id, log_data, future_days=7):
    # Insert log
    supabase.table("behavior_logs").insert(log_data).execute()
    # Fetch all logs for the pet
    df = fetch_logs_df(pet_id, limit=10000)
    if not df.empty:
        train_illness_model(df)
        forecast_sleep_with_tf(df["sleep_hours"].tolist())
        # Predict and store health and sleep for every date in the logs (refresh all predictions)
        all_dates = sorted(df['log_date'].unique())
        for d in all_dates:
            # analyze_pet_df computes both health and sleep forecast for each date
            analyze_pet_df(pet_id, df[df['log_date'] <= d], prediction_date=pd.to_datetime(d).date().isoformat(), store=True)
        # --- Predict for future dates using learned pattern ---
        last_date = max(all_dates)
        # Use logs up to last_date for any future-date predictions to avoid leakage
        train_df_for_future = df[df['log_date'] <= last_date].copy()
        for i in range(1, future_days + 1):
            future_date = last_date + timedelta(days=i)
            analyze_pet_df(pet_id, train_df_for_future, prediction_date=future_date.isoformat(), store=True)
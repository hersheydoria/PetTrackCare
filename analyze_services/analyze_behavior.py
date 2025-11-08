import os
from datetime import datetime, timedelta
from flask import Flask, request, jsonify, make_response
import pandas as pd
import numpy as np
from sklearn.ensemble import RandomForestClassifier, RandomForestRegressor, GradientBoostingRegressor
from sklearn.linear_model import LinearRegression, Ridge
from sklearn.preprocessing import LabelEncoder, StandardScaler
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

# Clean up old incompatible models on startup (sklearn version mismatch issue)
def cleanup_incompatible_models():
    """Delete old model files to force retraining with current sklearn version."""
    try:
        if os.path.exists(MODELS_DIR):
            model_files = [f for f in os.listdir(MODELS_DIR) if f.endswith('.pkl')]
            if model_files:
                print(f"[STARTUP] Cleaning up {len(model_files)} old model files due to sklearn version mismatch...")
                for f in model_files:
                    try:
                        os.remove(os.path.join(MODELS_DIR, f))
                        print(f"[STARTUP] Deleted: {f}")
                    except Exception as e:
                        print(f"[STARTUP] Failed to delete {f}: {e}")
    except Exception as e:
        print(f"[STARTUP] Error during model cleanup: {e}")

# Run cleanup on startup
cleanup_incompatible_models()

# ------------------- Data Fetch & Model Logic -------------------

def fetch_logs_df(pet_id, limit=200):
    resp = supabase.table("behavior_logs").select("*").eq("pet_id", pet_id).order("log_date", desc=False).limit(limit).execute()
    data = resp.data or []
    if not data:
        return pd.DataFrame()
    df = pd.DataFrame(data)
    df['log_date'] = pd.to_datetime(df['log_date']).dt.date
    df['activity_level'] = df.get('activity_level', pd.Series(['Unknown'] * len(df))).fillna('Unknown').astype(str)
    
    # Core health tracking columns
    df['food_intake'] = df.get('food_intake', pd.Series(['Unknown'] * len(df))).fillna('Unknown').astype(str)
    df['water_intake'] = df.get('water_intake', pd.Series(['Unknown'] * len(df))).fillna('Unknown').astype(str)
    df['bathroom_habits'] = df.get('bathroom_habits', pd.Series(['Unknown'] * len(df))).fillna('Unknown').astype(str)
    df['symptoms'] = df.get('symptoms', pd.Series(['[]'] * len(df))).fillna('[]').astype(str)
    
    return df

def train_illness_model(df, model_path=os.path.join(MODELS_DIR, "illness_model.pkl"), min_auc_threshold: float = 0.6):
    if df.shape[0] < 5:
        return None, None
    
    # Prepare label encoders for categorical features
    le_activity = LabelEncoder()
    le_food = LabelEncoder()
    le_water = LabelEncoder()
    le_bathroom = LabelEncoder()
    
    # Encode categorical features (activity, food, water, bathroom only)
    df['act_enc'] = le_activity.fit_transform(df['activity_level'])
    df['food_enc'] = le_food.fit_transform(df['food_intake'])
    df['water_enc'] = le_water.fit_transform(df['water_intake'])
    df['bathroom_enc'] = le_bathroom.fit_transform(df['bathroom_habits'])
    
    # Count symptoms (parse JSON array)
    def count_symptoms(symptoms_str):
        try:
            import json
            symptoms = json.loads(symptoms_str) if isinstance(symptoms_str, str) else []
            # Filter out "None of the Above" - case insensitive and handle variations
            filtered = [s for s in symptoms if str(s).lower().strip() not in ["none of the above", "", "none", "unknown"]]
            return len(filtered)
        except Exception:
            return 0
    
    df['symptom_count'] = df['symptoms'].apply(count_symptoms)
    
    # Build feature matrix with health indicators (activity, food, water, bathroom, symptoms only)
    X = df[['act_enc', 'food_enc', 'water_enc', 'bathroom_enc', 'symptom_count']].values
    
    # Illness indicator based on health data (without mood or sleep)
    y = (
        # Food intake issues
        (df['food_intake'].str.lower().isin(['not eating', 'eating less'])) |
        # Water intake issues
        (df['water_intake'].str.lower().isin(['not drinking', 'drinking less'])) |
        # Bathroom issues
        (df['bathroom_habits'].str.lower().isin(['diarrhea', 'constipation', 'frequent urination'])) |
        # Multiple symptoms (2 or more real symptoms)
        (df['symptom_count'] >= 2) |
        # Low activity level
        (df['activity_level'].str.lower() == 'low')
    ).astype(int).values

    # Guard: need both classes to train a classifier
    if len(np.unique(y)) < 2:
        return None, None
    
    # Use class balancing to mitigate imbalance
    clf = RandomForestClassifier(n_estimators=100, random_state=42, class_weight='balanced')
    clf.fit(X, y)

    # Try to evaluate model (cross-validated AUC) when we have enough samples
    auc_score = None
    try:
        # Only run CV when each class has enough members to support the requested n_splits.
        # Small class counts cause sklearn to warn or raise; guard against that.
        from collections import Counter
        class_counts = Counter(y)
        if len(class_counts) >= 2:
            min_class = min(class_counts.values())
            # choose up to 3 splits but no more than the smallest class size
            n_splits = min(3, min_class)
            # require at least 2 splits and at least n_splits*2 samples overall
            if n_splits >= 2 and len(y) >= n_splits * 2:
                cv = StratifiedKFold(n_splits=n_splits, shuffle=True, random_state=42)
                scores = cross_val_score(clf, X, y, cv=cv, scoring='roc_auc')
                auc_score = float(np.mean(scores))
            else:
                print(f"[INFO] Skipping CV AUC: not enough samples per class (counts={dict(class_counts)})")
        else:
            print(f"[INFO] Skipping CV AUC: only one class present in training data (counts={dict(class_counts)})")
    except Exception as e:
        print(f"[WARN] CV AUC check skipped/failed: {e}")
        auc_score = None

    # If we have a CV AUC and it's below the minimum threshold, do NOT save the model.
    if auc_score is not None and auc_score < float(min_auc_threshold):
        print(f"[WARN] Trained model AUC={auc_score:.3f} below threshold {min_auc_threshold}; not saving model.")
        # Return None to indicate model was not persisted/accepted
        return None, None

    # Build mapping dictionaries to handle unseen labels at prediction time
    act_map = {v: i for i, v in enumerate(getattr(le_activity, 'classes_', []))}
    food_map = {v: i for i, v in enumerate(getattr(le_food, 'classes_', []))}
    water_map = {v: i for i, v in enumerate(getattr(le_water, 'classes_', []))}
    bathroom_map = {v: i for i, v in enumerate(getattr(le_bathroom, 'classes_', []))}

    # Determine most common classes seen during training for safe fallback
    act_most_common = None
    food_most_common = None
    water_most_common = None
    bathroom_most_common = None
    
    try:
        act_most_common = df['activity_level'].mode().iloc[0] if not df['activity_level'].mode().empty else None
    except Exception:
        act_most_common = None
    try:
        food_most_common = df['food_intake'].mode().iloc[0] if not df['food_intake'].mode().empty else None
    except Exception:
        food_most_common = None
    try:
        water_most_common = df['water_intake'].mode().iloc[0] if not df['water_intake'].mode().empty else None
    except Exception:
        water_most_common = None
    try:
        bathroom_most_common = df['bathroom_habits'].mode().iloc[0] if not df['bathroom_habits'].mode().empty else None
    except Exception:
        bathroom_most_common = None

    metadata = {
        'trained_at': datetime.utcnow().isoformat(),
        'n_samples': int(len(y)),
        'pos_rate': float(np.mean(y)),
        'auc': auc_score,
        'act_most_common': (act_most_common or '').lower() if act_most_common else None,
        'food_most_common': (food_most_common or '').lower() if food_most_common else None,
        'water_most_common': (water_most_common or '').lower() if water_most_common else None,
        'bathroom_most_common': (bathroom_most_common or '').lower() if bathroom_most_common else None,
    }

    joblib.dump({
        'model': clf,
        'le_activity': le_activity,
        'le_food': le_food,
        'le_water': le_water,
        'le_bathroom': le_bathroom,
        'act_map': act_map,
        'food_map': food_map,
        'water_map': water_map,
        'bathroom_map': bathroom_map,
        'metadata': metadata,
    }, model_path)

    return clf, (le_activity, le_food, le_water, le_bathroom)

def load_illness_model(model_path=os.path.join(MODELS_DIR, "illness_model.pkl")):
    if os.path.exists(model_path):
        data = joblib.load(model_path)
        model = data.get('model')
        le_activity = data.get('le_activity')
        le_food = data.get('le_food')
        le_water = data.get('le_water')
        le_bathroom = data.get('le_bathroom')
        act_map = data.get('act_map')
        food_map = data.get('food_map')
        water_map = data.get('water_map')
        bathroom_map = data.get('bathroom_map')
        metadata = data.get('metadata')
        return model, (le_activity, le_food, le_water, le_bathroom), act_map, food_map, water_map, bathroom_map, metadata
    return None, None

def is_illness_model_trained(model_path=os.path.join(MODELS_DIR, "illness_model.pkl")):
    """Return True if a trained illness model (with encoders) exists on disk."""
    try:
        if not os.path.exists(model_path):
            return False
        data = joblib.load(model_path)
        return bool(data and data.get("model") and data.get("le_activity"))
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

def build_care_recommendations(illness_risk, mood_prob, activity_prob, avg_sleep, sleep_trend):
    """Return structured care tips: actions to take and what to expect. 
    Note: mood_prob, avg_sleep, and sleep_trend parameters are deprecated (no longer used)."""
    risk = (str(illness_risk or "low")).lower()
    activity_prob = activity_prob or {}

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
            "Minor activity changes may persist for a few days."
        ]
    else:
        actions += [
            "Maintain regular routine with daily exercise and enrichment."
        ]
        expectations += [
            "Normal behavior; continue routine monitoring."
        ]

    # Activity-focused tips
    top_activity = max(activity_prob, key=activity_prob.get) if activity_prob else None
    if top_activity == "low":
        actions += [
            "Offer short, low‑impact play sessions (2–3× for 10–15 min).",
            "Encourage hydration and balanced meals."
        ]
        expectations += [
            "Lower activity is normal with rest; energy should improve with routine."
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

    # General best practices
    actions += [
        "Keep fresh water available at all times.",
        "Use puzzle feeders or sniff walks for mental enrichment.",
        "Continue logging activity, food, and water intake daily."
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
    Compute illness risk from recent logs based on behavioral patterns.
    Only uses activity level, food intake, water intake, and bathroom habits.
    Distinguishes between serious issues (not eating/drinking) and minor issues (eating/drinking less).
    """
    if df is None or df.empty:
        print(f"[CONTEXTUAL-RISK] No data provided, returning 'low'")
        return "low"
    try:
        recent = df.copy()
        recent['log_date'] = pd.to_datetime(recent['log_date'])
        recent = recent.sort_values('log_date').tail(14)
        
        print(f"[CONTEXTUAL-RISK] Analyzing {len(recent)} recent logs")
        print(f"[CONTEXTUAL-RISK] Recent logs:\n{recent[['log_date', 'activity_level', 'food_intake', 'water_intake', 'bathroom_habits']].to_string()}")

        # Count SERIOUS problematic behaviors (not eating/drinking, bathroom issues)
        low_activity_count = (recent['activity_level'].str.lower() == 'low').sum()
        not_eating_count = recent['food_intake'].str.lower().isin(['not eating']).sum()  # SERIOUS
        eating_less_count = recent['food_intake'].str.lower().isin(['eating less']).sum()  # MINOR
        not_drinking_count = recent['water_intake'].str.lower().isin(['not drinking']).sum()  # SERIOUS
        drinking_less_count = recent['water_intake'].str.lower().isin(['drinking less']).sum()  # MINOR
        bad_bathroom_count = recent['bathroom_habits'].str.lower().isin(['diarrhea', 'constipation', 'frequent urination']).sum()
        
        total_logs = len(recent)
        
        p_low_act = low_activity_count / total_logs if total_logs > 0 else 0
        p_not_eating = not_eating_count / total_logs if total_logs > 0 else 0  # SERIOUS
        p_eating_less = eating_less_count / total_logs if total_logs > 0 else 0  # MINOR
        p_not_drinking = not_drinking_count / total_logs if total_logs > 0 else 0  # SERIOUS
        p_drinking_less = drinking_less_count / total_logs if total_logs > 0 else 0  # MINOR
        p_bad_bathroom = bad_bathroom_count / total_logs if total_logs > 0 else 0

        print(f"[CONTEXTUAL-RISK] Patterns: Low activity={p_low_act:.2f}, NOT eating={p_not_eating:.2f} (serious), eating less={p_eating_less:.2f} (minor), NOT drinking={p_not_drinking:.2f} (serious), drinking less={p_drinking_less:.2f} (minor), Bad bathroom={p_bad_bathroom:.2f}")

        risk = "low"
        
        # High risk: serious issues (not eating/drinking) combined with other problems
        if (p_not_eating > 0.5 or p_not_drinking > 0.5) and (low_activity_count >= 2 or p_bad_bathroom > 0.3):
            print(f"[CONTEXTUAL-RISK] → HIGH (serious issues: NOT eating={p_not_eating:.2f}>0.5 or NOT drinking={p_not_drinking:.2f}>0.5, combined with low activity or bathroom issues)")
            risk = "high"
        # Medium risk: single serious issue persisting, or multiple minor issues
        elif (p_low_act > 0.7) or (p_not_eating > 0.3) or (p_not_drinking > 0.3) or (p_bad_bathroom > 0.5):
            if p_low_act > 0.7:
                print(f"[CONTEXTUAL-RISK] → MEDIUM (low activity {p_low_act:.2f} > 0.7)")
            elif p_not_eating > 0.3:
                print(f"[CONTEXTUAL-RISK] → MEDIUM (serious: not eating {p_not_eating:.2f} > 0.3)")
            elif p_not_drinking > 0.3:
                print(f"[CONTEXTUAL-RISK] → MEDIUM (serious: not drinking {p_not_drinking:.2f} > 0.3)")
            elif p_bad_bathroom > 0.5:
                print(f"[CONTEXTUAL-RISK] → MEDIUM (bad bathroom {p_bad_bathroom:.2f} > 0.5)")
            risk = "medium"

        print(f"[CONTEXTUAL-RISK] Final contextual risk: {risk}")
        return risk
    except Exception as e:
        print(f"[CONTEXTUAL-RISK] Exception: {e}")
        import traceback
        traceback.print_exc()
        return "low"

def blend_illness_risk(ml_risk: str, contextual_risk: str) -> str:
    """Pick the higher severity between ML and contextual ('low' < 'medium' < 'high')."""
    sev = {"low": 0, "medium": 1, "high": 2}
    a = str(ml_risk or "low").lower()
    b = str(contextual_risk or "low").lower()
    return a if sev.get(a, 0) >= sev.get(b, 0) else b

# ------------------- Core Analysis -------------------
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

    # Calculate activity probabilities (mood no longer available in database)
    activity_counts = df['activity_level'].str.lower().value_counts(normalize=True).to_dict()
    activity_prob = {a: round(p, 2) for a, p in activity_counts.items()}
    mood_prob = {}  # Mood field removed from system

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
    This is IDEMPOTENT: runs every time but only processes records that don't exist in predictions table yet.
    """
    print("Starting idempotent migration of behavior_logs -> predictions...")
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
                except Exception as e:
                    print(f"Model training error for pet {pet_id} on date {d}: {e}")

                # Check if prediction already exists for this pet and date (IDEMPOTENT CHECK)
                existing = supabase.table("predictions").select("id").eq("pet_id", pet_id).eq("prediction_date", d.isoformat()).limit(1).execute()
                if existing.data and len(existing.data) > 0:
                    # Prediction already exists, skip this date
                    continue
                
                # analyze and store prediction for that historic date
                try:
                    # analyze_pet_df will attempt to store (store=True)
                    analyze_pet_df(pet_id, subset, prediction_date=d.isoformat(), store=True)
                    # Verify insertion
                    verify = supabase.table("predictions").select("id").eq("pet_id", pet_id).eq("prediction_date", d.isoformat()).limit(1).execute()
                    if verify.data and len(verify.data) > 0:
                        inserted_total += 1
                except Exception as e:
                    print(f"Analysis error for pet {pet_id} on date {d}: {e}")

        print(f"✓ Migration completed. Pets processed: {pet_count}, dates analyzed: {analyzed_total}, new predictions inserted: {inserted_total}.")
            
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

    print(f"\n[ANALYZE-START] ========== Analyzing pet {pet_id} ==========")
    
    # CONTINUOUS MODEL TRAINING: Fetch all logs for this specific pet and train/retrain the model
    df = fetch_logs_df(pet_id)
    print(f"[ANALYZE] Pet {pet_id}: Fetched {len(df)} logs for continuous training")
    
    # Only train if we have sufficient data
    if not df.empty and len(df) >= 5:
        try:
            trained_clf, encoders = train_illness_model(df)
            if trained_clf is not None:
                print(f"[ANALYZE] Pet {pet_id}: ✓ Model trained successfully with {len(df)} samples")
            else:
                print(f"[ANALYZE] Pet {pet_id}: Model training returned None (class imbalance or insufficient quality)")
        except Exception as e:
            print(f"[ANALYZE] Pet {pet_id}: ⚠ Model training error: {e}")
    else:
        print(f"[ANALYZE] Pet {pet_id}: ⚠ Insufficient data for training ({len(df)} logs, need ≥5)")

    # Core analysis (trend/recommendation/summaries) based on logs
    result = analyze_pet(pet_id)

    # ML illness_risk on latest log (or "low" if insufficient data)
    illness_risk_ml = "low"
    try:
        if not df.empty:
            latest = df.sort_values("log_date", ascending=False).iloc[0]
            activity_level = str(latest.get("activity_level", "") or "Unknown").lower()
            food_intake = str(latest.get("food_intake", "") or "Unknown").lower()
            water_intake = str(latest.get("water_intake", "") or "Unknown").lower()
            bathroom_habits = str(latest.get("bathroom_habits", "") or "Unknown").lower()
            
            # Count symptoms from latest log
            symptom_count = 0
            try:
                import json
                symptoms_str = str(latest.get("symptoms", "[]") or "[]")
                symptoms = json.loads(symptoms_str) if isinstance(symptoms_str, str) else []
                filtered = [s for s in symptoms if str(s).lower().strip() not in ["none of the above", "", "none", "unknown"]]
                symptom_count = len(filtered)
            except:
                symptom_count = 0
            
            # ONLY use ML prediction if we have clear problem indicators
            predicted_risk = predict_illness_risk(activity_level, food_intake, water_intake, bathroom_habits, symptom_count)
            if predicted_risk and predicted_risk != "low":
                illness_risk_ml = predicted_risk
                print(f"[ANALYZE] Pet {pet_id}: ML prediction = {illness_risk_ml}")
            else:
                illness_risk_ml = "low"
                print(f"[ANALYZE] Pet {pet_id}: ML prediction = low (no clear problems)")
    except Exception as e:
        print(f"[ANALYZE] Pet {pet_id}: ⚠ ML prediction error: {e}")
        illness_risk_ml = "low"

    # Contextual risk from recent logs
    contextual_risk = compute_contextual_risk(df)
    print(f"[ANALYZE] Pet {pet_id}: Contextual risk = {contextual_risk}")

    # Blend: choose higher severity so spikes are not hidden
    illness_risk_final = blend_illness_risk(illness_risk_ml, contextual_risk)
    print(f"[ANALYZE] Pet {pet_id}: Final blended risk = {illness_risk_final}")

    # model status and derived health status (based on blended risk)
    illness_model_trained = is_illness_model_trained()
    is_unhealthy = isinstance(illness_risk_final, str) and illness_risk_final.lower() in ("high", "medium")
    health_status = "unhealthy" if is_unhealthy else "healthy"
    print(f"[ANALYZE] Pet {pet_id}: Health status = {health_status}")

    # Care tips based on blended risk (sleep_hours no longer collected)
    tips = build_care_recommendations(
        illness_risk_final,
        result.get("mood_probabilities") or result.get("mood_prob"),
        result.get("activity_probabilities") or result.get("activity_prob"),
        0.0,  # avg_sleep_val - sleep tracking removed from system
        None,  # sleep_trend - sleep tracking removed from system
    )

    # Merge into response
    merged = dict(result)
    merged["illness_risk_ml"] = illness_risk_ml
    merged["illness_risk_contextual"] = contextual_risk
    merged["illness_risk_blended"] = illness_risk_final
    merged["illness_risk"] = illness_risk_final  # backward compatibility
    merged["illness_model_trained"] = illness_model_trained
    merged["health_status"] = health_status
    merged["illness_prediction"] = illness_risk_final
    merged["is_unhealthy"] = is_unhealthy
    merged["illness_status_text"] = "Unhealthy" if is_unhealthy else "Healthy"
    merged["care_recommendations"] = tips
    merged["pet_id"] = pet_id  # Include pet_id in response for clarity
    merged["log_count"] = len(df)  # Include count of logs analyzed
    
    print(f"[ANALYZE-END] ========== Analysis complete for pet {pet_id} ==========\n")
    return jsonify(merged)

@app.route("/predict", methods=["POST"])
def predict_endpoint():
    data = request.get_json()
    pet_id = data.get("pet_id")
    activity_level = data.get("activity_level")
    food_intake = data.get("food_intake")
    water_intake = data.get("water_intake")
    bathroom_habits = data.get("bathroom_habits")
    symptom_count = data.get("symptom_count", 0)
    
    if not all([pet_id, activity_level, food_intake, water_intake, bathroom_habits]):
        return jsonify({"error": "Missing fields"}), 400

    # Illness risk prediction
    illness_risk = predict_illness_risk(activity_level, food_intake, water_intake, bathroom_habits, symptom_count)
    illness_model_trained = is_illness_model_trained()
    is_unhealthy = isinstance(illness_risk, str) and illness_risk.lower() in ("high", "medium")
    health_status = "unhealthy" if is_unhealthy else "healthy"

    # Build pseudo-probabilities from input to drive tips
    activity_prob = {str(activity_level).lower(): 1.0}
    tips = build_care_recommendations(illness_risk, {}, activity_prob, 12.0, None)

    return jsonify({
        "illness_risk": illness_risk,
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
        # fetch pet with owner information joined from public.users table
        # Note: email is in auth.users, not public.users, so we only fetch name and role
        resp = supabase.table("pets").select("*, users!owner_id(name, role)").eq("id", pet_id).limit(1).execute()
        pet_rows = resp.data or []
        if not pet_rows:
            return make_response("<h3>Pet not found</h3>", 404)
        pet = pet_rows[0]

        # resolve owner using the app USERS table (public.users has: id, name, role)
        owner_name = None
        owner_email = None
        owner_role = None
        owner_id = pet.get("owner_id")
        
        # Try to get owner info from the joined data first
        owner_data = pet.get("users")
        if owner_data and isinstance(owner_data, dict):
            owner_name = owner_data.get("name")
            owner_role = owner_data.get("role")
            print(f"DEBUG: Got owner from join - name: {owner_name}, role: {owner_role}")

        # Fallback: if join didn't work, try direct query to users table
        if not owner_name and owner_id:
            try:
                # public.users has: id, name, role (email is in auth.users)
                uresp = supabase.table("users").select("name, role").eq("id", owner_id).limit(1).execute()
                urows = uresp.data or []
                if urows:
                    u0 = urows[0]
                    owner_name = u0.get("name")
                    owner_role = u0.get("role") or owner_role
                    print(f"DEBUG: Found owner in users table - name: {owner_name}, role: {owner_role}")
                else:
                    print(f"DEBUG: No user found in users table for owner_id: {owner_id}")
            except Exception as e:
                # ignore errors and continue to fallback attempts
                print(f"DEBUG: Error fetching from users table: {e}")
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
                        # Get email from auth.users (it's stored there, not in public.users)
                        if not owner_email:
                            owner_email = auth_user.get("email") if isinstance(auth_user, dict) else getattr(auth_user, "email", None)
                        
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
            avg_sleep_recent = 0.0
            sleep_trend_recent = None
        else:
            # Mood and sleep hours no longer collected - use defaults
            mood_prob_recent = {}
            activity_prob_recent = df_recent['activity_level'].str.lower().value_counts(normalize=True).to_dict()
            avg_sleep_recent = 0.0
            sleep_trend_recent = None

        care_tips = build_care_recommendations(
            latest_risk or "low",
            mood_prob_recent,
            activity_prob_recent,
            avg_sleep_recent,
            sleep_trend_recent
        )
        actions_html = "".join(f"<li>{a}</li>" for a in (care_tips.get("actions") or [])[:6]) or "<li>Ensure fresh water and rest today.</li>"
        expectations_html = "".join(f"<li>{e}</li>" for e in (care_tips.get("expectations") or [])[:6]) or "<li>Expect normal behavior with routine care.</li>"

        # The 7-day future predictions feature has been removed.
        # Keep an empty placeholder so API responses maintain a stable shape.
        future_predictions = []
        future_html = ""

        # Determine if pet is unhealthy for conditional care tips display
        is_unhealthy = status_text == "Unhealthy"
        
        # Build care tips section only if unhealthy
        care_tips_section = ""
        if is_unhealthy:
            care_tips_section = f"""
                  <hr/>
                  <h4>Care Tips</h4>
                  <p><strong>What to do</strong></p>
                  <ul>{actions_html}</ul>
                  <p><strong>What to expect</strong></p>
                  <ul>{expectations_html}</ul>
            """

        if "text/html" in request.headers.get("Accept", ""):
            # Simple HTML with modal dialog - auto-open on load, responsive and scrollable
            html = f"""
            <!doctype html>
            <html>
            <head>
              <meta name="viewport" content="width=device-width, initial-scale=1">
              <title>Pet Info - {pet_name}</title>
              <style>
                * {{ margin:0; padding:0; box-sizing:border-box; }}
                body {{ font-family: Arial, sans-serif; background:#f6f6f6; padding:12px; min-height:100vh; }}
                .card {{ max-width: 520px; margin:12px auto; background:#fff; border-radius:8px; padding:16px; box-shadow:0 6px 18px rgba(0,0,0,0.08); }}
                .label {{ color:#666; font-size:13px; margin-bottom:4px; }}
                .value {{ color:#222; font-weight:600; font-size:16px; margin-bottom:12px; }}
                .badge {{ display:inline-block;padding:6px 10px;border-radius:12px;font-weight:600;color:#fff;font-size:13px; }}
                h2 {{ font-size:20px; margin-bottom:16px; }}
                h3 {{ font-size:18px; margin-bottom:12px; }}
                h4 {{ font-size:16px; margin:16px 0 8px 0; }}
                p {{ margin-bottom:8px; font-size:14px; }}
                hr {{ margin:16px 0; border:none; border-top:1px solid #eee; }}
                ul {{ margin-left:20px; margin-bottom:12px; }}
                li {{ margin-bottom:6px; font-size:14px; }}
                /* modal */
                .modal-backdrop {{ position:fixed; inset:0; background:rgba(0,0,0,0.5); display:flex; align-items:center; justify-content:center; padding:16px; overflow-y:auto; }}
                .modal {{ background:#fff; border-radius:10px; padding:20px; max-width:500px; width:100%; max-height:90vh; overflow-y:auto; box-shadow:0 10px 30px rgba(0,0,0,0.3); }}
                .close-btn {{ background:#B82132; color:#fff; border:none; padding:10px 16px; border-radius:6px; cursor:pointer; font-size:14px; }}
                button {{ font-size:14px; }}
                .more-btn {{ background:#eee; border-radius:6px; padding:8px 16px; border:none; cursor:pointer; }}
                @media (max-width: 600px) {{
                  .card {{ padding:12px; margin:8px auto; }}
                  .modal {{ padding:16px; max-height:85vh; }}
                  h2 {{ font-size:18px; }}
                  h3 {{ font-size:16px; }}
                }}
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
                <div style="display:flex;gap:8px;align-items:center;justify-content:space-between;margin-top:12px;flex-wrap:wrap;">
                  <div style="flex:1;min-width:200px;">
                    <span class="label">Health Status</span><br/>
                    <span class="badge" style="background:{risk_color};">{status_text}</span>
                    <p style="margin-top:6px;color:#666;font-size:12px;">Model: {"AI (trained)" if illness_model_trained else "Rules (not trained)"}</p>
                    <p style="margin-top:6px;color:#666;font-size:13px;">Scan opened this page — tap "More" for details.</p>
                  </div>
                  <div style="text-align:right;">
                    <button onclick="openModal()" class="more-btn">More</button>
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
                  <p><strong>Summary:</strong> {latest_prediction_text or 'No analysis available'}</p>
                  <p><strong>Recommendation:</strong> {latest_suggestions or 'No recommendations available'}</p>
                  {care_tips_section}
                  {future_html}
                  <div style="margin-top:16px;text-align:right;">
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


@app.route("/pet/<pet_id>/7day-health", methods=["GET"])
def seven_day_health_endpoint(pet_id):
    """Endpoint removed: return 404 with a short explanation.

    The detailed 7-day forecast endpoint was removed to simplify the
    API surface. Clients should use the single-date `GET /pet/<id>`
    route which returns the latest prediction and care tips.
    """
    return jsonify({"error": "7-day health forecast endpoint removed", "note": "Use /pet/<id> for current status"}), 404

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

            # Serialize full 7-day forecast once and attach to each future-date row.
            # Consumers can read the full series from any of the future prediction rows.
            forecasts_json = json.dumps([])
            for i in range(1, days_ahead + 1):
                future_date = (last_date + timedelta(days=i)).isoformat()
                # idempotent insert: skip if a prediction already exists for that date
                existing = supabase.table("predictions").select("id").eq("pet_id", pet_id).eq("prediction_date", future_date).limit(1).execute()
                if existing.data:
                    continue
                payload = {
                    "pet_id": pet_id,
                    "prediction_date": future_date,
                    # Sleep forecast has been removed
                    "prediction_text": f"Forecast for day {i}",
                    "risk_level": "low",
                    "suggestions": "",
                    "activity_prob": 0
                }
                try:
                    supabase.table("predictions").insert(payload).execute()
                except Exception:
                    # don't fail the whole backfill for one insert
                    continue

        print("Backfill completed.")
    except Exception as e:
        print(f"Backfill error: {e}")


def migrate_legacy_sleep_forecasts(days_ahead: int = 7, batch_limit: int = 500, dry_run: bool = False):
    """Paginated migration to update prediction rows with a full `days_ahead`-day
    numeric `sleep_forecast` stored as a JSON string.

    - IDEMPOTENT: Scans `predictions` in batches and only updates rows where
      `sleep_forecast` is missing, empty, or shorter than `days_ahead`.
    - For each candidate row, computes forecasts using behavior_logs up to
      the prediction_date to avoid leakage.
    - Runs every time but only processes records that need updating.
    - dry_run=True will only print what would be updated.
    """
    print(f"Starting idempotent migration of legacy sleep_forecast to {days_ahead}-day series (batch={batch_limit}, dry_run={dry_run})...")
    try:
        offset = 0
        total_checked = 0
        total_updated = 0
        while True:
            resp = supabase.table("predictions").select("id, pet_id, prediction_date, sleep_forecast").order("id", asc=True).range(offset, offset + batch_limit - 1).execute()
            rows = resp.data or []
            if not rows:
                break

            for row in rows:
                total_checked += 1
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
                    
                    # Sleep forecast has been removed (sleep tracking no longer collected)
                    forecasts_json = json.dumps([])

                    if dry_run:
                        print(f"[DRY] Would update prediction id={pred_id} pet={pet_id} with sleep_forecast={forecasts_json}")
                    else:
                        update_resp = supabase.table("predictions").update({"sleep_forecast": forecasts_json}).eq("id", pred_id).execute()
                        if getattr(update_resp, "error", None):
                            print(f"Failed to update prediction id={pred_id} pet={pet_id}: {getattr(update_resp, 'error', '')}")
                        else:
                            total_updated += 1
                except Exception as e:
                    print(f"Error processing prediction row {row.get('id')}: {e}")

            offset += batch_limit

        print(f"✓ Migration complete. Checked {total_checked} rows, updated {total_updated} rows.")
                
    except Exception as e:
        print(f"Unexpected error during legacy sleep_forecast migration: {e}")

# The module's CLI dispatch / startup runner is placed at the end of the file
# to ensure all functions are defined before any task is invoked. See the
# `if __name__ == '__main__'` block appended to the end of this file.

def store_prediction(pet_id, prediction, risk_level, recommendation):
    # kept for backward compatibility
    supabase.table("predictions").insert({
        "pet_id": pet_id,
        "prediction_date": datetime.utcnow().date().isoformat(),
        "prediction_text": prediction,
        "risk_level": risk_level,
        "suggestions": recommendation
    }).execute()

def predict_illness_risk(activity_level, food_intake, water_intake, bathroom_habits, symptom_count=0, model_path=os.path.join(MODELS_DIR, "illness_model.pkl")):
    """
    Predict illness risk using activity, food intake, water intake, and bathroom habits.
    Returns 'low'/'medium'/'high'.
    Uses trained model if available, otherwise uses conservative rule-based logic.
    """
    # Normalize inputs
    activity_in = str(activity_level or '').strip().lower()
    food_in = str(food_intake or '').strip().lower()
    water_in = str(water_intake or '').strip().lower()
    bathroom_in = str(bathroom_habits or '').strip().lower()
    symptom_in = int(symptom_count) if symptom_count else 0

    print(f"[ML-PREDICT] Input: activity={activity_in}, food={food_in}, water={water_in}, bathroom={bathroom_in}, symptoms={symptom_in}")

    # Rule-based fallback - distinguishes between serious and minor concerns
    # SERIOUS issues: not eating/drinking, bathroom problems, 2+ symptoms, low activity
    # MINOR issues: eating/drinking less (yellow flag but not immediate danger)
    serious_flag = (
        food_in == "not eating" or
        water_in == "not drinking" or
        bathroom_in in ["diarrhea", "constipation", "frequent urination"] or
        symptom_in >= 2 or
        activity_in == "low"
    )
    
    minor_flag = (
        food_in == "eating less" or
        water_in == "drinking less"
    )
    
    rule_flag = serious_flag or (minor_flag and activity_in == "low")  # Only flag "eating less" if also low activity
    print(f"[ML-PREDICT] Rule-based: serious={serious_flag}, minor={minor_flag}, combined_flag={rule_flag}")

    loaded = load_illness_model(model_path)
    if not loaded or loaded[0] is None:
        print(f"[ML-PREDICT] No trained model found, using rule-based fallback")
        result = "high" if rule_flag else "low"
        print(f"[ML-PREDICT] → Rule-based result: {result}")
        return result

    try:
        model, encoders, act_map, food_map, water_map, bathroom_map, metadata = loaded
    except Exception as e:
        print(f"[ML-PREDICT] Failed to unpack loaded model: {e}, using rule-based fallback")
        result = "high" if rule_flag else "low"
        print(f"[ML-PREDICT] → Rule-based result: {result}")
        return result

    le_activity, le_food, le_water, le_bathroom = encoders if encoders else (None, None, None, None)

    # Encode features
    act_enc = None
    food_enc = None
    water_enc = None
    bathroom_enc = None

    try:
        if act_map and activity_in in act_map:
            act_enc = int(act_map[activity_in])
        elif le_activity and activity_in in getattr(le_activity, 'classes_', []):
            act_enc = int(np.where(getattr(le_activity, 'classes_', []) == activity_in)[0][0])
        else:
            ac = (metadata.get('act_most_common') if metadata else None)
            if ac and ac in (act_map or {}):
                act_enc = int((act_map or {})[ac])
                print(f"[ML-PREDICT] Activity '{activity_in}' not in training, using '{ac}'")
    except Exception as e:
        print(f"[ML-PREDICT] Failed to encode activity: {e}")

    try:
        if food_map and food_in in food_map:
            food_enc = int(food_map[food_in])
        elif le_food and food_in in getattr(le_food, 'classes_', []):
            food_enc = int(np.where(getattr(le_food, 'classes_', []) == food_in)[0][0])
        else:
            fc = (metadata.get('food_most_common') if metadata else None)
            if fc and fc in (food_map or {}):
                food_enc = int((food_map or {})[fc])
                print(f"[ML-PREDICT] Food '{food_in}' not in training, using '{fc}'")
    except Exception as e:
        print(f"[ML-PREDICT] Failed to encode food: {e}")

    try:
        if water_map and water_in in water_map:
            water_enc = int(water_map[water_in])
        elif le_water and water_in in getattr(le_water, 'classes_', []):
            water_enc = int(np.where(getattr(le_water, 'classes_', []) == water_in)[0][0])
        else:
            wc = (metadata.get('water_most_common') if metadata else None)
            if wc and wc in (water_map or {}):
                water_enc = int((water_map or {})[wc])
                print(f"[ML-PREDICT] Water '{water_in}' not in training, using '{wc}'")
    except Exception as e:
        print(f"[ML-PREDICT] Failed to encode water: {e}")

    try:
        if bathroom_map and bathroom_in in bathroom_map:
            bathroom_enc = int(bathroom_map[bathroom_in])
        elif le_bathroom and bathroom_in in getattr(le_bathroom, 'classes_', []):
            bathroom_enc = int(np.where(getattr(le_bathroom, 'classes_', []) == bathroom_in)[0][0])
        else:
            bc = (metadata.get('bathroom_most_common') if metadata else None)
            if bc and bc in (bathroom_map or {}):
                bathroom_enc = int((bathroom_map or {})[bc])
                print(f"[ML-PREDICT] Bathroom '{bathroom_in}' not in training, using '{bc}'")
    except Exception as e:
        print(f"[ML-PREDICT] Failed to encode bathroom: {e}")

    # If encodings are missing, fallback
    if act_enc is None or food_enc is None or water_enc is None or bathroom_enc is None:
        print(f"[ML-PREDICT] Missing encodings, using rule-based fallback")
        result = "high" if rule_flag else "low"
        print(f"[ML-PREDICT] → Rule-based result: {result}")
        return result

    X = np.array([[act_enc, food_enc, water_enc, bathroom_enc, symptom_in]])

    try:
        if hasattr(model, 'predict_proba'):
            proba = model.predict_proba(X)[0]
            p_pos = float(proba[1]) if len(proba) > 1 else float(proba[0])
            print(f"[ML-PREDICT] Model proba: {p_pos:.3f}")
        else:
            p_pos = float(model.predict(X)[0])
            print(f"[ML-PREDICT] Model prediction (raw): {p_pos:.3f}")
    except Exception as e:
        print(f"[ML-PREDICT] Model prediction failed: {e}, using rule-based fallback")
        result = "high" if rule_flag else "low"
        print(f"[ML-PREDICT] → Rule-based result: {result}")
        return result

    # Thresholds to convert probability into low/medium/high
    if p_pos >= 0.75:
        print(f"[ML-PREDICT] → HIGH (p_pos {p_pos:.3f} >= 0.75)")
        return "high"
    elif p_pos >= 0.40:
        print(f"[ML-PREDICT] → MEDIUM (p_pos {p_pos:.3f} >= 0.40)")
        return "medium"
    else:
        print(f"[ML-PREDICT] → LOW (p_pos {p_pos:.3f} < 0.40)")
        return "low"

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
        else:
            # train on all pets combined
            resp = supabase.table("behavior_logs").select("*").order("log_date", desc=False).limit(100000).execute()
            logs = resp.data or []
            if not logs:
                return jsonify({"status":"no_data","message":"No behavior_logs found"}), 200
            df_all = pd.DataFrame(logs)
            df_all['log_date'] = pd.to_datetime(df_all['log_date']).dt.date
            # Sleep hours and mood no longer collected - skip these columns
            df_all['activity_level'] = df_all['activity_level'].fillna('Unknown').astype(str)
            train_illness_model(df_all)
        return jsonify({"status":"ok","message":"Models trained"}), 200
    except Exception as e:
        return jsonify({"status":"error","message":str(e)}), 500

# Debug endpoint to understand sleep data and predictions
@app.route("/debug_sleep", methods=["POST"])
def debug_sleep_forecast():
    """Debug endpoint - Sleep tracking has been removed from the system."""
    data = request.get_json(silent=True) or {}
    pet_id = data.get("pet_id")
    if not pet_id:
        return jsonify({"error": "pet_id required"}), 400

    try:
        return jsonify({
            "pet_id": pet_id,
            "message": "Sleep tracking has been removed from the system",
            "note": "The system now focuses on activity_level, food_intake, water_intake, bathroom_habits, and symptoms for health analysis"
        })
    except Exception as e:
        return jsonify({"error": str(e)}), 500


@app.route("/test_accuracy", methods=["POST"])
def test_model_accuracy():
    """
    Test the accuracy of illness prediction and sleep forecasting models.
    Uses time-series cross-validation: train on past data, test on future data.
    
    Request body:
    {
        "pet_id": "optional - test specific pet or all pets if omitted",
        "test_days": 7  # how many days into future to test predictions
    }
    """
    data = request.get_json(silent=True) or {}
    pet_id = data.get("pet_id")
    test_days = int(data.get("test_days", 7))
    
    try:
        from sklearn.metrics import accuracy_score, precision_score, recall_score, f1_score, confusion_matrix, mean_absolute_error, mean_squared_error, r2_score
        
        results = {
            "illness_prediction": {
                "accuracy": None,
                "precision": None,
                "recall": None,
                "f1_score": None,
                "confusion_matrix": None,
                "test_samples": 0,
                "details": []
            },
            "sleep_forecast": {
                "mae": None,
                "rmse": None,
                "r2": None,
                "test_samples": 0,
                "details": []
            }
        }
        
        # Get pets to test
        if pet_id:
            pet_ids = [pet_id]
        else:
            pets_resp = supabase.table("pets").select("id").limit(50).execute()
            pet_ids = [p["id"] for p in (pets_resp.data or [])]
        
        illness_y_true, illness_y_pred = [], []
        sleep_y_true, sleep_y_pred = [], []
        
        for pid in pet_ids:
            df = fetch_logs_df(pid, limit=500)
            if df.empty or len(df) < test_days + 10:
                continue
            
            df = df.copy()
            df['log_date'] = pd.to_datetime(df['log_date'])
            df = df.sort_values('log_date')
            
            # Split: use all but last test_days for training, last test_days for testing
            split_idx = len(df) - test_days
            train_df = df.iloc[:split_idx]
            test_df = df.iloc[split_idx:]
            
            # --- Test Illness Prediction ---
            try:
                # Train model on training data
                train_illness_model(train_df)
                
                for _, row in test_df.iterrows():
                    activity = str(row.get("activity_level", ""))
                    food_intake = str(row.get("food_intake", ""))
                    water_intake = str(row.get("water_intake", ""))
                    bathroom_habits = str(row.get("bathroom_habits", ""))
                    
                    # Count symptoms
                    symptom_count = 0
                    try:
                        import json
                        symptoms_str = str(row.get("symptoms", "[]"))
                        symptoms = json.loads(symptoms_str) if isinstance(symptoms_str, str) else []
                        filtered = [s for s in symptoms if str(s).lower().strip() not in ["none of the above", "", "none", "unknown"]]
                        symptom_count = len(filtered)
                    except:
                        symptom_count = 0
                    
                    # Predict
                    pred_risk = predict_illness_risk(activity, food_intake, water_intake, bathroom_habits, symptom_count)
                    
                    # Ground truth: use same logic as training
                    actual_unhealthy = (
                        (food_intake.lower() in ['not eating', 'eating less']) or
                        (water_intake.lower() in ['not drinking', 'drinking less']) or
                        (bathroom_habits.lower() in ['diarrhea', 'constipation', 'frequent urination']) or
                        (symptom_count >= 2) or
                        (activity.lower() == 'low')
                    )
                    actual_risk = "high" if actual_unhealthy else "low"
                    
                    # Convert to binary for metrics (unhealthy=1, healthy=0)
                    illness_y_true.append(1 if actual_risk in ["high", "medium"] else 0)
                    illness_y_pred.append(1 if pred_risk in ["high", "medium"] else 0)
                    
                    results["illness_prediction"]["details"].append({
                        "pet_id": pid,
                        "date": str(row['log_date'].date()),
                        "predicted": pred_risk,
                        "actual": actual_risk,
                        "correct": pred_risk == actual_risk
                    })
            except Exception as e:
                print(f"Illness test error for pet {pid}: {e}")
            
            # Sleep forecast has been removed
        
        # Calculate illness prediction metrics
        if illness_y_true and illness_y_pred:
            results["illness_prediction"]["test_samples"] = len(illness_y_true)
            results["illness_prediction"]["accuracy"] = round(accuracy_score(illness_y_true, illness_y_pred), 3)
            results["illness_prediction"]["precision"] = round(precision_score(illness_y_true, illness_y_pred, zero_division=0), 3)
            results["illness_prediction"]["recall"] = round(recall_score(illness_y_true, illness_y_pred, zero_division=0), 3)
            results["illness_prediction"]["f1_score"] = round(f1_score(illness_y_true, illness_y_pred, zero_division=0), 3)
            
            cm = confusion_matrix(illness_y_true, illness_y_pred)
            results["illness_prediction"]["confusion_matrix"] = {
                "true_negative": int(cm[0][0]) if cm.shape == (2, 2) else 0,
                "false_positive": int(cm[0][1]) if cm.shape == (2, 2) else 0,
                "false_negative": int(cm[1][0]) if cm.shape == (2, 2) else 0,
                "true_positive": int(cm[1][1]) if cm.shape == (2, 2) else 0
            }
        
        # Calculate sleep forecasting metrics
        if sleep_y_true and sleep_y_pred:
            results["sleep_forecast"]["test_samples"] = len(sleep_y_true)
            results["sleep_forecast"]["mae"] = round(mean_absolute_error(sleep_y_true, sleep_y_pred), 3)
            results["sleep_forecast"]["rmse"] = round(np.sqrt(mean_squared_error(sleep_y_true, sleep_y_pred)), 3)
            
            try:
                r2 = r2_score(sleep_y_true, sleep_y_pred)
                results["sleep_forecast"]["r2"] = round(r2, 3)
            except:
                results["sleep_forecast"]["r2"] = None
        
        # Add interpretation
        results["interpretation"] = {
            "illness_prediction": _interpret_illness_metrics(
                results["illness_prediction"]["accuracy"],
                results["illness_prediction"]["f1_score"]
            ),
            "sleep_forecast": _interpret_sleep_metrics(
                results["sleep_forecast"]["mae"],
                results["sleep_forecast"]["r2"]
            )
        }
        
        return jsonify(results)
        
    except Exception as e:
        return jsonify({"error": str(e), "details": "Error during accuracy testing"}), 500


def _interpret_illness_metrics(accuracy, f1):
    """Interpret illness prediction performance"""
    if accuracy is None or f1 is None:
        return "Insufficient data for evaluation"
    
    if accuracy >= 0.85 and f1 >= 0.80:
        return "Excellent - Model is highly accurate and reliable"
    elif accuracy >= 0.75 and f1 >= 0.70:
        return "Good - Model performs well with room for improvement"
    elif accuracy >= 0.65 and f1 >= 0.60:
        return "Fair - Model is somewhat reliable but needs more training data"
    else:
        return "Poor - Model needs significant improvement, consider collecting more diverse data"


def _interpret_sleep_metrics(mae, r2):
    """Interpret sleep forecasting performance"""
    if mae is None:
        return "Insufficient data for evaluation"
    
    # MAE interpretation (hours off from actual)
    mae_quality = "excellent" if mae < 0.5 else "good" if mae < 1.0 else "fair" if mae < 1.5 else "poor"
    
    # R² interpretation (how much variance explained)
    if r2 is not None:
        if r2 >= 0.8:
            r2_quality = "excellent fit"
        elif r2 >= 0.6:
            r2_quality = "good fit"
        elif r2 >= 0.4:
            r2_quality = "moderate fit"
        else:
            r2_quality = "poor fit"
        
        return f"MAE: {mae_quality} (±{mae:.2f} hours error), R²: {r2_quality} ({r2:.2f})"
    
    return f"MAE: {mae_quality} (±{mae:.2f} hours error)"


@app.route("/test_accuracy/summary", methods=["GET"])
def test_accuracy_summary():
    """
    Get a quick summary of model performance across all pets.
    This is a lightweight version that provides overview metrics.
    """
    try:
        # Check if illness model is trained
        illness_trained = is_illness_model_trained()
        
        # Get counts
        pets_resp = supabase.table("pets").select("id", count="exact").execute()
        pets_count = len(pets_resp.data or [])
        
        logs_resp = supabase.table("behavior_logs").select("id", count="exact").limit(1).execute()
        
        preds_resp = supabase.table("predictions").select("id", count="exact").limit(1).execute()
        
        # Load illness model metadata if available
        model_metadata = None
        if illness_trained:
            try:
                loaded = load_illness_model()
                if loaded and loaded[0]:
                    model_metadata = loaded[4]  # metadata is 5th element
            except:
                pass
        
        return jsonify({
            "status": "ready" if illness_trained else "not_trained",
            "illness_model": {
                "trained": illness_trained,
                "metadata": model_metadata
            },
            "data_overview": {
                "total_pets": pets_count,
                "behavior_logs_available": logs_resp.count if hasattr(logs_resp, 'count') else "unknown",
                "predictions_stored": preds_resp.count if hasattr(preds_resp, 'count') else "unknown"
            },
            "recommendation": (
                "Model is trained and ready for accuracy testing. Use POST /test_accuracy to run detailed tests."
                if illness_trained
                else "Model not yet trained. Log more behavior data and use POST /train to train the model first."
            )
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


if __name__ == "__main__":
    # Run a one-time migration at startup (safe and idempotent)
    parser = argparse.ArgumentParser()
    parser.add_argument("--task", type=str, default=None,
                        help="Optional task to run directly: daily_analysis | migrate | backfill_sleep | migrate_legacy_sleep_forecasts")
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
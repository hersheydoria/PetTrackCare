import os
import re
import html
from datetime import datetime, date, timedelta
from zoneinfo import ZoneInfo
from flask import Flask, request, jsonify, make_response
import pandas as pd
import numpy as np
from sklearn.ensemble import RandomForestClassifier
from sklearn.preprocessing import LabelEncoder
from sklearn.model_selection import cross_val_score, StratifiedKFold
import requests
from dotenv import load_dotenv
from apscheduler.schedulers.background import BackgroundScheduler
import json
import joblib
import subprocess
import sys
import argparse
import traceback
import threading

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
load_dotenv(os.path.join(BASE_DIR, ".env"))
PARENT_DIR = os.path.dirname(BASE_DIR)
load_dotenv(os.path.join(PARENT_DIR, ".env"), override=True)

# Load environment variables
BACKEND_PORT = int(os.getenv("BACKEND_PORT", "5000"))
FASTAPI_BASE_URL = os.getenv("FASTAPI_BASE_URL") or f"http://172.20.10.7:{os.getenv('FASTAPI_PORT', '8000')}"
FASTAPI_TIMEOUT = float(os.getenv("FASTAPI_TIMEOUT", "15"))
BACKEND_ANALYZE_URL = (os.getenv("BACKEND_ANALYZE_URL") or f"http://172.20.10.7:{BACKEND_PORT}/analyze").strip()

http_session = requests.Session()
http_session.headers.update({"Accept": "application/json"})
app = Flask(__name__)

def _fastapi_url(path: str) -> str:
    base = FASTAPI_BASE_URL.rstrip("/")
    return f"{base}/{path.lstrip('/')}" if path else base

def _fastapi_get(path: str, params: dict | None = None, timeout: float | None = None):
    url = _fastapi_url(path)
    response = http_session.get(url, params=params, timeout=timeout or FASTAPI_TIMEOUT)
    response.raise_for_status()
    return response.json()

def _fastapi_get_optional(path: str, params: dict | None = None, timeout: float | None = None):
    try:
        return _fastapi_get(path, params=params, timeout=timeout)
    except requests.HTTPError as exc:
        if exc.response is not None and exc.response.status_code == 404:
            return None
        raise

def fetch_pet_record(pet_id: str) -> dict | None:
    try:
        return _fastapi_get_optional(f"/pets/{pet_id}")
    except Exception as exc:
        print(f"[DEBUG] Failed to fetch pet {pet_id}: {exc}")
        return None

def fetch_user_profile(user_id: str) -> dict | None:
    try:
        return _fastapi_get_optional(f"/users/{user_id}")
    except Exception as exc:
        print(f"[DEBUG] Failed to fetch user {user_id}: {exc}")
        return None

# Track last training time per pet to avoid re-training on every request
MODEL_TRAIN_HISTORY = {}
MODEL_TRAIN_COOLDOWN = timedelta(hours=6)


def schedule_pet_model_training(pet_id, df):
    """Run illness model training asynchronously with cooldown per pet."""
    if df is None or df.empty:
        return

    now = datetime.now()
    last_run = MODEL_TRAIN_HISTORY.get(pet_id)
    if last_run and (now - last_run) < MODEL_TRAIN_COOLDOWN:
        minutes_since = int((now - last_run).total_seconds() // 60)
        print(f"[ANALYZE] Pet {pet_id}: Skipping retrain (last run {minutes_since} min ago)")
        return

    def _train_async(df_snapshot):
        try:
            print(f"[ANALYZE] Pet {pet_id}: Async retraining illness model...")
            train_illness_model(df_snapshot)
            MODEL_TRAIN_HISTORY[pet_id] = datetime.now()
            print(f"[ANALYZE] Pet {pet_id}: Model retrain finished")
        except Exception as exc:
            print(f"[ANALYZE] Pet {pet_id}: ⚠ Model retrain failed: {exc}")

    threading.Thread(target=_train_async, args=(df.copy(),), daemon=True).start()

# ------------------- Health & Behavior Analysis Guide -------------------
# Based on veterinary research and AAHA guidelines for early detection of health issues

HEALTH_SYMPTOMS_REFERENCE = {
    # Weight-related concerns
    "weight_loss": {
        "description": "Unexplained weight loss",
        "possible_causes": ["hyperthyroidism", "diabetes", "cancer", "digestive issues", "parasites"],
        "urgency": "medium",
        "action": "Schedule vet visit within 1-2 weeks"
    },
    "weight_gain": {
        "description": "Unexplained weight gain",
        "possible_causes": ["obesity", "fluid retention", "hypothyroidism", "hormonal imbalance"],
        "urgency": "low",
        "action": "Discuss diet and exercise during next vet visit"
    },
    
    # Gastrointestinal issues
    "vomiting": {
        "description": "Vomiting or regurgitation",
        "possible_causes": ["infection", "toxins", "GI issues", "food intolerance", "pancreatitis"],
        "urgency": "high" if "repeated" else "low",
        "action": "Monitor; if repeated (2+ times in 24h), contact vet immediately"
    },
    "diarrhea": {
        "description": "Diarrhea or loose stools",
        "possible_causes": ["infection", "food change", "allergies", "parasites", "IBD"],
        "urgency": "high" if "bloody" else "medium",
        "action": "If bloody or persistent, seek vet care within 24 hours"
    },
    "bloody_stool": {
        "description": "Blood in stool",
        "possible_causes": ["infection", "parasites", "GI ulcers", "inflammatory bowel disease"],
        "urgency": "high",
        "action": "Contact vet same day"
    },
    
    # Respiratory issues
    "labored_breathing": {
        "description": "Labored breathing or respiratory distress",
        "possible_causes": ["respiratory infection", "heart disease", "asthma", "airway obstruction"],
        "urgency": "critical",
        "action": "EMERGENCY - Seek immediate veterinary care"
    },
    "coughing": {
        "description": "Persistent coughing",
        "possible_causes": ["respiratory infection", "heart disease", "asthma", "allergies"],
        "urgency": "medium",
        "action": "Schedule vet visit within 1 week"
    },
    "excessive_panting": {
        "description": "Excessive panting not related to exercise/heat",
        "possible_causes": ["heart disease", "anxiety", "pain", "fever"],
        "urgency": "high",
        "action": "Contact vet within 24 hours"
    },
    
    # Skin and grooming
    "excessive_grooming": {
        "description": "Excessive licking, chewing, or scratching",
        "possible_causes": ["allergies", "skin infection", "fleas", "anxiety", "pain"],
        "urgency": "medium",
        "action": "Schedule vet appointment within 1-2 weeks"
    },
    "hair_loss": {
        "description": "Hair loss or bald spots",
        "possible_causes": ["allergies", "infection", "parasites", "hormonal imbalance"],
        "urgency": "medium",
        "action": "Get veterinary skin evaluation"
    },
    "skin_redness": {
        "description": "Red or irritated skin",
        "possible_causes": ["infection", "allergies", "parasites", "inflammation"],
        "urgency": "medium",
        "action": "Prevent further irritation; schedule vet visit"
    },
    "hot_spots": {
        "description": "Hot spots or localized skin inflammation",
        "possible_causes": ["infection", "allergies", "over-grooming"],
        "urgency": "medium",
        "action": "Keep area clean; seek vet care to prevent worsening"
    },
    
    # Urinary issues
    "straining_urinate": {
        "description": "Straining to urinate",
        "possible_causes": ["UTI", "bladder stones", "urinary obstruction", "prostate issues"],
        "urgency": "high",
        "action": "Contact vet same day; may be urinary obstruction"
    },
    "blood_urine": {
        "description": "Blood in urine",
        "possible_causes": ["UTI", "bladder stones", "kidney disease", "trauma"],
        "urgency": "high",
        "action": "Vet visit same day"
    },
    "house_soiling": {
        "description": "Accidents in the house (house soiling)",
        "possible_causes": ["UTI", "incontinence", "cognitive decline", "anxiety", "digestive issues"],
        "urgency": "medium",
        "action": "Veterinary evaluation to rule out medical causes"
    },
    "excessive_urination": {
        "description": "Increased frequency of urination",
        "possible_causes": ["diabetes", "kidney disease", "UTI", "Cushing's disease"],
        "urgency": "medium",
        "action": "Vet visit within 24-48 hours"
    },
    
    # Oral health
    "bad_breath": {
        "description": "Persistent bad breath or foul odor",
        "possible_causes": ["dental disease", "oral infection", "oral tumors", "kidney disease"],
        "urgency": "low",
        "action": "Schedule dental exam with vet"
    },
    "excessive_drooling": {
        "description": "Excessive drooling or salivation",
        "possible_causes": ["dental disease", "mouth pain", "neurological issue", "toxin exposure"],
        "urgency": "medium",
        "action": "Vet examination needed"
    },
    "difficulty_chewing": {
        "description": "Difficulty chewing or swallowing",
        "possible_causes": ["dental disease", "mouth pain", "oral tumor", "neurological issue"],
        "urgency": "medium",
        "action": "Dental and neurological evaluation"
    },
    
    # Behavioral and neurological
    "sudden_aggression": {
        "description": "Sudden aggression or irritability",
        "possible_causes": ["pain", "neurological issue", "fear", "medical condition"],
        "urgency": "high",
        "action": "Veterinary behavioral and medical evaluation"
    },
    "withdrawal": {
        "description": "Withdrawal, hiding, or social isolation",
        "possible_causes": ["illness", "pain", "anxiety", "depression"],
        "urgency": "medium",
        "action": "Veterinary and behavioral assessment"
    },
    "clinginess": {
        "description": "Unusual clinginess or separation anxiety",
        "possible_causes": ["cognitive decline", "sensory impairment", "pain", "anxiety"],
        "urgency": "medium",
        "action": "Vet evaluation for underlying causes"
    },
    "head_pressing": {
        "description": "Head pressing against walls/furniture (red flag)",
        "possible_causes": ["intracranial disease", "neurological disorder", "toxin exposure"],
        "urgency": "critical",
        "action": "EMERGENCY - Immediate veterinary evaluation"
    },
    "circling": {
        "description": "Circling behavior or disorientation",
        "possible_causes": ["neurological issue", "cognitive decline", "inner ear problem"],
        "urgency": "high",
        "action": "Urgent vet examination"
    },
    "seizures": {
        "description": "Seizures or convulsions",
        "possible_causes": ["epilepsy", "toxin exposure", "neurological disease", "fever"],
        "urgency": "critical",
        "action": "EMERGENCY - Immediate veterinary care"
    },
    "loss_of_balance": {
        "description": "Loss of balance or coordination",
        "possible_causes": ["inner ear infection", "neurological issue", "vestibular disease"],
        "urgency": "high",
        "action": "Urgent vet evaluation"
    },
    
    # Movement and pain
    "lameness": {
        "description": "Limping or lameness",
        "possible_causes": ["injury", "arthritis", "joint pain", "neurological issue"],
        "urgency": "medium",
        "action": "Vet examination for pain management"
    },
    "difficulty_moving": {
        "description": "Difficulty standing or moving",
        "possible_causes": ["arthritis", "hip dysplasia", "injury", "neurological issue", "pain"],
        "urgency": "medium",
        "action": "Orthopedic and pain evaluation"
    },
    "reluctance_stairs": {
        "description": "Avoiding stairs or jumping",
        "possible_causes": ["joint pain", "arthritis", "age-related", "injury"],
        "urgency": "low",
        "action": "Pain management discussion with vet"
    },
    
    # Vital sign changes
    "excessive_thirst": {
        "description": "Excessive drinking (polydipsia)",
        "possible_causes": ["diabetes", "kidney disease", "Cushing's disease", "UTI", "fever"],
        "urgency": "medium",
        "action": "Vet visit within 24-48 hours for bloodwork"
    },
    "loss_appetite": {
        "description": "Loss of appetite (anorexia)",
        "possible_causes": ["dental pain", "illness", "digestive issue", "stress", "medication side effect"],
        "urgency": "medium",
        "action": "Vet evaluation; monitor for dehydration"
    },
    "increased_hunger": {
        "description": "Increased appetite (hyperphagia)",
        "possible_causes": ["hyperthyroidism (cats)", "Cushing's disease", "diabetes", "malabsorption"],
        "urgency": "low",
        "action": "Routine vet visit for evaluation"
    },
    "not_drinking": {
        "description": "Avoiding water or refusing to drink",
        "possible_causes": ["nausea", "oral pain", "dehydration", "kidney issues"],
        "urgency": "high",
        "action": "Offer small amounts of water frequently and contact your vet if it continues"
    },
    "drinking_less": {
        "description": "Drinking less water than usual",
        "possible_causes": ["mild dehydration", "illness", "medication side effects"],
        "urgency": "medium",
        "action": "Keep water bowls accessible and monitor intake closely"
    },
    "hyperactivity": {
        "description": "Hyperactivity or unusually high energy",
        "possible_causes": ["anxiety", "pain", "neurological issue", "environmental stress"],
        "urgency": "medium",
        "action": "Ensure ample exercise and calm enrichment; rule out medical causes"
    },
    
    # Sleep and energy
    "excessive_sleeping": {
        "description": "Sleeping more than usual",
        "possible_causes": ["pain", "infection", "metabolic issue", "depression", "age-related"],
        "urgency": "medium",
        "action": "Vet evaluation for underlying causes"
    },
    "restlessness_night": {
        "description": "Restlessness or pacing at night",
        "possible_causes": ["cognitive decline", "pain", "anxiety", "medical condition"],
        "urgency": "low",
        "action": "Discuss behavioral and medical options with vet"
    },
    "lethargy": {
        "description": "General lethargy or lack of energy",
        "possible_causes": ["infection", "pain", "metabolic issue", "cardiac issue", "depression"],
        "urgency": "high",
        "action": "Vet evaluation needed"
    },
}

HEALTH_REFERENCE_SYNONYMS = {
    "blood_urine": [
        "blood in urine",
        "bloody urine",
        "blood in stool",
        "bloody stool",
        "blood urine"
    ],
}

# Ensure a stable models directory
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

# ------------------- Helper Functions -------------------

def fetch_logs_df(pet_id, limit=200, days_back=30):
    """Fetch recent behavior logs for a pet (within last N days)"""
    params = {"pet_id": pet_id, "limit": limit}
    if days_back is not None:
        start_date = (datetime.utcnow().date() - timedelta(days=days_back)).isoformat()
        params["start_date"] = start_date
    try:
        data = _fastapi_get("/behavior_logs", params=params)
    except Exception as exc:
        print(f"[WARN] Failed to fetch logs for pet {pet_id}: {exc}")
        return pd.DataFrame()
    data = data or []
    if not data:
        return pd.DataFrame()
    df = pd.DataFrame(data)
    if 'log_date' in df:
        df['log_date'] = pd.to_datetime(df['log_date']).dt.date
    else:
        df['log_date'] = pd.Series([], dtype='datetime64[ns]').dt.date

    cutoff_date = (datetime.utcnow() - timedelta(days=days_back)).date() if days_back is not None else None
    if cutoff_date is not None:
        df = df[df['log_date'] >= cutoff_date]

    df['activity_level'] = df.get('activity_level', pd.Series(['Unknown'] * len(df))).fillna('Unknown').astype(str)
    df['food_intake'] = df.get('food_intake', pd.Series(['Unknown'] * len(df))).fillna('Unknown').astype(str)
    df['water_intake'] = df.get('water_intake', pd.Series(['Unknown'] * len(df))).fillna('Unknown').astype(str)
    df['bathroom_habits'] = df.get('bathroom_habits', pd.Series(['Unknown'] * len(df))).fillna('Unknown').astype(str)
    df['symptoms'] = df.get('symptoms', pd.Series(['[]'] * len(df))).fillna('[]').astype(str)

    return df

def fetch_pet_breed(pet_id):
    """Fetch pet breed from database"""
    pet = _fastapi_get_optional(f"/pets/{pet_id}")
    if pet:
        return pet.get("breed")
    return None

def train_illness_model(df, model_path=os.path.join(MODELS_DIR, "illness_model.pkl"), min_auc_threshold: float = 0.6):
    if df.shape[0] < 5:
        return None, None
    
    # Prepare label encoders for categorical features
    le_activity = LabelEncoder()
    le_food = LabelEncoder()
    le_water = LabelEncoder()
    le_bathroom = LabelEncoder()
    
    # Normalize (lowercase) categorical features before encoding to match prediction normalization
    df_norm = df.copy()
    df_norm['activity_level'] = df_norm['activity_level'].str.lower()
    df_norm['food_intake'] = df_norm['food_intake'].str.lower()
    df_norm['water_intake'] = df_norm['water_intake'].str.lower()
    df_norm['bathroom_habits'] = df_norm['bathroom_habits'].str.lower()
    
    # Encode categorical features (activity, food, water, bathroom only)
    df_norm['act_enc'] = le_activity.fit_transform(df_norm['activity_level'])
    df_norm['food_enc'] = le_food.fit_transform(df_norm['food_intake'])
    df_norm['water_enc'] = le_water.fit_transform(df_norm['water_intake'])
    df_norm['bathroom_enc'] = le_bathroom.fit_transform(df_norm['bathroom_habits'])
    
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
    
    df_norm['symptom_count'] = df_norm['symptoms'].apply(count_symptoms)
    
    # Build feature matrix with health indicators (activity, food, water, bathroom, symptoms only)
    X = df_norm[['act_enc', 'food_enc', 'water_enc', 'bathroom_enc', 'symptom_count']].values
    
    # Illness indicator based on health data (without mood or sleep)
    y = (
        # Food intake issues
        (df_norm['food_intake'].isin(['not eating', 'eating less'])) |
        # Water intake issues
        (df_norm['water_intake'].isin(['not drinking', 'drinking less'])) |
        # Bathroom issues
        (df_norm['bathroom_habits'].isin(['diarrhea', 'constipation', 'frequent urination'])) |
        # Multiple symptoms (2 or more real symptoms)
        (df_norm['symptom_count'] >= 2) |
        # Low activity level
        (df_norm['activity_level'] == 'low')
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
    Also detects sudden changes from baseline behavior.
    """
    if df is None or df.empty:
        print(f"[CONTEXTUAL-RISK] No data provided, returning 'low'")
        return "low"
    try:
        recent = df.copy()
        recent['log_date'] = pd.to_datetime(recent['log_date'])
        recent = recent.sort_values('log_date').tail(14)
        
        # Check if latest log is stale (more than 7 days old)
        if not recent.empty:
            latest_date = recent['log_date'].max()
            days_since_log = (datetime.now() - latest_date).days
            if days_since_log > 7:
                print(f"[CONTEXTUAL-RISK] [WARNING] Latest log is {days_since_log} days old - analysis may be outdated")
        
        print(f"[CONTEXTUAL-RISK] Analyzing {len(recent)} recent logs")
        print(f"[CONTEXTUAL-RISK] Recent logs:\n{recent[['log_date', 'activity_level', 'food_intake', 'water_intake', 'bathroom_habits']].to_string()}")

        # Count SERIOUS problematic behaviors (not eating/drinking, bathroom issues)
        # Updated to match new category values with substring matching
        low_activity_count = recent['activity_level'].str.lower().str.contains('low', regex=False, na=False).sum()
        not_eating_count = recent['food_intake'].str.lower().str.contains('not eating', regex=False, na=False).sum()  # SERIOUS
        eating_less_count = recent['food_intake'].str.lower().str.contains('eating less', regex=False, na=False).sum()  # MINOR
        weight_loss_count = recent['food_intake'].str.lower().str.contains('weight loss', regex=False, na=False).sum()  # SERIOUS
        not_drinking_count = recent['water_intake'].str.lower().str.contains('not drinking', regex=False, na=False).sum()  # SERIOUS
        drinking_less_count = recent['water_intake'].str.lower().str.contains('drinking less', regex=False, na=False).sum()  # MINOR
        diarrhea_count = recent['bathroom_habits'].str.lower().str.contains('diarrhea', regex=False, na=False).sum()
        constipation_count = recent['bathroom_habits'].str.lower().str.contains('constipation', regex=False, na=False).sum()
        straining_count = recent['bathroom_habits'].str.lower().str.contains('straining', regex=False, na=False).sum()
        blood_in_urine_count = recent['bathroom_habits'].str.lower().str.contains('blood', regex=False, na=False).sum()
        house_soiling_count = recent['bathroom_habits'].str.lower().str.contains('house soiling', regex=False, na=False).sum()
        frequent_urination_count = recent['bathroom_habits'].str.lower().str.contains('frequent urin', regex=False, na=False).sum()
        
        # Combine serious bathroom issues
        bad_bathroom_count = diarrhea_count + constipation_count + straining_count + blood_in_urine_count + house_soiling_count + frequent_urination_count
        
        total_logs = len(recent)
        
        p_low_act = low_activity_count / total_logs if total_logs > 0 else 0
        p_not_eating = (not_eating_count + weight_loss_count) / total_logs if total_logs > 0 else 0  # SERIOUS (includes weight loss)
        p_eating_less = eating_less_count / total_logs if total_logs > 0 else 0  # MINOR
        p_not_drinking = not_drinking_count / total_logs if total_logs > 0 else 0  # SERIOUS
        p_drinking_less = drinking_less_count / total_logs if total_logs > 0 else 0  # MINOR
        p_bad_bathroom = bad_bathroom_count / total_logs if total_logs > 0 else 0

        print(f"[CONTEXTUAL-RISK] Patterns: Low activity={p_low_act:.2f}, NOT eating={p_not_eating:.2f} (serious), eating less={p_eating_less:.2f} (minor), NOT drinking={p_not_drinking:.2f} (serious), drinking less={p_drinking_less:.2f} (minor), Bad bathroom={p_bad_bathroom:.2f}")

        # CHANGE DETECTION: Alert if latest log shows deterioration from baseline
        change_detected = False
        if len(recent) >= 2:
            latest_log = recent.iloc[-1]  # Most recent
            earlier_logs = recent.iloc[:-1]  # Previous logs
            
            # Check if latest food intake is worse than earlier pattern
            latest_food = str(latest_log['food_intake']).lower()
            earlier_food = earlier_logs['food_intake'].str.lower()
            normal_food_baseline = (earlier_food == 'normal').sum() > len(earlier_logs) * 0.5  # Was mostly normal
            
            if normal_food_baseline and latest_food in ['eating less', 'not eating']:
                print(f"[CONTEXTUAL-RISK] [ALERT] CHANGE DETECTED: Food intake changed from normal to '{latest_food}'")
                change_detected = True
            
            # Similar check for water intake
            latest_water = str(latest_log['water_intake']).lower()
            earlier_water = earlier_logs['water_intake'].str.lower()
            normal_water_baseline = (earlier_water == 'normal').sum() > len(earlier_logs) * 0.5
            
            if normal_water_baseline and latest_water in ['drinking less', 'not drinking']:
                print(f"[CONTEXTUAL-RISK] [ALERT] CHANGE DETECTED: Water intake changed from normal to '{latest_water}'")
                change_detected = True

        risk = "low"
        
        # High risk: serious issues (not eating/drinking) combined with other problems
        if (p_not_eating > 0.5 or p_not_drinking > 0.5) and (low_activity_count >= 2 or p_bad_bathroom > 0.3):
            print(f"[CONTEXTUAL-RISK] → HIGH (serious issues: NOT eating={p_not_eating:.2f}>0.5 or NOT drinking={p_not_drinking:.2f}>0.5, combined with low activity or bathroom issues)")
            risk = "high"
        # Medium risk: single serious issue persisting, multiple minor issues, or detected changes
        elif (p_low_act > 0.7) or (p_not_eating > 0.3) or (p_not_drinking > 0.3) or (p_bad_bathroom > 0.5) or change_detected:
            if change_detected:
                print(f"[CONTEXTUAL-RISK] → MEDIUM (sudden change in behavior detected from baseline)")
            elif p_low_act > 0.7:
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
def analyze_pet_df(pet_id, df, prediction_date=None):
    """Analyze provided DataFrame of logs for pet_id and return analysis results (no storage to predictions table)."""
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

    # Note: predictions table storage removed - only fresh analysis is returned

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

# ------------------- Missing Alert Helpers -------------------
MISSING_ALERT_PATTERNS = {
    "custom_message": re.compile(r"📝 Additional Details:\s*(?P<value>.*?)(?=\n\n|$)", re.DOTALL),
    "special_notes": re.compile(r"⚠️ Important Notes:\s*(?P<value>.*?)(?=\n\n|$)", re.DOTALL),
    "emergency_contact": re.compile(r"📞 Emergency Contact:\s*(?P<value>[^\n]+)"),
    "reward": re.compile(r"💰 Reward Offered:\s*₱\s*(?P<value>[^\n]+)")
}
URGENCY_LABELS = {
    "🚨 CRITICAL MISSING PET ALERT 🚨": "Critical",
    "⚠️ URGENT: MISSING PET ⚠️": "High",
    "🔍 Missing Pet Alert": "Medium",
}


def _parse_missing_alert_content(content: str) -> dict:
    if not content:
        return {}
    details: dict[str, str] = {}
    for key, pattern in MISSING_ALERT_PATTERNS.items():
        match = pattern.search(content)
        if match:
            value = match.group("value").strip()
            if value:
                details[key] = value
    for token, label in URGENCY_LABELS.items():
        if token in content:
            details["urgency"] = label
            break
    details.setdefault("urgency", "Medium")
    return details


def _match_missing_alert_post(posts: list[dict], pet_id: str | None, owner_id: str | None, pet_name: str | None) -> dict | None:
    normalized_name = (pet_name or "").strip().lower()
    for post in posts:
        if not post:
            continue
        post_pet_id = post.get("pet_id")
        if pet_id and post_pet_id and str(post_pet_id) == str(pet_id):
            return post
    if owner_id or normalized_name:
        for post in posts:
            if not post:
                continue
            if owner_id and post.get("user_id") == owner_id:
                content = (post.get("content") or "").lower()
                if not normalized_name or normalized_name in content:
                    return post
    for post in posts:
        if not post:
            continue
        content = (post.get("content") or "").lower()
        if normalized_name and normalized_name in content:
            return post
    return None


def get_latest_missing_alert_details(pet_id: str | None, pet_name: str | None, owner_id: str | None) -> dict | None:
    try:
        posts = _fastapi_get("/community/posts", params={"type": "missing", "limit": 12}) or []
    except Exception as exc:
        print(f"[DEBUG] Failed to load missing alert posts for pet {pet_id}: {exc}")
        return None
    post = _match_missing_alert_post(posts, pet_id, owner_id, pet_name)
    if not post:
        return None
    parsed = _parse_missing_alert_content(post.get("content") or "")
    details = {
        "post_id": str(post.get("id")) if post.get("id") is not None else None,
        "created_at": post.get("created_at"),
        "urgency": parsed.get("urgency"),
        "emergency_contact": parsed.get("emergency_contact"),
        "reward": parsed.get("reward"),
        "custom_message": parsed.get("custom_message"),
        "special_notes": parsed.get("special_notes"),
        "post_address": post.get("address"),
        "latitude": post.get("latitude"),
        "longitude": post.get("longitude"),
    }
    return {k: v for k, v in details.items() if v is not None}


def _render_missing_alert_card(details: dict | None) -> str:
    if not details:
        return ""
    rows: list[str] = []
    def add_row(label: str, key: str):
        value = details.get(key)
        if value:
            rows.append(f"""<div class=\"missing-detail-row\"><span class=\"missing-label\">{label}</span><span class=\"missing-value\">{html.escape(str(value))}</span></div>""")
    add_row("Urgency", "urgency")
    add_row("Reward", "reward")
    add_row("Emergency Contact", "emergency_contact")
    add_row("Custom Message", "custom_message")
    add_row("Special Notes", "special_notes")
    add_row("Location", "post_address")
    content_html = "".join(rows) if rows else "<p class=\"missing-alert-empty\">Missing alert posted but no extra details were captured.</p>"
    def _format_ph_datetime(value: str) -> str | None:
        if not value:
            return None
        try:
            parsed = datetime.fromisoformat(value)
        except Exception:
            try:
                parsed = datetime.strptime(value, "%Y-%m-%dT%H:%M:%S.%fZ")
                parsed = parsed.replace(tzinfo=ZoneInfo("UTC"))
            except Exception:
                return None
        if parsed.tzinfo is None:
            parsed = parsed.replace(tzinfo=ZoneInfo("UTC"))
        manila = parsed.astimezone(ZoneInfo("Asia/Manila"))
        return manila.strftime("%b %d, %Y • %I:%M %p")

    meta_html = ""
    created_at = details.get("created_at")
    formatted_timestamp = _format_ph_datetime(str(created_at)) if created_at else None
    if formatted_timestamp:
        meta_html = f"<div class=\"missing-alert-meta\">Posted: {html.escape(formatted_timestamp)} (Asia/Manila)</div>"
    return f"""
        <div class=\"missing-alert-card\">
            <div class=\"missing-alert-heading\">Missing Alert Details</div>
            {content_html}
            {meta_html}
        </div>
    """


# ------------------- Flask API -------------------
 
@app.route("/analyze", methods=["POST"])
def analyze_endpoint():
    data = request.get_json()
    pet_id = data.get("pet_id")
    if not pet_id:
        return jsonify({"error": "pet_id required"}), 400

    print(f"\n[ANALYZE-START] ========== Analyzing pet {pet_id} ==========")
    
    # FETCH PET BREED FOR PERSONALIZATION
    pet_breed = fetch_pet_breed(pet_id)
    print(f"[ANALYZE] Pet {pet_id}: Breed = {pet_breed}")
    
    # CONTINUOUS MODEL TRAINING: Fetch all logs for this specific pet and train/retrain the model
    df = fetch_logs_df(pet_id)
    print(f"[ANALYZE] Pet {pet_id}: Fetched {len(df)} logs for continuous training")
    
    # Only train if we have sufficient data, and schedule asynchronously to avoid blocking
    if not df.empty and len(df) >= 5:
        schedule_pet_model_training(pet_id, df)
    else:
        print(f"[ANALYZE] Pet {pet_id}: ⚠ Insufficient data for training ({len(df)} logs, need ≥5)")

    # Core analysis (trend/recommendation/summaries) based on logs
    result = analyze_pet(pet_id)

    # ML illness_risk on latest log with BREED ADJUSTMENT
    illness_risk_ml = "low"
    breed_notice = None  # Will hold breed-aware explanation if applicable
    activity_level = "unknown"
    food_intake = "unknown"
    water_intake = "unknown"
    bathroom_habits = "unknown"
    symptoms_detected = []
    latest_log_date = None
    try:
        if not df.empty:
            latest = df.sort_values("log_date", ascending=False).iloc[0]
            activity_level = str(latest.get("activity_level", "") or "Unknown").lower()
            food_intake = str(latest.get("food_intake", "") or "Unknown").lower()
            water_intake = str(latest.get("water_intake", "") or "Unknown").lower()
            bathroom_habits = str(latest.get("bathroom_habits", "") or "Unknown").lower()
            latest_log_date = latest.get("log_date")
            
            # Count symptoms from latest log
            symptom_count = 0
            symptoms_detected = []
            try:
                import json
                symptoms_str = str(latest.get("symptoms", "[]") or "[]")
                symptoms = json.loads(symptoms_str) if isinstance(symptoms_str, str) else []
                filtered = [s for s in symptoms if str(s).lower().strip() not in ["none of the above", "", "none", "unknown"]]
                symptoms_detected = filtered  # Keep for health guidance
                symptom_count = len(filtered)
            except:
                symptom_count = 0
                symptoms_detected = []
            
            # Use ML prediction directly
            predicted_risk = predict_illness_risk(activity_level, food_intake, water_intake, bathroom_habits, symptom_count)
            print(f"[ANALYZE] Pet {pet_id}: ML prediction = {predicted_risk}")
            
            if predicted_risk and predicted_risk != "low":
                illness_risk_ml = predicted_risk
            else:
                illness_risk_ml = "low"
                print(f"[ANALYZE] Pet {pet_id}: ML prediction = low (no clear problems)")
    except Exception as e:
        print(f"[ANALYZE] Pet {pet_id}: ⚠ ML prediction error: {e}")
        import traceback
        traceback.print_exc()
        illness_risk_ml = "low"

    # Contextual risk from recent logs
    contextual_risk = compute_contextual_risk(df)
    print(f"[ANALYZE] Pet {pet_id}: Contextual risk = {contextual_risk}")

    # Blend: choose higher severity
    illness_risk_final = blend_illness_risk(illness_risk_ml, contextual_risk)
    
    print(f"[ANALYZE] Pet {pet_id}: Final blended risk = {illness_risk_final}")

    # model status and derived health status (based on blended risk)
    illness_model_trained = is_illness_model_trained()
    is_unhealthy = isinstance(illness_risk_final, str) and illness_risk_final.lower() in ("high", "medium")
    health_status = "unhealthy" if is_unhealthy else "healthy"
    print(f"[ANALYZE] Pet {pet_id}: Health status = {health_status}")
    
    # Update health status based on ML prediction
    final_is_unhealthy = is_unhealthy
    final_health_status = "unhealthy" if final_is_unhealthy else "healthy"

    # Merge into response
    merged = dict(result)
    merged["illness_risk_ml"] = illness_risk_ml
    merged["illness_risk_contextual"] = contextual_risk
    merged["illness_risk_blended"] = illness_risk_final
    merged["illness_risk"] = illness_risk_final  # backward compatibility
    merged["illness_model_trained"] = illness_model_trained
    merged["health_status"] = final_health_status
    merged["illness_prediction"] = illness_risk_final
    merged["is_unhealthy"] = final_is_unhealthy
    merged["illness_status_text"] = "Unhealthy" if final_is_unhealthy else "Healthy"
    merged["pet_id"] = pet_id  # Include pet_id in response for clarity
    merged["log_count"] = len(df)  # Include count of logs analyzed
    merged["breed"] = pet_breed  # Include breed for reference
    
    # Analyze historical patterns FIRST (before creating notice) to check persistence
    historical_context = analyze_illness_duration_and_patterns(df)
    is_persistent_illness = historical_context.get("is_persistent", False)
    persistence_days = historical_context.get("illness_duration_days", 0)
    
    # Add illness risk notice for user display - INCLUDING persistence information
    if illness_risk_final == "high":
        merged["illness_risk_notice"] = {
            "status": "high_risk",
            "icon": "[ERROR]",
            "message": "Illness risk is HIGH",
            "is_persistent": is_persistent_illness,
            "persistence_days": persistence_days
        }
    elif illness_risk_final == "medium":
        merged["illness_risk_notice"] = {
            "status": "medium_risk",
            "icon": "[ALERT]",
            "message": "Illness risk is MEDIUM",
            "is_persistent": is_persistent_illness,
            "persistence_days": persistence_days
        }
    else:  # low
        merged["illness_risk_notice"] = {
            "status": "low_risk",
            "icon": "[OK]",
            "message": "Illness risk is LOW",
            "is_persistent": is_persistent_illness,
            "persistence_days": persistence_days
        }
    
    # Always analyze behavioral concerns from current log state
    behavioral_concerns = []
    feature_insights = []

    def _add_insight(feature_key, text):
        feature_insights.append({
            "feature": feature_key,
            "insight": text
        })
    
    # Activity level concerns
    activity_lower = activity_level.lower()
    if 'low activity' in activity_lower or 'lethargy' in activity_lower:
        behavioral_concerns.append({
            "description": 'Activity decreased significantly',
            "feature": 'activity_level',
            "value": activity_level,
            "reference": 'lethargy',
            "source": 'behavior',
            "urgency": 'high'
        })
        _add_insight('activity_level', 'Activity level is low; encourage short, gentle play sessions and extra rest to avoid exhaustion.')
    elif 'restlessness' in activity_lower or 'night' in activity_lower:
        behavioral_concerns.append({
            "description": 'Restlessness or disrupted sleep patterns',
            "feature": 'activity_level',
            "value": activity_level,
            "reference": 'restlessness_night',
            "source": 'behavior',
            "urgency": 'medium'
        })
        _add_insight('activity_level', 'Restless behaviors were noted; consider calming routines and an earlier bedtime.')
    elif 'weakness' in activity_lower or 'collapse' in activity_lower:
        behavioral_concerns.append({
            "description": 'Weakness or inability to move normally',
            "feature": 'activity_level',
            "value": activity_level,
            "reference": 'difficulty_moving',
            "source": 'behavior',
            "urgency": 'high'
        })
        _add_insight('activity_level', 'Weakness or collapse signals need for gentle handling and possible vet support.')
    elif 'high activity' in activity_lower:
        behavioral_concerns.append({
            "description": 'Unusual hyperactivity or excessive energy',
            "feature": 'activity_level',
            "value": activity_level,
            "reference": 'hyperactivity',
            "source": 'behavior',
            "urgency": 'medium'
        })
        _add_insight('activity_level', 'High activity levels could indicate anxiety or an injury; keep monitoring for persistent spikes.')
    else:
        _add_insight('activity_level', 'Activity level is within expected bounds; continue daily enrichment and checks.')
    
    # Food intake concerns
    food_lower = food_intake.lower()
    if 'not eating' in food_lower or 'loss of appetite' in food_lower:
        behavioral_concerns.append({
            "description": 'Loss of appetite or refusing to eat',
            "feature": 'food_intake',
            "value": food_intake,
            "reference": 'loss_appetite',
            "source": 'behavior',
            "urgency": 'medium'
        })
        _add_insight('food_intake', 'Food intake dropped or was refused; monitor appetite and hydration closely.')
    elif 'eating less' in food_lower:
        behavioral_concerns.append({
            "description": 'Reduced appetite',
            "feature": 'food_intake',
            "value": food_intake,
            "reference": 'loss_appetite',
            "source": 'behavior',
            "urgency": 'low'
        })
        _add_insight('food_intake', 'Appetite is reduced; try offering favorite foods in smaller servings to stimulate interest.')
    elif 'eating more' in food_lower:
        behavioral_concerns.append({
            "description": 'Increased appetite or excessive eating',
            "feature": 'food_intake',
            "value": food_intake,
            "reference": 'increased_hunger',
            "source": 'behavior',
            "urgency": 'low'
        })
        _add_insight('food_intake', 'Increased appetite noted; correlate with activity and stress for possible excitement behaviors.')
    elif 'weight loss' in food_lower:
        behavioral_concerns.append({
            "description": 'Unexplained weight loss',
            "feature": 'food_intake',
            "value": food_intake,
            "reference": 'weight_loss',
            "source": 'behavior',
            "urgency": 'medium'
        })
        _add_insight('food_intake', 'Weight loss detected; ensure portion sizes match caloric needs and report to your vet if it continues.')
    elif 'weight gain' in food_lower:
        behavioral_concerns.append({
            "description": 'Unexplained weight gain',
            "feature": 'food_intake',
            "value": food_intake,
            "reference": 'weight_gain',
            "source": 'behavior',
            "urgency": 'low'
        })
        _add_insight('food_intake', 'Weight gain or overeating may be linked to metabolic changes or treats; track portion control.')
    else:
        _add_insight('food_intake', 'Food intake appears regular; continue balanced meals and scheduled feedings.')
    
    # Water intake concerns
    water_lower = water_intake.lower()
    if 'not drinking' in water_lower:
        behavioral_concerns.append({
            "description": 'Not drinking water',
            "feature": 'water_intake',
            "value": water_intake,
            "reference": 'not_drinking',
            "source": 'behavior',
            "urgency": 'high'
        })
        _add_insight('water_intake', 'Water was avoided; offer fresh bowls and monitor for dehydration.')
    elif 'drinking less' in water_lower:
        behavioral_concerns.append({
            "description": 'Reduced water intake',
            "feature": 'water_intake',
            "value": water_intake,
            "reference": 'drinking_less',
            "source": 'behavior',
            "urgency": 'medium'
        })
        _add_insight('water_intake', 'Water intake is slightly lower; keep fresh water easily accessible.')
    elif 'excessive drinking' in water_lower or 'drinking more' in water_lower:
        behavioral_concerns.append({
            "description": 'Increased thirst/excessive drinking',
            "feature": 'water_intake',
            "value": water_intake,
            "reference": 'excessive_thirst',
            "source": 'behavior',
            "urgency": 'medium'
        })
        _add_insight('water_intake', 'Excessive thirst could signal metabolic changes; note frequency and share with your vet.')
    else:
        _add_insight('water_intake', 'Water intake is steady; good hydration supports recovery and energy.')
    
    # Bathroom habits concerns
    bathroom_lower = bathroom_habits.lower()
    if 'diarrhea' in bathroom_lower:
        behavioral_concerns.append({
            "description": 'Diarrhea or loose stools',
            "feature": 'bathroom_habits',
            "value": bathroom_habits,
            "reference": 'diarrhea',
            "source": 'behavior',
            "urgency": 'high'
        })
        _add_insight('bathroom_habits', 'Diarrhea detected; track frequency and look for signs of discomfort or mucus/blood.')
    elif 'constipation' in bathroom_lower:
        behavioral_concerns.append({
            "description": 'Constipation',
            "feature": 'bathroom_habits',
            "value": bathroom_habits,
            "reference": 'constipation',
            "source": 'behavior',
            "urgency": 'medium'
        })
        _add_insight('bathroom_habits', 'Constipation noted; ensure fiber and hydration; gentle tummy massages can help.')
    elif 'frequent urination' in bathroom_lower:
        behavioral_concerns.append({
            "description": 'Frequent urination',
            "feature": 'bathroom_habits',
            "value": bathroom_habits,
            "reference": 'excessive_urination',
            "source": 'behavior',
            "urgency": 'medium'
        })
        _add_insight('bathroom_habits', 'Frequent urination could hint at infections or diabetes; capture volume and color for vet review.')
    elif 'straining' in bathroom_lower:
        behavioral_concerns.append({
            "description": 'Straining to urinate or defecate',
            "feature": 'bathroom_habits',
            "value": bathroom_habits,
            "reference": 'straining_urinate',
            "source": 'behavior',
            "urgency": 'high'
        })
        _add_insight('bathroom_habits', 'Straining is a red flag; this requires immediate vet attention if it persists.')
    elif 'blood' in bathroom_lower:
        behavioral_concerns.append({
            "description": 'Blood in urine or stool',
            "feature": 'bathroom_habits',
            "value": bathroom_habits,
            "reference": 'blood_urine',
            "source": 'behavior',
            "urgency": 'high'
        })
        _add_insight('bathroom_habits', 'Blood in urine/stool is critical; seek veterinary care urgently.')
    elif 'accidents' in bathroom_lower or 'soiling' in bathroom_lower:
        behavioral_concerns.append({
            "description": 'Inappropriate toileting or house soiling',
            "feature": 'bathroom_habits',
            "value": bathroom_habits,
            "reference": 'house_soiling',
            "source": 'behavior',
            "urgency": 'medium'
        })
        _add_insight('bathroom_habits', 'House soiling may indicate stress or urinary issues; note context and timing for your vet.')
    else:
        _add_insight('bathroom_habits', 'Bathroom habits are within expected patterns.')
    
    if symptoms_detected:
        symptom_list = ', '.join(str(s).title() for s in symptoms_detected)
        _add_insight('symptoms', f'Clinical signs reported: {symptom_list}.')
    else:
        _add_insight('symptoms', 'No clinical signs were reported in the latest log.')

    recent_health_issues, window_days = _collect_recent_health_concerns(df, days=7)
    health_issues = _merge_health_issue_lists(behavioral_concerns, recent_health_issues)
    if symptoms_detected:
        symptom_entries = []
        for symptom in symptoms_detected:
            description = str(symptom).strip()
            if not description:
                continue
            symptom_entries.append({
                "description": description,
                "feature": "symptom",
                "value": description,
                "reference": _infer_health_reference_key(description),
                "urgency": "medium",
                "source": "symptom",
            })
        health_issues = _merge_health_issue_lists(health_issues, symptom_entries)

    if health_issues:
        health_guidance = generate_health_guidance(health_issues, df, historical_context, analysis_window_days=window_days or 7)
        merged["health_guidance"] = health_guidance
        print(f"[ANALYZE-RESPONSE] Pet {pet_id}: Health guidance generated for {len(health_issues)} health issue(s) ({len(behavioral_concerns)} behavioral + {len(symptoms_detected) if symptoms_detected else 0} clinical)")
    
    if final_is_unhealthy and historical_context.get('is_persistent'):
        print(f"[ANALYZE-RESPONSE] Pet {pet_id}: [ERROR] PERSISTENT ILLNESS: {historical_context.get('illness_duration_days')} days of unhealthy patterns detected")
    if feature_insights:
        merged["feature_insights"] = feature_insights
    
    # Add data sufficiency notice for user
    # Also check data freshness - warn if latest log is too old
    data_freshness_warning = None
    if not df.empty:
        latest_log_date = pd.to_datetime(df['log_date']).max()
        days_since_log = (datetime.now() - latest_log_date).days
        if days_since_log > 7:
            data_freshness_warning = f"Latest log is {days_since_log} days old. Recent data helps improve accuracy."
    
    if len(df) < 5:
        merged["data_notice"] = {
            "status": "insufficient_data",
            "message": f"Only {len(df)} logs available. Log at least {5 - len(df)} more health entries for more accurate analysis.",
            "details": "The system learns patterns from historical data. With more logs, it can better detect trends, baseline behaviors, and unusual changes. Current analysis is based on limited data.",
            "recommendation": "Continue logging daily to improve accuracy of health predictions.",
            "logs_needed": 5 - len(df),
            "freshness_warning": data_freshness_warning
        }
    else:
        notice_msg = f"Analysis based on {len(df)} logs. Pattern detection is active."
        if data_freshness_warning:
            notice_msg += f" {data_freshness_warning}"
        merged["data_notice"] = {
            "status": "sufficient_data",
            "message": notice_msg,
            "details": "The system has enough data to detect meaningful patterns and changes from baseline behavior."
        }
    
    # If model is not trained, add notice about rule-based analysis
    if not illness_model_trained:
        merged["model_notice"] = {
            "status": "no_model_trained",
            "message": "Using rule-based analysis (not machine learning)",
            "details": "Once you have 5+ logs, the system will train a machine learning model for more nuanced predictions.",
            "when_available": "After logging at least 5 health entries"
        }
    else:
        merged["model_notice"] = {
            "status": "model_trained",
            "message": "Using trained machine learning model + pattern analysis"
        }
    
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

    # Add user messaging about analysis method
    try:
        df = fetch_logs_df(pet_id)
        num_logs = len(df) if df is not None and len(df) > 0 else 0
        
        model_notice = {}
        if not illness_model_trained:
            model_notice = {
                "status": "no_model_trained",
                "message": "Using rule-based analysis (not ML)",
                "details": "ML model trains after 5+ logs.",
                "when_available": "After 5+ health entries"
            }
        else:
            model_notice = {
                "status": "model_trained",
                "message": "Using ML model for predictions",
                "details": f"Based on {num_logs} historical logs.",
                "confidence": "high" if num_logs >= 20 else "medium"
            }
    except:
        model_notice = {"status": "error", "message": "Could not determine analysis method"}

    return jsonify({
        "illness_risk": illness_risk,
        "illness_model_trained": illness_model_trained,
        "health_status": health_status,
        # aliases for UI
        "illness_prediction": illness_risk,
        "is_unhealthy": is_unhealthy,
        "illness_status_text": "Unhealthy" if is_unhealthy else "Healthy",
        "care_recommendations": tips,
        "model_notice": model_notice
    })

# ------------------- Public pet info page -------------------
@app.route("/pet/<pet_id>", methods=["GET"])
def public_pet_page(pet_id):
    try:
        pet = fetch_pet_record(pet_id)
        if not pet:
            return make_response("<h3>Pet not found</h3>", 404)
        owner_id = pet.get("owner_id")
        owner = fetch_user_profile(owner_id) if owner_id else None
        owner_name = owner.get("name") if owner else None
        owner_email = owner.get("email") if owner else None
        owner_role = owner.get("role") if owner else None
        owner_profile_picture = owner.get("profile_picture") if owner else ""

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
        
        # Calculate age from date_of_birth if available
        pet_age = ""
        pet_age_field = pet.get("date_of_birth")
        if pet_age_field:
            try:
                # Handle timezone-aware datetime strings (e.g., '2021-09-30 00:00:00+00')
                birth_date = pd.to_datetime(pet_age_field)
                # Convert to naive UTC date for comparison
                if hasattr(birth_date, 'tz_localize') and birth_date.tzinfo is not None:
                    birth_date = birth_date.tz_convert('UTC').tz_localize(None)
                
                today = pd.to_datetime(datetime.utcnow().date())
                age_delta = (today - birth_date).days
                
                if age_delta < 0:
                    # Birth date is in the future (invalid data)
                    print(f"DEBUG: Birth date is in the future: {pet_age_field}")
                    pet_age = "Unknown"
                else:
                    years = age_delta // 365
                    months = (age_delta % 365) // 30
                    
                    # Display age in a simple, readable format
                    if years >= 1:
                        pet_age = f"{years} year{'s' if years > 1 else ''} old"
                    elif months >= 1:
                        pet_age = f"{months} month{'s' if months > 1 else ''} old"
                    else:
                        pet_age = f"{age_delta} day{'s' if age_delta > 1 else ''} old"
                    
                    print(f"DEBUG: Calculated age from date_of_birth '{pet_age_field}': {pet_age} (delta: {age_delta} days, years: {years}, months: {months})")
            except Exception as e:
                print(f"DEBUG: Failed to parse date_of_birth '{pet_age_field}': {e}")
                import traceback
                traceback.print_exc()
                pet_age = "Unknown"
        
        pet_weight = pet.get("weight") or ""
        pet_gender = pet.get("gender") or "Unknown"
        pet_health = pet.get("health") or "Unknown"
        pet_profile_picture = pet.get("profile_picture") or ""
        
        # Get current illness risk from fresh analysis (predictions table deprecated)
        # Fetch fresh analysis from /analyze endpoint to get latest prediction
        latest_prediction_text = ""
        latest_suggestions = ""
        latest_risk = "low"
        illness_model_trained = False
        
        try:
            # Call /analyze endpoint internally to get current analysis
            analysis_resp = requests.post(BACKEND_ANALYZE_URL, json={"pet_id": pet_id}, timeout=10)
            if analysis_resp.status_code == 200:
                analysis_data = analysis_resp.json()
                latest_risk = analysis_data.get("illness_risk_blended") or analysis_data.get("illness_risk") or "low"
                latest_prediction_text = analysis_data.get("trend") or ""
                latest_suggestions = analysis_data.get("recommendation") or ""
                illness_model_trained = analysis_data.get("illness_model_trained", False)
                print(f"DEBUG: Got fresh analysis - risk: {latest_risk}, trend: {latest_prediction_text[:50]}")
            else:
                print(f"DEBUG: /analyze returned status {analysis_resp.status_code}")
        except Exception as e:
            print(f"DEBUG: Failed to fetch fresh analysis: {e}")
            latest_risk = "low"

        # determine a simple color for risk badge
        lr = str(latest_risk).lower()
        if "high" in lr:
            risk_color = "#B82132"  # deep red
        elif "medium" in lr:
            risk_color = "#FF8C00"  # orange
        elif "low" in lr:
            risk_color = "#2ECC71"  # green
        else:
            risk_color = "#666666"

        health_flag = str(pet_health or "").strip().lower()
        if health_flag == "bad":
            status_text = "Unhealthy"
        elif health_flag == "good":
            status_text = "Healthy"
        else:
            status_text = "Healthy"
            try:
                lr = str(latest_risk).lower()
                if ("high" in lr) or ("medium" in lr):
                    status_text = "Unhealthy"
            except Exception:
                status_text = "Healthy"

        # Build care tips for display using recent logs + current risk from analysis
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

        def _is_pet_missing(value):
            if value is None:
                return False
            if isinstance(value, bool):
                return value
            string_val = str(value).strip().lower()
            return string_val not in ("", "0", "false", "none", "null")

        pet_missing = _is_pet_missing(pet.get("is_missing"))
        missing_alert_details = get_latest_missing_alert_details(pet.get("id"), pet_name, owner_id) if pet_missing else None
        missing_alert_card_html = _render_missing_alert_card(missing_alert_details)

        # The 7-day future predictions feature has been removed.
        # Keep an empty placeholder so API responses maintain a stable shape.
        future_predictions = []
        future_html = ""

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
                                body {{ font-family: 'Inter', Arial, sans-serif; background:#f6f6f6; padding:16px; min-height:100vh; color:#1c1c1c; }}
                                .card {{ max-width: 540px; margin:12px auto; background:#fff; border-radius:16px; padding:24px; box-shadow:0 16px 32px rgba(0,0,0,0.08); display:flex; flex-direction:column; gap:24px; }}
                                .card h2 {{ font-size:22px; letter-spacing:0.02em; color:#B82132; margin-bottom:4px; }}
                                .card h3 {{ font-size:16px; color:#666; margin:0; text-transform:uppercase; letter-spacing:0.08em; }}
                                .profile-container {{ display:flex; gap:16px; align-items:flex-start; }}
                                .profile-img {{ width:130px; height:130px; border-radius:18px; object-fit:cover; border:3px solid #ffecec; box-shadow:0 10px 24px rgba(184, 33, 50, 0.18); }}
                                .profile-placeholder {{ width:130px; height:130px; border-radius:18px; background:#e9e9e9; border:3px dashed #d0d0d0; display:flex; align-items:center; justify-content:center; color:#999; font-size:18px; }}
                                .info-grid {{ flex:1; display:grid; grid-template-columns:repeat(auto-fit, minmax(180px, 1fr)); gap:12px; }}
                                .info-item {{ background:#fff7f6; border-radius:12px; padding:12px 14px; border:1px solid #ffe7e2; }}
                                .info-item p {{ margin:0; }}
                                .info-item .label {{ color:#777; font-size:12px; text-transform:uppercase; letter-spacing:0.1em; }}
                                .info-item .value {{ font-size:16px; font-weight:600; color:#1c1c1c; margin-top:4px; }}
                                .badge {{ display:inline-flex; align-items:center; gap:6px; padding:6px 12px; border-radius:999px; font-size:13px; font-weight:600; color:#fff; background:linear-gradient(120deg, #B82132, #D2665A); }}
                                .owner-info {{ display:flex; align-items:center; gap:12px; padding:14px 0 0; border-top:1px solid #f0f0f0; }}
                                .owner-contact {{ margin-left:auto; text-align:right; display:flex; flex-direction:column; gap:4px; }}
                                .owner-contact .value {{ color:#1c1c1c; text-decoration:none; font-weight:600; }}
                                .owner-info img {{ width:60px; height:60px; border-radius:50%; object-fit:cover; border:2px solid #e5e5e5; }}
                                .owner-info .initials {{ width:60px; height:60px; border-radius:50%; background:#e0e0e0; display:flex; align-items:center; justify-content:center; font-size:24px; color:#999; }}
                                .owner-info .label {{ font-size:12px; color:#666; margin-bottom:2px; }}
                                .owner-info .value {{ font-size:16px; font-weight:600; color:#1c1c1c; }}
                                .missing-alert-card {{
                                    margin-top: 16px;
                                    padding: 14px 16px 12px;
                                    border-radius: 14px;
                                    border: 1px solid #ffe7e2;
                                    background: #fff5f2;
                                    box-shadow: 0 12px 28px rgba(184, 33, 50, 0.15);
                                }}
                                .missing-alert-heading {{
                                    font-size: 15px;
                                    font-weight: 600;
                                    color: #b82132;
                                    margin-bottom: 8px;
                                    letter-spacing: 0.05em;
                                }}
                                .missing-detail-row {{
                                    display: flex;
                                    justify-content: space-between;
                                    align-items: flex-start;
                                    gap: 12px;
                                    margin-bottom: 6px;
                                }}
                                .missing-label {{
                                    font-size: 11px;
                                    text-transform: uppercase;
                                    letter-spacing: 0.08em;
                                    color: #777;
                                }}
                                .missing-value {{
                                    font-size: 14px;
                                    font-weight: 600;
                                    color: #1c1c1c;
                                    text-align: right;
                                }}
                                .missing-alert-meta {{
                                    margin-top: 10px;
                                    font-size: 12px;
                                    color: #444;
                                    letter-spacing: 0.02em;
                                }}
                                .missing-alert-empty {{
                                    font-size: 13px;
                                    color: #666;
                                    margin-bottom: 0;
                                }}
                                .status-row {{ display:flex; align-items:center; justify-content:space-between; flex-wrap:wrap; gap:8px; }}
                                .status-chip {{ font-size:13px; font-weight:600; padding:6px 16px; border-radius:999px; border:1px solid rgba(184,33,50,0.3); background:rgba(255,230,226,0.7); color:#B82132; }}
                                @media (max-width: 600px) {{
                                    .card {{ padding:20px; }}
                                    .profile-container {{ flex-direction:column; align-items:center; }}
                                    .info-grid {{ grid-template-columns:repeat(auto-fit, minmax(140px, 1fr)); }}
                                }}
                            </style>
                        </head>
                        <body>
                            <div class="card">
                                <div class="status-row">
                                    <div>
                                        <h2>Pet Quick Info</h2>
                                        <h3>If seen, please contact the owner immediately.</h3>
                                    </div>
                                    <span class="status-chip">{status_text}</span>
                                </div>
                                <div class="profile-container">
                                    {f'<img src="{pet_profile_picture}" alt="{pet_name}" class="profile-img">' if pet_profile_picture else '<div class="profile-placeholder">No photo</div>'}
                                    <div class="info-grid">
                                        <div class="info-item">
                                            <p class="label">Name</p>
                                            <p class="value">{pet_name}</p>
                                        </div>
                                        <div class="info-item">
                                            <p class="label">Breed</p>
                                            <p class="value">{pet_breed}</p>
                                        </div>
                                        <div class="info-item">
                                            <p class="label">Age</p>
                                            <p class="value">{pet_age if pet_age else 'Unknown'}</p>
                                        </div>
                                        <div class="info-item">
                                            <p class="label">Weight</p>
                                            <p class="value">{pet_weight if pet_weight else 'Not specified'}</p>
                                        </div>
                                        <div class="info-item">
                                            <p class="label">Gender</p>
                                            <p class="value">{pet_gender}</p>
                                        </div>
                                    </div>
                                </div>
                                <div class="owner-info">
                                    {f'<img src="{owner_profile_picture}" alt="{owner_name}" class="owner-avatar">' if owner_profile_picture else '<div class="initials">👤</div>'}
                                    <div>
                                        <p class="label">Owner</p>
                                        <p class="value">{owner_name}</p>
                                    </div>
                                </div>
                                {missing_alert_card_html}
                            </div>
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
            "missing_alert": missing_alert_details,
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
    try:
        pets = _fastapi_get("/pets") or []
    except Exception as exc:
        print(f"[ANALYZE] Failed to load pets for daily job: {exc}")
        pets = []
    for pet in pets:
        pet_id = pet.get("id")
        if not pet_id:
            continue
        df = fetch_logs_df(pet_id)
        if not df.empty:
            train_illness_model(df)  # retrain and persist illness model
        result = analyze_pet(pet_id)
        print(f"[INFO] Pet {pet['id']} analysis stored:", result)


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


# Removed: store_prediction() - predictions table deprecated

def analyze_illness_duration_and_patterns(df):
    """
    Analyze illness duration, persistence, and historical patterns.
    
    Returns dict with:
    - illness_duration_days: How long unhealthy pattern has persisted
    - is_persistent: Whether illness lasted >7 days
    - pattern_type: 'acute', 'chronic', 'cyclical', 'improving', 'worsening'
    - sudden_changes: List of sudden health changes detected
    - recovery_history: Whether pet has recovered before from similar patterns
    """
    if df is None or df.empty:
        return {"illness_duration_days": 0, "is_persistent": False, "pattern_type": None}
    
    try:
        df_copy = df.copy()
        df_copy['log_date'] = pd.to_datetime(df_copy['log_date'])
        df_copy = df_copy.sort_values('log_date')
        
        # Helper to detect unhealthy indicators in a row
        def is_unhealthy_log(row):
            activity = str(row.get('activity_level', '')).lower()
            food = str(row.get('food_intake', '')).lower()
            water = str(row.get('water_intake', '')).lower()
            bathroom = str(row.get('bathroom_habits', '')).lower()
            
            unhealthy_indicators = (
                'low' in activity or 'very low' in activity or
                'not eating' in food or 'eating less' in food or
                'not drinking' in water or 'drinking less' in water or
                'diarrhea' in bathroom or 'constipation' in bathroom or
                'blood' in bathroom or 'straining' in bathroom
            )
            return unhealthy_indicators
        
        df_copy['is_unhealthy'] = df_copy.apply(is_unhealthy_log, axis=1)
        
        # Find consecutive unhealthy period by log order (for pattern analysis)
        unhealthy_streak = 0
        max_streak = 0
        unhealthy_start_idx = None
        max_streak_start_idx = None
        
        for idx, is_unhealthy in enumerate(df_copy['is_unhealthy']):
            if is_unhealthy:
                if unhealthy_streak == 0:
                    unhealthy_start_idx = idx
                unhealthy_streak += 1
                if unhealthy_streak > max_streak:
                    max_streak = unhealthy_streak
                    max_streak_start_idx = unhealthy_start_idx
            else:
                unhealthy_streak = 0

        # Calculate illness duration focusing on consecutive days, filling gaps without logs as healthy days
        daily_health = (
            df_copy[['log_date', 'is_unhealthy']]
            .assign(log_day=lambda d: d['log_date'].dt.normalize())
            .groupby('log_day', as_index=False)['is_unhealthy']
            .any()
            .sort_values('log_day')
        )

        if not daily_health.empty:
            full_range = pd.date_range(
                start=daily_health['log_day'].min(),
                end=daily_health['log_day'].max(),
                freq='D'
            )
            daily_health = (
                daily_health.set_index('log_day')
                .reindex(full_range, fill_value=False)
                .rename_axis('log_day')
                .reset_index()
            )

        day_streak = 0
        longest_day_streak = 0
        streak_start_date = None
        longest_streak_start = None

        for _, row in daily_health.iterrows():
            current_day = row['log_day']
            if row['is_unhealthy']:
                if day_streak == 0:
                    streak_start_date = current_day
                day_streak += 1
                if day_streak > longest_day_streak:
                    longest_day_streak = day_streak
                    longest_streak_start = streak_start_date
            else:
                day_streak = 0
                streak_start_date = None

        # Current streak must end with the latest unhealthy log to be considered persistent
        current_streak_days = 0
        current_streak_start = None
        current_streak_end = None
        for _, row in daily_health.sort_values('log_day', ascending=False).iterrows():
            if row['is_unhealthy']:
                current_streak_days += 1
                if current_streak_end is None:
                    current_streak_end = row['log_day']
                current_streak_start = row['log_day']
            else:
                break

        illness_duration_days = current_streak_days

        is_persistent = illness_duration_days > 7
        
        # Determine pattern type
        pattern_type = None
        pattern_basis = longest_day_streak or illness_duration_days
        if pattern_basis <= 3:
            pattern_type = 'acute'
        elif pattern_basis > 7:
            pattern_type = 'chronic'
        
        # Check for cyclical pattern (unhealthy, recovery, unhealthy again)
        unhealthy_periods = []
        current_start = None
        for idx, is_unhealthy in enumerate(df_copy['is_unhealthy']):
            if is_unhealthy and current_start is None:
                current_start = idx
            elif not is_unhealthy and current_start is not None:
                unhealthy_periods.append((current_start, idx))
                current_start = None
        if current_start is not None:
            unhealthy_periods.append((current_start, len(df_copy)))
        
        if len(unhealthy_periods) >= 2:
            pattern_type = 'cyclical'
        
        # Check trend (improving vs worsening)
        if max_streak_start_idx is not None and max_streak_start_idx + max_streak < len(df_copy):
            # Check if improvement after illness streak
            post_streak = df_copy.iloc[max_streak_start_idx + max_streak:]
            if len(post_streak) >= 2 and not post_streak['is_unhealthy'].any():
                pattern_type = 'improving'
        
        # Check for worsening (escalating symptoms)
        if max_streak_start_idx is not None:
            streak_data = df_copy.iloc[max_streak_start_idx:max_streak_start_idx + max_streak]
            symptom_counts = []
            for _, row in streak_data.iterrows():
                try:
                    symptoms_str = str(row.get('symptoms', '[]'))
                    symptoms = json.loads(symptoms_str) if isinstance(symptoms_str, str) else []
                    filtered = [s for s in symptoms if str(s).lower().strip() not in ["none of the above", "", "none", "unknown"]]
                    symptom_counts.append(len(filtered))
                except:
                    symptom_counts.append(0)
            if len(symptom_counts) >= 2 and symptom_counts[-1] > symptom_counts[0]:
                pattern_type = 'worsening'
        
        # Detect sudden changes (healthy to unhealthy or major symptom jump)
        sudden_changes = []
        for i in range(1, len(df_copy)):
            prev_unhealthy = df_copy.iloc[i-1]['is_unhealthy']
            curr_unhealthy = df_copy.iloc[i]['is_unhealthy']
            if not prev_unhealthy and curr_unhealthy:
                sudden_changes.append({
                    "date": str(df_copy.iloc[i]['log_date']),
                    "change": "healthy_to_unhealthy"
                })
        
        # Check recovery history (has pet recovered before from similar patterns?)
        recovery_history = len(unhealthy_periods) > 1
        
        return {
            "illness_duration_days": illness_duration_days,
            "is_persistent": is_persistent,
            "pattern_type": pattern_type,
            "unhealthy_periods": len(unhealthy_periods),
            "sudden_changes": sudden_changes,
            "recovery_history": recovery_history,
            "total_logs_analyzed": len(df_copy),
            "current_streak_start": str(current_streak_start.date()) if current_streak_start is not None else None,
            "current_streak_end": str(current_streak_end.date()) if current_streak_end is not None else None,
            "current_streak_days": current_streak_days,
            "longest_unhealthy_streak_days": longest_day_streak,
            "longest_streak_start": str(longest_streak_start.date()) if longest_streak_start is not None else None
        }
    except Exception as e:
        print(f"[PATTERN-ANALYSIS] Error analyzing patterns: {e}")
        return {"illness_duration_days": 0, "is_persistent": False, "pattern_type": None}

def _infer_health_reference_key(description: str | None) -> str | None:
    if not description:
        return None
    normalized = str(description).lower()
    for key in HEALTH_SYMPTOMS_REFERENCE:
        key_norm = key.replace('_', ' ').lower()
        if key_norm and key_norm in normalized:
            return key
        key_parts = [part for part in key_norm.split() if part]
        if key_parts and all(part in normalized for part in key_parts):
            return key
    for key, synonyms in HEALTH_REFERENCE_SYNONYMS.items():
        for synonym in synonyms:
            if synonym in normalized:
                return key
    return None

def _extract_health_concerns_from_row(row, *, source: str, log_date) -> list[dict]:
    issues = []
    def _make_issue(description, feature, reference, urgency, value):
        issue = {
            "description": description,
            "feature": feature,
            "value": value,
            "reference": reference,
            "urgency": urgency,
            "source": source
        }
        return issue

    activity_lower = str(row.get('activity_level', '')).lower()
    food_lower = str(row.get('food_intake', '')).lower()
    water_lower = str(row.get('water_intake', '')).lower()
    bathroom_lower = str(row.get('bathroom_habits', '')).lower()

    if 'low activity' in activity_lower or 'lethargy' in activity_lower or activity_lower == 'low':
        issues.append(_make_issue('Activity decreased significantly', 'activity_level', 'lethargy', 'high', row.get('activity_level')))
    elif 'restlessness' in activity_lower or 'night' in activity_lower:
        issues.append(_make_issue('Restlessness or disrupted sleep patterns', 'activity_level', 'restlessness_night', 'medium', row.get('activity_level')))
    elif 'weakness' in activity_lower or 'collapse' in activity_lower:
        issues.append(_make_issue('Weakness or inability to move normally', 'activity_level', 'difficulty_moving', 'high', row.get('activity_level')))
    elif 'high activity' in activity_lower or 'hyperactivity' in activity_lower:
        issues.append(_make_issue('Unusual hyperactivity or excessive energy', 'activity_level', 'hyperactivity', 'medium', row.get('activity_level')))

    if 'not eating' in food_lower or 'loss of appetite' in food_lower:
        issues.append(_make_issue('Loss of appetite or refusing to eat', 'food_intake', 'loss_appetite', 'medium', row.get('food_intake')))
    elif 'eating less' in food_lower:
        issues.append(_make_issue('Reduced appetite', 'food_intake', 'loss_appetite', 'low', row.get('food_intake')))
    elif 'eating more' in food_lower or 'increased appetite' in food_lower:
        issues.append(_make_issue('Increased appetite or excessive eating', 'food_intake', 'increased_hunger', 'low', row.get('food_intake')))
    elif 'weight loss' in food_lower:
        issues.append(_make_issue('Unexplained weight loss', 'food_intake', 'weight_loss', 'medium', row.get('food_intake')))
    elif 'weight gain' in food_lower:
        issues.append(_make_issue('Unexplained weight gain', 'food_intake', 'weight_gain', 'low', row.get('food_intake')))

    if 'not drinking' in water_lower:
        issues.append(_make_issue('Not drinking water', 'water_intake', 'not_drinking', 'high', row.get('water_intake')))
    elif 'drinking less' in water_lower:
        issues.append(_make_issue('Reduced water intake', 'water_intake', 'drinking_less', 'medium', row.get('water_intake')))
    elif 'excessive drinking' in water_lower or 'drinking more' in water_lower:
        issues.append(_make_issue('Increased thirst/excessive drinking', 'water_intake', 'excessive_thirst', 'medium', row.get('water_intake')))

    if 'diarrhea' in bathroom_lower:
        issues.append(_make_issue('Diarrhea or loose stools', 'bathroom_habits', 'diarrhea', 'high', row.get('bathroom_habits')))
    elif 'constipation' in bathroom_lower:
        issues.append(_make_issue('Constipation', 'bathroom_habits', 'constipation', 'medium', row.get('bathroom_habits')))
    elif 'frequent urination' in bathroom_lower:
        issues.append(_make_issue('Frequent urination', 'bathroom_habits', 'excessive_urination', 'medium', row.get('bathroom_habits')))
    elif 'straining' in bathroom_lower:
        issues.append(_make_issue('Straining to urinate or defecate', 'bathroom_habits', 'straining_urinate', 'high', row.get('bathroom_habits')))
    elif 'blood' in bathroom_lower:
        issues.append(_make_issue('Blood in urine or stool', 'bathroom_habits', 'blood_urine', 'high', row.get('bathroom_habits')))
    elif 'accidents' in bathroom_lower or 'soiling' in bathroom_lower:
        issues.append(_make_issue('Inappropriate toileting or house soiling', 'bathroom_habits', 'house_soiling', 'medium', row.get('bathroom_habits')))

    # Include clinical symptoms from logs
    symptoms_raw = row.get('symptoms')
    try:
        if isinstance(symptoms_raw, str):
            symptoms = json.loads(symptoms_raw)
        else:
            symptoms = symptoms_raw or []
    except Exception:
        symptoms = []

    for symptom in symptoms:
        if not symptom:
            continue
        desc = str(symptom).strip()
        lower = desc.lower()
        if lower in ["none of the above", "none", "", "unknown"]:
            continue
        reference = _infer_health_reference_key(desc)
        issues.append({
            "description": desc,
            "feature": "symptom",
            "value": desc,
            "reference": reference,
            "urgency": "medium",
            "source": source,
        })

    return issues

def _collect_recent_health_concerns(df, days=7):
    if df is None or df.empty:
        return [], 0
    df_dates = pd.to_datetime(df['log_date'])
    latest = df_dates.max()
    if pd.isna(latest):
        return [], 0
    window_start = (latest - timedelta(days=days - 1)).date()
    recent = df[df['log_date'] >= window_start]
    if recent.empty:
        return [], 0
    earliest = pd.to_datetime(recent['log_date']).min()
    actual_window = max(1, (latest.date() - earliest.date()).days + 1)
    issues = []
    for _, row in recent.iterrows():
        issues.extend(_extract_health_concerns_from_row(row, source='7day', log_date=row.get('log_date')))
    unique = []
    seen = set()
    for issue in issues:
        key = (
            issue.get('reference'),
            issue.get('description'),
            issue.get('feature')
        )
        if key in seen:
            continue
        seen.add(key)
        unique.append(issue)
    return unique, min(actual_window, days)

def _merge_health_issue_lists(primary: list[dict], secondary: list[dict]) -> list[dict]:
    merged = []
    seen = set()
    for issue in (primary or []) + (secondary or []):
        if not isinstance(issue, dict):
            continue
        key = (
            issue.get('reference'),
            issue.get('description'),
            issue.get('feature')
        )
        if key in seen:
            continue
        seen.add(key)
        merged.append(issue)
    return merged

def generate_health_guidance(health_issues, df=None, historical_context=None, analysis_window_days: int | None = None):
    """
    Generate health guidance and recommendations based on detected health concerns.
    Uses HEALTH_SYMPTOMS_REFERENCE to provide evidence-based information.
    Includes historical context (duration, patterns, sudden changes).
    
    Args:
        health_issues: List of dicts describing the concerning features (behavioral or clinical)
        df: Optional DataFrame with all logs for historical analysis
        historical_context: Optional dict with pattern analysis results
        
    Returns:
        dict with guidance, urgency level, and recommended actions
    """
    if not health_issues:
        return {
            "guidance": "No specific health concerns detected. Continue regular monitoring.",
            "urgency": "none",
            "recommendations": ["Maintain regular vet checkups", "Continue logging pet behavior"]
        }
    
    # Analyze patterns if not provided
    if historical_context is None and df is not None:
        historical_context = analyze_illness_duration_and_patterns(df)
    
    guidance_items = []
    max_urgency = "none"
    urgency_levels = {"none": 0, "low": 1, "medium": 2, "high": 3, "critical": 4}

    for issue in health_issues:
        if isinstance(issue, dict):
            description = str(issue.get("description") or "").strip()
            reference = issue.get("reference")
            issue_value = issue.get("value")
        else:
            description = str(issue).strip()
            reference = None
            issue_value = None
        if not description:
            continue

        display_description = description
        if issue_value:
            value_str = str(issue_value).strip()
            if value_str and value_str.lower() not in description.lower():
                display_description = f"{description} (current: {value_str})"

        if not reference:
            reference = _infer_health_reference_key(description)

        if reference and reference in HEALTH_SYMPTOMS_REFERENCE:
            info = HEALTH_SYMPTOMS_REFERENCE[reference].copy()
        else:
            info = {
                "description": description,
                "possible_causes": [],
                "urgency": (issue.get("urgency") if isinstance(issue, dict) else "medium") or "medium",
                "action": issue.get("action") if isinstance(issue, dict) else None
            }

        info["issue_description"] = display_description
        info["issue_reference"] = reference
        info["feature"] = issue.get("feature") if isinstance(issue, dict) else None
        info["source"] = issue.get("source") if isinstance(issue, dict) else "unspecified"
        info["description"] = info.get("description") or display_description

        issue_urgency = info.get("urgency", "none")
        if urgency_levels.get(issue_urgency, 0) > urgency_levels.get(max_urgency, 0):
            max_urgency = issue_urgency
        guidance_items.append(info)
    
    # Build recommendations
    recommendations = []
    
    # Enhance urgency if illness is persistent (>7 days)
    if historical_context and historical_context.get('is_persistent'):
        duration = historical_context.get('illness_duration_days', 0)
        if max_urgency in ['low', 'medium']:
            max_urgency = 'high'  # Upgrade persistent illness
        recommendations.append(f"[ALERT] PERSISTENT ILLNESS: Clinical signs lasting {duration} day{'s' if duration != 1 else ''} requires veterinary evaluation")
    
    if max_urgency == "critical":
        recommendations.append("EMERGENCY: Seek immediate veterinary care")
    elif max_urgency == "high":
        recommendations.append("Contact your veterinarian same day")
    elif max_urgency == "medium":
        recommendations.append("Schedule a vet appointment within 24-48 hours")
    elif max_urgency == "low":
        recommendations.append("Schedule a routine vet visit")
    
    # Add specific recommendations
    for item in guidance_items:
        if item.get("action"):
            recommendations.append(item["action"])
    
    # Add contextual insights from historical patterns
    context_insights = []
    if historical_context:
        pattern_type = historical_context.get('pattern_type')
        if pattern_type == 'cyclical':
            context_insights.append(f"Pattern: Your pet shows cyclical health patterns with {historical_context.get('unhealthy_periods')} episodes")
        elif pattern_type == 'worsening':
            context_insights.append("Pattern: Symptoms are escalating - immediate vet attention recommended")
        elif pattern_type == 'improving':
            context_insights.append("Pattern: Symptoms are improving - continue monitoring")
        
        if historical_context.get('sudden_changes'):
            context_insights.append(f"Alert: Sudden health change detected on {historical_context.get('sudden_changes')[0].get('date')}")
        
        if historical_context.get('recovery_history'):
            context_insights.append("History: Your pet has recovered from similar episodes before")
    
    detected_texts = [item.get("issue_description") or item.get("description") for item in guidance_items]
    return {
        "guidance": f"Detected {len(guidance_items)} health concern(s). {HEALTH_SYMPTOMS_REFERENCE.get('summary', 'See details below.')}",
        "urgency": max_urgency,
        "detected_symptoms": detected_texts,
        "detected_health_issues": detected_texts,
        "recommendations": recommendations[:7],  # Up to 7 recommendations
        "pattern_context": context_insights,
        "illness_duration_days": historical_context.get('illness_duration_days') if historical_context else None,
        "is_persistent_illness": historical_context.get('is_persistent') if historical_context else False,
        "analysis_window_days": analysis_window_days,
        "details": guidance_items
    }

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
    # Updated to use substring matching for new category values
    serious_flag = (
        "not eating" in food_in or
        "not drinking" in water_in or
        "diarrhea" in bathroom_in or
        "constipation" in bathroom_in or
        "frequent urin" in bathroom_in or
        "straining" in bathroom_in or
        "blood" in bathroom_in or
        "house soiling" in bathroom_in or
        symptom_in >= 2 or
        "low" in activity_in
    )
    
    minor_flag = (
        "eating less" in food_in or
        "drinking less" in water_in
    )
    
    rule_flag = serious_flag or (minor_flag and "low" in activity_in)  # Only flag "eating less" if also low activity
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
    
    print(f"[ML-PREDICT] Available maps: act_map={bool(act_map and len(act_map))}, food_map={bool(food_map and len(food_map))}, water_map={bool(water_map and len(water_map))}, bathroom_map={bool(bathroom_map and len(bathroom_map))}")

    try:
        if act_map and activity_in in act_map:
            act_enc = int(act_map[activity_in])
        elif le_activity and activity_in in getattr(le_activity, 'classes_', []):
            act_enc = int(np.where(getattr(le_activity, 'classes_', []) == activity_in)[0][0])
        else:
            # Fallback: match on keyword if exact value not found
            ac = None
            if "low" in activity_in:
                ac = "low"
            elif "high" in activity_in:
                ac = "high"
            elif "medium" in activity_in or "normal" in activity_in:
                ac = "medium"
            else:
                # Use most common as last resort
                ac = metadata.get('act_most_common') if metadata else None
            
            if ac:
                if act_map and ac in act_map:
                    act_enc = int(act_map[ac])
                    print(f"[ML-PREDICT] Activity '{activity_in}' mapped to '{ac}'")
                elif le_activity and ac in getattr(le_activity, 'classes_', []):
                    act_enc = int(np.where(getattr(le_activity, 'classes_', []) == ac)[0][0])
                    print(f"[ML-PREDICT] Activity '{activity_in}' mapped to '{ac}'")
    except Exception as e:
        print(f"[ML-PREDICT] Failed to encode activity: {e}")

    try:
        if food_map and food_in in food_map:
            food_enc = int(food_map[food_in])
        elif le_food and food_in in getattr(le_food, 'classes_', []):
            food_enc = int(np.where(getattr(le_food, 'classes_', []) == food_in)[0][0])
        else:
            # Fallback: match on keyword if exact value not found
            fc = None
            if "not eating" in food_in or "no appetite" in food_in or "refusing food" in food_in:
                fc = "not eating"
            elif "eating less" in food_in or "reduced appetite" in food_in:
                fc = "eating less"
            elif "weight loss" in food_in or "losing weight" in food_in:
                fc = "weight loss"
            elif "normal" in food_in:
                fc = "normal"
            else:
                # Use most common as last resort
                fc = metadata.get('food_most_common') if metadata else None
            
            if fc:
                if food_map and fc in food_map:
                    food_enc = int(food_map[fc])
                    print(f"[ML-PREDICT] Food '{food_in}' mapped to '{fc}'")
                elif le_food and fc in getattr(le_food, 'classes_', []):
                    food_enc = int(np.where(getattr(le_food, 'classes_', []) == fc)[0][0])
                    print(f"[ML-PREDICT] Food '{food_in}' mapped to '{fc}'")
    except Exception as e:
        print(f"[ML-PREDICT] Failed to encode food: {e}")

    try:
        if water_map and water_in in water_map:
            water_enc = int(water_map[water_in])
        elif le_water and water_in in getattr(le_water, 'classes_', []):
            water_enc = int(np.where(getattr(le_water, 'classes_', []) == water_in)[0][0])
        else:
            # Fallback: match on keyword if exact value not found
            wc = None
            if "not drinking" in water_in or "refusing water" in water_in or "no water" in water_in:
                wc = "not drinking"
            elif "drinking less" in water_in or "reduced water" in water_in:
                wc = "drinking less"
            elif "normal" in water_in:
                wc = "normal"
            elif "high water" in water_in or "increased water" in water_in:
                wc = "high water"
            else:
                # Use most common as last resort
                wc = metadata.get('water_most_common') if metadata else None
            
            if wc:
                if water_map and wc in water_map:
                    water_enc = int(water_map[wc])
                    print(f"[ML-PREDICT] Water '{water_in}' mapped to '{wc}'")
                elif le_water and wc in getattr(le_water, 'classes_', []):
                    water_enc = int(np.where(getattr(le_water, 'classes_', []) == wc)[0][0])
                    print(f"[ML-PREDICT] Water '{water_in}' mapped to '{wc}'")
    except Exception as e:
        print(f"[ML-PREDICT] Failed to encode water: {e}")

    try:
        if bathroom_map and bathroom_in in bathroom_map:
            bathroom_enc = int(bathroom_map[bathroom_in])
        elif le_bathroom and bathroom_in in getattr(le_bathroom, 'classes_', []):
            bathroom_enc = int(np.where(getattr(le_bathroom, 'classes_', []) == bathroom_in)[0][0])
        else:
            # Fallback: match on keyword if exact value not found
            bc = None
            if "diarrhea" in bathroom_in or "loose stool" in bathroom_in:
                bc = "diarrhea"
            elif "constipation" in bathroom_in or "hard stool" in bathroom_in:
                bc = "constipation"
            elif "frequent urin" in bathroom_in or "frequent urination" in bathroom_in:
                bc = "frequent urination"
            elif "straining" in bathroom_in or "strain" in bathroom_in:
                bc = "straining"
            elif "blood" in bathroom_in or "bloody" in bathroom_in:
                bc = "blood in urine"
            elif "house soiling" in bathroom_in or "accidents" in bathroom_in:
                bc = "house soiling"
            elif "normal" in bathroom_in:
                bc = "normal"
            else:
                # Use most common as last resort
                bc = metadata.get('bathroom_most_common') if metadata else None
            
            if bc:
                if bathroom_map and bc in bathroom_map:
                    bathroom_enc = int(bathroom_map[bc])
                    print(f"[ML-PREDICT] Bathroom '{bathroom_in}' mapped to '{bc}'")
                elif le_bathroom and bc in getattr(le_bathroom, 'classes_', []):
                    bathroom_enc = int(np.where(getattr(le_bathroom, 'classes_', []) == bc)[0][0])
                    print(f"[ML-PREDICT] Bathroom '{bathroom_in}' mapped to '{bc}'")
    except Exception as e:
        print(f"[ML-PREDICT] Failed to encode bathroom: {e}")

    # If encodings are missing, fallback
    if act_enc is None or food_enc is None or water_enc is None or bathroom_enc is None:
        print(f"[ML-PREDICT] Missing encodings: act={act_enc}, food={food_enc}, water={water_enc}, bathroom={bathroom_enc}")
        print(f"[ML-PREDICT] Using rule-based fallback")
        result = "high" if rule_flag else "low"
        print(f"[ML-PREDICT] → Rule-based result: {result}")
        return result

    print(f"[ML-PREDICT] Encodings: act={act_enc}, food={food_enc}, water={water_enc}, bathroom={bathroom_enc}, symptoms={symptom_in}")
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
            try:
                logs = _fastapi_get("/behavior_logs", params={"limit": 100000}) or []
            except Exception as exc:
                print(f"[TRAIN] Failed to fetch behavior logs: {exc}")
                return jsonify({"status": "error", "message": "Failed to load behavior logs"}), 500
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

@app.route("/test_accuracy", methods=["POST"])
def test_model_accuracy():
    """
    Evaluate the illness prediction model using time-series cross-validation.
    This endpoint trains on earlier logs and tests on the most recent `test_days`.

    Request body:
    {
        "pet_id": "optional",
        "test_days": 7
    }
    """

    data = request.get_json(silent=True) or {}
    pet_id = data.get("pet_id")
    test_days = int(data.get("test_days", 7))

    try:
        from sklearn.metrics import (
            accuracy_score, precision_score, recall_score,
            f1_score, confusion_matrix
        )

        results = {
            "accuracy": None,
            "precision": None,
            "recall": None,
            "f1_score": None,
            "confusion_matrix": None,
            "test_samples": 0,
            "details": []
        }

        # -----------------------------
        # SELECT PET(S)
        # -----------------------------
        if pet_id:
            pet_ids = [pet_id]
        else:
            try:
                pets = _fastapi_get("/pets", params={"limit": 1}) or []
                pet_ids = [p.get("id") for p in pets if p.get("id")]
            except Exception:
                return jsonify({"warning": "Could not fetch pets"}), 400

        if not pet_ids:
            return jsonify({"warning": "No pets found"}), 200

        y_true, y_pred = [], []

        # -----------------------------
        # PROCESS EACH PET
        # -----------------------------
        for pid in pet_ids:

            df = fetch_logs_df(pid, limit=500)
            if df.empty or len(df) < test_days + 10:
                continue

            df = df.copy()
            df["log_date"] = pd.to_datetime(df["log_date"])
            df = df.sort_values("log_date")

            # train/test split
            split_idx = len(df) - test_days
            train_df = df.iloc[:split_idx]
            test_df = df.iloc[split_idx:]

            # ---------------------------------
            # TRAIN MODEL ON TRAIN SUBSET ONLY
            # ---------------------------------
            try:
                trained = train_illness_model(train_df)
                if not trained:
                    continue
            except Exception as e:
                print(f"Training error for pet {pid}: {e}")
                continue

            # ---------------------------------
            # RUN PREDICTIONS ON TEST SUBSET
            # ---------------------------------
            import json

            for _, row in test_df.iterrows():

                activity = str(row.get("activity_level", ""))
                food = str(row.get("food_intake", ""))
                water = str(row.get("water_intake", ""))
                bathroom = str(row.get("bathroom_habits", ""))

                # count symptoms
                symptom_count = 0
                try:
                    raw = row.get("symptoms", "[]")
                    arr = json.loads(raw) if isinstance(raw, str) else []
                    filtered = [
                        s for s in arr
                        if str(s).lower().strip() not in ["none", "none of the above", ""]
                    ]
                    symptom_count = len(filtered)
                except:
                    symptom_count = 0

                # predicted
                pred = predict_illness_risk(
                    activity, food, water, bathroom, symptom_count
                )

                # ground truth based on the SAME heuristic used for training labels
                actual_unhealthy = (
                    (food.lower() in ["not eating", "eating less"]) or
                    (water.lower() in ["not drinking", "drinking less"]) or
                    (bathroom.lower() in ["diarrhea", "constipation", "frequent urination"]) or
                    (symptom_count >= 2) or
                    (activity.lower() == "low")
                )
                actual = "high" if actual_unhealthy else "low"

                # convert to binary (same as training)
                y_true.append(1 if actual == "high" else 0)
                y_pred.append(1 if pred in ["high", "medium"] else 0)

                results["details"].append({
                    "pet_id": pid,
                    "date": str(row["log_date"].date()),
                    "predicted": pred,
                    "actual": actual,
                    "correct": (pred == actual)
                })

        # -----------------------------
        # COMPUTE METRICS
        # -----------------------------
        if y_true and y_pred:
            results["test_samples"] = len(y_true)
            results["accuracy"] = round(accuracy_score(y_true, y_pred), 3)
            results["precision"] = round(precision_score(y_true, y_pred, zero_division=0), 3)
            results["recall"] = round(recall_score(y_true, y_pred, zero_division=0), 3)
            results["f1_score"] = round(f1_score(y_true, y_pred, zero_division=0), 3)

            cm = confusion_matrix(y_true, y_pred)
            if cm.shape == (2, 2):
                results["confusion_matrix"] = {
                    "true_negative": int(cm[0][0]),
                    "false_positive": int(cm[0][1]),
                    "false_negative": int(cm[1][0]),
                    "true_positive": int(cm[1][1])
                }
            else:
                results["confusion_matrix"] = "Invalid shape"

        return jsonify(results)

    except Exception as e:
        return jsonify({"error": str(e)}), 500

@app.route("/test_accuracy_quick", methods=["POST"])
def test_model_accuracy_quick():
    """
    Quick lightweight accuracy check without detailed confusion matrices.
    Faster alternative to /test_accuracy for testing on limited resources.
    """
    data = request.get_json(silent=True) or {}
    pet_id = data.get("pet_id")
    test_days = int(data.get("test_days", 7))
    
    try:
        from sklearn.metrics import accuracy_score, f1_score
        
        # Get pets to test
        if pet_id:
            pet_ids = [pet_id]
        else:
            try:
                pets = _fastapi_get("/pets", params={"limit": 1}) or []
                pet_ids = [p.get("id") for p in pets if p.get("id")]
            except:
                return jsonify({"error": "Could not fetch pets", "note": "Please provide pet_id parameter"}), 400
        
        if not pet_ids:
            return jsonify({"warning": "No pets found"}), 200
        
        results = {
            "test_samples": 0,
            "accuracy": None,
            "f1_score": None,
            "interpretation": None,
            "model_status": None
        }
        
        illness_y_true, illness_y_pred = [], []
        
        for pid in pet_ids:
            df = fetch_logs_df(pid, limit=200)
            if df.empty or len(df) < test_days + 5:
                continue
            
            df = df.copy()
            df['log_date'] = pd.to_datetime(df['log_date'])
            df = df.sort_values('log_date')
            
            split_idx = len(df) - test_days
            train_df = df.iloc[:split_idx]
            test_df = df.iloc[split_idx:]
            
            try:
                train_illness_model(train_df)
                
                for _, row in test_df.iterrows():
                    activity = str(row.get("activity_level", ""))
                    food_intake = str(row.get("food_intake", ""))
                    water_intake = str(row.get("water_intake", ""))
                    bathroom_habits = str(row.get("bathroom_habits", ""))
                    
                    symptom_count = 0
                    try:
                        import json
                        symptoms_str = str(row.get("symptoms", "[]"))
                        symptoms = json.loads(symptoms_str) if isinstance(symptoms_str, str) else []
                        filtered = [s for s in symptoms if str(s).lower().strip() not in ["none of the above", "", "none", "unknown"]]
                        symptom_count = len(filtered)
                    except:
                        symptom_count = 0
                    
                    pred_risk = predict_illness_risk(activity, food_intake, water_intake, bathroom_habits, symptom_count)
                    
                    actual_unhealthy = (
                        (food_intake.lower() in ['not eating', 'eating less']) or
                        (water_intake.lower() in ['not drinking', 'drinking less']) or
                        (bathroom_habits.lower() in ['diarrhea', 'constipation', 'frequent urination']) or
                        (symptom_count >= 2) or
                        (activity.lower() == 'low')
                    )
                    actual_risk = "high" if actual_unhealthy else "low"
                    
                    illness_y_true.append(1 if actual_risk in ["high", "medium"] else 0)
                    illness_y_pred.append(1 if pred_risk in ["high", "medium"] else 0)
            except Exception as e:
                print(f"Quick test error for pet {pid}: {e}")
        
        if illness_y_true and illness_y_pred:
            results["test_samples"] = len(illness_y_true)
            results["accuracy"] = round(accuracy_score(illness_y_true, illness_y_pred), 3)
            results["f1_score"] = round(f1_score(illness_y_true, illness_y_pred, zero_division=0), 3)
            results["interpretation"] = _interpret_illness_metrics(results["accuracy"], results["f1_score"])
        
        results["model_status"] = "trained" if is_illness_model_trained() else "untrained"
        
        return jsonify(results)
    
    except Exception as e:
        print(f"[ERROR] Quick accuracy test failed: {e}")
        return jsonify({"error": str(e)}), 500

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


@app.route("/test_accuracy/summary", methods=["GET"])
def test_accuracy_summary():
    """
    Get a quick summary of model performance across all pets.
    This is a lightweight version that provides overview metrics.
    """
    try:
        # Check if illness model is trained
        illness_trained = is_illness_model_trained()
        
        # Get counts with timeout protection
        pets_count = 0
        logs_count = 0

        try:
            pets_list = _fastapi_get("/pets") or []
            pets_count = len(pets_list)
        except Exception as exc:
            print(f"[SUMMARY] Failed to fetch pets count: {exc}")
            pets_count = 0

        try:
            logs_list = _fastapi_get("/behavior_logs", params={"limit": 100000}) or []
            logs_count = len(logs_list)
        except Exception as exc:
            print(f"[SUMMARY] Failed to fetch behavior logs count: {exc}")
            logs_count = 0
        
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
                "behavior_logs_available": logs_count
            },
            "recommendation": (
                "Model is trained and ready for accuracy testing. Use POST /test_accuracy to run detailed tests."
                if illness_trained
                else "Model not yet trained. Log more behavior data and use POST /train to train the model first."
            )
        })
    except Exception as e:
        return jsonify({"error": str(e)}), 500

def migrate_behavior_logs_to_predictions():
    """Migration function (deprecated) - predictions table no longer used."""
    try:
        print("[MIGRATION] migrate_behavior_logs_to_predictions: Skipping (predictions table deprecated)")
        return
    except Exception as e:
        print(f"[MIGRATION] Error: {e}")


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
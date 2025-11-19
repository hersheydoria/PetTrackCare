import os
from datetime import datetime, timedelta
from flask import Flask, request, jsonify, make_response
import pandas as pd
import numpy as np
from sklearn.ensemble import RandomForestClassifier
from sklearn.preprocessing import LabelEncoder
from sklearn.model_selection import cross_val_score, StratifiedKFold
from supabase import create_client
from dotenv import load_dotenv
from apscheduler.schedulers.background import BackgroundScheduler
import json
import joblib
import subprocess
import sys
import argparse
import traceback

# Load environment variables
load_dotenv()
SUPABASE_URL = os.getenv("SUPABASE_URL")
SUPABASE_KEY = os.getenv("SUPABASE_KEY")
BACKEND_PORT = int(os.getenv("BACKEND_PORT", "5000"))

supabase = create_client(SUPABASE_URL, SUPABASE_KEY)
app = Flask(__name__)

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

# ------------------- Helper Functions -------------------

def fetch_logs_df(pet_id, limit=200, days_back=30):
    """Fetch recent behavior logs for a pet (within last N days)"""
    resp = supabase.table("behavior_logs").select("*").eq("pet_id", pet_id).order("log_date", desc=False).limit(limit).execute()
    data = resp.data or []
    if not data:
        return pd.DataFrame()
    df = pd.DataFrame(data)
    df['log_date'] = pd.to_datetime(df['log_date']).dt.date
    
    # Filter to only include logs from last N days
    cutoff_date = (datetime.now() - timedelta(days=days_back)).date()
    df = df[df['log_date'] >= cutoff_date]
    
    df['activity_level'] = df.get('activity_level', pd.Series(['Unknown'] * len(df))).fillna('Unknown').astype(str)
    
    # Core health tracking columns
    df['food_intake'] = df.get('food_intake', pd.Series(['Unknown'] * len(df))).fillna('Unknown').astype(str)
    df['water_intake'] = df.get('water_intake', pd.Series(['Unknown'] * len(df))).fillna('Unknown').astype(str)
    df['bathroom_habits'] = df.get('bathroom_habits', pd.Series(['Unknown'] * len(df))).fillna('Unknown').astype(str)
    df['symptoms'] = df.get('symptoms', pd.Series(['[]'] * len(df))).fillna('[]').astype(str)
    
    return df

def fetch_pet_breed(pet_id):
    """Fetch pet breed from database"""
    try:
        pet_resp = supabase.table("pets").select("breed").eq("id", pet_id).limit(1).execute()
        if pet_resp.data:
            return pet_resp.data[0].get("breed")
    except Exception as e:
        print(f"[WARN] Failed to fetch breed for pet {pet_id}: {e}")
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

    # ML illness_risk on latest log with BREED ADJUSTMENT
    illness_risk_ml = "low"
    breed_notice = None  # Will hold breed-aware explanation if applicable
    try:
        if not df.empty:
            latest = df.sort_values("log_date", ascending=False).iloc[0]
            activity_level = str(latest.get("activity_level", "") or "Unknown").lower()
            food_intake = str(latest.get("food_intake", "") or "Unknown").lower()
            water_intake = str(latest.get("water_intake", "") or "Unknown").lower()
            bathroom_habits = str(latest.get("bathroom_habits", "") or "Unknown").lower()
            
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
    
    # Activity level concerns
    activity_lower = activity_level.lower()
    if 'low activity' in activity_lower or 'lethargy' in activity_lower:
        behavioral_concerns.append('Activity decreased significantly')
    elif 'restlessness' in activity_lower or 'night' in activity_lower:
        behavioral_concerns.append('Restlessness or disrupted sleep patterns')
    elif 'weakness' in activity_lower or 'collapse' in activity_lower:
        behavioral_concerns.append('Weakness or inability to move normally')
    elif 'high activity' in activity_lower:
        behavioral_concerns.append('Unusual hyperactivity or excessive energy')
    
    # Food intake concerns
    food_lower = food_intake.lower()
    if 'not eating' in food_lower or 'loss of appetite' in food_lower:
        behavioral_concerns.append('Loss of appetite or refusing to eat')
    elif 'eating less' in food_lower:
        behavioral_concerns.append('Reduced appetite')
    elif 'eating more' in food_lower:
        behavioral_concerns.append('Increased appetite or excessive eating')
    elif 'weight loss' in food_lower:
        behavioral_concerns.append('Unexplained weight loss')
    elif 'weight gain' in food_lower:
        behavioral_concerns.append('Unexplained weight gain')
    
    # Water intake concerns
    water_lower = water_intake.lower()
    if 'not drinking' in water_lower:
        behavioral_concerns.append('Not drinking water')
    elif 'drinking less' in water_lower:
        behavioral_concerns.append('Reduced water intake')
    elif 'excessive drinking' in water_lower or 'drinking more' in water_lower:
        behavioral_concerns.append('Increased thirst/excessive drinking')
    
    # Bathroom habits concerns
    bathroom_lower = bathroom_habits.lower()
    if 'diarrhea' in bathroom_lower:
        behavioral_concerns.append('Diarrhea or loose stools')
    elif 'constipation' in bathroom_lower:
        behavioral_concerns.append('Constipation')
    elif 'frequent urination' in bathroom_lower:
        behavioral_concerns.append('Frequent urination')
    elif 'straining' in bathroom_lower:
        behavioral_concerns.append('Straining to urinate or defecate')
    elif 'blood' in bathroom_lower:
        behavioral_concerns.append('Blood in urine or stool')
    elif 'accidents' in bathroom_lower or 'soiling' in bathroom_lower:
        behavioral_concerns.append('Inappropriate toileting or house soiling')
    
    # Generate health guidance based on detected symptoms or behavioral changes
    # Combine behavioral concerns with any detected clinical symptoms for comprehensive health guidance
    all_health_issues = behavioral_concerns + (symptoms_detected if symptoms_detected else [])
    if all_health_issues:
        health_guidance = generate_health_guidance(all_health_issues, df, historical_context)
        merged["health_guidance"] = health_guidance
        print(f"[ANALYZE-RESPONSE] Pet {pet_id}: Health guidance generated for {len(all_health_issues)} health issue(s) ({len(behavioral_concerns)} behavioral + {len(symptoms_detected) if symptoms_detected else 0} clinical)")
    
    if final_is_unhealthy and historical_context.get('is_persistent'):
        print(f"[ANALYZE-RESPONSE] Pet {pet_id}: [ERROR] PERSISTENT ILLNESS: {historical_context.get('illness_duration_days')} days of unhealthy patterns detected")
    
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
        
        # Fetch owner profile picture
        owner_profile_picture = ""
        if owner_id:
            try:
                uresp = supabase.table("users").select("profile_picture").eq("id", owner_id).limit(1).execute()
                urows = uresp.data or []
                if urows:
                    owner_profile_picture = urows[0].get("profile_picture") or ""
            except Exception as e:
                print(f"DEBUG: Failed to fetch owner profile picture: {e}")

        # Get current illness risk from fresh analysis (predictions table deprecated)
        # Fetch fresh analysis from /analyze endpoint to get latest prediction
        latest_prediction_text = ""
        latest_suggestions = ""
        latest_risk = "low"
        illness_model_trained = False
        
        try:
            # Call /analyze endpoint internally to get current analysis
            import requests
            analysis_url = f"http://pettrackcare.onrender.com/analyze"
            analysis_resp = requests.post(analysis_url, json={"pet_id": pet_id}, timeout=10)
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
                .profile-img {{ width:120px; height:120px; border-radius:12px; object-fit:cover; border:3px solid #e0e0e0; margin-bottom:12px; }}
                .profile-container {{ display:flex; align-items:flex-start; gap:16px; margin-bottom:16px; }}
                .profile-text {{ flex:1; }}
                .owner-info {{ margin-top:16px; padding-top:16px; border-top:1px solid #eee; }}
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
                <div class="profile-container">
                  {f'<img src="{pet_profile_picture}" alt="{pet_name}" class="profile-img">' if pet_profile_picture else '<div style="width:120px;height:120px;background:#e0e0e0;border-radius:12px;display:flex;align-items:center;justify-content:center;color:#999;">No photo</div>'}
                  <div class="profile-text">
                    <p class="label">Name</p><p class="value">{pet_name}</p>
                    <p class="label">Breed</p><p class="value">{pet_breed}</p>
                    <p class="label">Age</p><p class="value">{pet_age if pet_age else 'Not available'}</p>
                    <p class="label">Weight</p><p class="value">{pet_weight if pet_weight else 'Not specified'}</p>
                  </div>
                </div>
                <p class="label">Gender</p><p class="value">{pet_gender}</p>
                <p class="label">Health</p><p class="value">{pet_health}</p>
                <div style="display:flex;gap:8px;align-items:center;justify-content:space-between;margin-top:12px;flex-wrap:wrap;">
                  <div style="flex:1;min-width:200px;">
                    <span class="label">Health Status</span><br/>
                    <span class="badge" style="background:{risk_color};">{status_text}</span>
                    <p><strong>Risk Level:</strong> {latest_risk.title() if latest_risk else 'None'}</p>
                  </div>
                </div>
                <div class="owner-info">
                  <div style="display:flex;gap:12px;align-items:center;">
                    {f'<img src="{owner_profile_picture}" alt="{owner_name}" style="width:60px;height:60px;border-radius:50%;object-fit:cover;border:2px solid #e0e0e0;">' if owner_profile_picture else '<div style="width:60px;height:60px;background:#e0e0e0;border-radius:50%;display:flex;align-items:center;justify-content:center;color:#999;font-size:24px;">👤</div>'}
                    <div>
                      <p class="label">Owner</p><p class="value">{owner_name}</p>
                    </div>
                  </div>
                </div>
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


# Removed: backfill_future_sleep_forecasts() - predictions table deprecated
# Removed: migrate_legacy_sleep_forecasts() - predictions table deprecated  
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
        
        # Find consecutive unhealthy period
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
        
        # Calculate illness duration based on actual days covered by the longest unhealthy streak
        illness_duration_days = 0
        if max_streak_start_idx is not None and max_streak > 0:
            streak_start_date = df_copy.iloc[max_streak_start_idx]['log_date']
            streak_end_idx = min(max_streak_start_idx + max_streak - 1, len(df_copy) - 1)
            streak_end_date = df_copy.iloc[streak_end_idx]['log_date']
            illness_duration_days = max(1, (streak_end_date - streak_start_date).days + 1)

        is_persistent = illness_duration_days > 7
        
        # Determine pattern type
        pattern_type = None
        if illness_duration_days <= 3:
            pattern_type = 'acute'
        elif illness_duration_days > 7:
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
            "total_logs_analyzed": len(df_copy)
        }
    except Exception as e:
        print(f"[PATTERN-ANALYSIS] Error analyzing patterns: {e}")
        return {"illness_duration_days": 0, "is_persistent": False, "pattern_type": None}

def generate_health_guidance(symptoms_list, df=None, historical_context=None):
    """
    Generate health guidance and recommendations based on detected symptoms.
    Uses HEALTH_SYMPTOMS_REFERENCE to provide evidence-based information.
    Now includes historical context (duration, patterns, sudden changes).
    
    Args:
        symptoms_list: List of symptom strings detected from the pet's logs
        df: Optional DataFrame with all logs for historical analysis
        historical_context: Optional dict with pattern analysis results
        
    Returns:
        dict with guidance, urgency level, and recommended actions
    """
    if not symptoms_list:
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
    
    for symptom in symptoms_list:
        symptom_lower = str(symptom).lower().strip()
        # Try to find matching symptom in reference
        for key, info in HEALTH_SYMPTOMS_REFERENCE.items():
            if key in symptom_lower or symptom_lower in key:
                guidance_items.append(info)
                if urgency_levels.get(info.get("urgency", "none"), 0) > urgency_levels.get(max_urgency, 0):
                    max_urgency = info.get("urgency", "none")
                break
    
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
    
    return {
        "guidance": f"Detected {len(guidance_items)} health concern(s). {HEALTH_SYMPTOMS_REFERENCE.get('summary', 'See details below.')}",
        "urgency": max_urgency,
        "detected_symptoms": [item.get("description") for item in guidance_items],
        "detected_health_issues": symptoms_list,  # Raw behavioral and clinical health concerns
        "recommendations": recommendations[:7],  # Up to 7 recommendations
        "pattern_context": context_insights,
        "illness_duration_days": historical_context.get('illness_duration_days') if historical_context else None,
        "is_persistent_illness": historical_context.get('is_persistent') if historical_context else False,
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

@app.route("/test_accuracy", methods=["POST"])
def test_model_accuracy():
    """
    Test the accuracy of illness prediction models.
    Uses time-series cross-validation: train on past data, test on future data.
    [WARNING] This endpoint can be slow on limited resources. Test with specific pet_id for speed.
    
    Request body:
    {
        "pet_id": "optional - test specific pet or first available pet if omitted",
        "test_days": 7  # how many days into future to test predictions
    }
    
    For faster results, provide a pet_id. Otherwise, it will test the first available pet.
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
        
        # Get pets to test - limit to 1 by default for speed on limited resources
        if pet_id:
            pet_ids = [pet_id]
        else:
            # Default: test only the first pet (instead of 50) for faster response
            try:
                pets_resp = supabase.table("pets").select("id").limit(1).execute()
                pet_ids = [p["id"] for p in (pets_resp.data or [])]
            except:
                return jsonify({"error": "Could not fetch pets", "note": "Please provide pet_id parameter for faster results"}), 400
        
        if not pet_ids:
            return jsonify({"warning": "No pets found", "recommendation": "Log behavior data for pets first"}), 200
        
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
                pets_resp = supabase.table("pets").select("id").limit(1).execute()
                pet_ids = [p["id"] for p in (pets_resp.data or [])]
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
        
        # Get counts with timeout protection
        pets_count = 0
        logs_count = 0
        
        try:
            pets_resp = supabase.table("pets").select("id", count="exact").execute()
            pets_count = len(pets_resp.data or [])
        except:
            pets_count = 0
        
        try:
            logs_resp = supabase.table("behavior_logs").select("id", count="exact").limit(1).execute()
            # Try to get count from response
            logs_count = getattr(logs_resp, 'count', None) or len(logs_resp.data or [])
        except:
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


def backfill_future_sleep_forecasts():
    """Sleep forecasting deprecated - no-op function."""
    print("[MIGRATION] backfill_future_sleep_forecasts: Skipping (sleep tracking deprecated)")
    return


def migrate_legacy_sleep_forecasts():
    """Sleep forecasting deprecated - no-op function."""
    print("[MIGRATION] migrate_legacy_sleep_forecasts: Skipping (sleep tracking deprecated)")
    return


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
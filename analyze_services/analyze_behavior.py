import os
from datetime import datetime, timedelta
from flask import Flask, request, jsonify
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

def analyze_pet(pet_id):
    """Analyze pet behavior trends, store predictions, and return results."""
    df = fetch_logs_df(pet_id)
    if df.empty:
        return {
            "trend": "No data available.",
            "recommendation": "Log more behavior data to get analysis.",
            "sleep_trend": "N/A",
            "mood_prob": None,
            "activity_prob": None
        }

    # Convert dates
    df['log_date'] = pd.to_datetime(df['log_date'])

    # Calculate mood probability
    mood_counts = df['mood'].str.lower().value_counts(normalize=True).to_dict()
    mood_prob = {m: round(p, 2) for m, p in mood_counts.items()}

    # Calculate activity probability
    activity_counts = df['activity_level'].str.lower().value_counts(normalize=True).to_dict()
    activity_prob = {a: round(p, 2) for a, p in activity_counts.items()}

    # Trend and risk logic for all moods and activity levels
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

    # Store prediction in Supabase
    try:
        supabase.table("predictions").insert({
            "pet_id": pet_id,
            "prediction_date": datetime.utcnow().date().isoformat(),
            "prediction_text": trend,
            "risk_level": risk_level,
            "suggestions": recommendation,
            "activity_prob": activity_prob.get("high", 0)
        }).execute()
    except Exception as e:
        print(f"Error storing prediction: {e}")

    return {
        "trend": trend,
        "recommendation": recommendation,
        "sleep_trend": sleep_trend,
        "mood_prob": mood_prob,
        "activity_prob": activity_prob
    }

# ------------------- Flask API -------------------

@app.route("/analyze", methods=["POST"])
def analyze_endpoint():
    data = request.get_json()
    pet_id = data.get("pet_id")
    if not pet_id:
        return jsonify({"error": "pet_id required"}), 400
    return jsonify(analyze_pet(pet_id))

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
scheduler.start()

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=BACKEND_PORT)

def store_prediction(pet_id, prediction, risk_level, recommendation):
    supabase.table("predictions").insert({
        "pet_id": pet_id,
        "prediction_date": datetime.utcnow().date().isoformat(),
        "prediction_text": prediction,
        "risk_level": risk_level,
        "suggestions": recommendation
    }).execute()

def daily_analysis_job():
    print(f"🔄 Running daily pet behavior analysis at {datetime.now()}")
    pets_resp = supabase.table("pets").select("id").execute()
    for pet in pets_resp.data or []:
        result = analyze_pet(pet["id"])
        print(f"📊 Pet {pet['id']} analysis stored:", result)

def predict_illness_risk(mood, sleep_hours, activity_level, model_path="illness_model.pkl"):
    model, (le_mood, le_activity) = load_illness_model(model_path)
    if model is None or le_mood is None or le_activity is None:
        return None  # Model not trained yet
    # Encode inputs
    mood_enc = le_mood.transform([mood])[0] if mood in le_mood.classes_ else 0
    act_enc = le_activity.transform([activity_level])[0] if activity_level in le_activity.classes_ else 0
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
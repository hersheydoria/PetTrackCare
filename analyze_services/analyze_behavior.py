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

# Load environment variables
load_dotenv()
SUPABASE_URL = os.getenv("SUPABASE_URL")
SUPABASE_KEY = os.getenv("SUPABASE_KEY")
BACKEND_PORT = int(os.getenv("BACKEND_PORT", "5000"))

supabase = create_client(SUPABASE_URL, SUPABASE_KEY)
app = Flask(__name__)

# ------------------- Data Fetch & Model Logic -------------------

def fetch_logs_df(pet_id, limit=200):
    resp = supabase.table("behavior_logs").select("*").eq("pet_id", pet_id).order("log_date", {"ascending": True}).limit(limit).execute()
    data = resp.data or []
    if not data:
        return pd.DataFrame()
    df = pd.DataFrame(data)
    df['log_date'] = pd.to_datetime(df['log_date']).dt.date
    df['sleep_hours'] = pd.to_numeric(df['sleep_hours'], errors='coerce').fillna(0.0)
    df['mood'] = df['mood'].fillna('Unknown').astype(str)
    df['activity_level'] = df['activity_level'].fillna('Unknown').astype(str)
    return df

def train_illness_model(df):
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
    return clf, (le_mood, le_activity)

def forecast_sleep_with_tf(series, days_ahead=7):
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
    model = tf.keras.Sequential([
        tf.keras.layers.Input(shape=(X.shape[1],)),
        tf.keras.layers.Dense(32, activation='relu'),
        tf.keras.layers.Dense(16, activation='relu'),
        tf.keras.layers.Dense(1)
    ])
    model.compile(optimizer='adam', loss='mse')
    model.fit(X, y, epochs=50, batch_size=8, verbose=0)
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

def analyze_pet(pet_id):
    df = fetch_logs_df(pet_id)
    clf, encoders = train_illness_model(df)
    mood_prob, activity_prob = calc_mood_activity_trends(df, days=14)
    if not df.empty:
        last_log = df.iloc[-1]
        mood = last_log['mood']
        sleep_hours = float(last_log['sleep_hours'])
        activity = last_log['activity_level']
    else:
        mood, sleep_hours, activity = "Unknown", 0.0, "Unknown"
    if clf is None:
        risk = (mood.lower() in ['lethargic','aggressive']) or (sleep_hours < 5) or (activity.lower()=='low')
    else:
        le_mood, le_activity = encoders
        mood_enc = le_mood.transform([mood])[0] if mood in le_mood.classes_ else 0
        act_enc = le_activity.transform([activity])[0] if activity in le_activity.classes_ else 0
        risk = bool(clf.predict(np.array([[mood_enc, sleep_hours, act_enc]]))[0])
    prediction = "Your pet may be at risk of illness soon." if risk else "Your pet is likely to stay healthy."
    recommendation = ("Monitor closely and consider a vet visit." if risk 
                      else "Keep current routine. Encourage play and rest.")
    sleep_series = df['sleep_hours'].tolist() if not df.empty else []
    sleep_forecast = forecast_sleep_with_tf(sleep_series, days_ahead=7) if sleep_series else [sleep_hours]*7
    trends = {
        "sleep_forecast": [round(float(x),2) for x in sleep_forecast],
        "mood_probabilities": {k: round(float(v),3) for k,v in mood_prob.items()},
        "activity_probabilities": {k: round(float(v),3) for k,v in activity_prob.items()}
    }
    return {"prediction": prediction, "recommendation": recommendation, "trends": trends}

# ------------------- Flask API -------------------

@app.route("/analyze", methods=["POST"])
def analyze_endpoint():
    data = request.get_json()
    pet_id = data.get("pet_id")
    if not pet_id:
        return jsonify({"error": "pet_id required"}), 400
    return jsonify(analyze_pet(pet_id))

# ------------------- Daily Scheduler -------------------

def daily_analysis_job():
    print(f"🔄 Running daily pet behavior analysis at {datetime.now()}")
    pets_resp = supabase.table("pets").select("id").execute()
    for pet in pets_resp.data or []:
        result = analyze_pet(pet["id"])
        print(f"📊 Pet {pet['id']} analysis:", result)

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

def analyze_pet(pet_id):
    df = fetch_logs_df(pet_id)
    clf, encoders = train_illness_model(df)
    mood_prob, activity_prob = calc_mood_activity_trends(df, days=14)
    
    if not df.empty:
        last_log = df.iloc[-1]
        mood = last_log['mood']
        sleep_hours = float(last_log['sleep_hours'])
        activity = last_log['activity_level']
    else:
        mood, sleep_hours, activity = "Unknown", 0.0, "Unknown"

    if clf is None:
        risk = (mood.lower() in ['lethargic','aggressive']) or (sleep_hours < 5) or (activity.lower()=='low')
    else:
        le_mood, le_activity = encoders
        mood_enc = le_mood.transform([mood])[0] if mood in le_mood.classes_ else 0
        act_enc = le_activity.transform([activity])[0] if activity in le_activity.classes_ else 0
        risk = bool(clf.predict(np.array([[mood_enc, sleep_hours, act_enc]]))[0])
    
    prediction = "Your pet may be at risk of illness soon." if risk else "Your pet is likely to stay healthy."
    recommendation = ("Monitor closely and consider a vet visit." if risk 
                      else "Keep current routine. Encourage play and rest.")
    risk_level = "High" if risk else "Low"

    sleep_series = df['sleep_hours'].tolist() if not df.empty else []
    sleep_forecast = forecast_sleep_with_tf(sleep_series, days_ahead=7) if sleep_series else [sleep_hours]*7
    trends = {
        "sleep_forecast": [round(float(x), 2) for x in sleep_forecast],
        "mood_probabilities": {k: round(float(v), 3) for k, v in mood_prob.items()},
        "activity_probabilities": {k: round(float(v), 3) for k, v in activity_prob.items()}
    }

    # Store in Supabase predictions table
    store_prediction(pet_id, prediction, risk_level, recommendation)

    return {"prediction": prediction, "recommendation": recommendation, "trends": trends}

def daily_analysis_job():
    print(f"🔄 Running daily pet behavior analysis at {datetime.now()}")
    pets_resp = supabase.table("pets").select("id").execute()
    for pet in pets_resp.data or []:
        result = analyze_pet(pet["id"])
        print(f"📊 Pet {pet['id']} analysis stored:", result)

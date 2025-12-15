import requests

API_URL = "http://localhost:5000"
TEST_DAYS = 7

# Replace with your actual pet IDs
pet_ids = [
    "1cf6c1b0-6e1b-4539-b354-9d8596dd0cb8",
    "46fc4e1a-d52e-476e-a11d-71c32cb0de71"
]

for pet_id in pet_ids:
    print(f"Testing accuracy for pet {pet_id}...")
    r = requests.post(f"{API_URL}/test_accuracy",
                      json={"pet_id": pet_id, "test_days": TEST_DAYS})
    try:
        print(r.json())
    except Exception as e:
        print(f"Error for pet {pet_id}: {e}, response: {r.text}")
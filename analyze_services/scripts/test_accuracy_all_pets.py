import requests

API_URL = "https://pettrackcare.onrender.com"
TEST_DAYS = 7

# Replace with your actual pet IDs
pet_ids = [
    "92615a69-fc43-4467-bebc-1f1ecab52334",
    "2af1de22-2b85-4b81-b1a1-29e6a716c8ac",
    "12f382c0-8906-4ad9-a05f-8889478d9fa7"
]

for pet_id in pet_ids:
    print(f"Testing accuracy for pet {pet_id}...")
    r = requests.post(f"{API_URL}/test_accuracy",
                      json={"pet_id": pet_id, "test_days": TEST_DAYS})
    try:
        print(r.json())
    except Exception as e:
        print(f"Error for pet {pet_id}: {e}, response: {r.text}")
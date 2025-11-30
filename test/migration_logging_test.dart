import '../lib/services/location_sync_service.dart';

/// Test the enhanced logging in location sync service
void main() async {
  print('🧪 Testing enhanced Firebase to Supabase migration logging...');
  
  final locationSync = LocationSyncService();
  
  try {
    // Test Firebase connection
    print('\n📊 Testing Firebase data retrieval...');
    final firebaseData = await locationSync.getFirebaseLocationData();
    
    if (firebaseData != null) {
      print('✅ Firebase data retrieved successfully');
      print('📋 Sample keys: ${firebaseData.keys.take(3).toList()}');
    } else {
      print('❌ Failed to retrieve Firebase data');
    }
    
    // Note: We won't test Supabase insertion here since it requires auth
    print('\n⚠️ Supabase testing skipped - requires authentication');
    print('Run the full app to test complete migration with Supabase');
    
  } catch (e) {
    print('❌ Test failed: $e');
  }
  
  print('\n🧪 Test completed');
}
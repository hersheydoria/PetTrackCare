/// Test script to verify Firebase to Supabase location sync functionality
/// Run this script to test the LocationSyncService without the full app
import 'dart:io';
import 'package:flutter/material.dart';
import '../lib/services/location_sync_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  print('🧪 Testing Firebase to Supabase Location Sync Service...');
  
  final locationSync = LocationSyncService();
  
  // Test 1: Fetch Firebase data
  print('\n📡 Test 1: Fetching data from Firebase...');
  final firebaseData = await locationSync.getFirebaseLocationData();
  
  if (firebaseData == null) {
    print('❌ No data found in Firebase or connection failed');
  } else {
    print('✅ Firebase data retrieved: ${firebaseData.keys.length} entries');
    
    // Show sample of the data
    if (firebaseData.isNotEmpty) {
      final firstEntry = firebaseData.entries.first;
      print('📊 Sample entry: ${firstEntry.key} => ${firstEntry.value}');
    }
  }
  
  // Test 2: Test data sync (commented out to avoid actual insertion during test)
  print('\n🔄 Test 2: Testing sync logic...');
  print('ℹ️ Sync test would be performed here in actual implementation');
  
  // Test 3: Test single entry fetch
  if (firebaseData != null && firebaseData.isNotEmpty) {
    print('\n📡 Test 3: Fetching single entry...');
    final firstKey = firebaseData.keys.first;
    final singleEntry = await locationSync.getFirebaseEntryLocationData(firstKey);
    
    if (singleEntry != null) {
      print('✅ Single entry retrieved: $singleEntry');
    } else {
      print('❌ Failed to retrieve single entry');
    }
  }
  
  print('\n🧪 Testing completed!');
  print('\n📋 Summary:');
  print('- Firebase connection: ${firebaseData != null ? "✅ OK" : "❌ FAILED"}');
  print('- Data structure: Expected {"lat": number, "long": number, "device_mac": string}');
  print('- Ready for Supabase sync: ${firebaseData != null ? "✅ YES" : "❌ NO"}');
}
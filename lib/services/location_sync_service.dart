import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';

/// Service for syncing location data from Firebase to Supabase
/// Firebase data structure: {"lat":14.5995,"long":120.9842,"device_mac":"00:4B:12:3A:46:44","timestamp":"2025-10-05T10:30:00Z"}
class LocationSyncService {
  /// Firebase host from environment variables
  static String get _firebaseHost => dotenv.env['FIREBASE_HOST'] ?? 'pettrackcare-default-rtdb.firebaseio.com';
  
  /// Firebase authentication key from environment variables
  static String get _authKey => dotenv.env['FIREBASE_AUTH_KEY'] ?? '';
  
  final SupabaseClient _supabase = Supabase.instance.client;
  
  /// Validate Firebase configuration from environment variables
  bool get _isFirebaseConfigured {
    final host = dotenv.env['FIREBASE_HOST'];
    final key = dotenv.env['FIREBASE_AUTH_KEY'];
    
    if (host == null || host.isEmpty) {
      if (kDebugMode) {
        print('❌ FIREBASE_HOST not found in environment variables');
      }
      return false;
    }
    
    if (key == null || key.isEmpty) {
      if (kDebugMode) {
        print('❌ FIREBASE_AUTH_KEY not found in environment variables');
      }
      return false;
    }
    
    if (kDebugMode) {
      print('✅ Firebase configuration loaded from environment');
      print('   🔗 Host: $host');
      print('   🔑 Key: ${key.substring(0, 10)}...[HIDDEN]');
    }
    
    return true;
  }
  
  /// Retrieve all location data from Firebase Realtime Database
  /// Data is stored at root level with Firebase-generated keys
  Future<Map<String, dynamic>?> getFirebaseLocationData() async {
    try {
      // Validate Firebase configuration
      if (!_isFirebaseConfigured) {
        if (kDebugMode) {
          print('❌ Firebase configuration is missing. Please check .env file');
        }
        return null;
      }
      
      // Corrected URL - data is at root level, not under /locations
      final url = 'https://$_firebaseHost/.json?auth=$_authKey';
      
      if (kDebugMode) {
        print('🔍 Fetching location data from Firebase: $url');
      }
      
      final response = await http.get(Uri.parse(url));
      
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        
        if (kDebugMode) {
          print('✅ Firebase response received successfully');
          print('📊 Response data type: ${data.runtimeType}');
          
          if (data is Map<String, dynamic>) {
            print('📋 Total entries in Firebase: ${data.keys.length}');
            print('📋 Entry keys sample: ${data.keys.take(3).toList()}');
            
            // Count valid location entries
            int locationCount = 0;
            for (final entry in data.entries) {
              if (entry.value is Map<String, dynamic>) {
                final entryData = entry.value as Map<String, dynamic>;
                if (entryData.containsKey('lat') && 
                    entryData.containsKey('long') && 
                    entryData.containsKey('device_mac')) {
                  locationCount++;
                }
              }
            }
            print('📍 Valid location entries found: $locationCount');
          } else {
            print('⚠️  Unexpected data format: $data');
          }
        }
        
        return data as Map<String, dynamic>?;
      } else {
        if (kDebugMode) {
          print('❌ Failed to fetch Firebase data: ${response.statusCode} - ${response.body}');
        }
        return null;
      }
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error fetching Firebase location data: $e');
      }
      return null;
    }
  }
  
  /// Get location data for a specific entry from Firebase
  /// Data is stored at root level with Firebase-generated keys
  Future<Map<String, dynamic>?> getFirebaseEntryLocationData(String entryId) async {
    try {
      // Validate Firebase configuration
      if (!_isFirebaseConfigured) {
        if (kDebugMode) {
          print('❌ Firebase configuration is missing. Please check .env file');
        }
        return null;
      }
      
      // Corrected URL - data is at root level
      final url = 'https://$_firebaseHost/$entryId.json?auth=$_authKey';
      
      if (kDebugMode) {
        print('🔍 Fetching location data from Firebase for entry: $entryId');
      }
      
      final response = await http.get(Uri.parse(url));
      
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        
        if (kDebugMode) {
          print('✅ Firebase location data retrieved for $entryId: $data');
        }
        
        return data as Map<String, dynamic>?;
      } else {
        if (kDebugMode) {
          print('❌ Failed to fetch Firebase data: ${response.statusCode} - ${response.body}');
        }
        return null;
      }
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error fetching Firebase location data: $e');
      }
      return null;
    }
  }
  
  /// Push location data to Supabase location_history table
  /// Note: pet_id will be auto-populated by the populate_pet_id() trigger using device_mac
  Future<bool> pushLocationToSupabase({
    required double latitude,
    required double longitude,
    required String deviceMac,
    DateTime? timestamp,
    String? firebaseEntryId,
  }) async {
    try {
      final locationData = <String, dynamic>{
        'latitude': latitude,
        'longitude': longitude,
        'timestamp': timestamp?.toIso8601String() ?? DateTime.now().toIso8601String(),
        'device_mac': deviceMac, // This will trigger the populate_pet_id() function
      };
      
      // Explicitly add firebase_entry_id if provided (ensures it's included in the payload)
      if (firebaseEntryId != null) {
        locationData['firebase_entry_id'] = firebaseEntryId;
      }
      
      if (kDebugMode) {
        print('📤 Pushing location data to Supabase location_history table');
        print('   📍 Coordinates: ($latitude, $longitude)');
        print('   📱 Device MAC: $deviceMac');
        print('   ⏰ Timestamp: ${locationData['timestamp']}');
        print('   🔑 Firebase Entry ID: ${firebaseEntryId ?? "NOT PROVIDED"}');
        print('   � firebase_entry_id in payload: ${locationData.containsKey('firebase_entry_id') ? locationData['firebase_entry_id'] : "NOT IN PAYLOAD"}');
        print('   �📊 Full payload: $locationData');
      }
      
      final response = await _supabase
          .from('location_history')
          .insert(locationData)
          .select();
      
      if (kDebugMode) {
        print('✅ Supabase INSERT successful!');
        print('   📋 Response type: ${response.runtimeType}');
        print('   📋 Response data: $response');
        
        if (response.isNotEmpty) {
          final insertedRecord = response.first;
          print('   🆔 Inserted record ID: ${insertedRecord['id']}');
          print('   🐾 Auto-populated pet_id: ${insertedRecord['pet_id']}');
          print('   🔑 Stored firebase_entry_id: ${insertedRecord['firebase_entry_id'] ?? "NULL"}');
          print('   ✅ Record successfully created in location_history table');
        } else {
          print('   ⚠️  Unexpected response format: $response');
        }
      }
      
      return true;
    } catch (e) {
      if (kDebugMode) {
        print('❌ FAILED to push location data to Supabase');
        print('   🔍 Error type: ${e.runtimeType}');
        print('   📝 Error details: $e');
        
        // Check for common Supabase errors
        final errorStr = e.toString();
        if (errorStr.contains('relation "location_history" does not exist')) {
          print('   💡 Solution: Create location_history table in Supabase');
        } else if (errorStr.contains('permission denied')) {
          print('   💡 Solution: Check Supabase RLS policies for location_history table');
        } else if (errorStr.contains('populate_pet_id')) {
          print('   💡 Solution: Check populate_pet_id() trigger function in Supabase');
        }
      }
      return false;
    }
  }
  
  /// Sync all location data from Firebase to Supabase
  /// Firebase data structure: {"lat":14.5995,"long":120.9842,"device_mac":"00:4B:12:3A:46:44"}
  Future<Map<String, dynamic>> syncAllLocationsFromFirebase() async {
    final result = <String, dynamic>{
      'success': 0,
      'failed': 0,
      'errors': <String>[],
      'processed_entries': <String>[],
      'migration_timestamp': DateTime.now().toIso8601String(),
    };
    
    try {
      if (kDebugMode) {
        print('🔄 ==========================================');
        print('🔄 STARTING FIREBASE TO SUPABASE MIGRATION');
        print('🔄 ==========================================');
      }
      
      final firebaseData = await getFirebaseLocationData();
      
      if (firebaseData == null) {
        final error = 'Failed to fetch data from Firebase - check connection and credentials';
        (result['errors'] as List<String>).add(error);
        if (kDebugMode) {
          print('❌ $error');
        }
        return result;
      }
      
      if (firebaseData.isEmpty) {
        if (kDebugMode) {
          print('ℹ️ Firebase database is empty - no data to migrate');
        }
        return result;
      }
      
      if (kDebugMode) {
        print('📊 Processing ${firebaseData.length} entries from Firebase...');
      }
      
      int entryCount = 0;
      for (final entry in firebaseData.entries) {
        entryCount++;
        final entryId = entry.key; // Firebase-generated key
        final locationData = entry.value;
        
        if (kDebugMode) {
          print('');
          print('📋 Processing entry $entryCount/${firebaseData.length}');
          print('   🔑 Firebase key: $entryId');
          print('   📊 Raw data: $locationData');
          print('   📊 Data type: ${locationData.runtimeType}');
        }
        
        if (locationData == null || locationData is! Map<String, dynamic>) {
          final error = 'Invalid data structure for entry $entryId - expected Map, got ${locationData.runtimeType}';
          (result['errors'] as List<String>).add(error);
          result['failed'] = (result['failed'] as int) + 1;
          if (kDebugMode) {
            print('   ❌ $error');
          }
          continue;
        }
        
        try {
          // Extract Firebase data: lat, long, device_mac, timestamp
          final latitude = locationData['lat'];
          final longitude = locationData['long'];
          final deviceMac = locationData['device_mac'];
          final firebaseTimestamp = locationData['timestamp']; // Extract timestamp from Firebase
          
          if (kDebugMode) {
            print('   🔍 Extracted fields:');
            print('     📍 lat: $latitude (${latitude.runtimeType})');
            print('     📍 long: $longitude (${longitude.runtimeType})');
            print('     📱 device_mac: $deviceMac (${deviceMac.runtimeType})');
            print('     ⏰ timestamp: $firebaseTimestamp (${firebaseTimestamp.runtimeType})');
          }
          
          // Validate required fields
          if (latitude == null || longitude == null || deviceMac == null) {
            final error = 'Missing required fields for entry $entryId - lat: $latitude, long: $longitude, device_mac: $deviceMac';
            (result['errors'] as List<String>).add(error);
            result['failed'] = (result['failed'] as int) + 1;
            if (kDebugMode) {
              print('   ❌ $error');
            }
            continue;
          }
          
          // Convert to proper types
          late double latValue, longValue;
          try {
            latValue = latitude.toDouble();
            longValue = longitude.toDouble();
          } catch (e) {
            final error = 'Invalid coordinate values for entry $entryId - lat: $latitude, long: $longitude, error: $e';
            (result['errors'] as List<String>).add(error);
            result['failed'] = (result['failed'] as int) + 1;
            if (kDebugMode) {
              print('   ❌ $error');
            }
            continue;
          }
          
          final deviceMacStr = deviceMac.toString();
          
          // Parse timestamp from Firebase or use current time as fallback
          DateTime timestampToUse;
          try {
            if (firebaseTimestamp != null && firebaseTimestamp.toString().isNotEmpty) {
              // Try to parse Firebase timestamp
              if (firebaseTimestamp is int) {
                // Handle Unix timestamp (seconds or milliseconds)
                final timestamp = firebaseTimestamp;
                if (timestamp > 1000000000000) {
                  // Milliseconds
                  timestampToUse = DateTime.fromMillisecondsSinceEpoch(timestamp);
                } else {
                  // Seconds
                  timestampToUse = DateTime.fromMillisecondsSinceEpoch(timestamp * 1000);
                }
              } else if (firebaseTimestamp is String) {
                // Handle ISO string timestamp
                timestampToUse = DateTime.parse(firebaseTimestamp);
              } else {
                // Unknown format, use current time
                timestampToUse = DateTime.now();
                if (kDebugMode) {
                  print('   ⚠️  Unknown timestamp format: $firebaseTimestamp (${firebaseTimestamp.runtimeType}), using current time');
                }
              }
            } else {
              // No timestamp in Firebase, use current time
              timestampToUse = DateTime.now();
              if (kDebugMode) {
                print('   ℹ️  No timestamp in Firebase data, using current time');
              }
            }
          } catch (e) {
            // Error parsing timestamp, use current time as fallback
            timestampToUse = DateTime.now();
            if (kDebugMode) {
              print('   ⚠️  Error parsing timestamp "$firebaseTimestamp": $e, using current time');
            }
          }
          
          if (kDebugMode) {
            print('   ✅ Validation passed - checking if already migrated');
            print('   🔑 Firebase Entry ID to check: $entryId');
            print('   ⏰ Final timestamp: ${timestampToUse.toIso8601String()}');
          }
          
          // CHECK IF ALREADY MIGRATED: Query Supabase using firebase_entry_id to prevent duplicate migrations
          try {
            if (kDebugMode) {
              print('   🔍 Querying Supabase for firebase_entry_id: $entryId');
            }
            
            final existingRecords = await _supabase
                .from('location_history')
                .select('id, firebase_entry_id')
                .eq('firebase_entry_id', entryId)
                .limit(1);
            
            if (kDebugMode) {
              print('   📊 Query result: ${existingRecords.length} records found');
              if (existingRecords.isNotEmpty) {
                print('   📋 Existing record: ${existingRecords.first}');
              }
            }
            
            if (existingRecords.isNotEmpty) {
              if (kDebugMode) {
                print('   ⏭️  SKIPPED: Firebase entry $entryId already migrated (Supabase id: ${existingRecords.first['id']})');
              }
              // Don't count as success or failure - just skip
              continue;
            }
            
            if (kDebugMode) {
              print('   🆕 NEW: Firebase entry $entryId not yet migrated - proceeding with insert');
            }
          } catch (checkError) {
            if (kDebugMode) {
              print('   ⚠️  Could not check existing record: $checkError');
              // If firebase_entry_id column doesn't exist, fall back to coordinate/timestamp matching
              print('   ⚠️  Attempting fallback check using coordinates and timestamp...');
              try {
                final fallbackRecords = await _supabase
                    .from('location_history')
                    .select('id')
                    .eq('device_mac', deviceMacStr)
                    .eq('latitude', latValue)
                    .eq('longitude', longValue)
                    .eq('timestamp', timestampToUse.toIso8601String())
                    .limit(1);
                
                if (fallbackRecords.isNotEmpty) {
                  if (kDebugMode) {
                    print('   ⏭️  SKIPPED: Entry matches existing record (id: ${fallbackRecords.first['id']})');
                  }
                  continue;
                }
              } catch (fallbackError) {
                if (kDebugMode) {
                  print('   ⚠️  Fallback check also failed: $fallbackError - proceeding with insert');
                }
              }
            }
          }
          
          // Insert into location_history - the populate_pet_id trigger will handle pet_id mapping
          final success = await pushLocationToSupabase(
            latitude: latValue,
            longitude: longValue,
            deviceMac: deviceMacStr,
            timestamp: timestampToUse, // Use Firebase timestamp or current time as fallback
            firebaseEntryId: entryId, // Track which Firebase entry this came from
          );
          
          if (success) {
            result['success'] = (result['success'] as int) + 1;
            (result['processed_entries'] as List<String>).add(entryId);
            if (kDebugMode) {
              print('   ✅ SUCCESS: Entry $entryId synced to Supabase');
            }
          } else {
            result['failed'] = (result['failed'] as int) + 1;
            final error = 'Failed to insert entry $entryId into Supabase';
            (result['errors'] as List<String>).add(error);
            if (kDebugMode) {
              print('   ❌ $error');
            }
          }
          
        } catch (e) {
          result['failed'] = (result['failed'] as int) + 1;
          final error = 'Exception processing entry $entryId: $e';
          (result['errors'] as List<String>).add(error);
          if (kDebugMode) {
            print('   ❌ $error');
          }
        }
      }
      
      if (kDebugMode) {
        print('');
        print('🔄 ==========================================');
        print('🔄 MIGRATION SUMMARY');
        print('🔄 ==========================================');
        print('✅ Successful migrations: ${result['success']}');
        print('❌ Failed migrations: ${result['failed']}');
        print('📊 Total entries processed: ${firebaseData.length}');
        
        if ((result['errors'] as List<String>).isNotEmpty) {
          print('');
          print('❌ ERRORS ENCOUNTERED:');
          for (int i = 0; i < (result['errors'] as List<String>).length; i++) {
            print('   ${i + 1}. ${(result['errors'] as List<String>)[i]}');
          }
        }
        
        if ((result['processed_entries'] as List<String>).isNotEmpty) {
          print('');
          print('✅ SUCCESSFULLY PROCESSED ENTRIES:');
          for (final entryId in (result['processed_entries'] as List<String>)) {
            print('   - $entryId');
          }
        }
        print('🔄 ==========================================');
      }
      
    } catch (e) {
      final error = 'Critical error during migration: $e';
      (result['errors'] as List<String>).add(error);
      if (kDebugMode) {
        print('❌ CRITICAL ERROR: $error');
      }
    }
    
    return result;
  }
  
  /// Sync location data for a specific entry from Firebase to Supabase
  Future<bool> syncEntryLocationFromFirebase(String entryId) async {
    try {
      if (kDebugMode) {
        print('🔄 Syncing location data for entry: $entryId');
      }
      
      final firebaseData = await getFirebaseEntryLocationData(entryId);
      
      if (firebaseData == null) {
        if (kDebugMode) {
          print('ℹ️ No location data found for entry $entryId in Firebase');
        }
        return false;
      }
      
      // Extract Firebase data: lat, long, device_mac, timestamp
      final latitude = firebaseData['lat']?.toDouble();
      final longitude = firebaseData['long']?.toDouble();
      final deviceMac = firebaseData['device_mac'] as String?;
      final firebaseTimestamp = firebaseData['timestamp'];
      
      if (latitude == null || longitude == null || deviceMac == null) {
        if (kDebugMode) {
          print('❌ Invalid data for entry $entryId - missing lat/long/device_mac');
        }
        return false;
      }
      
      // Parse timestamp from Firebase or use current time as fallback
      DateTime timestampToUse;
      try {
        if (firebaseTimestamp != null && firebaseTimestamp.toString().isNotEmpty) {
          if (firebaseTimestamp is int) {
            // Handle Unix timestamp (seconds or milliseconds)
            if (firebaseTimestamp > 1000000000000) {
              timestampToUse = DateTime.fromMillisecondsSinceEpoch(firebaseTimestamp);
            } else {
              timestampToUse = DateTime.fromMillisecondsSinceEpoch(firebaseTimestamp * 1000);
            }
          } else if (firebaseTimestamp is String) {
            timestampToUse = DateTime.parse(firebaseTimestamp);
          } else {
            timestampToUse = DateTime.now();
          }
        } else {
          timestampToUse = DateTime.now();
        }
      } catch (e) {
        timestampToUse = DateTime.now();
        if (kDebugMode) {
          print('⚠️  Error parsing timestamp for entry $entryId: $e');
        }
      }
      
      if (kDebugMode) {
        print('📊 Entry data: lat=$latitude, long=$longitude, mac=$deviceMac, timestamp=${timestampToUse.toIso8601String()}');
      }
      
      // Check if already migrated
      try {
        final existingRecords = await _supabase
            .from('location_history')
            .select('id, firebase_entry_id')
            .eq('firebase_entry_id', entryId)
            .limit(1);
        
        if (existingRecords.isNotEmpty) {
          if (kDebugMode) {
            print('⏭️  Entry $entryId already migrated (id: ${existingRecords.first['id']})');
          }
          return true; // Already migrated, consider it a success
        }
      } catch (checkError) {
        if (kDebugMode) {
          print('⚠️  Could not check existing record: $checkError');
        }
      }
      
      // Insert into location_history
      final success = await pushLocationToSupabase(
        latitude: latitude,
        longitude: longitude,
        deviceMac: deviceMac,
        timestamp: timestampToUse,
        firebaseEntryId: entryId, // Track which Firebase entry this came from
      );
      
      if (kDebugMode) {
        print(success 
            ? '✅ Successfully synced location for entry $entryId (device: $deviceMac)'
            : '❌ Failed to sync location for entry $entryId');
      }
      
      return success;
      
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error syncing entry location for $entryId: $e');
      }
      return false;
    }
  }
  
  /// Get the latest location data for a pet from Supabase
  Future<Map<String, dynamic>?> getLatestPetLocation(String petId) async {
    try {
      final response = await _supabase
          .from('location_history')
          .select()
          .eq('pet_id', petId)
          .order('timestamp', ascending: false)
          .limit(1)
          .maybeSingle();
      
      return response;
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error getting latest pet location from Supabase: $e');
      }
      return null;
    }
  }
  
  /// Get location history for a pet from Supabase
  Future<List<Map<String, dynamic>>> getPetLocationHistory(
    String petId, {
    int limit = 100,
    DateTime? startDate,
    DateTime? endDate,
  }) async {
    try {
      var query = _supabase
          .from('location_history')
          .select()
          .eq('pet_id', petId)
          .order('timestamp', ascending: false);
      
      // Note: Date filtering removed due to API limitations
      // You may need to filter results client-side if needed
      
      query = query.limit(limit);
      
      final response = await query;
      final results = List<Map<String, dynamic>>.from(response);
      
      // Client-side date filtering if needed
      if (startDate != null || endDate != null) {
        return results.where((record) {
          final timestamp = DateTime.tryParse(record['timestamp']?.toString() ?? '');
          if (timestamp == null) return false;
          
          if (startDate != null && timestamp.isBefore(startDate)) return false;
          if (endDate != null && timestamp.isAfter(endDate)) return false;
          
          return true;
        }).toList();
      }
      
      return results;
      
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error getting pet location history from Supabase: $e');
      }
      return [];
    }
  }
  
  /// Get location history for a device MAC from Supabase
  Future<List<Map<String, dynamic>>> getDeviceLocationHistory(
    String deviceMac, {
    int limit = 100,
    DateTime? startDate,
    DateTime? endDate,
  }) async {
    try {
      var query = _supabase
          .from('location_history')
          .select()
          .eq('device_mac', deviceMac)
          .order('timestamp', ascending: false);
      
      // Note: Date filtering removed due to API limitations
      // You may need to filter results client-side if needed
      
      query = query.limit(limit);
      
      final response = await query;
      final results = List<Map<String, dynamic>>.from(response);
      
      // Client-side date filtering if needed
      if (startDate != null || endDate != null) {
        return results.where((record) {
          final timestamp = DateTime.tryParse(record['timestamp']?.toString() ?? '');
          if (timestamp == null) return false;
          
          if (startDate != null && timestamp.isBefore(startDate)) return false;
          if (endDate != null && timestamp.isAfter(endDate)) return false;
          
          return true;
        }).toList();
      }
      
      return results;
      
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error getting device location history from Supabase: $e');
      }
      return [];
    }
  }
  
  /// Delete a location entry from Firebase (cleanup after successful sync)
  Future<bool> deleteFirebaseLocationEntry(String entryId) async {
    try {
      final url = 'https://$_firebaseHost/locations/$entryId.json?auth=$_authKey';
      
      if (kDebugMode) {
        print('🗑️ Deleting location data from Firebase for entry: $entryId');
      }
      
      final response = await http.delete(Uri.parse(url));
      
      if (response.statusCode == 200) {
        if (kDebugMode) {
          print('✅ Successfully deleted Firebase location data for entry $entryId');
        }
        return true;
      } else {
        if (kDebugMode) {
          print('❌ Failed to delete Firebase location data: ${response.statusCode} - ${response.body}');
        }
        return false;
      }
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error deleting Firebase location data: $e');
      }
      return false;
    }
  }

  /// Sync and cleanup - sync data from Firebase to Supabase then optionally delete from Firebase
  Future<Map<String, dynamic>> syncAndCleanup({bool deleteAfterSync = false}) async {
    final syncResult = await syncAllLocationsFromFirebase();
    
    if (deleteAfterSync && syncResult['success'] > 0) {
      try {
        final firebaseData = await getFirebaseLocationData();
        if (firebaseData != null) {
          int deletedCount = 0;
          for (final entryId in firebaseData.keys) {
            final deleted = await deleteFirebaseLocationEntry(entryId);
            if (deleted) deletedCount++;
          }
          syncResult['deleted'] = deletedCount;
          
          if (kDebugMode) {
            print('🧹 Cleanup completed. Deleted $deletedCount entries from Firebase');
          }
        }
      } catch (e) {
        (syncResult['errors'] as List<String>).add('Cleanup error: $e');
      }
    }
    
    return syncResult;
  }
}
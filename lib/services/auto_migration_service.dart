import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'location_sync_service.dart';

/// Service for automatic Firebase to Supabase migration on app startup
/// Migration runs every time conditions are met (no time limits)
class AutoMigrationService {
  static const String _lastMigrationKey = 'last_firebase_migration';
  static const String _migrationEnabledKey = 'firebase_migration_enabled';
  
  final LocationSyncService _locationSyncService = LocationSyncService();
  
  /// Force run migration for testing (bypasses all conditions)
  Future<void> forceRunMigration() async {
    print('🚨 FORCE RUN MIGRATION CALLED');
    print('🚨 Bypassing all conditions for testing');
    await runAutoMigration();
  }
  
  /// Reset migration timer (for testing - allows migration to run again)
  Future<void> resetMigrationTimer() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_lastMigrationKey);
    print('🔄 Migration timer reset - migration can run again');
  }
  
  /// Force migration bypassing ALL conditions (for immediate testing)
  Future<void> forceImmediateMigration() async {
    print('🚨 ==========================================');
    print('🚨 FORCE IMMEDIATE MIGRATION');
    print('🚨 Bypassing all conditions and timers');
    print('🚨 ==========================================');
    
    try {
      // Run migration directly
      final migrationResult = await _locationSyncService.syncAllLocationsFromFirebase();
      
      print('🚨 FORCE MIGRATION RESULTS:');
      print('   ✅ Successful: ${migrationResult['success']}');
      print('   ❌ Failed: ${migrationResult['failed']}');
      print('   📝 Errors: ${migrationResult['errors']}');
      
      // Update last migration timestamp if successful
      if (migrationResult['success'] > 0) {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(_lastMigrationKey, DateTime.now().toIso8601String());
        print('🚨 Updated migration timestamp after successful migration');
      }
      
    } catch (e) {
      print('🚨 Force migration error: $e');
    }
    
    print('🚨 ==========================================');
  }
  
  /// Check migration status and last run time
  Future<void> checkMigrationStatus() async {
    print('📊 ==========================================');
    print('📊 MIGRATION STATUS CHECK');
    print('📊 ==========================================');
    
    try {
      final prefs = await SharedPreferences.getInstance();
      final lastMigration = prefs.getString(_lastMigrationKey);
      final migrationEnabled = prefs.getBool(_migrationEnabledKey) ?? true;
      final user = Supabase.instance.client.auth.currentUser;
      
      print('📊 Migration Enabled: $migrationEnabled');
      print('📊 User Logged In: ${user != null}');
      if (user != null) {
        final metadata = user.userMetadata ?? {};
        final role = metadata['role']?.toString() ?? 'Pet Owner';
        print('📊 User Role: $role');
        print('📊 User ID: ${user.id}');
      }
      
      if (lastMigration != null) {
        final lastMigrationDate = DateTime.parse(lastMigration);
        final hoursSince = DateTime.now().difference(lastMigrationDate).inHours;
        final daysSince = DateTime.now().difference(lastMigrationDate).inDays;
        
        print('📊 Last Migration: $lastMigration');
        print('📊 Time Since Last: $daysSince days, ${hoursSince % 24} hours');
        print('📊 Can Run Again: YES (no time limit)');
      } else {
        print('📊 Last Migration: Never');
        print('📊 Can Run Again: YES');
      }
      
      final shouldRun = await shouldRunMigration();
      print('📊 Should Run Now: ${shouldRun ? "YES" : "NO"}');
      
    } catch (e) {
      print('❌ Status check error: $e');
    }
    
    print('📊 ==========================================');
  }
  
  /// Debug migration with detailed Firebase connectivity test
  Future<void> debugMigrationTest() async {
    print('🔬 ==========================================');
    print('🔬 DEBUG MIGRATION TEST');
    print('🔬 ==========================================');
    
    try {
      // Test Firebase connectivity directly
      print('🔬 Step 1: Testing Firebase connectivity...');
      final firebaseData = await _locationSyncService.getFirebaseLocationData();
      
      if (firebaseData == null) {
        print('❌ Firebase returned null - check configuration or network');
        return;
      }
      
      if (firebaseData.isEmpty) {
        print('⚠️ Firebase returned empty data - no location entries found');
        return;
      }
      
      print('✅ Firebase connectivity successful!');
      print('📊 Found ${firebaseData.length} entries in Firebase');
      print('📋 Sample keys: ${firebaseData.keys.take(3).toList()}');
      
      // Show sample data
      if (firebaseData.isNotEmpty) {
        final firstEntry = firebaseData.entries.first;
        print('📄 Sample entry:');
        print('   🔑 Key: ${firstEntry.key}');
        print('   📊 Data: ${firstEntry.value}');
      }
      
      // Test migration
      print('🔬 Step 2: Running full migration...');
      final migrationResult = await _locationSyncService.syncAllLocationsFromFirebase();
      
      print('🔬 Step 3: Migration Results:');
      print('   ✅ Successful: ${migrationResult['success']}');
      print('   ❌ Failed: ${migrationResult['failed']}');
      print('   📝 Errors: ${migrationResult['errors']}');
      
    } catch (e) {
      print('❌ Debug test error: $e');
      print('Stack trace: ${StackTrace.current}');
    }
    
    print('🔬 ==========================================');
  }

  /// Check if automatic migration should run
  Future<bool> shouldRunMigration() async {
    try {
      print('🔄 ==========================================');
      print('🔄 CHECKING AUTO-MIGRATION CONDITIONS');
      print('🔄 ==========================================');
      print('🔄 Service: AutoMigrationService.shouldRunMigration()');
      print('🔄 Timestamp: ${DateTime.now().toIso8601String()}');
      
      final prefs = await SharedPreferences.getInstance();
      
      // Check if migration is enabled (default: true)
      final migrationEnabled = prefs.getBool(_migrationEnabledKey) ?? true;
      if (kDebugMode) {
        print('🔄 Migration enabled in preferences: $migrationEnabled');
      }
      if (!migrationEnabled) {
        print('🔄 Auto-migration disabled by user preference');
        return false;
      }
      
      // Check if user is logged in
      final user = Supabase.instance.client.auth.currentUser;
      print('🔄 Current user check: ${user != null ? "Authenticated" : "Not authenticated"}');
      if (user != null) {
        print('🔄 User ID: ${user.id}');
        print('🔄 User email: ${user.email ?? "No email"}');
      }
      if (user == null) {
        print('🔄 Auto-migration skipped: No authenticated user');
        return false;
      }
      
      // Check user role (allow Pet Owner and Pet Sitter)
      final metadata = user.userMetadata ?? {};
      final role = metadata['role']?.toString() ?? 'Pet Owner';
      if (kDebugMode) {
        print('🔄 User metadata: $metadata');
        print('🔄 Detected role: $role');
      }
      if (role != 'Pet Owner' && role != 'Pet Sitter') {
        if (kDebugMode) {
          print('🔄 Auto-migration skipped: User is not a Pet Owner or Pet Sitter ($role)');
        }
        return false;
      }
      if (kDebugMode) {
        print('✅ Auto-migration allowed for role: $role');
      }
      
      // Log last migration time for reference (no time limit enforced)
      final lastMigration = prefs.getString(_lastMigrationKey);
      if (kDebugMode) {
        print('🔄 Last migration timestamp: ${lastMigration ?? "Never"}');
      }
      if (lastMigration != null) {
        final lastMigrationDate = DateTime.parse(lastMigration);
        final hoursSinceLastMigration = DateTime.now().difference(lastMigrationDate).inHours;
        
        if (kDebugMode) {
          print('🔄 Time since last migration: ${hoursSinceLastMigration} hours ago');
          print('🔄 Migration can run anytime (no time limit)');
        }
      }
      
      print('✅ All conditions met - Auto-migration should run for user: ${user.id} ($role)');
      print('🔄 ==========================================');
      return true;
      
    } catch (e) {
      print('❌ Error checking migration conditions: $e');
      return false;
    }
  }
  
  /// Run automatic migration in background
  Future<void> runAutoMigration() async {
    try {
      print('🚀 ==========================================');
      print('🚀 STARTING AUTOMATIC MIGRATION');
      print('🚀 ==========================================');
      print('🚀 Timestamp: ${DateTime.now().toIso8601String()}');
      print('🚀 User: ${Supabase.instance.client.auth.currentUser?.id ?? "Unknown"}');
      print('🚀 Service: AutoMigrationService.runAutoMigration()');
      
      // Check if migration should actually run
      if (!await shouldRunMigration()) {
        print('⏭️ ==========================================');
        print('⏭️ AUTO-MIGRATION SKIPPED - CONDITIONS NOT MET');
        print('⏭️ ==========================================');
        return;
      }
      
      print('📡 Calling LocationSyncService.syncAllLocationsFromFirebase()...');
      
      // Run the migration
      final results = await _locationSyncService.syncAllLocationsFromFirebase();
      
      // Save migration timestamp
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_lastMigrationKey, DateTime.now().toIso8601String());
      
      print('');
      print('🚀 ==========================================');
      print('🚀 AUTO-MIGRATION RESULTS');
      print('🚀 ==========================================');
      print('✅ Successful records: ${results['success']}');
      print('❌ Failed records: ${results['failed']}');
      print('📊 Migration timestamp saved: ${DateTime.now().toIso8601String()}');
      
      if ((results['errors'] as List).isNotEmpty) {
        print('');
        print('❌ MIGRATION ERRORS:');
        for (int i = 0; i < (results['errors'] as List).length; i++) {
          print('   ${i + 1}. ${(results['errors'] as List)[i]}');
        }
      }
      
      if (results['processed_entries'] != null && (results['processed_entries'] as List).isNotEmpty) {
        print('');
        print('✅ PROCESSED FIREBASE ENTRIES:');
        for (final entryId in (results['processed_entries'] as List)) {
          print('   - $entryId');
        }
      }
      
      print('🚀 ==========================================');
      
      // Log successful migration to database (optional)
      if (results['success'] > 0) {
        await _logMigrationResult(results);
        print('📝 Migration results logged to database');
      }
      
      // Summary notification
      print('');
      if (results['success'] > 0 && results['failed'] == 0) {
        print('🎉 AUTO-MIGRATION COMPLETED SUCCESSFULLY! 🎉');
      } else if (results['success'] > 0 && results['failed'] > 0) {
        print('⚠️  AUTO-MIGRATION COMPLETED WITH PARTIAL SUCCESS ⚠️');
      } else if (results['success'] == 0 && results['failed'] > 0) {
        print('💥 AUTO-MIGRATION FAILED - NO DATA MIGRATED 💥');
      } else {
        print('ℹ️  AUTO-MIGRATION COMPLETED - NO DATA TO PROCESS');
      }
      
    } catch (e) {
      print('❌ ==========================================');
      print('❌ AUTO-MIGRATION ERROR');
      print('❌ ==========================================');
      print('❌ Error type: ${e.runtimeType}');
      print('❌ Error message: $e');
      print('❌ Stack trace: ${StackTrace.current}');
    }
  }
  
  /// Log migration results to Supabase for monitoring
  Future<void> _logMigrationResult(Map<String, dynamic> results) async {
    try {
      final user = Supabase.instance.client.auth.currentUser;
      if (user == null) return;
      
      final logData = {
        'user_id': user.id,
        'migration_type': 'auto_firebase_sync',
        'success_count': results['success'] ?? 0,
        'failed_count': results['failed'] ?? 0,
        'error_details': (results['errors'] as List).isNotEmpty ? results['errors'].toString() : null,
        'timestamp': DateTime.now().toIso8601String(),
      };
      
      // Try to insert into migration_logs table if it exists
      await Supabase.instance.client
          .from('migration_logs')
          .insert(logData);
          
      if (kDebugMode) {
        print('📊 Migration result logged successfully');
      }
      
    } catch (e) {
      // Ignore logging errors - don't fail migration because of this
      if (kDebugMode) {
        print('⚠️ Could not log migration result (this is OK): $e');
      }
    }
  }
  
  /// Enable or disable automatic migration
  Future<void> setMigrationEnabled(bool enabled) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_migrationEnabledKey, enabled);
      
      if (kDebugMode) {
        print('🔄 Auto-migration ${enabled ? 'enabled' : 'disabled'}');
      }
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error setting migration preference: $e');
      }
    }
  }
  
  /// Check if automatic migration is enabled
  Future<bool> isMigrationEnabled() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getBool(_migrationEnabledKey) ?? true;
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error checking migration preference: $e');
      }
      return true; // Default to enabled
    }
  }
  
  /// Get last migration date
  Future<DateTime?> getLastMigrationDate() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final lastMigration = prefs.getString(_lastMigrationKey);
      if (lastMigration != null) {
        return DateTime.parse(lastMigration);
      }
      return null;
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error getting last migration date: $e');
      }
      return null;
    }
  }
  
  /// Force run migration (ignoring time constraints)
  Future<Map<String, dynamic>> forceMigration() async {
    try {
      if (kDebugMode) {
        print('🔄 Force running Firebase migration...');
      }
      
      final results = await _locationSyncService.syncAllLocationsFromFirebase();
      
      // Update last migration time
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_lastMigrationKey, DateTime.now().toIso8601String());
      
      // Log the result
      if (results['success'] > 0) {
        await _logMigrationResult(results);
      }
      
      return results;
      
    } catch (e) {
      if (kDebugMode) {
        print('❌ Force migration error: $e');
      }
      return {
        'success': 0,
        'failed': 1,
        'errors': ['Force migration error: $e'],
      };
    }
  }
}
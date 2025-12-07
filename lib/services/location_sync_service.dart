import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:http/http.dart' as http;

import 'fastapi_service.dart';

class LocationSyncService {
  static String get _firebaseHost => dotenv.env['FIREBASE_HOST'] ?? 'pettrackcare-default-rtdb.firebaseio.com';
  static String get _authKey => dotenv.env['FIREBASE_AUTH_KEY'] ?? '';

  final FastApiService _fastApi = FastApiService.instance;
  final Map<String, String?> _devicePetCache = {};

  bool get _isFirebaseConfigured {
    final host = dotenv.env['FIREBASE_HOST'];
    final key = dotenv.env['FIREBASE_AUTH_KEY'];

    if (host == null || host.isEmpty) {
      if (kDebugMode) {
        print('FIREBASE_HOST is missing in environment');
      }
      return false;
    }

    if (key == null || key.isEmpty) {
      if (kDebugMode) {
        print('FIREBASE_AUTH_KEY is missing in environment');
      }
      return false;
    }

    if (kDebugMode) {
      print('Firebase configuration loaded.');
    }

    return true;
  }

  Future<Map<String, dynamic>?> getFirebaseLocationData() async {
    if (!_isFirebaseConfigured) {
      if (kDebugMode) {
        print('Firebase configuration not ready. Skipping fetch.');
      }
      return null;
    }

    final url = 'https://$_firebaseHost/.json?auth=$_authKey';
    if (kDebugMode) {
      print('Fetching Firebase location data from $url');
    }

    try {
      final response = await http.get(Uri.parse(url));
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        if (data is Map<String, dynamic>) {
          return data;
        }
        if (kDebugMode) {
          print('Unexpected Firebase payload type: ${data.runtimeType}');
        }
      } else {
        if (kDebugMode) {
          print('Firebase request failed: ${response.statusCode}');
        }
      }
    } catch (error) {
      if (kDebugMode) {
        print('Exception while fetching Firebase data: $error');
      }
    }

    return null;
  }

  Future<Map<String, dynamic>?> getFirebaseEntryLocationData(String entryId) async {
    if (!_isFirebaseConfigured) {
      if (kDebugMode) {
        print('Firebase configuration not ready. Skipping single entry fetch.');
      }
      return null;
    }

    final url = 'https://$_firebaseHost/$entryId.json?auth=$_authKey';
    if (kDebugMode) {
      print('Fetching Firebase entry data for $entryId');
    }

    try {
      final response = await http.get(Uri.parse(url));
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        if (data is Map<String, dynamic>) {
          return data;
        }
        if (kDebugMode) {
          print('Unexpected Firebase entry payload type: ${data.runtimeType}');
        }
      } else {
        if (kDebugMode) {
          print('Firebase request failed for $entryId: ${response.statusCode}');
        }
      }
    } catch (error) {
      if (kDebugMode) {
        print('Exception while fetching Firebase entry $entryId: $error');
      }
    }

    return null;
  }

  Future<bool> pushLocation({
    required String petId,
    required double latitude,
    required double longitude,
    required String deviceMac,
    DateTime? timestamp,
    String? firebaseEntryId,
  }) async {
    final payload = <String, dynamic>{
      'pet_id': petId,
      'latitude': latitude,
      'longitude': longitude,
      'device_mac': deviceMac,
      if (timestamp != null) 'timestamp': timestamp.toIso8601String(),
      if (firebaseEntryId != null) 'firebase_entry_id': firebaseEntryId,
    };

    if (kDebugMode) {
      print('Pushing location to FastAPI: $payload');
    }

    try {
      await _fastApi.createLocation(payload);
      return true;
    } catch (error) {
      if (kDebugMode) {
        print('Failed to create location record via FastAPI: $error');
      }
      return false;
    }
  }

  Future<Map<String, dynamic>> syncAllLocationsFromFirebase() async {
    final result = <String, dynamic>{
      'success': 0,
      'failed': 0,
      'errors': <String>[],
      'processed_entries': <String>[],
      'skipped': 0,
      'skipped_entries': <String>[],
      'migration_timestamp': DateTime.now().toIso8601String(),
    };

    if (kDebugMode) {
      print('Starting full Firebase to FastAPI sync...');
    }

    final firebaseData = await getFirebaseLocationData();
    if (firebaseData == null) {
      final error = 'Failed to fetch data from Firebase';
      (result['errors'] as List<String>).add(error);
      return result;
    }

    if (firebaseData.isEmpty) {
      if (kDebugMode) {
        print('Firebase contains no location entries');
      }
      return result;
    }

    for (final entry in firebaseData.entries) {
      final entryId = entry.key;
      final locationData = entry.value;
      if (locationData == null || locationData is! Map<String, dynamic>) {
        final error =
            'Entry $entryId does not contain a valid Map payload (type: ${locationData.runtimeType})';
        (result['errors'] as List<String>).add(error);
        result['failed'] = (result['failed'] as int) + 1;
        continue;
      }

      final latitude = locationData['lat'];
      final longitude = locationData['long'];
      final deviceMac = locationData['device_mac'];
      final timestampValue = locationData['timestamp'];

      if (await _firebaseEntryAlreadyMigrated(entryId)) {
        if (kDebugMode) {
          print('Skipping Firebase entry $entryId – already migrated to Postgres');
        }
        result['skipped'] = (result['skipped'] as int) + 1;
        (result['skipped_entries'] as List<String>).add(entryId);
        continue;
      }

      if (latitude == null || longitude == null || deviceMac == null) {
        final error =
            'Entry $entryId missing lat/long/device_mac (lat: $latitude, long: $longitude, device_mac: $deviceMac)';
        (result['errors'] as List<String>).add(error);
        result['failed'] = (result['failed'] as int) + 1;
        continue;
      }

      late double latValue;
      late double longValue;
      try {
        latValue = latitude.toDouble();
        longValue = longitude.toDouble();
      } catch (parseError) {
        final error =
            'Entry $entryId has invalid coordinates (lat: $latitude, long: $longitude, error: $parseError)';
        (result['errors'] as List<String>).add(error);
        result['failed'] = (result['failed'] as int) + 1;
        continue;
      }

      final deviceMacStr = deviceMac.toString();
      final timestamp = _parseTimestamp(timestampValue);
      final petId = await _resolvePetForDevice(deviceMacStr);
      if (petId == null) {
        final error = 'Entry $entryId could not be mapped to a pet (device_mac: $deviceMacStr)';
        (result['errors'] as List<String>).add(error);
        result['failed'] = (result['failed'] as int) + 1;
        continue;
      }

      final success = await pushLocation(
        petId: petId,
        latitude: latValue,
        longitude: longValue,
        deviceMac: deviceMacStr,
        timestamp: timestamp,
        firebaseEntryId: entryId,
      );

      if (success) {
        result['success'] = (result['success'] as int) + 1;
        (result['processed_entries'] as List<String>).add(entryId);
      } else {
        result['failed'] = (result['failed'] as int) + 1;
        (result['errors'] as List<String>).add('Failed to insert entry $entryId');
      }
    }

    if (kDebugMode) {
      print('Sync complete: ${result['success']} succeeded, ${result['failed']} failed');
    }

    return result;
  }

  Future<bool> syncEntryLocationFromFirebase(String entryId) async {
    if (kDebugMode) {
      print('Syncing single Firebase entry $entryId');
    }

    final entryData = await getFirebaseEntryLocationData(entryId);
    if (entryData == null) {
      if (kDebugMode) {
        print('No Firebase data found for $entryId');
      }
      return false;
    }

    if (await _firebaseEntryAlreadyMigrated(entryId)) {
      if (kDebugMode) {
        print('Skipping Firebase entry $entryId – already migrated to Postgres');
      }
      return true;
    }

    final latitude = entryData['lat'];
    final longitude = entryData['long'];
    final deviceMac = entryData['device_mac'];
    final timestampValue = entryData['timestamp'];

    if (latitude == null || longitude == null || deviceMac == null) {
      if (kDebugMode) {
        print('Entry $entryId missing required fields');
      }
      return false;
    }

    late double latValue;
    late double longValue;
    try {
      latValue = latitude.toDouble();
      longValue = longitude.toDouble();
    } catch (parseError) {
      if (kDebugMode) {
        print('Invalid coordinates for $entryId: $parseError');
      }
      return false;
    }

    final timestamp = _parseTimestamp(timestampValue);
    final deviceMacStr = deviceMac.toString();
    final petId = await _resolvePetForDevice(deviceMacStr);
    if (petId == null) {
      if (kDebugMode) {
        print('Entry $entryId could not be mapped to a pet (device_mac: $deviceMacStr)');
      }
      return false;
    }

    final success = await pushLocation(
      petId: petId,
      latitude: latValue,
      longitude: longValue,
      deviceMac: deviceMacStr,
      timestamp: timestamp,
      firebaseEntryId: entryId,
    );

    return success;
  }

  Future<Map<String, dynamic>?> getLatestPetLocation(String petId) async {
    try {
      return await _fastApi.fetchLatestLocationForPet(petId);
    } catch (error) {
      if (kDebugMode) {
        print('Failed to fetch latest location for pet $petId: $error');
      }
      return null;
    }
  }

  Future<List<Map<String, dynamic>>> getPetLocationHistory(
    String petId, {
    int limit = 100,
    DateTime? startDate,
    DateTime? endDate,
  }) async {
    try {
      final history = await _fastApi.fetchLocationHistory(petId, limit: limit);
      final filtered = history.where((record) {
        if (startDate == null && endDate == null) {
          return true;
        }
        final timestamp = _parseTimestamp(record['timestamp']);
        if (startDate != null && timestamp.isBefore(startDate)) {
          return false;
        }
        if (endDate != null && timestamp.isAfter(endDate)) {
          return false;
        }
        return true;
      }).toList();
      return filtered;
    } catch (error) {
      if (kDebugMode) {
        print('Failed to fetch location history for $petId: $error');
      }
      return [];
    }
  }

  Future<bool> deleteFirebaseLocationEntry(String entryId) async {
    final url = 'https://$_firebaseHost/$entryId.json?auth=$_authKey';
    if (kDebugMode) {
      print('Deleting Firebase entry $entryId');
    }

    try {
      final response = await http.delete(Uri.parse(url));
      if (response.statusCode == 200) {
        return true;
      }
      if (kDebugMode) {
        print('Firebase delete failed for $entryId: ${response.statusCode}');
      }
    } catch (error) {
      if (kDebugMode) {
        print('Exception while deleting Firebase entry $entryId: $error');
      }
    }

    return false;
  }

  Future<Map<String, dynamic>> syncAndCleanup({bool deleteAfterSync = false}) async {
    final result = await syncAllLocationsFromFirebase();

    if (!deleteAfterSync || (result['processed_entries'] as List<String>).isEmpty) {
      return result;
    }

    final entries = await getFirebaseLocationData();
    if (entries == null) {
      return result;
    }

    var deleted = 0;
    for (final entryId in entries.keys) {
      final removed = await deleteFirebaseLocationEntry(entryId);
      if (removed) {
        deleted++;
      }
    }

    result['deleted'] = deleted;
    return result;
  }

  DateTime _parseTimestamp(dynamic candidate) {
    if (candidate == null) {
      return DateTime.now();
    }
    if (candidate is DateTime) {
      return candidate;
    }
    if (candidate is int || candidate is double) {
      final value = candidate is double ? candidate.toInt() : candidate;
      if (value > 1000000000000) {
        return DateTime.fromMillisecondsSinceEpoch(value);
      }
      return DateTime.fromMillisecondsSinceEpoch(value * 1000);
    }
    if (candidate is String) {
      try {
        return DateTime.parse(candidate);
      } catch (_) {
        return DateTime.now();
      }
    }
    return DateTime.now();
  }

  String _normalizeDeviceKey(String deviceId) => deviceId.toLowerCase();

  Future<String?> _resolvePetForDevice(String deviceId) async {
    final cacheKey = _normalizeDeviceKey(deviceId);
    if (_devicePetCache.containsKey(cacheKey)) {
      return _devicePetCache[cacheKey];
    }

    try {
      final mapping = await _fastApi.fetchDeviceForDevice(deviceId);
      final petId = mapping?['pet_id']?.toString();
      _devicePetCache[cacheKey] = petId;
      return petId;
    } catch (error) {
      if (kDebugMode) {
        print('Failed to resolve pet for device $deviceId: $error');
      }
      _devicePetCache[cacheKey] = null;
      return null;
    }
  }

  Future<bool> _firebaseEntryAlreadyMigrated(String entryId) async {
    if (entryId.isEmpty) {
      return false;
    }
    try {
      final existing = await _fastApi.fetchLocationByFirebaseEntry(entryId);
      return existing != null;
    } catch (error) {
      if (kDebugMode) {
        print('Failed to verify Firebase entry $entryId on FastAPI: $error');
      }
      return false;
    }
  }
}

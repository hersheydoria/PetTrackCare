# Firebase to Supabase Location Migration System

## Overview
The PetTrackCare app includes an automatic migration system that transfers location data from Firebase Realtime Database to Supabase. This system runs silently in the background and requires no user intervention.

## System Architecture

### Components
- **LocationSyncService**: Core migration logic for data transfer
- **AutoMigrationService**: Automatic scheduling and user preference management
- **Background Integration**: Seamless execution during app startup

### Data Flow
1. **Firebase Source**: `pettrackcare-default-rtdb.firebaseio.com`
2. **Data Structure**: `{"lat": 14.5995, "long": 120.9842, "device_mac": "00:4B:12:3A:46:44"}`
3. **Supabase Destination**: `location_history` table with `populate_pet_id()` trigger

## Firebase Data Structure

The service fetches Firebase data in the following format:
```json
{
  "lat": 14.5995,
  "long": 120.9842,
  "device_mac": "00:4B:12:3A:46:44"
}
```

## Supabase Table Structure

The data will be inserted into the `location_history` table:
```sql
CREATE TABLE location_history (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  latitude DOUBLE PRECISION NOT NULL,
  longitude DOUBLE PRECISION NOT NULL,
  timestamp TIMESTAMPTZ DEFAULT NOW(),
  device_mac TEXT,
  pet_id UUID, -- Auto-populated by populate_pet_id() trigger
  FOREIGN KEY (pet_id) REFERENCES pets(id) ON DELETE SET NULL
);
```

## How It Works

### Automatic Migration
- **Trigger**: Runs automatically when opening the app on `/home` route
- **Frequency**: Once per day maximum per user
- **User Type**: Pet Owners only (pet sitters are excluded)
- **Background Execution**: Non-blocking, uses `Future.microtask()`

### Migration Process
1. **Initialization**: Check if migration should run (daily limit + user type)
2. **Firebase Data Retrieval**: Fetch all location data using REST API
   - Host: `pettrackcare-default-rtdb.firebaseio.com`
   - Auth: Uses provided auth key
   - Endpoint: Root level location objects
3. **Data Validation**: Verify latitude, longitude, and device MAC address
4. **Supabase Integration**: Insert data into `location_history` table
5. **Pet Association**: Automatic pet ID population via database trigger
6. **Preference Storage**: Update last migration timestamp

### Data Structure Mapping

#### Firebase Format
```json
{
  "lat": 14.5995,
  "long": 120.9842,
  "device_mac": "00:4B:12:3A:46:44"
}
```

#### Supabase Format
```sql
INSERT INTO location_history (latitude, longitude, device_mac, created_at)
VALUES (14.5995, 120.9842, '00:4B:12:3A:46:44', NOW());
```

## Configuration

### Firebase Settings
- **Host**: `pettrackcare-default-rtdb.firebaseio.com`
- **Authentication**: API key-based access
- **Data Path**: Root level location objects

### Supabase Settings
- **Table**: `location_history`
- **Required Fields**: `latitude`, `longitude`, `device_mac`
- **Auto Fields**: `pet_id` (via trigger), `created_at`

### User Preferences (SharedPreferences)
- **Key**: `firebase_migration_enabled` (boolean)
- **Key**: `last_migration_date` (string, YYYY-MM-DD format)
- **Default**: Migration enabled for Pet Owners

## Technical Implementation

### Core Services

#### AutoMigrationService
```dart
class AutoMigrationService {
  // Check if migration should run (daily limit)
  static Future<bool> shouldRunMigration()
  
  // Execute automatic migration in background
  static Future<void> runAutoMigration()
  
  // Enable/disable migration for user
  static Future<void> setMigrationEnabled(bool enabled)
}
```

#### LocationSyncService
```dart
class LocationSyncService {
  // Main migration method
  Future<void> syncAllLocationsFromFirebase()
  
  // Push individual location to Supabase
  Future<void> pushLocationToSupabase(Map<String, dynamic> locationData)
}
```

### Integration Points

#### Main App Integration (main.dart)
```dart
// Automatic migration trigger
void _runAutoMigrationInBackground() {
  Future.microtask(() async {
    await AutoMigrationService.runAutoMigration();
  });
}
```

#### Route-Based Activation
- **Route**: `/home` (Pet Owner dashboard)
- **Method**: Non-blocking background execution
- **User Experience**: Completely transparent

### Manual Migration (Programmatic)

For manual control, use the `AutoMigrationService`:
```dart
import '../services/auto_migration_service.dart';

// Check if migration should run
final shouldRun = await AutoMigrationService.shouldRunMigration();

// Run migration manually
await AutoMigrationService.runAutoMigration();

// Enable/disable auto-migration
await AutoMigrationService.setMigrationEnabled(false); // Disable
await AutoMigrationService.setMigrationEnabled(true);  // Enable

// Direct location sync service
import '../services/location_sync_service.dart';
final locationSync = LocationSyncService();
final results = await locationSync.syncAllLocationsFromFirebase();
```

## Features

### Core Functionality
- ✅ Fetch all location data from Firebase
- ✅ Validate Firebase data structure
- ✅ Insert into Supabase location_history table
- ✅ Auto-map device_mac to pet_id via trigger
- ✅ Batch processing with error handling
- ✅ Detailed error reporting

### Automatic Migration Features
- ✅ **Automatic execution**: Runs when Pet Owners open the app
- ✅ **Smart scheduling**: Once per day maximum (configurable)
- ✅ **User preferences**: Can be enabled/disabled per user
- ✅ **Background processing**: Non-blocking, silent operation
- ✅ **Role-based**: Only Pet Owners (not Sitters) get auto-migration
- ✅ **Error handling**: Graceful failure without app crashes

### Additional Features
- ✅ Sync individual entries
- ✅ Get location history by pet ID
- ✅ Get location history by device MAC
- ✅ Migration status tracking

## Error Handling

### Common Scenarios
- **Network Issues**: Graceful failure with retry capability
- **Invalid Data**: Skip malformed records, continue migration
- **Authentication Errors**: Log error, stop migration attempt
- **Supabase Conflicts**: Handle duplicate entries gracefully

### Logging & Debugging
- Migration attempts and results logged to console (debug mode)
- User preference changes tracked
- Error states preserved for troubleshooting

## User Experience

### Pet Owner Experience
1. Open app normally
2. Navigate to home screen
3. Migration runs automatically in background
4. No UI interruption or loading screens
5. Data available immediately in Supabase

### Pet Sitter Experience
- No migration system active
- Location tracking continues normally
- No background migration processes

## Maintenance & Monitoring

### Daily Operations
- **Automatic Execution**: No manual intervention required
- **Self-Limiting**: Maximum one migration per user per day
- **Resource Efficient**: Background execution prevents UI blocking

### Monitoring Points
- Migration success/failure rates
- Data transfer volumes
- User preference configurations
- Performance impact on app startup

### Configuration Management
- User can disable migration via app settings (if implemented)
- Developer can modify migration frequency
- Firebase credentials managed via environment configuration

## Migration History

### Previous Implementation
- **Version 1.0**: Manual button-triggered migration with UI dialog
- **User Feedback**: Preferred automatic, seamless migration
- **Version 2.0**: Current automatic background system

### Evolution Benefits
- **User Experience**: No manual intervention required
- **Reliability**: Consistent daily execution
- **Performance**: Non-blocking background operation
- **Maintenance**: Reduced support overhead

## Troubleshooting

### Common Issues
1. **Migration Not Running**: Check user type (Pet Owner required)
2. **Data Not Appearing**: Verify Supabase table structure and triggers
3. **Daily Limit**: Migration runs once per day maximum
4. **Network Problems**: Ensure stable internet connection

### Debug Information
- Check console logs for migration attempts
- Verify SharedPreferences for migration settings
- Monitor network requests to Firebase and Supabase
- Validate user authentication and permissions

## Security Considerations

### Data Protection
- Firebase access via secure API key
- Supabase connections use authenticated channels
- Location data encrypted in transit
- No sensitive data stored in local preferences

### Access Control
- Pet Owner authentication required
- Firebase read permissions validated
- Supabase write permissions enforced
- Device MAC address anonymization (if required)

## Future Enhancements

### Potential Improvements
1. **Progress Notifications**: Optional user notifications for large migrations
2. **Selective Migration**: User choice of specific date ranges
3. **Real-time Sync**: Continuous synchronization option
4. **Analytics Dashboard**: Migration statistics and insights
5. **Conflict Resolution**: Advanced handling of duplicate data

### Scalability Considerations
- Batch processing for large datasets
- Rate limiting for API calls
- Incremental migration support
- Archive old Firebase data post-migration

## Database Trigger Requirement

The migration relies on the existing `populate_pet_id()` trigger function that:
1. Takes the `device_mac` from inserted location records
2. Looks up the corresponding `pet_id` from device mapping tables
3. Updates the `pet_id` field in the location record

Make sure this trigger is properly configured in your Supabase database.

## Testing

Run the test script to verify Firebase connectivity:
```bash
cd test
dart location_sync_test.dart
```

This will test Firebase connection and data retrieval without performing actual sync operations.

---

## Summary
The automatic Firebase to Supabase migration system provides a seamless, user-friendly solution for location data transfer. Operating transparently in the background, it ensures Pet Owners' location data is consistently synchronized without manual intervention while maintaining high performance and reliability standards.
import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import '../services/location_sync_service.dart';

// Color palette
const deepRed = Color(0xFFB82132);
const coral = Color(0xFFD2665A);
const peach = Color(0xFFF2B28C);
const lightBlush = Color(0xFFF6DED8);

class FirebaseMigrationDialog extends StatefulWidget {
  @override
  _FirebaseMigrationDialogState createState() => _FirebaseMigrationDialogState();
}

class _FirebaseMigrationDialogState extends State<FirebaseMigrationDialog> {
  final LocationSyncService _locationSyncService = LocationSyncService();
  bool _isLoading = false;
  bool _migrationCompleted = false;
  Map<String, dynamic> _migrationResults = {};
  String _statusMessage = '';

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Row(
        children: [
          Container(
            padding: EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: coral.withOpacity(0.1),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(
              Icons.sync,
              color: coral,
              size: 24,
            ),
          ),
          SizedBox(width: 12),
          Expanded(
            child: Text(
              'Firebase Location Sync',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: deepRed,
              ),
            ),
          ),
        ],
      ),
      content: SingleChildScrollView(
        child: Container(
          width: double.maxFinite,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (!_migrationCompleted) ...[
                Text(
                  'This will retrieve location data from Firebase Realtime Database and sync it to Supabase.',
                  style: TextStyle(
                    fontSize: 14,
                    color: Colors.grey[700],
                  ),
                ),
                SizedBox(height: 16),
                Container(
                  padding: EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.blue.shade50,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.blue.shade200),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        Icons.info_outline,
                        color: Colors.blue,
                        size: 20,
                      ),
                      SizedBox(width: 8),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Migration Details:',
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.bold,
                                color: Colors.blue.shade800,
                              ),
                            ),
                            SizedBox(height: 4),
                            Text(
                              '• Firebase Host: ${dotenv.env['FIREBASE_HOST'] ?? 'Not configured'}\n'
                              '• Data will be copied to Supabase location_history table\n'
                              '• Pet associations will be auto-populated via device MAC',
                              style: TextStyle(
                                fontSize: 12,
                                color: Colors.blue.shade700,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ] else ...[
                // Show migration results
                Container(
                  padding: EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: _migrationResults['success'] != null && _migrationResults['success'] > 0 
                        ? Colors.green.shade50 
                        : Colors.orange.shade50,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: _migrationResults['success'] != null && _migrationResults['success'] > 0 
                          ? Colors.green.shade200 
                          : Colors.orange.shade200,
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(
                            _migrationResults['success'] != null && _migrationResults['success'] > 0 
                                ? Icons.check_circle 
                                : Icons.warning,
                            color: _migrationResults['success'] != null && _migrationResults['success'] > 0 
                                ? Colors.green 
                                : Colors.orange,
                          ),
                          SizedBox(width: 8),
                          Text(
                            'Migration Results',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                              color: _migrationResults['success'] != null && _migrationResults['success'] > 0 
                                  ? Colors.green.shade800 
                                  : Colors.orange.shade800,
                            ),
                          ),
                        ],
                      ),
                      SizedBox(height: 8),
                      if (_migrationResults['success'] != null)
                        Text(
                          'Successfully synced: ${_migrationResults['success']} records',
                          style: TextStyle(
                            fontSize: 14,
                            color: Colors.green.shade700,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      if (_migrationResults['failed'] != null && _migrationResults['failed'] > 0)
                        Text(
                          'Failed: ${_migrationResults['failed']} records',
                          style: TextStyle(
                            fontSize: 14,
                            color: Colors.red.shade700,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      if (_migrationResults['errors'] != null && 
                          (_migrationResults['errors'] as List).isNotEmpty) ...[
                        SizedBox(height: 8),
                        Text(
                          'Errors:',
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.bold,
                            color: Colors.red.shade800,
                          ),
                        ),
                        ...(_migrationResults['errors'] as List).take(3).map(
                          (error) => Padding(
                            padding: EdgeInsets.only(left: 8, top: 2),
                            child: Text(
                              '• $error',
                              style: TextStyle(
                                fontSize: 12,
                                color: Colors.red.shade600,
                              ),
                            ),
                          ),
                        ),
                        if ((_migrationResults['errors'] as List).length > 3)
                          Padding(
                            padding: EdgeInsets.only(left: 8, top: 2),
                            child: Text(
                              '• ... and ${(_migrationResults['errors'] as List).length - 3} more errors',
                              style: TextStyle(
                                fontSize: 12,
                                color: Colors.red.shade600,
                                fontStyle: FontStyle.italic,
                              ),
                            ),
                          ),
                      ],
                    ],
                  ),
                ),
              ],
              
              if (_isLoading) ...[
                SizedBox(height: 16),
                Row(
                  children: [
                    SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        valueColor: AlwaysStoppedAnimation<Color>(coral),
                      ),
                    ),
                    SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        _statusMessage.isNotEmpty ? _statusMessage : 'Syncing location data...',
                        style: TextStyle(
                          fontSize: 14,
                          color: Colors.grey[600],
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _isLoading ? null : () => Navigator.of(context).pop(),
          child: Text(
            _migrationCompleted ? 'Close' : 'Cancel',
            style: TextStyle(color: Colors.grey[600]),
          ),
        ),
        if (!_migrationCompleted)
          ElevatedButton(
            onPressed: _isLoading ? null : _startMigration,
            style: ElevatedButton.styleFrom(
              backgroundColor: coral,
              foregroundColor: Colors.white,
              disabledBackgroundColor: Colors.grey[300],
            ),
            child: Text(_isLoading ? 'Syncing...' : 'Start Sync'),
          ),
        if (_migrationCompleted)
          ElevatedButton(
            onPressed: () {
              // Reset for another migration if needed
              setState(() {
                _migrationCompleted = false;
                _migrationResults = {};
                _statusMessage = '';
              });
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: deepRed,
              foregroundColor: Colors.white,
            ),
            child: Text('Sync Again'),
          ),
      ],
    );
  }

  Future<void> _startMigration() async {
    setState(() {
      _isLoading = true;
      _statusMessage = 'Connecting to Firebase...';
    });

    try {
      // First, check if there's any data in Firebase
      setState(() {
        _statusMessage = 'Checking Firebase data...';
      });

      final firebaseData = await _locationSyncService.getFirebaseLocationData();
      
      if (firebaseData == null || firebaseData.isEmpty) {
        setState(() {
          _isLoading = false;
          _migrationCompleted = true;
          _migrationResults = {
            'success': 0,
            'failed': 0,
            'errors': ['No location data found in Firebase'],
          };
        });
        return;
      }

      setState(() {
        _statusMessage = 'Found ${firebaseData.keys.length} location records. Starting sync...';
      });

      // Wait a bit to show the status message
      await Future.delayed(Duration(seconds: 1));

      // Start the migration
      final results = await _locationSyncService.syncAllLocationsFromFirebase();

      setState(() {
        _isLoading = false;
        _migrationCompleted = true;
        _migrationResults = results;
      });

      // Show success snackbar if migration was successful
      if (results['success'] > 0) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Row(
              children: [
                Icon(Icons.check_circle, color: Colors.white),
                SizedBox(width: 8),
                Text('Successfully synced ${results['success']} location records'),
              ],
            ),
            backgroundColor: Colors.green,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
        );
      }

    } catch (e) {
      setState(() {
        _isLoading = false;
        _migrationCompleted = true;
        _migrationResults = {
          'success': 0,
          'failed': 1,
          'errors': ['Migration failed: $e'],
        };
      });

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Row(
            children: [
              Icon(Icons.error, color: Colors.white),
              SizedBox(width: 8),
              Expanded(child: Text('Migration failed: $e')),
            ],
          ),
          backgroundColor: Colors.red,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
      );
    }
  }
}
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'fastapi_service.dart';

class MissingPetAlertService {
  static final MissingPetAlertService _instance = MissingPetAlertService._internal();
  factory MissingPetAlertService() => _instance;
  MissingPetAlertService._internal();

  Timer? _alertTimer;
  String? _lastMissingPostId; // Changed from int to String for UUID support
  BuildContext? _context;
  bool _isInitialized = false;
  
  // Track which alerts have been shown or dismissed by the user
  Set<String> _shownAlerts = <String>{};
  Set<String> _dismissedAlerts = <String>{};

  // Initialize the service with the app's main context
  void initialize(BuildContext context) {
    print('🔔 MissingPetAlertService: Initializing with context');
    _context = context;
    if (!_isInitialized) {
      // Force reinitialize sets to ensure proper String type when starting fresh
      _resetSets();
      print('🔔 MissingPetAlertService: Starting alert monitoring');
      _startMissingPetAlerts();
      _isInitialized = true;
    } else {
      print('🔔 MissingPetAlertService: Already initialized, just updating context');
    }
  }

  // Force reset sets to ensure proper type initialization
  void _resetSets() {
    _shownAlerts = <String>{};
    _dismissedAlerts = <String>{};
    print('🔔 MissingPetAlertService: Reset alert tracking sets');
  }

  // Update context when navigating between screens
  void updateContext(BuildContext context) {
    print('🔔 MissingPetAlertService: Updating context');
    _context = context;
  }

  // Start monitoring for missing pet posts
  final FastApiService _fastApi = FastApiService.instance;

  void _startMissingPetAlerts() {
    print('🔔 MissingPetAlertService: Starting monitoring timer (every 5 seconds)');
    _alertTimer?.cancel();
    _alertTimer = Timer.periodic(Duration(seconds: 5), (timer) async {
      try {
        print('🔔 MissingPetAlertService: Checking for missing pets...');
        Map<String, dynamic>? currentUser;
        try {
          currentUser = await _fastApi.fetchCurrentUser();
        } catch (e) {
          print('🔔 MissingPetAlertService: Failed to fetch current user: $e');
          return;
        }
        final currentUserId = currentUser?['id']?.toString();
        if (currentUserId == null || _context == null) {
          print('🔔 MissingPetAlertService: No user ID or context, skipping check');
          return;
        }

        print('🔔 MissingPetAlertService: User ID: $currentUserId, Context available: ${_context != null}');

        try {
          final posts = await _fastApi.fetchCommunityPosts(
            limit: 5,
            postType: 'missing',
          );

          final availablePosts = posts
              .where((post) => post['user_id']?.toString() != currentUserId)
              .toList();

          print('🔔 MissingPetAlertService: Query completed successfully');
          print('🔔 MissingPetAlertService: Posts raw result: $availablePosts');
          print('🔔 MissingPetAlertService: Found ${availablePosts.length} missing posts');
          print('🔔 MissingPetAlertService: Posts data type: ${availablePosts.runtimeType}');

          if (availablePosts.isNotEmpty) {
            print('🔔 MissingPetAlertService: First post structure: ${availablePosts[0].keys.toList()}');
            print('🔔 MissingPetAlertService: First post raw: ${availablePosts[0]}');

            for (var post in availablePosts) {
              try {
                print('🔔 MissingPetAlertService: Processing post: ${post['id']} (type: ${post['id']?.runtimeType})');

                final dynamic rawPostId = post['id'];
                final String? postId = rawPostId?.toString();

                if (postId == null || postId.isEmpty) {
                  print('🔔 MissingPetAlertService: ⚠️ Skipping post with invalid ID: $rawPostId');
                  continue;
                }

                print('🔔 MissingPetAlertService: Post ID: $postId, Already shown: ${_shownAlerts.contains(postId)}');

                if (!_shownAlerts.contains(postId) && !_dismissedAlerts.contains(postId)) {
                  print('🔔 MissingPetAlertService: Showing alert for post $postId');
                  _shownAlerts.add(postId);

                  final petName = post['content'] ?? 'A pet';
                  final ownerName = post['user']?['name'] ?? 'Someone';

                  print('🔔 MissingPetAlertService: Pet: $petName, Owner: $ownerName');

                  if (_context != null) {
                    print('🔔 MissingPetAlertService: Showing dialog with context');
                    _showGlobalMissingAlert(post, postId);
                  } else {
                    print('🔔 MissingPetAlertService: ❌ No context available for dialog');
                  }
                  return;
                }
              } catch (e, stackTrace) {
                print('🔔 MissingPetAlertService: ❌ Error processing individual post: $e');
                print('🔔 MissingPetAlertService: Stack trace: $stackTrace');
                continue;
              }
            }
          }
        } catch (e, stackTrace) {
          print('🔔 MissingPetAlertService: ❌ Error in posts query: $e');
          print('🔔 MissingPetAlertService: Stack trace: $stackTrace');
          return;
        }
      } catch (e, stackTrace) {
        print('🔔 MissingPetAlertService: ❌ Error in timer callback: $e');
        print('🔔 MissingPetAlertService: Stack trace: $stackTrace');
      }
    });
  }

  // Show the missing pet alert dialog
  void _showGlobalMissingAlert(Map<String, dynamic> post, String postId) {
    print('🔔 MissingPetAlertService: _showGlobalMissingAlert called for post $postId');
    if (_context == null) {
      print('🔔 MissingPetAlertService: ❌ No context available in _showGlobalMissingAlert');
      return;
    }

    _showAlertWithLocationInfo(post, postId);
  }

  // Helper method to format time ago
  String _formatTimeAgo(DateTime dateTime) {
    final now = DateTime.now();
    final difference = now.difference(dateTime);

    if (difference.inMinutes < 1) {
      return 'just now';
    } else if (difference.inMinutes < 60) {
      return '${difference.inMinutes} minutes ago';
    } else if (difference.inHours < 24) {
      return '${difference.inHours} hours ago';
    } else {
      return '${difference.inDays} days ago';
    }
  }

  // Reverse geocode using Nominatim (OpenStreetMap). Returns display_name or null.
  Future<String?> _reverseGeocode(double lat, double lng) async {
    try {
      final url = Uri.parse('https://nominatim.openstreetmap.org/reverse?format=jsonv2&lat=$lat&lon=$lng');
      final resp = await http.get(url, headers: {'User-Agent': 'PetTrackCare/1.0 (+your-email@example.com)'});
      if (resp.statusCode == 200) {
        final body = jsonDecode(resp.body) as Map<String, dynamic>;
        final display = body['display_name'];
        if (display is String && display.isNotEmpty) return display;
      }
    } catch (_) {}
    return null;
  }

  // Show alert with location processing
  Future<void> _showAlertWithLocationInfo(Map<String, dynamic> post, String postId) async {
    try {
      final content = post['content']?.toString() ?? '';
      final imageUrl = post['image_url']?.toString();
      final posterName = post['user']?['name']?.toString() ?? 'Someone';
      final createdAt = DateTime.tryParse(post['created_at']?.toString() ?? '');
      final timeAgo = createdAt != null 
          ? _formatTimeAgo(createdAt)
          : 'just now';

      // Extract pet name from content
      final petNameMatch = RegExp(r'"([^\"]+)"').firstMatch(content);
      final petName = petNameMatch?.group(1) ?? 'Pet';

      // Process location information
      String locationText = 'Location unknown';
      final latitude = post['latitude'];
      final longitude = post['longitude'];
      final savedAddress = post['address']?.toString();

      if (latitude != null && longitude != null) {
        final lat = double.tryParse(latitude.toString());
        final lng = double.tryParse(longitude.toString());
        
        if (lat != null && lng != null) {
          // Use saved address if available, otherwise try reverse geocoding
          String? address = savedAddress;
          if (address == null || address.isEmpty) {
            print('🔔 MissingPetAlertService: Reverse geocoding coordinates: $lat, $lng');
            address = await _reverseGeocode(lat, lng);
          }
          
          if (address != null && address.isNotEmpty) {
            locationText = address;
          } else {
            // Fallback to coordinates
            locationText = 'Coordinates: ${lat.toStringAsFixed(5)}, ${lng.toStringAsFixed(5)}';
          }
        }
      }

      final lastSeenLocation = _extractField(content, 'Last seen');
      if (lastSeenLocation.isNotEmpty) {
        locationText = lastSeenLocation;
      }

      String timeText = _extractField(content, 'Time');
      if (timeText.isEmpty) {
        timeText = timeAgo;
      }

      print('🔔 MissingPetAlertService: Showing dialog for pet: $petName, poster: $posterName, location: $locationText');

      _showFormattedAlert(petName, posterName, timeText, locationText, imageUrl, content, postId);
    } catch (e, stackTrace) {
      print('🔔 MissingPetAlertService: ❌ Error processing alert location: $e');
      print('🔔 MissingPetAlertService: Stack trace: $stackTrace');
      // Fallback to basic alert
      _showBasicAlert(post, postId);
    }
  }

  void _showBasicAlert(Map<String, dynamic> post, String postId) {
    final content = post['content']?.toString() ?? '';
    final posterName = post['user']?['name']?.toString() ?? 'Someone';
    final petNameMatch = RegExp(r'"([^"]+)"').firstMatch(content);
    final petName = petNameMatch?.group(1) ?? 'Pet';
    
    _showFormattedAlert(petName, posterName, 'Recently', 'Location from post', post['image_url']?.toString(), content, postId);
  }

  void _showFormattedAlert(String petName, String posterName, String timeText, String locationText, String? imageUrl, String originalContent, String postId) {
    showDialog(
      context: _context!,
      barrierDismissible: false,
      builder: (ctx) {
        print('🔔 MissingPetAlertService: Dialog builder called - creating AlertDialog');
        return AlertDialog(
        backgroundColor: Colors.red.shade50,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Icon(Icons.warning, color: Colors.red, size: 28),
                SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'MISSING PET ALERT',
                    style: TextStyle(
                      color: Colors.red.shade700,
                      fontWeight: FontWeight.bold,
                      fontSize: 18,
                    ),
                  ),
                ),
              ],
            ),
            SizedBox(height: 4),
              if (_hasSectionContent(originalContent, 'Additional Details'))
                _buildSection('Additional Details', _extractSection(originalContent, 'Additional Details'), Icons.edit, Colors.orange.shade400),
              if (_hasSectionContent(originalContent, 'Important Notes'))
                _buildSection('Important Notes', _extractSection(originalContent, 'Important Notes'), Icons.warning_amber, Colors.amber.shade400),
              if (_hasSectionContent(originalContent, 'Reward Offered'))
                _buildSection('Reward Offered', _extractSection(originalContent, 'Reward Offered'), Icons.monetization_on, Colors.green.shade400),
              if (_hasSectionContent(originalContent, 'Emergency Contact'))
                _buildSection('Emergency Contact', _extractSection(originalContent, 'Emergency Contact'), Icons.contact_phone, Colors.blue.shade400),
            Text(
              'This alert will only show once',
              style: TextStyle(
                fontSize: 12,
                color: Colors.grey.shade600,
                fontStyle: FontStyle.italic,
              ),
            ),
          ],
        ),
        content: Container(
          width: double.maxFinite,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (imageUrl != null && imageUrl.isNotEmpty)
                Center(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: Image.network(
                      imageUrl,
                      height: 120,
                      width: 120,
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => Container(
                        height: 120,
                        width: 120,
                        decoration: BoxDecoration(
                          color: Colors.grey.shade300,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Icon(Icons.pets, size: 40, color: Colors.grey),
                      ),
                    ),
                  ),
                ),
              SizedBox(height: 12),
              Text(
                'Pet: $petName',
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 16,
                  color: Colors.red.shade700,
                ),
              ),
              SizedBox(height: 8),
              Text(
                'Reported by: $posterName',
                style: TextStyle(fontWeight: FontWeight.w500),
              ),
              Text(
                'Last seen: $timeText',
                style: TextStyle(color: Colors.grey.shade600),
              ),
              SizedBox(height: 8),
              Container(
                padding: EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.blue.shade50,
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: Colors.blue.shade200),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.location_on, size: 16, color: Colors.blue.shade700),
                        SizedBox(width: 4),
                        Text(
                          'Last seen location:',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 12,
                            color: Colors.blue.shade700,
                          ),
                        ),
                      ],
                    ),
                    SizedBox(height: 4),
                    Text(
                      locationText,
                      style: TextStyle(fontSize: 14, color: Colors.blue.shade800),
                    ),
                  ],
                ),
              ),
              SizedBox(height: 12),
              if (_hasSectionContent(originalContent, 'Additional Details'))
                _buildSection('Additional Details', _extractSection(originalContent, 'Additional Details'), Icons.edit, Colors.orange.shade400),
              if (_hasSectionContent(originalContent, 'Important Notes'))
                _buildSection('Important Notes', _extractSection(originalContent, 'Important Notes'), Icons.warning_amber, Colors.amber.shade400),
              if (_hasSectionContent(originalContent, 'Reward Offered'))
                _buildSection('Reward Offered', _extractSection(originalContent, 'Reward Offered'), Icons.monetization_on, Colors.green.shade400),
              if (_hasSectionContent(originalContent, 'Emergency Contact'))
                _buildSection('Emergency Contact', _extractSection(originalContent, 'Emergency Contact'), Icons.contact_phone, Colors.blue.shade400),
              Container(
                padding: EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.orange.shade50,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  '💡 Please keep an eye out for this pet and contact the owner if you see them!',
                  style: TextStyle(
                    fontSize: 12,
                    color: Colors.orange.shade700,
                    fontStyle: FontStyle.italic,
                  ),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              _dismissedAlerts.add(postId); // Mark as dismissed
              Navigator.pop(ctx);
            },
            child: Text(
              'Dismiss',
              style: TextStyle(color: Colors.red),
            ),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.green,
              foregroundColor: Colors.white,
            ),
            onPressed: () {
              _dismissedAlerts.add(postId); // Also mark as dismissed
              Navigator.pop(ctx);
              
              // Navigate to community screen and scroll to the specific post
              print('🔔 MissingPetAlertService: Navigating to community screen with post $postId');
              Navigator.of(_context!).pushNamed(
                '/community',
                arguments: {'postId': postId, 'scrollToPost': true},
              );
            },
            child: Text('Help Find'),
          ),
        ],
      );
      },
    );
  }

  String _extractSection(String content, String label) {
    final escapedLabel = RegExp.escape(label);
    final regex = RegExp('$escapedLabel:\\s*\\n([\\s\\S]+?)(?=\\n\\n|\\z)', caseSensitive: false);
    final match = regex.firstMatch(content);
    if (match != null) {
      return match.group(1)?.trim() ?? '';
    }
    return '';
  }

  bool _hasSectionContent(String content, String label) {
    return _extractSection(content, label).isNotEmpty;
  }

  String _extractField(String content, String label) {
    final escapedLabel = RegExp.escape(label);
    final regex = RegExp('$escapedLabel:\s*(.+?)(?=\n|\z)', caseSensitive: false);
    final match = regex.firstMatch(content);
    if (match != null) {
      return match.group(1)?.trim() ?? '';
    }
    return '';
  }

  Widget _buildSection(String title, String value, IconData icon, Color iconColor) {
    return Container(
      margin: EdgeInsets.symmetric(vertical: 6),
      padding: EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: iconColor.withOpacity(0.2),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: iconColor.withOpacity(0.5)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: iconColor),
          SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(fontWeight: FontWeight.bold, color: iconColor),
                ),
                SizedBox(height: 4),
                Text(
                  value,
                  style: TextStyle(fontSize: 13, color: Colors.grey.shade900),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // Stop the alert service
  void dispose() {
    _alertTimer?.cancel();
    _isInitialized = false;
  }

  // Pause alerts (useful when user is in certain screens)
  void pauseAlerts() {
    print('🔔 MissingPetAlertService: Pausing alerts');
    _alertTimer?.cancel();
  }

  // Resume alerts
  void resumeAlerts() {
    print('🔔 MissingPetAlertService: Resuming alerts');
    if (_isInitialized) {
      _startMissingPetAlerts();
    }
  }

  // Clear the last shown post ID (useful when a pet is marked as found)
  void clearLastMissingPostData() {
    print('🔔 MissingPetAlertService: Clearing last missing post and all alert history');
    _lastMissingPostId = null;
    // Clear shown and dismissed alerts to allow re-showing if needed
    final shownCount = _shownAlerts.length;
    final dismissedCount = _dismissedAlerts.length;
    _shownAlerts.clear();
    _dismissedAlerts.clear();
    print('🔔 MissingPetAlertService: Cleared $shownCount shown alerts and $dismissedCount dismissed alerts');
  }

  // Alias for backward compatibility
  void clearLastMissingPost() {
    clearLastMissingPostData();
  }

  // Reset the alert state for a specific post ID
  void resetAlertForPost(String? postId) {
    if (postId != null) {
      print('🔔 MissingPetAlertService: Resetting alert state for post $postId');
      if (_lastMissingPostId == postId) {
        _lastMissingPostId = null;
      }
      _shownAlerts.remove(postId);
      _dismissedAlerts.remove(postId);
    }
  }

  // Clear all alert tracking (useful for testing or reset)
  void clearAllAlertHistory() {
    print('🔔 MissingPetAlertService: Clearing ALL alert history');
    print('🔔 MissingPetAlertService: - Shown alerts: ${_shownAlerts.length}');
    print('🔔 MissingPetAlertService: - Dismissed alerts: ${_dismissedAlerts.length}');
    _shownAlerts.clear();
    _dismissedAlerts.clear();
    _lastMissingPostId = null;
    print('🔔 MissingPetAlertService: All alert history cleared');
  }

  // Mark a specific alert as dismissed (useful for external dismissal)
  void dismissAlert(String postId) {
    print('🔔 MissingPetAlertService: Dismissing alert for post $postId');
    _dismissedAlerts.add(postId);
  }

  // Test method to show a sample alert (for debugging)
  void showTestAlert() {
    print('🔔 MissingPetAlertService: showTestAlert called');
    if (_context == null) {
      print('🔔 MissingPetAlertService: ❌ No context available for test alert');
      return;
    }
    
    // Create a fake post for testing
    final testPost = {
      'id': 99999,
      'content': 'TEST ALERT: My pet "TestPet" is missing for testing purposes.',
      'image_url': null,
      'created_at': DateTime.now().toIso8601String(),
      'user_id': 'test-user',
      'user': {'name': 'Test User'}
    };
    
    print('🔔 MissingPetAlertService: Showing test alert');
    _showGlobalMissingAlert(testPost, 'test-alert-99999');
  }
}
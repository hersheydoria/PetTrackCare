import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'dart:convert';
import 'package:http/http.dart' as http;

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
    
    // Force reinitialize sets to ensure proper String type 
    _resetSets();
    
    _context = context;
    if (!_isInitialized) {
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
  void _startMissingPetAlerts() {
    print('🔔 MissingPetAlertService: Starting monitoring timer (every 5 seconds)');
    _alertTimer?.cancel();
    _alertTimer = Timer.periodic(Duration(seconds: 5), (timer) async {
      try {
        print('🔔 MissingPetAlertService: Checking for missing pets...');
        final currentUserId = Supabase.instance.client.auth.currentUser?.id;
        if (currentUserId == null || _context == null) {
          print('🔔 MissingPetAlertService: No user ID or context, skipping check');
          return;
        }
        
        print('🔔 MissingPetAlertService: User ID: $currentUserId, Context available: ${_context != null}');

        try {
          final posts = await Supabase.instance.client
              .from('community_posts')
              .select('*, users!inner(name)')
              .eq('type', 'missing')
              .neq('user_id', currentUserId) // Don't show alerts for your own pets
              .order('created_at', ascending: false)
              .limit(5); // Get more posts to check for validity

          print('🔔 MissingPetAlertService: Query completed successfully');
          print('🔔 MissingPetAlertService: Posts raw result: $posts');
          print('🔔 MissingPetAlertService: Found ${posts.length} missing posts');
          print('🔔 MissingPetAlertService: Posts data type: ${posts.runtimeType}');
          
          print('🔔 MissingPetAlertService: Posts is a List with ${posts.length} items');
          if (posts.isNotEmpty) {
            print('🔔 MissingPetAlertService: First post structure: ${posts[0].keys.toList()}');
            print('🔔 MissingPetAlertService: First post raw: ${posts[0]}');
            
            // Check each post to find a valid missing pet alert
            for (var post in posts) {
              try {
                print('🔔 MissingPetAlertService: Processing post: ${post['id']} (type: ${post['id'].runtimeType})');
                
                // Handle postId as String (UUID) from database
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

                  // Get pet name from post content
                  final petName = post['content'] ?? 'A pet';
                  final ownerName = post['users']?['name'] ?? 'Someone';

                  print('🔔 MissingPetAlertService: Pet: $petName, Owner: $ownerName');

                  if (_context != null) {
                    print('🔔 MissingPetAlertService: Showing dialog with context');
                    _showGlobalMissingAlert(post, postId);
                  } else {
                    print('🔔 MissingPetAlertService: ❌ No context available for dialog');
                  }
                  return; // Only show one alert at a time
                }
              } catch (e, stackTrace) {
                print('🔔 MissingPetAlertService: ❌ Error processing individual post: $e');
                print('🔔 MissingPetAlertService: Stack trace: $stackTrace');
                continue; // Continue with next post
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
      final posterName = post['users']?['name']?.toString() ?? 'Someone';
      final createdAt = DateTime.tryParse(post['created_at']?.toString() ?? '');
      final timeAgo = createdAt != null 
          ? _formatTimeAgo(createdAt)
          : 'just now';

      // Extract pet name from content
      final petNameMatch = RegExp(r'"([^"]+)"').firstMatch(content);
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

      // Extract time information from content if available
      String timeText = timeAgo;
      final timeMatch = RegExp(r'on (.+?)\.').firstMatch(content);
      if (timeMatch != null) {
        timeText = timeMatch.group(1) ?? timeAgo;
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
    final posterName = post['users']?['name']?.toString() ?? 'Someone';
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
                    '🚨 MISSING PET ALERT',
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
              style: TextStyle(color: Colors.grey.shade600),
            ),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.blue,
              foregroundColor: Colors.white,
            ),
            onPressed: () {
              _dismissedAlerts.add(postId); // Also mark as dismissed
              Navigator.pop(ctx);
              // Here you could navigate to community screen or show contact info
              ScaffoldMessenger.of(_context!).showSnackBar(
                SnackBar(
                  content: Text('Check the Community tab for more details about this missing pet'),
                  backgroundColor: Colors.blue,
                ),
              );
            },
            child: Text('Help Find'),
          ),
        ],
      );
      },
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
      'users': {'name': 'Test User'}
    };
    
    print('🔔 MissingPetAlertService: Showing test alert');
    _showGlobalMissingAlert(testPost, 'test-alert-99999');
  }
}
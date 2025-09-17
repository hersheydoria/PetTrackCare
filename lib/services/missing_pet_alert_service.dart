import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class MissingPetAlertService {
  static final MissingPetAlertService _instance = MissingPetAlertService._internal();
  factory MissingPetAlertService() => _instance;
  MissingPetAlertService._internal();

  Timer? _alertTimer;
  int? _lastMissingPostId;
  BuildContext? _context;
  bool _isInitialized = false;

  // Initialize the service with the app's main context
  void initialize(BuildContext context) {
    _context = context;
    if (!_isInitialized) {
      _startMissingPetAlerts();
      _isInitialized = true;
    }
  }

  // Update context when navigating between screens
  void updateContext(BuildContext context) {
    _context = context;
  }

  // Start monitoring for missing pet posts
  void _startMissingPetAlerts() {
    _alertTimer?.cancel();
    _alertTimer = Timer.periodic(Duration(seconds: 5), (timer) async {
      try {
        final currentUserId = Supabase.instance.client.auth.currentUser?.id;
        if (currentUserId == null || _context == null) return;

        final posts = await Supabase.instance.client
            .from('community_posts')
            .select('*, users!inner(name)')
            .eq('type', 'missing')
            .neq('user_id', currentUserId) // Don't show alerts for your own pets
            .order('created_at', ascending: false)
            .limit(1);

        if (posts is List && posts.isNotEmpty) {
          final post = posts.first;
          final postId = post['id'] as int?;
          final createdAt = DateTime.tryParse(post['created_at']?.toString() ?? '');

          // Only show alerts for posts created in the last 2 minutes
          final now = DateTime.now();
          final isRecent = createdAt != null && 
              now.difference(createdAt).inMinutes <= 2;

          if (postId != null && 
              postId != _lastMissingPostId && 
              isRecent &&
              _context != null) {
            _lastMissingPostId = postId;
            _showGlobalMissingAlert(post);
            
            // Add haptic feedback for urgency
            HapticFeedback.heavyImpact();
          }
        }
      } catch (e) {
        print('Error in missing pet alert service: $e');
      }
    });
  }

  // Show the missing pet alert dialog
  void _showGlobalMissingAlert(Map<String, dynamic> post) {
    if (_context == null) return;

    final content = post['content'] ?? '';
    final imageUrl = post['image_url']?.toString();
    final posterName = post['users']?['name']?.toString() ?? 'Someone';
    final createdAt = DateTime.tryParse(post['created_at']?.toString() ?? '');
    final timeAgo = createdAt != null 
        ? _formatTimeAgo(createdAt)
        : 'just now';

    // Extract pet name from content
    final petNameMatch = RegExp(r'"([^"]+)"').firstMatch(content);
    final petName = petNameMatch?.group(1) ?? 'Pet';

    showDialog(
      context: _context!,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.red.shade50,
        title: Row(
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
                'Time: $timeAgo',
                style: TextStyle(color: Colors.grey.shade600),
              ),
              SizedBox(height: 12),
              Container(
                padding: EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.orange.shade50,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.orange.shade200),
                ),
                child: Text(
                  content,
                  style: TextStyle(fontSize: 14),
                ),
              ),
              SizedBox(height: 12),
              Container(
                padding: EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.blue.shade50,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  '💡 Please keep an eye out for this pet and contact the owner if you see them!',
                  style: TextStyle(
                    fontSize: 12,
                    color: Colors.blue.shade700,
                    fontStyle: FontStyle.italic,
                  ),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text('Dismiss', style: TextStyle(color: Colors.grey)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red.shade600,
              foregroundColor: Colors.white,
            ),
            onPressed: () {
              Navigator.pop(ctx);
              // Navigate to post detail if route exists
              try {
                Navigator.pushNamed(_context!, '/postDetail', arguments: {
                  'postId': post['id']?.toString(),
                });
              } catch (e) {
                // If route doesn't exist, show a snackbar with the information
                ScaffoldMessenger.of(_context!).showSnackBar(
                  SnackBar(
                    content: Text('Missing pet details: $content'),
                    duration: Duration(seconds: 5),
                  ),
                );
              }
            },
            child: Text('View Details'),
          ),
        ],
      ),
    );
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

  // Stop the alert service
  void dispose() {
    _alertTimer?.cancel();
    _isInitialized = false;
  }

  // Pause alerts (useful when user is in certain screens)
  void pauseAlerts() {
    _alertTimer?.cancel();
  }

  // Resume alerts
  void resumeAlerts() {
    if (_isInitialized) {
      _startMissingPetAlerts();
    }
  }
}
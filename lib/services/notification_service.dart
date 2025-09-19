import 'package:supabase_flutter/supabase_flutter.dart';

/// Sends a notification to all users when a pet is marked missing or found.
/// [petName] - The name of the pet.
/// [type] - 'missing' or 'found'.
/// [postId] - Optional post ID to link the notification to a community post.
Future<void> sendPetAlertToAllUsers({
  required String petName,
  required String type,
  required String actorId,
  String? postId,
}) async {
  final supabase = Supabase.instance.client;
  final message = type == 'missing'
      ? 'Alert: $petName has been marked as missing.'
      : 'Update: $petName has been found!';

  try {
    // Fetch all user IDs
    final users = await supabase.from('users').select('id');
    final userIds = List<String>.from(users.map((u) => u['id'].toString()));
    if (userIds.isEmpty) {
      print('No user IDs found.');
      return;
    }

    // Prepare notification rows
    final notifications = userIds.map((uid) => {
      'user_id': uid, // recipient
      'actor_id': actorId, // user who performed the action
      'message': message,
      'type': type == 'missing' ? 'missing_pet' : 'found_pet',
      'post_id': postId, // link to community post
      'is_read': false,
      'created_at': DateTime.now().toIso8601String(),
    }).toList();

    // Insert notifications in batch and print response
    final response = await supabase.from('notifications').insert(notifications);
    print('Insert response: $response');
    if (response == null || (response is Map && response['error'] != null)) {
      print('Error inserting notifications: ${response?['error'] ?? response}');
    }
    // Note: Local notifications are automatically shown when users receive the database
    // notifications via realtime subscriptions in NotificationScreen. Each user's 
    // notification screen will show a system notification when new rows are inserted.
    print('Pet alert notifications sent to ${userIds.length} users: $message');
  } catch (e) {
    print('Failed to send pet alert notifications: $e');
  }
}

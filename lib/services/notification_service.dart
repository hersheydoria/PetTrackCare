import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'dart:convert';

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
    // For development: show local notifications instead of FCM push notifications
    try {
      final flutterLocalNotificationsPlugin = FlutterLocalNotificationsPlugin();
      
      // Check if the plugin is initialized (should be done in main.dart or notification_screen.dart)
      // Show local notification for the current user
      final currentUser = supabase.auth.currentUser;
      if (currentUser != null) {
        await _showLocalNotification(
          flutterLocalNotificationsPlugin,
          title: 'PetTrackCare: ${type == 'missing' ? 'Missing pet' : 'Pet found'}',
          body: message,
          payload: json.encode({
            'petName': petName,
            'type': type,
            if (postId != null) 'postId': postId,
          }),
        );
      }
    } catch (e) {
      print('Failed to show local notification: $e');
    }
  } catch (e) {
    print('Failed to send pet alert notifications: $e');
  }
}

/// Shows a local notification for development purposes
Future<void> _showLocalNotification(
  FlutterLocalNotificationsPlugin plugin, {
  required String title,
  required String body,
  String? payload,
}) async {
  const androidDetails = AndroidNotificationDetails(
    'pet_alerts',
    'Pet Alerts',
    channelDescription: 'Notifications for missing and found pets',
    importance: Importance.high,
    priority: Priority.high,
    showWhen: true,
  );

  const notificationDetails = NotificationDetails(android: androidDetails);

  await plugin.show(
    DateTime.now().millisecondsSinceEpoch.remainder(100000), // Simple ID based on timestamp
    title,
    body,
    notificationDetails,
    payload: payload,
  );
}

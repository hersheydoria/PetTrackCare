import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:http/http.dart' as http;
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
    // Attempt to send push notifications to devices registered for each user.
    // NOTE: Sending push notifications requires a server key / secure environment.
    // It's strongly recommended to use a Supabase Edge Function or a trusted server
    // to perform the actual push send. If you still want to send from here, you
    // can provide an environment variable (via .env) named FCM_SERVER_KEY and
    // the code below will use the legacy FCM HTTP API. Do NOT hardcode the key
    // into the mobile app in production. A better approach: create an Edge
    // Function that calls FCM and invoke it here with a short-lived token.
    try {
      // Fetch device tokens for all users
      final deviceRows = await supabase.from('user_device_tokens').select('user_id, device_token');
      if (deviceRows != null && deviceRows is List && deviceRows.isNotEmpty) {
        // Map userId -> list of tokens
        final Map<String, Set<String>> tokensByUser = {};
        for (final r in deviceRows) {
          final uid = r['user_id']?.toString();
          final t = r['device_token']?.toString();
          if (uid == null || t == null || t.isEmpty) continue;
          tokensByUser.putIfAbsent(uid, () => <String>{}).add(t);
        }

        // Prepare per-user payloads and send via FCM if server key set
        // Read server key from environment via Supabase client (if using flutter_dotenv)
        // or from Supabase project's secrets / Edge Function. We don't ship a key.
        final serverKey = const String.fromEnvironment('FCM_SERVER_KEY', defaultValue: '');
        if (serverKey.isEmpty) {
          print('FCM server key not provided; skipping push sends. Configure FCM_SERVER_KEY in a secure place or use an Edge Function.');
        } else {
          final allTokens = tokensByUser.values.expand((s) => s).toSet().toList();
          await _sendFcmLegacy(serverKey, allTokens, title: 'PetTrackCare: ${type == 'missing' ? 'Missing pet' : 'Pet found'}', body: message, data: {'petName': petName, 'type': type, if (postId != null) 'postId': postId});
        }
      }
    } catch (e) {
      print('Failed to send push notifications: $e');
    }
  } catch (e) {
    print('Failed to send pet alert notifications: $e');
  }
}

/// Sends a legacy FCM HTTP v1 (legacy) message to the provided device tokens.
/// serverKey must be kept secret and never embedded in a released mobile app.
Future<void> _sendFcmLegacy(String serverKey, List<String> tokens, {required String title, required String body, Map<String, dynamic>? data}) async {
  if (tokens.isEmpty) return;

  // FCM legacy endpoint
  final url = Uri.parse('https://fcm.googleapis.com/fcm/send');

  // Build request. For many tokens, consider batching to <=1000 tokens per request.
  final payload = {
    'registration_ids': tokens,
    'notification': {
      'title': title,
      'body': body,
      'sound': 'default',
    },
    'data': data ?? {},
    'priority': 'high',
  };

  final resp = await http.post(url, headers: {
    'Content-Type': 'application/json',
    'Authorization': 'key=$serverKey',
  }, body: json.encode(payload));

  if (resp.statusCode >= 200 && resp.statusCode < 300) {
    print('FCM send success: ${resp.body}');
  } else {
    print('FCM send failed: ${resp.statusCode} ${resp.body}');
  }
}

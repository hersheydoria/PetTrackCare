import 'package:supabase_flutter/supabase_flutter.dart';

/// Sends a notification to all users when a pet is marked missing or found.
/// [petName] - The name of the pet.
/// [type] - 'missing' or 'found'.
Future<void> sendPetAlertToAllUsers({
  required String petName,
  required String type,
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
      'user_id': uid,
      'message': message,
      'type': type,
      'is_read': false,
      'created_at': DateTime.now().toIso8601String(),
    }).toList();

    // Insert notifications in batch and print response
    final response = await supabase.from('notifications').insert(notifications);
    print('Insert response: $response');
    if (response == null || (response is Map && response['error'] != null)) {
      print('Error inserting notifications: ${response?['error'] ?? response}');
    }
  } catch (e) {
    print('Failed to send pet alert notifications: $e');
  }
}

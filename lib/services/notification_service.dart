import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter/material.dart';
import 'dart:convert';

// Initialize local notifications plugin
final FlutterLocalNotificationsPlugin _localNotifications = FlutterLocalNotificationsPlugin();

/// Initialize system notifications (Android only)
Future<void> initializeSystemNotifications() async {
  const androidSettings = AndroidInitializationSettings('@mipmap/ic_launcher');
  // iOS notifications disabled - only Android notifications will work
  const initSettings = InitializationSettings(
    android: androidSettings,
    iOS: null, // Disable iOS notifications
  );
  
  final initialized = await _localNotifications.initialize(
    initSettings,
    onDidReceiveNotificationResponse: _onNotificationTapped,
  );
  
  print('System notifications initialized: $initialized');
  
  // Check and request notification permissions (Android 13+)
  if (initialized != null && initialized) {
    final permissionGranted = await _localNotifications
        .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
        ?.requestNotificationsPermission();
    print('Notification permission granted: $permissionGranted');
    
    // Test notification to verify setup
    await _showTestNotification();
  }
}

/// Show a test notification to verify setup
Future<void> _showTestNotification() async {
  try {
    const androidDetails = AndroidNotificationDetails(
      'test_channel',
      'Test Notifications',
      channelDescription: 'Test notification channel',
      importance: Importance.high,
      priority: Priority.high,
      icon: '@mipmap/ic_launcher',
      enableVibration: true,
      playSound: true,
    );

    const notificationDetails = NotificationDetails(android: androidDetails);
    
    await _localNotifications.show(
      999,
      'PetTrackCare Test',
      'System notifications are working! 🎉',
      notificationDetails,
    );
    print('Test notification sent successfully');
  } catch (e) {
    print('Failed to send test notification: $e');
  }
}

/// Handle notification tap
void _onNotificationTapped(NotificationResponse response) {
  final payload = response.payload;
  if (payload != null) {
    try {
      final Map<String, dynamic> data = json.decode(payload);
      print('System notification tapped: $data');
      // The main app will handle navigation based on the payload
    } catch (e) {
      print('Error parsing notification payload: $e');
    }
  }
}

/// Show system notification (Android only)
Future<void> _showSystemNotification({
  required String title,
  required String body,
  String? payload,
  String? type,
  String? recipientId, // Added recipient ID to check if current user should receive notification
}) async {
  // Only show notification if the current user is the intended recipient
  final currentUser = Supabase.instance.client.auth.currentUser;
  if (currentUser == null) {
    print('No current user - skipping system notification');
    return;
  }
  
  // If recipientId is specified, only show notification to that user
  if (recipientId != null && currentUser.id != recipientId) {
    print('System notification not for current user (${currentUser.id}) - intended for $recipientId');
    return;
  }

  // Check if user has enabled notifications
  final metadata = currentUser.userMetadata ?? {};
  final notificationPrefs = metadata['notification_preferences'] ?? {'enabled': true};
  final notificationsEnabled = notificationPrefs['enabled'] ?? true;
  
  if (!notificationsEnabled) {
    print('System notifications disabled by user');
    return;
  }

  // Configure notification based on type
  String channelId = 'general_notifications';
  String channelName = 'General Notifications';
  String channelDescription = 'General app notifications';
  
  switch (type) {
    case 'job_request':
    case 'job_accepted':
    case 'job_declined':
    case 'job_completed':
      channelId = 'job_notifications';
      channelName = 'Job Notifications';
      channelDescription = 'Pet sitting job related notifications';
      break;
    case 'missing_pet':
    case 'found_pet':
      channelId = 'emergency_notifications';
      channelName = 'Emergency Notifications';
      channelDescription = 'Missing and found pet alerts';
      break;
    case 'message':
      channelId = 'chat_notifications';
      channelName = 'Chat Messages';
      channelDescription = 'New message notifications';
      break;
    case 'like':
    case 'comment':
    case 'mention':
      channelId = 'community_notifications';
      channelName = 'Community Notifications';
      channelDescription = 'Community interactions and mentions';
      break;
  }

  final androidDetails = AndroidNotificationDetails(
    channelId,
    channelName,
    channelDescription: channelDescription,
    importance: type == 'missing_pet' || type == 'found_pet' ? Importance.max : Importance.high,
    priority: type == 'missing_pet' || type == 'found_pet' ? Priority.max : Priority.high,
    icon: '@mipmap/ic_launcher',
    color: const Color(0xFFB82132),
    enableVibration: true,
    playSound: true,
    showWhen: true,
    enableLights: true,
    autoCancel: true,
    styleInformation: BigTextStyleInformation(body),
  );

  // iOS notifications disabled - only Android notifications will work
  final notificationDetails = NotificationDetails(
    android: androidDetails,
    iOS: null, // Disable iOS notifications
  );

  final id = DateTime.now().millisecondsSinceEpoch.remainder(100000);
  
  try {
    await _localNotifications.show(
      id,
      title,
      body,
      notificationDetails,
      payload: payload,
    );
    print('Android system notification shown: $title');
  } catch (e) {
    print('Failed to show system notification: $e');
  }
}

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
    
    // Show system notification for pet alerts (to all users - will be filtered per user)
    await _showSystemNotification(
      title: type == 'missing' ? '🚨 Missing Pet Alert' : '✅ Pet Found',
      body: message,
      type: type == 'missing' ? 'missing_pet' : 'found_pet',
      recipientId: null, // Pet alerts go to all users, so no specific recipient filtering
      payload: json.encode({
        'type': type == 'missing' ? 'missing_pet' : 'found_pet',
        'postId': postId,
        'petName': petName,
      }),
    );
    
    // Note: Local notifications are automatically shown when users receive the database
    // notifications via realtime subscriptions in NotificationScreen. Each user's 
    // notification screen will show a system notification when new rows are inserted.
    print('Pet alert notifications sent to ${userIds.length} users: $message');
  } catch (e) {
    print('Failed to send pet alert notifications: $e');
  }
}

/// Sends a job-related notification to a specific user.
/// [recipientId] - The user ID who will receive the notification.
/// [actorId] - The user ID who performed the action.
/// [jobId] - The ID of the sitting job.
/// [type] - The type of job notification ('job_request', 'job_accepted', 'job_declined', 'job_completed').
/// [petName] - The name of the pet involved in the job.
/// [actorName] - The name of the user who performed the action.
Future<void> sendJobNotification({
  required String recipientId,
  required String actorId,
  required String jobId,
  required String type,
  required String petName,
  String actorName = '',
}) async {
  final supabase = Supabase.instance.client;
  
  // Generate message based on notification type
  String message;
  switch (type) {
    case 'job_request':
      message = 'New job request for $petName${actorName.isNotEmpty ? ' from $actorName' : ''}';
      break;
    case 'job_accepted':
      message = '${actorName.isNotEmpty ? '$actorName' : 'Sitter'} accepted your job request for $petName';
      break;
    case 'job_declined':
      message = '${actorName.isNotEmpty ? '$actorName' : 'Sitter'} declined your job request for $petName';
      break;
    case 'job_completed':
      message = 'Job for $petName has been marked as completed${actorName.isNotEmpty ? ' by $actorName' : ''}';
      break;
    default:
      message = 'Job update for $petName';
      break;
  }

  try {
    // Insert notification
    await supabase.from('notifications').insert({
      'user_id': recipientId,
      'actor_id': actorId,
      'message': message,
      'type': type,
      'job_id': jobId, // link to the specific job
      'is_read': false,
      'created_at': DateTime.now().toIso8601String(),
    });
    
    // Show system notification for job updates
    String notificationTitle;
    switch (type) {
      case 'job_request':
        notificationTitle = '💼 New Job Request';
        break;
      case 'job_accepted':
        notificationTitle = '✅ Job Accepted';
        break;
      case 'job_declined':
        notificationTitle = '❌ Job Declined';
        break;
      case 'job_completed':
        notificationTitle = '🎉 Job Completed';
        break;
      default:
        notificationTitle = '📋 Job Update';
        break;
    }
    
    await _showSystemNotification(
      title: notificationTitle,
      body: message,
      type: type,
      recipientId: recipientId, // Only show to the intended recipient
      payload: json.encode({
        'type': type,
        'jobId': jobId,
        'petName': petName,
        'actorName': actorName,
      }),
    );
    
    print('Job notification sent: $message to user $recipientId');
  } catch (e) {
    print('Failed to send job notification: $e');
  }
}

/// Sends a community-related notification (like, comment, mention, etc.)
/// [recipientId] - The user ID who will receive the notification.
/// [actorId] - The user ID who performed the action.
/// [type] - The type of community notification ('like', 'comment', 'mention', 'follow').
/// [message] - The notification message.
/// [postId] - Optional post ID for post-related notifications.
/// [commentId] - Optional comment ID for comment-related notifications.
/// [actorName] - The name of the user who performed the action.
Future<void> sendCommunityNotification({
  required String recipientId,
  required String actorId,
  required String type,
  required String message,
  String? postId,
  String? commentId,
  String actorName = '',
}) async {
  final supabase = Supabase.instance.client;
  
  try {
    // Insert notification
    final notificationData = {
      'user_id': recipientId,
      'actor_id': actorId,
      'message': message,
      'type': type,
      'is_read': false,
      'created_at': DateTime.now().toIso8601String(),
    };
    
    if (postId != null) notificationData['post_id'] = postId;
    if (commentId != null) notificationData['comment_id'] = commentId;
    
    await supabase.from('notifications').insert(notificationData);
    
    // Show system notification for community interactions
    String notificationTitle;
    switch (type) {
      case 'like':
        notificationTitle = '❤️ New Like';
        break;
      case 'comment':
        notificationTitle = '💬 New Comment';
        break;
      case 'mention':
        notificationTitle = '👋 You were mentioned';
        break;
      case 'follow':
        notificationTitle = '👥 New Follower';
        break;
      default:
        notificationTitle = '🔔 Community Update';
        break;
    }
    
    await _showSystemNotification(
      title: notificationTitle,
      body: message,
      type: type,
      recipientId: recipientId, // Only show to the intended recipient
      payload: json.encode({
        'type': type,
        'postId': postId,
        'commentId': commentId,
        'actorName': actorName,
      }),
    );
    
    print('Community notification sent: $message to user $recipientId');
  } catch (e) {
    print('Failed to send community notification: $e');
  }
}

/// Sends a message notification
/// [recipientId] - The user ID who will receive the notification.
/// [senderId] - The user ID who sent the message.
/// [senderName] - The name of the sender.
/// [messagePreview] - Preview of the message content.
Future<void> sendMessageNotification({
  required String recipientId,
  required String senderId,
  required String senderName,
  required String messagePreview,
}) async {
  final supabase = Supabase.instance.client;
  
  try {
    // Store message notification in database
    await supabase.from('notifications').insert({
      'user_id': recipientId,
      'actor_id': senderId,
      'message': 'sent you a message: $messagePreview',
      'type': 'message',
      'is_read': false,
      'created_at': DateTime.now().toIso8601String(),
    });
    
    // Show system notification
    await _showSystemNotification(
      title: '💬 $senderName',
      body: messagePreview,
      type: 'message',
      recipientId: recipientId, // Only show to the message recipient
      payload: json.encode({
        'type': 'message',
        'senderId': senderId,
        'senderName': senderName,
      }),
    );
    
    print('Message notification sent: $messagePreview from $senderName to user $recipientId');
  } catch (e) {
    print('Failed to send message notification: $e');
  }
}

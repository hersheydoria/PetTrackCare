import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dart:convert';

// Initialize local notifications plugin
final FlutterLocalNotificationsPlugin _localNotifications = FlutterLocalNotificationsPlugin();

// Global realtime channel for notifications
RealtimeChannel? _globalNotificationChannel;

// Track recently shown notifications to prevent duplicates
final Set<String> _recentNotifications = {};
final Map<String, DateTime> _notificationTimestamps = {};

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
    
    // Setup global realtime subscription for system notifications
    await _setupGlobalNotificationSubscription();
    
    // Setup app lifecycle monitoring for background notifications
    _setupAppLifecycleMonitoring();
  }
}

/// Setup app lifecycle monitoring for background notification handling
void _setupAppLifecycleMonitoring() {
  print('📱 Setting up app lifecycle monitoring for background notifications');
  
  // Listen to app lifecycle changes
  WidgetsBinding.instance.addObserver(_AppLifecycleObserver());
}

/// App lifecycle observer for background notification handling
class _AppLifecycleObserver extends WidgetsBindingObserver {
  DateTime? _lastBackgroundTime;
  
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    print('📱 App lifecycle state changed: $state');
    
    switch (state) {
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
        // App going to background or being closed
        _lastBackgroundTime = DateTime.now();
        print('📱 App went to background at: $_lastBackgroundTime');
        break;
        
      case AppLifecycleState.resumed:
        // App coming back to foreground
        print('📱 App resumed from background');
        if (_lastBackgroundTime != null) {
          final backgroundDuration = DateTime.now().difference(_lastBackgroundTime!);
          print('📱 App was in background for: ${backgroundDuration.inSeconds} seconds');
          
          // Check for missed notifications if app was in background for more than 5 seconds
          if (backgroundDuration.inSeconds > 5) {
            _checkMissedNotifications(_lastBackgroundTime!);
          }
        }
        
        // Reconnect realtime subscription in case it was dropped
        _reconnectRealtimeSubscription();
        break;
        
      case AppLifecycleState.inactive:
        // App is inactive but still visible (e.g., phone call overlay)
        print('📱 App became inactive');
        break;
        
      case AppLifecycleState.hidden:
        // App is hidden but still running
        print('📱 App is hidden');
        break;
    }
  }
}

/// Check for notifications that might have been missed while app was in background
Future<void> _checkMissedNotifications(DateTime since) async {
  final currentUser = Supabase.instance.client.auth.currentUser;
  if (currentUser == null) return;
  
  print('🔍 Checking for missed notifications since: $since');
  
  try {
    final response = await Supabase.instance.client
        .from('notifications')
        .select()
        .eq('user_id', currentUser.id)
        .eq('is_read', false)
        .gte('created_at', since.toIso8601String())
        .order('created_at', ascending: false);
    
    final missedNotifications = List<Map<String, dynamic>>.from(response);
    print('📬 Found ${missedNotifications.length} missed notifications');
    
    // Show system notifications for missed notifications
    for (final notification in missedNotifications) {
      await _showMissedNotification(notification);
      
      // Add small delay between notifications to avoid overwhelming
      await Future.delayed(Duration(milliseconds: 500));
    }
  } catch (e) {
    print('❌ Error checking missed notifications: $e');
  }
}

/// Show system notification for a missed notification
Future<void> _showMissedNotification(Map<String, dynamic> notification) async {
  String title = '🔔 Missed Notification';
  String body = notification['message']?.toString() ?? '';
  String? type = notification['type']?.toString();
  
  // Customize title based on type
  switch (type) {
    case 'like':
      title = '❤️ New Like (while away)';
      break;
    case 'comment':
      title = '💬 New Comment (while away)';
      break;
    case 'message':
      title = '💬 New Message (while away)';
      break;
    case 'job_request':
      title = '🐕 Job Request (while away)';
      break;
    case 'job_accepted':
      title = '✅ Job Accepted (while away)';
      break;
    case 'missing_pet':
      title = '🚨 Missing Pet Alert (while away)';
      break;
    case 'found_pet':
      title = '✅ Pet Found (while away)';
      break;
    default:
      title = '🔔 Missed Notification';
      break;
  }
  
  // Prepare payload
  final payloadMap = <String, dynamic>{};
  if (notification['id'] != null) payloadMap['notificationId'] = notification['id'].toString();
  if (notification['post_id'] != null) payloadMap['postId'] = notification['post_id'].toString();
  if (notification['job_id'] != null) payloadMap['jobId'] = notification['job_id'].toString();
  if (notification['type'] != null) payloadMap['type'] = notification['type'].toString();
  if (notification['actor_id'] != null) payloadMap['senderId'] = notification['actor_id'].toString();
  
  final payloadJson = json.encode(payloadMap);
  
  print('📬 Showing missed notification: $title');
  
  // Show the notification
  await showSystemNotification(
    title: title,
    body: body.isNotEmpty ? body : title,
    type: type,
    recipientId: Supabase.instance.client.auth.currentUser?.id,
    payload: payloadJson,
  );
}

/// Reconnect realtime subscription (in case it was dropped while in background)
Future<void> _reconnectRealtimeSubscription() async {
  print('🔄 Reconnecting realtime subscription after resuming from background');
  await _setupGlobalNotificationSubscription();
}

/// Setup global realtime subscription for system notifications
Future<void> _setupGlobalNotificationSubscription() async {
  final currentUser = Supabase.instance.client.auth.currentUser;
  if (currentUser == null) {
    print('❌ No current user - skipping global notification subscription');
    return;
  }
  
  final userId = currentUser.id;
  print('🌐 Setting up global notification subscription for user: $userId');
  
  // Dispose existing channel if any
  if (_globalNotificationChannel != null) {
    await _globalNotificationChannel!.unsubscribe();
  }
  
  _globalNotificationChannel = Supabase.instance.client.channel('global_notifications_$userId');
  
  _globalNotificationChannel!.onPostgresChanges(
    event: PostgresChangeEvent.insert,
    schema: 'public',
    table: 'notifications',
    filter: PostgresChangeFilter(
      type: PostgresChangeFilterType.eq,
      column: 'user_id',
      value: userId,
    ),
    callback: (payload) async {
      print('🌐 *** REALTIME EVENT RECEIVED ***');
      print('   Event: ${payload.eventType}');
      print('   Table: ${payload.table}');
      print('   Schema: ${payload.schema}');
      print('   User ID filter: $userId');
      print('   Full payload: $payload');
      print('   New record: ${payload.newRecord}');
      print('   Old record: ${payload.oldRecord}');
      
      final newRow = payload.newRecord;
      
      // Build notification title and body
      String title = '🔔 New Notification';
      String body = newRow['message']?.toString() ?? '';
      String? type = newRow['type']?.toString();
      
      // Customize title based on type
      switch (type) {
        case 'like':
          title = '❤️ New Like';
          break;
        case 'comment':
          title = '💬 New Comment';
          break;
        case 'message':
          title = '💬 New Message';
          print('🔔 Processing MESSAGE notification in global subscription');
          break;
        case 'job_request':
          title = '🐕 Job Request';
          break;
        case 'job_accepted':
          title = '✅ Job Accepted';
          break;
        case 'missing_pet':
          title = '🚨 Missing Pet Alert';
          break;
        case 'found_pet':
          title = '✅ Pet Found';
          break;
        default:
          title = '🔔 New Notification';
          break;
      }
      
      // Prepare payload for navigation
      final payloadMap = <String, dynamic>{};
      if (newRow['id'] != null) payloadMap['notificationId'] = newRow['id'].toString();
      if (newRow['post_id'] != null) payloadMap['postId'] = newRow['post_id'].toString();
      if (newRow['job_id'] != null) payloadMap['jobId'] = newRow['job_id'].toString();
      if (newRow['type'] != null) payloadMap['type'] = newRow['type'].toString();
      if (newRow['actor_id'] != null) {
        payloadMap['senderId'] = newRow['actor_id'].toString();
        // For message notifications, try to get sender name
        if (type == 'message') {
          try {
            final actorResponse = await Supabase.instance.client
                .from('users')
                .select('name')
                .eq('id', newRow['actor_id'])
                .single();
            payloadMap['senderName'] = actorResponse['name'] ?? 'Someone';
          } catch (e) {
            payloadMap['senderName'] = 'Someone';
          }
        }
      }
      final payloadJson = json.encode(payloadMap);
      
      print('🔔 Showing global system notification: $title');
      print('   Type: $type');
      print('   Body: ${body.isNotEmpty ? body : title}');
      print('   Recipient: $userId');
      print('   Payload: $payloadJson');
      
      if (type == 'message') {
        print('🔔 *** ABOUT TO SHOW MESSAGE SYSTEM NOTIFICATION ***');
        print('   Title: $title');
        print('   Body: ${body.isNotEmpty ? body : title}');
        print('   Type: $type');
        print('   Recipient ID: $userId');
      }
      
      // Show system notification directly
      await showSystemNotification(
        title: title,
        body: body.isNotEmpty ? body : title,
        type: type,
        recipientId: userId, // Current user should receive this notification
        payload: payloadJson,
      );
      
      if (type == 'message') {
        print('🔔 *** MESSAGE SYSTEM NOTIFICATION CALL COMPLETED ***');
      }
    },
  );
  
  print('🔗 Subscribing to global notification channel...');
  
  try {
    await _globalNotificationChannel!.subscribe();
    print('✅ Successfully subscribed to global notifications for user: $userId');
  } catch (e) {
    print('❌ Failed to subscribe to global notifications. Error: $e');
  }
}

/// Reinitialize global notification subscription (call after user login)
Future<void> reinitializeNotificationSubscription() async {
  print('🔄 Reinitializing global notification subscription...');
  await _setupGlobalNotificationSubscription();
}

Future<void> testCommunityNotification() async {
  final user = Supabase.instance.client.auth.currentUser;
  if (user == null) {
    print('❌ No user logged in for test');
    return;
  }
  
  print('🧪 Testing community notification flow...');
  await sendCommunityNotification(
    recipientId: user.id, // Send to self for testing
    actorId: user.id,
    type: 'like',
    message: 'Test User liked your post',
    postId: 'test-post-123',
    actorName: 'Test User',
  );
}

/// PUBLIC: Test message notification flow
Future<void> testMessageNotification() async {
  final user = Supabase.instance.client.auth.currentUser;
  if (user == null) {
    print('❌ No user logged in for test');
    return;
  }
  
  print('🧪 Testing message notification flow...');
  
  // Test 1: Direct database insert to test realtime subscription
  print('🧪 Step 1: Testing direct database insert...');
  try {
    final directInsertData = {
      'user_id': user.id,
      'actor_id': user.id,
      'message': 'Test direct insert message notification',
      'type': 'message',
      'is_read': false,
      'created_at': DateTime.now().toIso8601String(),
    };
    print('   Direct insert data: $directInsertData');
    
    final directResult = await Supabase.instance.client
        .from('notifications')
        .insert(directInsertData);
    print('✅ Direct insert result: $directResult');
  } catch (e) {
    print('❌ Direct insert failed: $e');
  }
  
  // Test 2: Using sendMessageNotification function
  print('🧪 Step 2: Testing sendMessageNotification function...');
  await sendMessageNotification(
    recipientId: user.id, // Send to self for testing
    senderId: user.id,
    senderName: 'Test User',
    messagePreview: 'This is a test message notification via function',
  );
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

/// Show system notification (Android only) - Public function for use across the app
Future<void> showSystemNotification({
  required String title,
  required String body,
  String? payload,
  String? type,
  String? recipientId, // Added recipient ID to check if current user should receive notification
}) async {
  print('\n🔔 ========== showSystemNotification CALLED ==========');
  print('   Title: $title');
  print('   Body: $body');
  print('   Type: $type');
  print('   Recipient ID: $recipientId');
  
  // Only show notification if the current user is the intended recipient
  final currentUser = Supabase.instance.client.auth.currentUser;
  if (currentUser == null) {
    print('⚠️ No user logged in - cannot show notification');
    return;
  }

  // If recipientId is specified, only show notification to that user
  if (recipientId != null && currentUser.id != recipientId) {
    // Skip silently - notification not for this user (this is normal behavior)
    print('⏭️  Skipping notification - intended for $recipientId, current user is ${currentUser.id}');
    return;
  }
  
  print('✅ Recipient match confirmed - will show notification to ${currentUser.id}');

  // Deduplication: Create a unique key for this notification
  final notificationKey = '${recipientId ?? currentUser.id}:$type:$title:$body';
  final now = DateTime.now();
  
  // Check if we've shown this notification recently (within last 5 seconds)
  if (_recentNotifications.contains(notificationKey)) {
    final lastShown = _notificationTimestamps[notificationKey];
    if (lastShown != null && now.difference(lastShown).inSeconds < 5) {
      print('⏭️  DUPLICATE NOTIFICATION BLOCKED - shown ${now.difference(lastShown).inSeconds}s ago');
      return;
    }
  }
  
  // Add to recent notifications
  _recentNotifications.add(notificationKey);
  _notificationTimestamps[notificationKey] = now;
  
  // Clean up old entries (older than 10 seconds)
  _notificationTimestamps.removeWhere((key, timestamp) {
    final shouldRemove = now.difference(timestamp).inSeconds > 10;
    if (shouldRemove) {
      _recentNotifications.remove(key);
    }
    return shouldRemove;
  });
  
  print('✅ New notification - will show (key: $notificationKey)');

  // Check if user has enabled notifications
  final metadata = currentUser.userMetadata ?? {};
  final notificationPrefs = metadata['notification_preferences'] ?? {'enabled': true};
  final notificationsEnabled = notificationPrefs['enabled'] ?? true;
  
  if (!notificationsEnabled) {
    print('⚠️ Notifications disabled by user in preferences');
    return;
  }
  
  print('✓ User check passed, preparing notification...');  // Configure notification based on type
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
    // Debug: Show notification attempt (only for important info, not spam)
    print('📱 Showing notification: $title');
    
    await _localNotifications.show(
      id,
      title,
      body,
      notificationDetails,
      payload: payload,
    );
    
    print('✅ Notification displayed successfully');
  } catch (e) {
    // Important: Log errors to help debug notification issues
    print('❌ Failed to display notification: $e');
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
    await showSystemNotification(
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
      'job_id': jobId.isNotEmpty ? jobId : null, // Only set if jobId is not empty
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
    
    print('📤 Attempting to send system notification: $notificationTitle to user $recipientId');
    
    await showSystemNotification(
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
    
    print('✅ Job notification sent successfully');
  } catch (e) {
    print('❌ Error sending job notification: $e');
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
  
  print('🏘️ sendCommunityNotification called:');
  print('   Recipient ID: $recipientId');
  print('   Actor ID: $actorId');
  print('   Type: $type');
  print('   Message: $message');
  print('   Post ID: $postId');
  print('   Actor Name: $actorName');
  
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
    
    print('💾 Inserting notification into database...');
    print('   Data: $notificationData');
    
    final insertResult = await supabase.from('notifications').insert(notificationData);
    print('✅ Community notification inserted - Response: $insertResult');
    
    // Verify the insert by querying the database
    try {
      final verifyQuery = await supabase
        .from('notifications')
        .select()
        .eq('user_id', recipientId)
        .eq('type', type)
        .order('created_at', ascending: false)
        .limit(1);
      print('🔍 Verification query result: $verifyQuery');
    } catch (e) {
      print('⚠️ Failed to verify notification insert: $e');
    }
    
    
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
    
    print('📱 Calling showSystemNotification...');
    await showSystemNotification(
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
    
    print('✅ Community notification process completed: $message to user $recipientId');
  } catch (e) {
    print('❌ Failed to send community notification: $e');
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
  
  print('📨 sendMessageNotification called:');
  print('   Recipient ID: $recipientId');
  print('   Sender ID: $senderId');
  print('   Sender Name: $senderName');
  print('   Message Preview: $messagePreview');
  
  try {
    // Store message notification in database
    print('💾 Storing message notification in database...');
    final notificationData = {
      'user_id': recipientId,
      'actor_id': senderId,
      'message': 'sent you a message: $messagePreview',
      'type': 'message',
      'is_read': false,
      'created_at': DateTime.now().toIso8601String(),
    };
    print('   Notification data: $notificationData');
    
    final insertResult = await supabase.from('notifications').insert(notificationData);
    print('✅ Message notification inserted - Response: $insertResult');
    
    // Verify the insert by querying the database
    try {
      final verifyQuery = await supabase
        .from('notifications')
        .select()
        .eq('user_id', recipientId)
        .eq('type', 'message')
        .order('created_at', ascending: false)
        .limit(1);
      print('🔍 Message notification verification query result: $verifyQuery');
    } catch (e) {
      print('⚠️ Failed to verify message notification insert: $e');
    }
    
    // Show system notification
    print('🔔 Calling showSystemNotification...');
    await showSystemNotification(
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
    
    print('✅ Message notification process completed: $messagePreview from $senderName to user $recipientId');
  } catch (e) {
    print('❌ Failed to send message notification: $e');
  }
}

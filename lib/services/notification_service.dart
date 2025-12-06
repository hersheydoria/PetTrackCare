import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'fastapi_service.dart';

final FlutterLocalNotificationsPlugin _localNotifications = FlutterLocalNotificationsPlugin();
final Set<String> _recentNotifications = {};
final Map<String, DateTime> _notificationTimestamps = {};
final Set<String> _deliveredNotificationIds = {};
Timer? _notificationPollTimer;
const Duration _notificationPollInterval = Duration(seconds: 20);
bool _lifecycleObserverRegistered = false;
Map<String, dynamic>? _cachedUserData;

Future<void> initializeSystemNotifications() async {
  const androidSettings = AndroidInitializationSettings('@mipmap/ic_launcher');
  const initSettings = InitializationSettings(android: androidSettings, iOS: null);

  final initialized = await _localNotifications.initialize(
    initSettings,
    onDidReceiveNotificationResponse: _onNotificationTapped,
  );

  print('System notifications initialized: $initialized');

  if (initialized == true) {
    await _refreshCurrentUser();
    await _pollNotifications();
    _startNotificationPolling();
    _setupAppLifecycleMonitoring();
  }
}

Future<void> _refreshCurrentUser() async {
  try {
    _cachedUserData = await FastApiService.instance.fetchCurrentUser();
  } catch (e) {
    print('Unable to refresh current user data: $e');
  }
}

String? get _currentUserId => _cachedUserData?['id']?.toString();
Map<String, dynamic> get _currentUserMetadata {
  final metadata = _cachedUserData?['metadata'];
  if (metadata is Map<String, dynamic>) {
    return metadata;
  }
  if (metadata is String && metadata.isNotEmpty) {
    try {
      return Map<String, dynamic>.from(jsonDecode(metadata) as Map);
    } catch (_) {
      return {};
    }
  }
  return {};
}

void _setupAppLifecycleMonitoring() {
  if (_lifecycleObserverRegistered) return;
  WidgetsBinding.instance.addObserver(_AppLifecycleObserver());
  _lifecycleObserverRegistered = true;
}

class _AppLifecycleObserver extends WidgetsBindingObserver {
  DateTime? _lastBackgroundTime;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    print('📱 App lifecycle state changed: $state');

    switch (state) {
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
        _lastBackgroundTime = DateTime.now();
        print('📱 App went to background at: $_lastBackgroundTime');
        _stopNotificationPolling();
        break;
      case AppLifecycleState.resumed:
        print('📱 App resumed from background');
        _refreshCurrentUser();
        _pollNotifications(since: _lastBackgroundTime);
        _startNotificationPolling();
        if (_lastBackgroundTime != null) {
          _checkMissedNotifications(_lastBackgroundTime!);
        }
        break;
      case AppLifecycleState.inactive:
      case AppLifecycleState.hidden:
        break;
    }
  }
}

Future<void> _checkMissedNotifications(DateTime since) async {
  await _pollNotifications(since: since);
}

void _startNotificationPolling() {
  _notificationPollTimer?.cancel();
  _notificationPollTimer = Timer.periodic(_notificationPollInterval, (_) {
    _pollNotifications();
  });
}

void _stopNotificationPolling() {
  _notificationPollTimer?.cancel();
  _notificationPollTimer = null;
}

Future<void> _pollNotifications({DateTime? since}) async {
  try {
    final notifications = await FastApiService.instance.fetchNotifications();
    final entries = notifications.where((notification) {
      final id = notification['id']?.toString();
      if (id == null || id.isEmpty) return false;
      if (_deliveredNotificationIds.contains(id)) return false;
      if (since != null) {
        final timestamp = _parseTimestamp(notification['created_at']);
        if (timestamp == null || !timestamp.isAfter(since)) return false;
      }
      return true;
    }).toList();

    if (entries.isEmpty) return;

    entries.sort((a, b) {
      final aTime = _parseTimestamp(a['created_at']) ?? DateTime.now();
      final bTime = _parseTimestamp(b['created_at']) ?? DateTime.now();
      return aTime.compareTo(bTime);
    });

    for (final notification in entries) {
      await _handleIncomingNotification(notification);
    }
  } catch (e) {
    print('❌ Failed to poll notifications: $e');
  }
}

Future<void> _handleIncomingNotification(Map<String, dynamic> notification) async {
  final id = notification['id']?.toString();
  if (id == null || id.isEmpty) return;
  if (_deliveredNotificationIds.contains(id)) return;
  _deliveredNotificationIds.add(id);
  if (_deliveredNotificationIds.length > 250) {
    _deliveredNotificationIds.remove(_deliveredNotificationIds.first);
  }

  final title = _titleForNotification(notification['type']?.toString(), missed: true);
  await _showNotificationFromRecord(notification, title);
}

Future<void> _showNotificationFromRecord(Map<String, dynamic> notification, String title) async {
  final message = notification['message']?.toString() ?? 'You have a new notification';
  final type = notification['type']?.toString();
  final payload = _buildPayloadFromNotification(notification);
  await showSystemNotification(
    title: title,
    body: message,
    type: type,
    recipientId: notification['user_id']?.toString(),
    payload: payload.isNotEmpty ? json.encode(payload) : null,
  );
}

DateTime? _parseTimestamp(dynamic value) {
  try {
    final str = value?.toString();
    if (str == null || str.isEmpty) return null;
    return DateTime.parse(str);
  } catch (_) {
    return null;
  }
}

Map<String, dynamic> _buildPayloadFromNotification(Map<String, dynamic> notification) {
  final payload = <String, dynamic>{};
  payload['notificationId'] = notification['id']?.toString();
  if (notification['post_id'] != null) payload['postId'] = notification['post_id'].toString();
  if (notification['job_id'] != null) payload['jobId'] = notification['job_id'].toString();
  if (notification['actor_id'] != null) payload['senderId'] = notification['actor_id'].toString();
  if (notification['type'] != null) payload['type'] = notification['type'].toString();
  final metadata = notification['metadata'];
  if (metadata is Map<String, dynamic>) {
    payload.addAll(metadata);
  }
  return payload;
}

String _titleForNotification(String? type, {bool missed = false}) {
  switch (type) {
    case 'like':
      return missed ? '❤️ New Like (while away)' : '❤️ New Like';
    case 'comment':
      return missed ? '💬 New Comment (while away)' : '💬 New Comment';
    case 'message':
      return missed ? '💬 New Message (while away)' : '💬 New Message';
    case 'job_request':
      return missed ? '🐕 Job Request (while away)' : '🐕 Job Request';
    case 'job_accepted':
      return missed ? '✅ Job Accepted (while away)' : '✅ Job Accepted';
    case 'missing_pet':
      return missed ? '🚨 Missing Pet Alert (while away)' : '🚨 Missing Pet Alert';
    case 'found_pet':
      return missed ? '✅ Pet Found (while away)' : '✅ Pet Found';
    default:
      return missed ? '🔔 Missed Notification' : '🔔 New Notification';
  }
}

/// Handle notification tap
void _onNotificationTapped(NotificationResponse response) {
  final payload = response.payload;
  if (payload != null) {
    try {
      final Map<String, dynamic> data = json.decode(payload);
      print('System notification tapped: $data');
    } catch (e) {
      print('Error parsing notification payload: $e');
    }
  }
}

Future<void> showSystemNotification({
  required String title,
  required String body,
  String? payload,
  String? type,
  String? recipientId,
}) async {
  if (_currentUserId == null) {
    await _refreshCurrentUser();
  }

  final currentUserId = _currentUserId;
  if (currentUserId == null) {
    print('⚠️ No user context available - skipping notification');
    return;
  }

  if (recipientId != null && currentUserId != recipientId) {
    print('⏭️ Skipping notification for $recipientId (current user $currentUserId)');
    return;
  }

  final notificationKey = '${recipientId ?? currentUserId}:$type:$title:$body';
  final now = DateTime.now();

  if (_recentNotifications.contains(notificationKey)) {
    final lastShown = _notificationTimestamps[notificationKey];
    if (lastShown != null && now.difference(lastShown).inSeconds < 5) {
      print('⏭️ Duplicate notification suppressed: $title');
      return;
    }
  }

  _recentNotifications.add(notificationKey);
  _notificationTimestamps[notificationKey] = now;
  _notificationTimestamps.removeWhere((key, timestamp) {
    final shouldRemove = now.difference(timestamp).inSeconds > 10;
    if (shouldRemove) {
      _recentNotifications.remove(key);
    }
    return shouldRemove;
  });

  final notificationPrefs =
      (_currentUserMetadata['notification_preferences'] as Map<String, dynamic>?) ?? {'enabled': true};
  final notificationsEnabled = notificationPrefs['enabled'] ?? true;

  if (notificationsEnabled != true) {
    print('⚠️ Notifications disabled by user preferences');
    return;
  }

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

  final notificationDetails = NotificationDetails(android: androidDetails, iOS: null);

  final id = DateTime.now().millisecondsSinceEpoch.remainder(100000);
  try {
    print('📱 Showing notification: $title');
    await _localNotifications.show(id, title, body, notificationDetails, payload: payload);
    print('✅ Notification displayed successfully');
  } catch (e) {
    print('❌ Failed to display notification: $e');
  }
}

Future<void> reinitializeNotificationSubscription() async {
  print('🔄 Reinitializing notification polling...');
  await _refreshCurrentUser();
  _startNotificationPolling();
  await _pollNotifications();
}

Future<void> _createNotificationForUser({
  required String recipientId,
  required String message,
  required String type,
  String? actorId,
  String? postId,
  String? jobId,
  Map<String, dynamic>? metadata,
}) async {
  final payload = {
    'user_id': recipientId,
    if (actorId != null) 'actor_id': actorId,
    'message': message,
    'type': type,
    if (postId != null) 'post_id': postId,
    if (jobId != null) 'job_id': jobId,
    'metadata': metadata ?? {},
  };
  await FastApiService.instance.createNotification(payload);
}

Future<void> sendPetAlertToAllUsers({
  required String petName,
  required String type,
  required String actorId,
  String? postId,
}) async {
  try {
    final recipients = await FastApiService.instance.fetchAllUserIds(pageSize: 200);
    final message = type == 'missing'
        ? 'Alert: $petName has been marked as missing.'
        : 'Update: $petName has been found!';

    for (final recipientId in recipients) {
      await _createNotificationForUser(
        recipientId: recipientId,
        message: message,
        type: type == 'missing' ? 'missing_pet' : 'found_pet',
        actorId: actorId,
        postId: postId,
        metadata: {
          'petName': petName,
          if (postId != null) 'postId': postId,
        },
      );
    }

    await showSystemNotification(
      title: type == 'missing' ? '🚨 Missing Pet Alert' : '✅ Pet Found',
      body: message,
      type: type == 'missing' ? 'missing_pet' : 'found_pet',
      payload: json.encode({
        'type': type == 'missing' ? 'missing_pet' : 'found_pet',
        'postId': postId,
        'petName': petName,
      }),
    );
    print('Pet alert notifications sent to ${recipients.length} users: $message');
  } catch (e) {
    print('Failed to send pet alert notifications: $e');
  }
}

Future<void> sendJobNotification({
  required String recipientId,
  required String actorId,
  required String jobId,
  required String type,
  required String petName,
  String actorName = '',
}) async {
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
    await _createNotificationForUser(
      recipientId: recipientId,
      message: message,
      type: type,
      actorId: actorId,
      jobId: jobId.isNotEmpty ? jobId : null,
      metadata: {
        'petName': petName,
        if (actorName.isNotEmpty) 'actorName': actorName,
      },
    );
    await showSystemNotification(
      title: _titleForNotification(type),
      body: message,
      type: type,
      recipientId: recipientId,
      payload: json.encode({
        'type': type,
        'jobId': jobId,
        'petName': petName,
        'actorName': actorName,
      }),
    );
  } catch (e) {
    print('❌ Error sending job notification: $e');
  }
}

Future<void> sendCommunityNotification({
  required String recipientId,
  required String actorId,
  required String type,
  required String message,
  String? postId,
  String? commentId,
  String actorName = '',
}) async {
  try {
    await _createNotificationForUser(
      recipientId: recipientId,
      message: message,
      type: type,
      actorId: actorId,
      metadata: {
        if (postId != null) 'postId': postId,
        if (commentId != null) 'commentId': commentId,
        if (actorName.isNotEmpty) 'actorName': actorName,
      },
    );
    final notificationTitle = _titleForNotification(type);
    await showSystemNotification(
      title: notificationTitle,
      body: message,
      type: type,
      recipientId: recipientId,
      payload: json.encode({
        'type': type,
        'postId': postId,
        'commentId': commentId,
        'actorName': actorName,
      }),
    );
  } catch (e) {
    print('❌ Failed to send community notification: $e');
  }
}

Future<void> sendMessageNotification({
  required String recipientId,
  required String senderId,
  required String senderName,
  required String messagePreview,
}) async {
  try {
    await _createNotificationForUser(
      recipientId: recipientId,
      message: 'sent you a message: $messagePreview',
      type: 'message',
      actorId: senderId,
      metadata: {
        'senderName': senderName,
      },
    );
    await showSystemNotification(
      title: '💬 $senderName',
      body: messagePreview,
      type: 'message',
      recipientId: recipientId,
      payload: json.encode({
        'type': 'message',
        'senderId': senderId,
        'senderName': senderName,
      }),
    );
  } catch (e) {
    print('❌ Failed to send message notification: $e');
  }
}

Future<void> testCommunityNotification() async {
  if (_currentUserId == null) {
    await _refreshCurrentUser();
  }
  final userId = _currentUserId;
  if (userId == null) {
    print('❌ No user logged in for community notification test');
    return;
  }
  print('🧪 Testing community notification flow...');
  await sendCommunityNotification(
    recipientId: userId,
    actorId: userId,
    type: 'like',
    message: 'Test User liked your post',
    actorName: 'Test User',
  );
}

Future<void> testMessageNotification() async {
  if (_currentUserId == null) {
    await _refreshCurrentUser();
  }
  final userId = _currentUserId;
  if (userId == null) {
    print('❌ No user logged in for message notification test');
    return;
  }
  print('🧪 Testing message notification flow...');
  await sendMessageNotification(
    recipientId: userId,
    senderId: userId,
    senderName: 'Test User',
    messagePreview: 'This is a test message notification via function',
  );
}

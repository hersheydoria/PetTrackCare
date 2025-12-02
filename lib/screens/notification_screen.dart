import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'dart:convert';
import '../services/fastapi_service.dart';
import '../services/notification_service.dart';
import 'chat_detail_screen.dart';

// Color palette
const deepRed = Color(0xFFB82132);
const coral = Color(0xFFF2B28C);
const peach = Color(0xFFF2B28C);
const lightBlush = Color(0xFFF6DED8);

class NotificationScreen extends StatefulWidget {
  const NotificationScreen({super.key});

  @override
  _NotificationScreenState createState() => _NotificationScreenState();
}

class _NotificationScreenState extends State<NotificationScreen> {
  final _fastApi = FastApiService.instance;
  List<Map<String, dynamic>> notifications = [];
  bool isLoading = true;

  final FlutterLocalNotificationsPlugin _localNotifications = FlutterLocalNotificationsPlugin();
  final Map<String, Map<String, dynamic>> _userCache = {};
  final Map<String, String?> _avatarCache = {};
  final Set<String> _seenNotificationIds = {};
  Timer? _pollingTimer;
  bool _isRefreshing = false;
  String? _currentUserId;
  bool _authFailed = false;

  @override
  void initState() {
    super.initState();
    _initLocalNotifications();
    _initNotifications();
  }

  @override
  void dispose() {
    _pollingTimer?.cancel();
    super.dispose();
  }

  Future<void> _initLocalNotifications() async {
    const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
    await _localNotifications.initialize(
      InitializationSettings(android: androidInit),
      onDidReceiveNotificationResponse: (response) {
        // Called when user taps a notification
        final payload = response.payload;
        if (payload != null && payload.isNotEmpty) {
          _handleNotificationPayloadTap(payload);
        }
      },
    );
  }

  Future<void> _initNotifications() async {
    if (!_fastApi.hasToken) {
      setState(() => isLoading = false);
      return;
    }

    try {
      final user = await _fastApi.fetchCurrentUser();
      _currentUserId = user['id']?.toString();
    } catch (e) {
      print('❌ Failed to load current user for notifications: $e');
      if (e.toString().contains('401')) {
        await _handleAuthFailure();
        return;
      }
    }

    if (_currentUserId == null) {
      setState(() => isLoading = false);
      return;
    }

    await _refreshNotifications();
    _startPolling();
  }

  Future<void> _showLocalNotification(Map<String, dynamic> n) async {
    print('📱 _showLocalNotification called in notification_screen');
    print('   Notification data: $n');
    
    // Use the centralized notification service to show system notifications
    final title = await _buildNotificationTitle(n);
    final body = n['message']?.toString() ?? '';
    final type = n['type']?.toString();
    final currentUserId = _currentUserId;
    
    print('   Title: $title');
    print('   Body: $body');
    print('   Type: $type');
    print('   Current User ID: $currentUserId');
    
    // Prepare payload for navigation
    final payloadMap = <String, dynamic>{};
    if (n['id'] != null) payloadMap['notificationId'] = n['id'].toString();
    if (n['post_id'] != null) payloadMap['postId'] = n['post_id'].toString();
    if (n['postId'] != null && payloadMap['postId'] == null) {
      payloadMap['postId'] = n['postId'].toString();
    }
    if (n['post_id'] != null) payloadMap['post_id'] = n['post_id'].toString();
    if (n['job_id'] != null) payloadMap['jobId'] = n['job_id'].toString();
    if (n['job_id'] != null) payloadMap['job_id'] = n['job_id'].toString();
    if (n['type'] != null) payloadMap['type'] = n['type'].toString();
    if (n['actor_id'] != null) {
      payloadMap['senderId'] = n['actor_id'].toString();
      // Get actor name for message notifications
      if (type == 'message') {
        final actorName = await _getActorName(n['actor_id'].toString());
        payloadMap['senderName'] = actorName ?? 'Someone';
      }
    }
    final payload = json.encode(payloadMap);
    
    print('   Payload: $payload');
    
    try {
      // Use the centralized system notification service from notification_service.dart
      print('🔔 Calling centralized showSystemNotification...');
      await showSystemNotification(
        title: title,
        body: body.isNotEmpty ? body : title,
        type: type,
        recipientId: currentUserId, // Current user should receive this notification
        payload: payload,
      );
      print('✅ System notification completed via centralized service: $title');
    } catch (e) {
      print('❌ Failed to show system notification: $e');
    }
  }

  void _handleNotificationPayloadTap(String payload) async {
    try {
      final Map<String, dynamic> map = json.decode(payload) as Map<String, dynamic>;
      var postId = map['postId']?.toString();
      postId ??= map['post_id']?.toString();
      final notificationId = map['notificationId']?.toString();
      final jobId = map['jobId']?.toString();
      final notificationType = map['type']?.toString();
      final senderId = map['senderId']?.toString();

      print('System notification tapped: postId=$postId, jobId=$jobId, notificationId=$notificationId, type=$notificationType, senderId=$senderId');

      // Mark notification as read if we have an ID
      if (notificationId != null) {
        await _markAsRead(notificationId);
      }

      // Handle message notifications - navigate to chat
      if (notificationType == 'message' && senderId != null) {
        if (!mounted) return;
        Navigator.of(context).pushNamed('/chat', arguments: {
          'receiverId': senderId,
          'userName': map['senderName']?.toString() ?? 'Chat',
        });
        return;
      }

      // Handle job notifications - navigate to home screen
      if (notificationType != null && notificationType.startsWith('job_')) {
        if (!mounted) return;
        Navigator.of(context).pushNamedAndRemoveUntil(
          '/home',
          (route) => false,
          arguments: {'initialTab': 0}, // Home tab
        );
        return;
      }

      // Navigate to post detail if we have a postId
      if (postId != null && postId.isNotEmpty) {
        if (!mounted) return;
        Navigator.of(context).pushNamed('/postDetail', arguments: {'postId': postId});
        return;
      }

      // If no specific navigation target, just stay on the Notifications screen 
      print('No specific navigation target, staying on notifications screen');
    } catch (e) {
      print('Error handling notification payload tap: $e');
    }
  }

  Future<void> _markAsRead(String id) async {
    setState(() {
      final idx = notifications.indexWhere((n) => n['id'] == id);
      if (idx != -1) notifications[idx]['is_read'] = true;
    });
    try {
      await _fastApi.updateNotification(id, {'is_read': true});
    } catch (e) {
      print('Failed to mark notification read: $e');
    }
  }

  String? _extractPostId(Map<String, dynamic> n) {
    final postId = n['post_id']?.toString();
    if (postId != null && postId.isNotEmpty) return postId;
    final camelPostId = n['postId']?.toString();
    if (camelPostId != null && camelPostId.isNotEmpty) return camelPostId;
    return null;
  }

  Future<String?> _extractPostIdAsync(Map<String, dynamic> n) async {
    return _extractPostId(n);
  }

  Future<String> _buildNotificationTitle(Map<String, dynamic> n) async {
    final msg = n['message']?.toString();
    final actorId = n['actor_id']?.toString();
    final actorName = actorId != null ? await _getActorName(actorId) : null;

    if (msg != null && msg.isNotEmpty) {
      return actorName != null ? '$actorName $msg' : msg;
    }

    if (actorName != null) {
      final type = n['type']?.toString() ?? '';
      switch (type) {
        case 'like':
          return '$actorName liked your post';
        case 'comment':
          return '$actorName commented on your post';
        case 'comment_like':
          return '$actorName liked your comment';
        case 'reply':
          return '$actorName replied to your comment';
        case 'mention':
          return '$actorName mentioned you in a ${n['comment_id'] != null ? 'comment' : 'post'}';
        case 'follow':
          return '$actorName started following you';
        case 'missing_pet':
          return '$actorName posted about a missing pet';
        case 'found_pet':
          return '$actorName posted about a found pet';
        case 'job_request':
          return '$actorName sent you a job request';
        case 'job_accepted':
          return '$actorName accepted your job request';
        case 'job_declined':
          return '$actorName declined your job request';
        case 'job_completed':
          return '$actorName marked a job as completed';
        default:
          return '$actorName interacted with your content';
      }
    }

    return 'You have a new notification';
  }

  Future<String?> _getProfilePicture(String userId) async {
    if (_avatarCache.containsKey(userId)) {
      return _avatarCache[userId];
    }
    final userRow = await _fetchUser(userId);
    final userPic = userRow?['profile_picture']?.toString();
    if (userPic != null && userPic.trim().isNotEmpty && !userPic.toLowerCase().contains('default')) {
      _avatarCache[userId] = userPic;
      return userPic;
    }
    _avatarCache[userId] = null;
    return null;
  }

  Future<Map<String, dynamic>?> _fetchUser(String userId) async {
    if (_userCache.containsKey(userId)) {
      return _userCache[userId];
    }
    try {
      final user = await _fastApi.fetchUserById(userId);
      _userCache[userId] = user;
      return user;
    } catch (e) {
      print('Error fetching user $userId: $e');
      return null;
    }
  }

  Future<String?> _getActorName(String userId) async {
    final user = await _fetchUser(userId);
    return user?['name']?.toString();
  }

  String? _extractPublicUserId(Map<String, dynamic> n) {
    // Use actor_id (the person who performed the action) for profile picture
    // This should be the person who liked, commented, etc., not the notification recipient
    final actorId = n['actor_id'];
    if (actorId != null && actorId.toString().isNotEmpty) {
      return actorId.toString();
    }
    
    // Fallback: if no actor_id, don't show user_id as that's the notification recipient
    // Instead return null to show default avatar
    return null;
  }

  DateTime? _parseDate(dynamic v) {
    if (v is DateTime) return v;
    if (v == null) return null;
    return DateTime.tryParse(v.toString());
  }

  String _formatDateHeader(DateTime dt) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final thatDay = DateTime(dt.year, dt.month, dt.day);
    final diff = thatDay.difference(today).inDays;
    if (diff == 0) return 'Today';
    if (diff == -1) return 'Yesterday';

    const months = [
      'Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'
    ];
    return '${months[dt.month - 1]} ${dt.day}, ${dt.year}';
  }

  List<Map<String, dynamic>> _buildSectionedNotificationItems() {
    final List<Map<String, dynamic>> items = [];
    final sorted = [...notifications]..sort((a, b) {
      final ad = _parseDate(a['created_at']) ?? DateTime.fromMillisecondsSinceEpoch(0);
      final bd = _parseDate(b['created_at']) ?? DateTime.fromMillisecondsSinceEpoch(0);
      return bd.compareTo(ad);
    });

    String? lastKey;
    for (final n in sorted) {
      final dt = _parseDate(n['created_at']);
      final key = dt != null
          ? '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}'
          : 'unknown';
      if (key != lastKey) {
        lastKey = key;
        final label = dt != null ? _formatDateHeader(dt) : 'Unknown date';
        items.add({'kind': 'header', 'label': label});
      }
      items.add({'kind': 'item', 'data': n});
    }
    return items;
  }

  void _handleNotificationTap(BuildContext context, Map<String, dynamic> n) async {
    await _markAsRead(n['id'].toString());
    
    final type = n['type']?.toString() ?? '';
    final actorId = n['actor_id']?.toString();
    
    print('In-app notification tapped: type=$type, actorId=$actorId');
    
    // Handle message notifications - navigate to chat
    if (type == 'message' && actorId != null) {
      // Get sender name for navigation
      final senderName = await _getActorName(actorId) ?? 'Chat';
      
      print('Navigating to chat with senderId=$actorId, senderName=$senderName');
      if (_currentUserId != null) {
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (context) => ChatDetailScreen(
              userId: _currentUserId!,
              receiverId: actorId,
              userName: senderName,
            ),
          ),
        );
      }
      return;
    }
    
    // Handle job notifications differently - navigate to home screen jobs section
    if (type.startsWith('job_')) {
      // Navigate to home screen which shows job management
      Navigator.of(context).pushNamedAndRemoveUntil(
        '/home', // Correct route for main navigation
        (route) => false,
        arguments: {'initialTab': 0}, // Home tab
      );
      return;
    }
    
    // Handle regular post-related notifications
    final postId = await _extractPostIdAsync(n);
    print('Post-related notification tapped: postId=$postId');
    if (postId != null && postId.isNotEmpty) {
      Navigator.of(context).pushNamed(
        '/postDetail',
        arguments: {'postId': postId},
      );
      return;
    }
    
    // Show message for notifications without specific navigation
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Notification viewed'),
        backgroundColor: Colors.green,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final signedIn = _currentUserId != null;
    if (!signedIn) {
      final title = _authFailed ? 'Session Expired' : 'Sign In Required';
      final subtitle = _authFailed
          ? 'Your session expired. Please log back in to keep receiving notifications.'
          : 'Please sign in to view your notifications';
      final actionLabel = _authFailed ? 'Re-Login' : 'Sign In';
      return Scaffold(
        backgroundColor: lightBlush,
        appBar: AppBar(
          backgroundColor: deepRed,
          elevation: 0,
          title: const Text(
            'Notifications', 
            style: TextStyle(
              fontWeight: FontWeight.bold,
              color: Colors.white,
            ),
          ),
        ),
        body: isLoading
            ? _buildLoadingState()
            : _buildEmptyState(
                icon: Icons.login,
                title: title,
                subtitle: subtitle,
                actionLabel: actionLabel,
                onAction: () => Navigator.of(context).pushNamed('/login'),
              ),
      );
    }

    final unreadCount = notifications.where((n) => n['is_read'] != true).length;

    return Scaffold(
      backgroundColor: lightBlush,
      appBar: AppBar(
        backgroundColor: deepRed,
        elevation: 0,
        title: Row(
          children: [
            Text(
              'Notifications',
              style: TextStyle(
                fontWeight: FontWeight.bold,
                color: Colors.white,
                fontSize: 20,
              ),
            ),
            if (unreadCount > 0) ...[
              SizedBox(width: 8),
              Container(
                padding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  '$unreadCount',
                  style: TextStyle(
                    color: deepRed,
                    fontWeight: FontWeight.bold,
                    fontSize: 12,
                  ),
                ),
              ),
            ],
          ],
        ),
        actions: [
          if (notifications.isNotEmpty) ...[
            IconButton(
              icon: Container(
                padding: EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.2),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(
                  Icons.mark_email_read,
                  color: Colors.white,
                  size: 20,
                ),
              ),
              tooltip: 'Mark all as read',
              onPressed: unreadCount > 0 ? () async {
                final unreadIds = notifications.where((n) => n['is_read'] != true).map((n) => n['id']).toList();
                if (unreadIds.isEmpty) return;
                
                setState(() {
                  for (var n in notifications) n['is_read'] = true;
                });
                
                try {
                  final futures = unreadIds
                      .map((id) => id?.toString())
                      .whereType<String>()
                      .map((id) => _fastApi.updateNotification(id, {'is_read': true}));
                  await Future.wait(futures);
                  
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text('All notifications marked as read'),
                        backgroundColor: Colors.green,
                        behavior: SnackBarBehavior.floating,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                      ),
                    );
                  }
                } catch (e) {
                  print('Failed to mark all read: $e');
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text('Failed to update notifications'),
                        backgroundColor: Colors.red,
                        behavior: SnackBarBehavior.floating,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                      ),
                    );
                  }
                }
              } : null,
            ),
          ],
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _refreshNotifications,
        color: deepRed,
        backgroundColor: Colors.white,
        child: isLoading
            ? _buildLoadingState()
            : notifications.isEmpty
                ? _buildEmptyState(
                    icon: Icons.notifications_none,
                    title: 'No Notifications',
                    subtitle: 'When you receive notifications, they\'ll appear here',
                  )
                : _buildNotificationsList(),
      ),
    );
  }

  // Enhanced loading state
  Widget _buildLoadingState() {
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [lightBlush, Colors.white],
        ),
      ),
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              padding: EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: Colors.white,
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    color: deepRed.withOpacity(0.1),
                    blurRadius: 20,
                    offset: Offset(0, 5),
                  ),
                ],
              ),
              child: CircularProgressIndicator(
                color: deepRed,
                strokeWidth: 3,
              ),
            ),
            SizedBox(height: 20),
            Text(
              'Loading notifications...',
              style: TextStyle(
                color: Colors.grey.shade600,
                fontSize: 16,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // Enhanced empty state
  Widget _buildEmptyState({
    required IconData icon,
    required String title,
    required String subtitle,
    String? actionLabel,
    VoidCallback? onAction,
  }) {
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [lightBlush, Colors.white],
        ),
      ),
      child: Center(
        child: Padding(
          padding: EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                padding: EdgeInsets.all(32),
                decoration: BoxDecoration(
                  color: Colors.white,
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: deepRed.withOpacity(0.1),
                      blurRadius: 30,
                      offset: Offset(0, 10),
                    ),
                  ],
                ),
                child: Icon(
                  icon,
                  size: 64,
                  color: coral,
                ),
              ),
              SizedBox(height: 24),
              Text(
                title,
                style: TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.bold,
                  color: deepRed,
                ),
                textAlign: TextAlign.center,
              ),
              SizedBox(height: 12),
              Text(
                subtitle,
                style: TextStyle(
                  fontSize: 16,
                  color: Colors.grey.shade600,
                  height: 1.5,
                ),
                textAlign: TextAlign.center,
              ),
              if (actionLabel != null && onAction != null) ...[
                SizedBox(height: 32),
                ElevatedButton(
                  onPressed: onAction,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: deepRed,
                    foregroundColor: Colors.white,
                    padding: EdgeInsets.symmetric(horizontal: 32, vertical: 16),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(25),
                    ),
                    elevation: 4,
                  ),
                  child: Text(
                    actionLabel,
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  // Enhanced notifications list
  Widget _buildNotificationsList() {
    final items = _buildSectionedNotificationItems();
    
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [lightBlush, Colors.white],
        ),
      ),
      child: ListView.builder(
        padding: const EdgeInsets.all(16),
        itemCount: items.length,
        itemBuilder: (context, index) {
          final it = items[index];
          if (it['kind'] == 'header') {
            return _buildDateHeader(it['label'] as String);
          }

          final n = it['data'] as Map<String, dynamic>;
          return _buildNotificationCard(n, index);
        },
      ),
    );
  }

  // Enhanced date header
  Widget _buildDateHeader(String label) {
    return Container(
      margin: EdgeInsets.only(top: 16, bottom: 8),
      child: Row(
        children: [
          Expanded(
            child: Container(
              height: 1,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [Colors.transparent, coral.withOpacity(0.3), Colors.transparent],
                ),
              ),
            ),
          ),
          Padding(
            padding: EdgeInsets.symmetric(horizontal: 16),
            child: Container(
              padding: EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: coral.withOpacity(0.1),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: coral.withOpacity(0.3)),
              ),
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: deepRed,
                  letterSpacing: 0.5,
                ),
              ),
            ),
          ),
          Expanded(
            child: Container(
              height: 1,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [Colors.transparent, coral.withOpacity(0.3), Colors.transparent],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // Enhanced notification card
  Widget _buildNotificationCard(Map<String, dynamic> n, int index) {
    final id = n['id'] as String?;
    final read = n['is_read'] == true;
    final type = n['type']?.toString() ?? '';
    
    final createdAtRaw = n['created_at'];
    final parsedDate = createdAtRaw != null
        ? DateTime.tryParse(createdAtRaw.toString())
        : null;
    
    return Container(
      margin: EdgeInsets.only(bottom: 12),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: id == null ? null : () => _handleNotificationTap(context, n),
          borderRadius: BorderRadius.circular(16),
          child: AnimatedContainer(
            duration: Duration(milliseconds: 300),
            padding: EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: read ? Colors.white.withOpacity(0.7) : Colors.white,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: read ? Colors.grey.shade200 : coral.withOpacity(0.3),
                width: read ? 1 : 2,
              ),
              boxShadow: [
                BoxShadow(
                  color: read 
                    ? Colors.grey.withOpacity(0.1) 
                    : deepRed.withOpacity(0.1),
                  blurRadius: read ? 8 : 12,
                  offset: Offset(0, read ? 2 : 4),
                ),
              ],
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Enhanced avatar with type indicator
                Stack(
                  children: [
                    _buildEnhancedAvatar(n, read),
                    Positioned(
                      bottom: 0,
                      right: 0,
                      child: _buildTypeIndicator(type),
                    ),
                  ],
                ),
                
                SizedBox(width: 12),
                
                // Content section
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      FutureBuilder<String>(
                        future: _buildNotificationTitle(n),
                        builder: (context, snapshot) {
                          return Text(
                            snapshot.data ?? 'Loading...',
                            style: TextStyle(
                              fontSize: 15,
                              fontWeight: read ? FontWeight.w500 : FontWeight.w600,
                              color: read ? Colors.grey.shade700 : deepRed,
                              height: 1.3,
                            ),
                          );
                        },
                      ),
                      
                      if (parsedDate != null) ...[
                        SizedBox(height: 6),
                        Row(
                          children: [
                            Icon(
                              Icons.access_time,
                              size: 12,
                              color: Colors.grey.shade500,
                            ),
                            SizedBox(width: 4),
                            Text(
                              _formatRelativeTime(parsedDate),
                              style: TextStyle(
                                fontSize: 12,
                                color: Colors.grey.shade500,
                                fontWeight: FontWeight.w400,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
                
                // Status indicator
                if (!read) ...[
                  SizedBox(width: 8),
                  Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: coral,
                      shape: BoxShape.circle,
                      boxShadow: [
                        BoxShadow(
                          color: coral.withOpacity(0.3),
                          blurRadius: 4,
                          offset: Offset(0, 1),
                        ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  // Refresh functionality
  Future<void> _refreshNotifications({bool showNewSystemNotifications = false}) async {
    if (_currentUserId == null || _isRefreshing) return;
    _isRefreshing = true;

    try {
      final fetched = await _fastApi.fetchNotifications();
      final newEntries = showNewSystemNotifications
          ? fetched.where((n) => _isNotificationNew(n)).toList()
          : <Map<String, dynamic>>[];

      if (mounted) {
        setState(() {
          notifications = fetched;
          isLoading = false;
        });
      }

      _seenNotificationIds.addAll(
        fetched
            .map((n) => n['id']?.toString())
            .whereType<String>(),
      );

      if (showNewSystemNotifications && newEntries.isNotEmpty) {
        for (final entry in newEntries.reversed) {
          await _showLocalNotification(entry);
        }
      }
    } catch (e) {
      print('Error refreshing notifications: $e');
      if (e.toString().contains('401')) {
        await _handleAuthFailure();
        return;
      }
      if (!showNewSystemNotifications && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to refresh notifications'),
            backgroundColor: Colors.red,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          ),
        );
      }
    } finally {
      _isRefreshing = false;
    }
  }

  Future<void> _handleAuthFailure() async {
    print('🚪 Notification screen auth failure detected – clearing session');
    await _fastApi.logout();
    if (mounted) {
      setState(() {
        _currentUserId = null;
        isLoading = false;
        _authFailed = true;
      });
    }
  }

  bool _isNotificationNew(Map<String, dynamic> item) {
    final id = item['id']?.toString();
    return id != null && !_seenNotificationIds.contains(id);
  }

  void _startPolling() {
    _pollingTimer?.cancel();
    _pollingTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      _refreshNotifications(showNewSystemNotifications: true);
    });
  }

  // Enhanced avatar with better styling
  Widget _buildEnhancedAvatar(Map<String, dynamic> n, bool read) {
    final publicUserId = _extractPublicUserId(n);
    
    final baseAvatar = Container(
      width: 50,
      height: 50,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [coral.withOpacity(0.8), peach.withOpacity(0.8)],
        ),
        border: Border.all(
          color: read ? Colors.grey.shade300 : coral,
          width: 2,
        ),
      ),
      child: Icon(
        Icons.person,
        color: Colors.white,
        size: 24,
      ),
    );

    Widget fromUrl(String? url) {
      if (url == null || url.isEmpty) return baseAvatar;
      return Container(
        width: 50,
        height: 50,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(
            color: read ? Colors.grey.shade300 : coral,
            width: 2,
          ),
        ),
        child: ClipOval(
          child: Image.network(
            url,
            width: 46,
            height: 46,
            fit: BoxFit.cover,
            errorBuilder: (_, __, ___) => baseAvatar,
          ),
        ),
      );
    }

    if (publicUserId == null) {
      return Opacity(opacity: read ? 0.7 : 1.0, child: baseAvatar);
    }

    final cachedUrl = _avatarCache[publicUserId];
    if (cachedUrl != null) {
      return Opacity(opacity: read ? 0.7 : 1.0, child: fromUrl(cachedUrl));
    }

    return Opacity(
      opacity: read ? 0.7 : 1.0,
      child: FutureBuilder<String?>(
        future: _getProfilePicture(publicUserId),
        builder: (context, snapshot) => fromUrl(snapshot.data),
      ),
    );
  }

  // Type indicator for different notification types
  Widget _buildTypeIndicator(String type) {
    IconData icon;
    Color color;
    
    switch (type) {
      case 'like':
        icon = Icons.favorite;
        color = Colors.red;
        break;
      case 'comment':
        icon = Icons.comment;
        color = Colors.blue;
        break;
      case 'follow':
        icon = Icons.person_add;
        color = Colors.green;
        break;
      case 'missing_pet':
        icon = Icons.pets;
        color = Colors.orange;
        break;
      case 'found_pet':
        icon = Icons.pets;
        color = Colors.green;
        break;
      case 'mention':
        icon = Icons.alternate_email;
        color = Colors.purple;
        break;
      case 'job_request':
        icon = Icons.work;
        color = Colors.indigo;
        break;
      case 'job_accepted':
        icon = Icons.check_circle;
        color = Colors.green;
        break;
      case 'job_declined':
        icon = Icons.cancel;
        color = Colors.red;
        break;
      case 'job_completed':
        icon = Icons.task_alt;
        color = Colors.blue;
        break;
      default:
        icon = Icons.notifications;
        color = coral;
    }
    
    return Container(
      width: 18,
      height: 18,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        border: Border.all(color: Colors.white, width: 1.5),
        boxShadow: [
          BoxShadow(
            color: color.withOpacity(0.3),
            blurRadius: 3,
            offset: Offset(0, 1),
          ),
        ],
      ),
      child: Icon(
        icon,
        color: Colors.white,
        size: 10,
      ),
    );
  }

  // Format relative time
  String _formatRelativeTime(DateTime dateTime) {
    final now = DateTime.now();
    final difference = now.difference(dateTime);
    
    if (difference.inMinutes < 1) {
      return 'Just now';
    } else if (difference.inHours < 1) {
      final minutes = difference.inMinutes;
      return '${minutes}m ago';
    } else if (difference.inDays < 1) {
      final hours = difference.inHours;
      return '${hours}h ago';
    } else if (difference.inDays < 7) {
      final days = difference.inDays;
      return '${days}d ago';
    } else {
      return '${dateTime.day}/${dateTime.month}/${dateTime.year}';
    }
  }
}
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'dart:convert';

// Color palette
const deepRed = Color(0xFFB82132);
const coral = Color(0xFFD2665A);
const peach = Color(0xFFF2B28C);
const lightBlush = Color(0xFFF6DED8);

class NotificationScreen extends StatefulWidget {
  const NotificationScreen({super.key});

  @override
  _NotificationScreenState createState() => _NotificationScreenState();
}

class _NotificationScreenState extends State<NotificationScreen> {
  final supabase = Supabase.instance.client;
  List<Map<String, dynamic>> notifications = [];
  StreamSubscription<List<Map<String, dynamic>>>? _subscription;
  RealtimeChannel? _realtimeChannel;
  bool isLoading = true;

  final FlutterLocalNotificationsPlugin _localNotifications = FlutterLocalNotificationsPlugin();
  final Map<String, String?> _avatarCache = {};
  final Map<String, String?> _postCaptionCache = {};

  @override
  void initState() {
    super.initState();
    _initLocalNotifications();
    _initNotifications();
  }

  @override
  void dispose() {
    _subscription?.cancel();
    if (_realtimeChannel != null) {
      supabase.removeChannel(_realtimeChannel!);
    }
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
    final user = supabase.auth.currentUser;
    if (user == null) {
      setState(() => isLoading = false);
      return;
    }
    final userId = user.id;

    try {
      final res = await supabase
          .from('notifications')
          .select()
          .eq('user_id', userId)
          .order('created_at', ascending: false);
      setState(() {
        notifications = List<Map<String, dynamic>>.from(res);
        isLoading = false;
      });
      _prefetchCaptionsFor(notifications);
    } catch (e) {
      setState(() => isLoading = false);
    }

    _realtimeChannel = supabase.channel('notifications_user_$userId');

    _realtimeChannel!.onPostgresChanges(
      event: PostgresChangeEvent.insert,
      schema: 'public',
      table: 'notifications',
      filter: PostgresChangeFilter(
        type: PostgresChangeFilterType.eq,
        column: 'user_id',
        value: userId,
      ),
      callback: (payload) {
        final newRow = payload.newRecord;
        final row = Map<String, dynamic>.from(newRow);
        setState(() {
          notifications = [row, ...notifications];
        });
        // Show system notification (appears outside the app)
        _showLocalNotification(row);
      },
    );

    _realtimeChannel!.subscribe();
  }

  Future<void> _showLocalNotification(Map<String, dynamic> n) async {
    // Check if user has enabled notifications
    final user = Supabase.instance.client.auth.currentUser;
    if (user != null) {
      // Check user preferences from metadata first
      final metadata = user.userMetadata ?? {};
      final notificationPrefs = metadata['notification_preferences'] ?? {'enabled': true};
      final notificationsEnabled = notificationPrefs['enabled'] ?? true;
      
      // If notifications are disabled, don't show system notification
      if (!notificationsEnabled) {
        print('System notifications disabled for user');
        return;
      }
    }
    
    final title = await _buildNotificationTitle(n);
    final body = n['message']?.toString() ?? '';
    
    // Enhanced Android notification details for better system notification experience
    const androidDetails = AndroidNotificationDetails(
      'notifications_channel',
      'Notifications',
      channelDescription: 'App notifications',
      importance: Importance.max,
      priority: Priority.high,
      playSound: true,
      enableVibration: true,
      showWhen: true,
      enableLights: true,
      autoCancel: true, // Notification disappears when tapped
      icon: '@mipmap/ic_launcher', // Use app icon
    );
    const details = NotificationDetails(android: androidDetails);

    final id = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    // Compose a payload so tapping the local notification can navigate to the right place.
    // We'll include the notification DB id and any postId so NotificationScreen can route.
    final payloadMap = <String, dynamic>{};
    if (n['id'] != null) payloadMap['notificationId'] = n['id'].toString();
    if (n['post_id'] != null) payloadMap['postId'] = n['post_id'].toString();
    final payload = json.encode(payloadMap);

    try {
      // Show system notification (appears in notification tray, works outside app)
      await _localNotifications.show(id, title, body.isNotEmpty ? body : null, details, payload: payload);
      print('System notification shown: $title');
    } catch (e) {
      print('Local notification error: $e');
    }
  }

  void _handleNotificationPayloadTap(String payload) async {
    try {
      final Map<String, dynamic> map = json.decode(payload) as Map<String, dynamic>;
      final postId = map['postId']?.toString();
      final notificationId = map['notificationId']?.toString();

      print('System notification tapped: postId=$postId, notificationId=$notificationId');

      // Mark notification as read if we have an ID
      if (notificationId != null) {
        await _markAsRead(notificationId);
      }

      // Navigate to post detail if we have a postId
      if (postId != null && postId.isNotEmpty) {
        if (!mounted) return;
        // Navigate to post detail page
        Navigator.of(context).pushNamed('/postDetail', arguments: {'postId': postId});
        return;
      }

      // If no postId, just stay on the Notifications screen 
      // (user will see the updated notification list)
      print('No postId available, staying on notifications screen');
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
      await supabase.from('notifications').update({'is_read': true}).eq('id', id);
    } catch (e) {
      print('Failed to mark notification read: $e');
    }
  }

  String? _extractPostId(Map<String, dynamic> n) {
    final postId = n['post_id']?.toString();
    if (postId != null && postId.isNotEmpty) return postId;
    return null;
  }

  Future<String?> _extractPostIdAsync(Map<String, dynamic> n) async {
    // First try direct post_id
    final postId = n['post_id']?.toString();
    if (postId != null && postId.isNotEmpty) return postId;
    
    // For comment-related notifications, get post_id from the comment
    final type = n['type']?.toString() ?? '';
    final commentId = n['comment_id']?.toString();
    final replyId = n['reply_id']?.toString();
    
    if ((type == 'comment_like' || type == 'reply' || type == 'mention') && commentId != null && commentId.isNotEmpty) {
      try {
        final commentRes = await supabase
            .from('comments')
            .select('post_id')
            .eq('id', commentId)
            .maybeSingle();
        
        final commentPostId = commentRes?['post_id']?.toString();
        if (commentPostId != null && commentPostId.isNotEmpty) {
          return commentPostId;
        }
      } catch (e) {
        print('Error fetching post_id from comment: $e');
      }
    }
    
    // For reply notifications, we might need to get the post_id from the reply's comment
    if (type == 'reply' && replyId != null && replyId.isNotEmpty) {
      try {
        final replyRes = await supabase
            .from('replies')
            .select('comment_id')
            .eq('id', replyId)
            .maybeSingle();
        
        final parentCommentId = replyRes?['comment_id']?.toString();
        if (parentCommentId != null && parentCommentId.isNotEmpty) {
          final commentRes = await supabase
              .from('comments')
              .select('post_id')
              .eq('id', parentCommentId)
              .maybeSingle();
          
          final commentPostId = commentRes?['post_id']?.toString();
          if (commentPostId != null && commentPostId.isNotEmpty) {
            return commentPostId;
          }
        }
      } catch (e) {
        print('Error fetching post_id from reply: $e');
      }
    }
    
    return null;
  }

  Future<void> _prefetchCaptionsFor(List<Map<String, dynamic>> items) async {
    final ids = <String>{};
    
    // First collect post IDs from direct post_id fields
    for (final n in items) {
      final pid = _extractPostId(n);
      if (pid != null && !_postCaptionCache.containsKey(pid)) {
        ids.add(pid);
      }
    }
    
    // Then collect post IDs from comment-related notifications
    for (final n in items) {
      final pid = await _extractPostIdAsync(n);
      if (pid != null && !_postCaptionCache.containsKey(pid)) {
        ids.add(pid);
      }
    }
    
    if (ids.isEmpty) return;
    try {
      final List<dynamic> rows = await supabase
          .from('community_posts')
          .select('id, content')
          .inFilter('id', ids.toList());
      for (final r in rows) {
        final id = r['id']?.toString();
        final content = r['content']?.toString();
        if (id != null) _postCaptionCache[id] = content;
      }
      if (mounted) setState(() {});
    } catch (_) {}
  }

  Future<String> _buildNotificationTitle(Map<String, dynamic> n) async {
    // First, check if we have a message from the database triggers (with content previews)
    final msg = n['message'];
    if (msg != null && msg.toString().isNotEmpty) {
      // If we have actor_id, prepend the actor name to the message
      final actorId = n['actor_id'];
      if (actorId != null) {
        try {
          final userRow = await supabase
              .from('users')
              .select('name')
              .eq('id', actorId.toString())
              .maybeSingle();
          final actorName = userRow?['name']?.toString() ?? 'Someone';
          
          // Return actor name + message from database
          return '$actorName ${msg.toString()}';
        } catch (e) {
          print('Error getting actor name: $e');
          // Return just the message if we can't get actor name
          return msg.toString();
        }
      } else {
        // Return just the message if no actor_id
        return msg.toString();
      }
    }
    
    // Fallback to generic messages if no message in database (for older notifications)
    final actorId = n['actor_id'];
    if (actorId != null) {
      try {
        final userRow = await supabase
            .from('users')
            .select('name')
            .eq('id', actorId.toString())
            .maybeSingle();
        final actorName = userRow?['name']?.toString() ?? 'Someone';
        
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
          default:
            return '$actorName interacted with your content';
        }
      } catch (e) {
        print('Error building notification title with actor: $e');
      }
    }
    
    return 'You have a new notification';
  }

  Future<String?> _getProfilePicture(String userId) async {
    if (_avatarCache.containsKey(userId)) {
      return _avatarCache[userId];
    }
    try {
      final userRow = await supabase
          .from('users')
          .select('profile_picture')
          .eq('id', userId)
          .maybeSingle();
      final userPic = userRow?['profile_picture']?.toString();
      if (userPic != null && userPic.trim().isNotEmpty && !userPic.toLowerCase().contains('default')) {
        _avatarCache[userId] = userPic;
        return userPic;
      }
      _avatarCache[userId] = null;
      return null;
    } catch (_) {
      _avatarCache[userId] = null;
      return null;
    }
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

  Widget _leadingAvatar(Map<String, dynamic> n, bool read) {
    final baseAvatar = CircleAvatar(
      radius: 22,
      backgroundColor: Colors.grey.shade300,
      child: const Icon(Icons.person, color: Colors.white),
    );

    Widget fromUrl(String? url) {
      if (url == null || url.isEmpty) return baseAvatar;
      return CircleAvatar(
        radius: 22,
        backgroundColor: Colors.transparent,
        child: ClipOval(
          child: Image.network(
            url,
            width: 44,
            height: 44,
            fit: BoxFit.cover,
            errorBuilder: (_, __, ___) => baseAvatar,
          ),
        ),
      );
    }

    final publicUserId = _extractPublicUserId(n);
    if (publicUserId == null) {
      return Opacity(opacity: read ? 0.6 : 1.0, child: baseAvatar);
    }

    final cachedUrl = _avatarCache[publicUserId];
    if (cachedUrl != null) {
      return Opacity(opacity: read ? 0.6 : 1.0, child: fromUrl(cachedUrl));
    }

    return Opacity(
      opacity: read ? 0.6 : 1.0,
      child: FutureBuilder<String?>(
        future: _getProfilePicture(publicUserId),
        builder: (context, snapshot) => fromUrl(snapshot.data),
      ),
    );
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
    final postId = await _extractPostIdAsync(n);
    print('Notification tapped: postId=$postId');
    if (postId != null && postId.isNotEmpty) {
      Navigator.of(context).pushNamed(
        '/postDetail',
        arguments: {'postId': postId},
      );
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('No details available for this notification.\npostId: $postId')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final user = supabase.auth.currentUser;
    if (user == null) {
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
        body: _buildEmptyState(
          icon: Icons.login,
          title: 'Sign In Required',
          subtitle: 'Please sign in to view your notifications',
          actionLabel: 'Sign In',
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
                  await supabase
                      .from('notifications')
                      .update({'is_read': true})
                      .inFilter('id', unreadIds.map((id) => id.toString()).toList());
                  
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
            SizedBox(width: 8),
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
  Future<void> _refreshNotifications() async {
    final user = supabase.auth.currentUser;
    if (user == null) return;
    
    try {
      final res = await supabase
          .from('notifications')
          .select()
          .eq('user_id', user.id)
          .order('created_at', ascending: false);
      
      setState(() {
        notifications = List<Map<String, dynamic>>.from(res);
      });
      
      _prefetchCaptionsFor(notifications);
    } catch (e) {
      print('Error refreshing notifications: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to refresh notifications'),
            backgroundColor: Colors.red,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          ),
        );
      }
    }
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
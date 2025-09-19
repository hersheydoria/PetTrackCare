import 'dart:async';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'dart:convert';

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
    
    if ((type == 'comment_like' || type == 'reply') && commentId != null && commentId.isNotEmpty) {
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
        appBar: AppBar(
          backgroundColor: const Color(0xFFCB4154),
          title: const Text('Notifications', style: TextStyle(fontWeight: FontWeight.bold)),
        ),
        body: const Center(child: Text('Please sign in to view notifications')),
      );
    }

    return Scaffold(
      appBar: AppBar(
        backgroundColor: const Color(0xFFCB4154),
        title: const Text('Notifications', style: TextStyle(fontWeight: FontWeight.bold)),
        actions: [
          IconButton(
            icon: const Icon(Icons.mark_email_read),
            onPressed: () async {
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
              } catch (e) {
                print('Failed to mark all read: $e');
              }
            },
          )
        ],
      ),
      body: isLoading
          ? const Center(child: CircularProgressIndicator(color: Color(0xFFCB4154)))
          : notifications.isEmpty
              ? const Center(child: Text('No notifications'))
              : Builder(builder: (context) {
                  final items = _buildSectionedNotificationItems();
                  return ListView.builder(
                    padding: const EdgeInsets.all(16),
                    itemCount: items.length,
                    itemBuilder: (context, index) {
                      final it = items[index];
                      if (it['kind'] == 'header') {
                        return Padding(
                          padding: const EdgeInsets.only(top: 8, bottom: 8),
                          child: Text(
                            it['label'] as String,
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.bold,
                              color: Colors.grey.shade700,
                            ),
                          ),
                        );
                      }

                      final n = it['data'] as Map<String, dynamic>;
                      final id = n['id'] as String?;
                      final read = n['is_read'] == true;

                      final createdAtRaw = n['created_at'];
                      final parsedDate = createdAtRaw != null
                          ? DateTime.tryParse(createdAtRaw.toString())
                          : null;
                      final subtitleText = parsedDate != null
                          ? parsedDate.toLocal().toString().split('.')[0]
                          : null;

                      return ListTile(
                        leading: _leadingAvatar(n, read),
                        title: FutureBuilder<String>(
                          future: _buildNotificationTitle(n),
                          builder: (context, snapshot) {
                            return Text(snapshot.data ?? 'Loading...');
                          },
                        ),
                        subtitle: subtitleText != null
                            ? Text(subtitleText, style: const TextStyle(fontSize: 12))
                            : null,
                        trailing: read
                            ? null
                            : const Icon(Icons.brightness_1, size: 10, color: Colors.redAccent),
                        onTap: id == null
                            ? null
                            : () => _handleNotificationTap(context, n),
                      );
                    },
                  );
                }),
    );
  }
}
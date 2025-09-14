import 'dart:async';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

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
    final iosInit = DarwinInitializationSettings();
    await _localNotifications.initialize(
      InitializationSettings(android: androidInit, iOS: iosInit),
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
        _showLocalNotification(row);
      },
    );

    _realtimeChannel!.subscribe();

    _subscription = supabase
        .from('notifications')
        .stream(primaryKey: ['id'])
        .eq('user_id', userId)
        .order('created_at', ascending: false)
        .listen((rows) {
      setState(() => notifications = rows);
    });
  }

  Future<void> _showLocalNotification(Map<String, dynamic> n) async {
    final title = _buildSubtitle(n);
    final body = n['message']?.toString() ?? '';
    const androidDetails = AndroidNotificationDetails(
      'notifications_channel',
      'Notifications',
      channelDescription: 'App notifications',
      importance: Importance.max,
      priority: Priority.high,
      playSound: true,
    );
    const iosDetails = DarwinNotificationDetails();
    final details = NotificationDetails(android: androidDetails, iOS: iosDetails);

    final id = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    try {
      await _localNotifications.show(id, title, body.isNotEmpty ? body : null, details);
    } catch (e) {
      print('Local notification error: $e');
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

  Future<void> _prefetchCaptionsFor(List<Map<String, dynamic>> items) async {
    final ids = <String>{};
    for (final n in items) {
      final pid = _extractPostId(n);
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

  String _buildSubtitle(Map<String, dynamic> n) {
    final msg = n['message'];
    if (msg != null && msg.toString().isNotEmpty) {
      return msg.toString();
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
    // Prefer actor_id for profile picture, fallback to user_id
    final actorId = n['actor_id'];
    if (actorId != null && actorId.toString().isNotEmpty) {
      return actorId.toString();
    }
    final userId = n['user_id'];
    if (userId != null && userId.toString().isNotEmpty) {
      return userId.toString();
    }
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
    final postId = _extractPostId(n);
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
                        title: Text(_buildSubtitle(n)),
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
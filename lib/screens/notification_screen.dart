import 'dart:async';
import 'dart:convert';
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
  // Cache avatar URLs by user id to reduce roundtrips
  final Map<String, String?> _avatarCache = {};
  // Cache post captions by post id to avoid repeated queries
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
        notifications = List<Map<String, dynamic>>.from(res ?? []);
        isLoading = false;
      });
      // Prefetch captions for posts referenced by notifications
      _prefetchCaptionsFor(notifications);
    } catch (e) {
      setState(() => isLoading = false);
    }

    // ✅ NEW Supabase Realtime API
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
        if (newRow != null) {
          final row = Map<String, dynamic>.from(newRow);
          setState(() {
            notifications = [row, ...notifications];
          });
          // Prefetch caption for the new notification if needed
          _prefetchCaptionsFor([row]);
          _showLocalNotification(row);
        }
      },
    );

    _realtimeChannel!.subscribe();

    // Backup stream
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

  // Parse notification data whether Map or JSON string
  Map<String, dynamic> _safeData(dynamic data) {
    if (data is Map<String, dynamic>) return data;
    if (data is String && data.trim().isNotEmpty) {
      try {
        final parsed = jsonDecode(data);
        if (parsed is Map<String, dynamic>) return parsed;
      } catch (_) {}
    }
    return {};
  }

  // Ensure we return a public URL from our bucket even if only a path is provided
  String _ensurePublicUrl(String value) {
    final v = value.trim();
    if (v.startsWith('http://') || v.startsWith('https://')) return v;

    // Remove leading slashes
    var clean = v.replaceFirst(RegExp(r'^/+'), '');

    // If the string contains "/profile_images/...", keep from there
    final idx = clean.indexOf('profile_images/');
    if (idx != -1) {
      clean = clean.substring(idx);
    } else {
      // Otherwise, strip any bucket prefixes like "profile-pictures/" or "storage/.../profile-pictures/"
      clean = clean
          .replaceFirst(RegExp(r'^storage/v1/object/public/profile-pictures/'), '')
          .replaceFirst(RegExp(r'^profile-pictures/'), '');
    }

    // Ensure it starts with "profile_images/"
    if (!clean.startsWith('profile_images/')) {
      clean = 'profile_images/$clean';
    }

    return supabase.storage.from('profile-pictures').getPublicUrl(clean);
  }

  // Get the actor/sender user id from multiple potential keys (avoid recipient user_id)
  String? _extractActorId(Map<String, dynamic> n) {
    final data = _safeData(n['data']);
    final me = supabase.auth.currentUser?.id;

    String? asId(dynamic v) {
      if (v == null) return null;
      if (v is Map && v['id'] != null) return v['id'].toString();
      final s = v.toString();
      return s.isEmpty ? null : s;
    }

    final rawCandidates = <dynamic>[
      // data-level preferred
      data['from_user_id'],
      data['sender_id'],
      data['actor_id'],
      data['user_id'],
      data['profile_user_id'],
      data['liked_by'],
      data['commented_by'],
      data['owner_id'],
      data['author_id'],
      data['creator_id'],
      data['user'],
      data['actor'],
      data['sender'],
      data['from_user'],
      // top-level fallbacks
      n['from_user_id'],
      n['sender_id'],
      n['actor_id'],
      n['by_user_id'],
      n['user'],
      n['actor'],
      n['sender'],
      n['from_user'],
      // usually recipient; filtered by 'me' below
      n['user_id'],
    ];

    for (final v in rawCandidates) {
      final id = asId(v);
      if (id == null) continue;
      if (id == me) continue; // don't use recipient id
      return id;
    }
    return null;
  }

  // Extract post id from notification payload (schema: top-level post_id)
  String? _extractPostId(Map<String, dynamic> n) {
    final postId = n['post_id']?.toString();
    if (postId != null && postId.isNotEmpty) return postId;
    // fallback to data if needed
    final data = _safeData(n['data']);
    final dataPostId = data['post_id']?.toString();
    if (dataPostId != null && dataPostId.isNotEmpty) return dataPostId;
    return null;
  }

  // Prefetch captions for given notifications (community_posts.content)
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
      if (mounted) setState(() {}); // refresh titles with fetched captions
    } catch (_) {
      // ignore errors; fallback titles will be used
    }
  }

  // Get caption either from data payload or from cached community_posts lookup
  String _captionFor(Map<String, dynamic> n) {
    final data = _safeData(n['data']);
    // direct fields in payload
    final fromData = (data['post_caption'] ??
            data['caption'] ??
            data['post_title'] ??
            data['content'] ??
            '')
        .toString()
        .trim();
    if (fromData.isNotEmpty) return fromData;

    // nested post objects
    String? fromPostObj(dynamic m) {
      if (m is Map) {
        final map = Map<String, dynamic>.from(m);
        final v = (map['content'] ?? map['caption'] ?? map['title'] ?? map['text'])?.toString().trim();
        if (v != null && v.isNotEmpty) return v;
      }
      return null;
    }
    final nestedCaption = fromPostObj(data['post']) ??
        fromPostObj(data['community_post']) ??
        fromPostObj(data['target_post']) ??
        fromPostObj(data['liked_post']) ??
        fromPostObj(data['commented_post']);
    if (nestedCaption != null && nestedCaption.isNotEmpty) return nestedCaption;

    // cached from community_posts
    final postId = _extractPostId(n);
    if (postId != null) {
      final cached = _postCaptionCache[postId];
      if (cached != null && cached.trim().isNotEmpty) return cached.trim();
    }
    return '';
  }

  String _buildSubtitle(Map<String, dynamic> n) {
    final type = n['type'];
    final data = _safeData(n['data']);

    Map<String, dynamic>? actorObj() {
      final candidates = <dynamic>[
        data['from_user'],
        data['actor'],
        data['sender'],
        data['user'],
        n['from_user'],
        n['actor'],
        n['sender'],
        n['user'],
      ];
      for (final v in candidates) {
        if (v is Map) return Map<String, dynamic>.from(v);
      }
      return null;
    }

    String actorName() {
      final obj = actorObj();
      final fromObj = obj != null
          ? (obj['full_name'] ?? obj['name'] ?? obj['username'] ?? obj['display_name'])
          : null;
      return (fromObj ??
              data['from_user_name'] ??
              data['actor_name'] ??
              data['username'] ??
              data['full_name'] ??
              data['name'] ??
              'Someone')
          .toString();
    }

    if (type == 'like') {
      final name = actorName();
      final caption = _captionFor(n);
      return '$name likes your post${caption.isNotEmpty ? ' "$caption"' : ''}';
    } else if (type == 'comment') {
      final name = actorName();
      final caption = _captionFor(n);
      final comment = (data['comment'] ?? data['comment_text'] ?? '').toString().trim();
      return '$name commented on your post${caption.isNotEmpty ? ' "$caption"' : ''}${comment.isNotEmpty ? ': "$comment"' : ''}';
    } else if (type == 'pet_alert') {
      final pet = data['pet_name'] ?? 'Your pet';
      final msg = data['message'] ?? 'Check this alert';
      return '$pet — $msg';
    }
    return n['message'] ?? 'You have a new notification';
  }

  // Remove any avatar/profile logic except profile_picture from public.users

  // Get profile_picture directly from public.users table and display it
  Future<String?> _getProfilePicture(String userId) async {
    // Use cache if available
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
        _avatarCache[userId] = userPic; // Use the URL directly
        return userPic;
      }
      _avatarCache[userId] = null;
      return null;
    } catch (_) {
      _avatarCache[userId] = null;
      return null;
    }
  }

  // Get the correct public.users id for avatar lookup
  String? _extractPublicUserId(Map<String, dynamic> n) {
    final data = _safeData(n['data']);
    // Try to get from nested user object first
    dynamic userObj = data['actor'] ?? data['user'] ?? data['from_user'] ?? n['actor'] ?? n['user'] ?? n['from_user'];
    if (userObj is Map && userObj['id'] != null) {
      return userObj['id'].toString();
    }
    // Try direct keys that match public.users
    final candidates = [
      data['profile_user_id'],
      data['user_id'],
      n['profile_user_id'],
      n['user_id'],
    ];
    for (final v in candidates) {
      if (v != null && v.toString().isNotEmpty) return v.toString();
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

    // Use public.users id for avatar lookup
    final publicUserId = _extractPublicUserId(n);
    if (publicUserId == null) {
      return Opacity(opacity: read ? 0.6 : 1.0, child: baseAvatar);
    }

    // Use cached avatar if available for instant display
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

  // Parse created_at value to DateTime
  DateTime? _parseDate(dynamic v) {
    if (v is DateTime) return v;
    if (v == null) return null;
    return DateTime.tryParse(v.toString());
  }

  // Pretty date header: Today / Yesterday / MMM d, yyyy
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

  // Build a flat list of headers/items for the ListView
  List<Map<String, dynamic>> _buildSectionedNotificationItems() {
    final List<Map<String, dynamic>> items = [];
    // Ensure notifications are in descending created_at order
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

  // Navigation handler for notification tap
  void _handleNotificationTap(BuildContext context, Map<String, dynamic> n) async {
    await _markAsRead(n['id'].toString());
    final type = n['type'];
    final postId = _extractPostId(n);
    final data = _safeData(n['data']);
    final petId = data['pet_id']?.toString();

    print('Notification tapped: type=$type, postId=$postId, petId=$petId, data=$data');

    // Use postId for navigation if present
    if (postId != null && postId.isNotEmpty) {
      Navigator.of(context).pushNamed(
        '/postDetail',
        arguments: {'postId': postId},
      );
      return;
    } else if (type == 'pet_alert' && petId != null && petId.isNotEmpty) {
      Navigator.of(context).pushNamed(
        '/petAlert',
        arguments: {'petId': petId},
      );
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('No details available for this notification.\nType: $type\npostId: $postId\npetId: $petId')),
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
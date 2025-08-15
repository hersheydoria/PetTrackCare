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
      if (idx != -1) notifications[idx]['read'] = true;
    });
    try {
      await supabase.from('notifications').update({'read': true}).eq('id', id);
    } catch (e) {
      print('Failed to mark notification read: $e');
    }
  }

  Widget _leadingIcon(String? type, bool read) {
    final color = read ? Colors.grey : Colors.redAccent;
    switch (type) {
      case 'like':
        return Icon(Icons.favorite, color: color);
      case 'comment':
        return Icon(Icons.comment, color: color);
      case 'pet_alert':
        return Icon(Icons.pets, color: color);
      default:
        return Icon(Icons.notifications, color: color);
    }
  }

  String _buildSubtitle(Map<String, dynamic> n) {
    final type = n['type'];
    final data = (n['data'] is String) ? {} : (n['data'] ?? {});
    if (type == 'like') {
      final from = data['from_user_name'] ?? 'Someone';
      final pet = data['pet_name'] != null ? ' on ${data['pet_name']}' : '';
      return '$from liked your post$pet';
    } else if (type == 'comment') {
      final from = data['from_user_name'] ?? 'Someone';
      final pet = data['pet_name'] != null ? ' about ${data['pet_name']}' : '';
      final comment = data['comment'] ?? '';
      return '$from commented$pet: "$comment"';
    } else if (type == 'pet_alert') {
      final pet = data['pet_name'] ?? 'Your pet';
      final msg = data['message'] ?? 'Check this alert';
      return '$pet — $msg';
    }
    return n['message'] ?? 'You have a new notification';
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
              final unreadIds = notifications.where((n) => n['read'] != true).map((n) => n['id']).toList();
              if (unreadIds.isEmpty) return;
              setState(() {
                for (var n in notifications) n['read'] = true;
              });
              try {
                final idList = unreadIds.map((id) => id.toString()).join(',');
                final inValue = '($idList)';
                await supabase.from('notifications').update({'read': true}).filter('id', 'in', inValue);
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
              : ListView.separated(
                  padding: const EdgeInsets.all(16),
                  itemCount: notifications.length,
                  separatorBuilder: (_, __) => const Divider(),
                  itemBuilder: (context, index) {
                    final n = notifications[index];
                    final id = n['id'] as String?;
                    final read = n['read'] == true;

                    final createdAtRaw = n['created_at'];
                    final parsedDate = createdAtRaw != null
                        ? DateTime.tryParse(createdAtRaw.toString())
                        : null;
                    final subtitleText = parsedDate != null
                        ? parsedDate.toLocal().toString().split('.')[0]
                        : null;

                    return ListTile(
                      leading: _leadingIcon(n['type'] as String?, read),
                      title: Text(_buildSubtitle(n)),
                      subtitle: subtitleText != null
                          ? Text(subtitleText, style: const TextStyle(fontSize: 12))
                          : null,
                      trailing: read
                          ? null
                          : const Icon(Icons.brightness_1, size: 10, color: Colors.redAccent),
                      onTap: id == null
                          ? null
                          : () async {
                              await _markAsRead(id);
                            },
                    );
                  },
                ),
    );
  }
}

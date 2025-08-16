import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'chat_detail_screen.dart';
import 'notification_screen.dart';

class ChatListScreen extends StatefulWidget {
  @override
  _ChatListScreenState createState() => _ChatListScreenState();
}

class _ChatListScreenState extends State<ChatListScreen> {
  final supabase = Supabase.instance.client;
  List<Map<String, dynamic>> messages = [];

  // Subscribe to user name changes
  RealtimeChannel? _usersChannel;
  Set<String> _contactIds = {};

  @override
  void initState() {
    super.initState();
    fetchMessages();
    setupRealtimeSubscription();
  }

  @override
  void dispose() {
    if (_usersChannel != null) {
      supabase.removeChannel(_usersChannel!);
      _usersChannel = null;
    }
    super.dispose();
  }

  void setupRealtimeSubscription() {
    final channel = supabase.channel('public:messages');

    channel
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'messages',
          callback: (payload, [ref]) {
            fetchMessages(); // Refresh the messages list on new insert
          },
        )
        .subscribe();
  }

  // Subscribe to name updates for the current contacts
  void _subscribeToUserNames(Set<String> ids) {
    // Reset previous channel
    if (_usersChannel != null) {
      supabase.removeChannel(_usersChannel!);
      _usersChannel = null;
    }
    if (ids.isEmpty) return;

    _usersChannel = supabase.channel('chat_list_users');

    for (final userId in ids) {
      _usersChannel!.onPostgresChanges(
        event: PostgresChangeEvent.update,
        schema: 'public',
        table: 'users',
        filter: PostgresChangeFilter(
          type: PostgresChangeFilterType.eq,
          column: 'id',
          value: userId,
        ),
        callback: (payload) {
          final newRow = payload.newRecord;
          if (newRow == null) return;
          final id = newRow['id']?.toString();
          final name = newRow['name']?.toString();
          if (id == null || name == null) return;

          // Update in-place
          final idx = messages.indexWhere((m) => m['contactId'] == id);
          if (idx != -1) {
            setState(() {
              messages[idx] = {
                ...messages[idx],
                'contactName': name,
              };
            });
          }
        },
      );
    }

    _usersChannel!.subscribe();
  }

  Future<void> fetchMessages() async {
    final userId = supabase.auth.currentUser?.id;
    if (userId == null) return;

    final response = await supabase
        .from('messages')
        .select('sender_id, receiver_id, content, sent_at, is_seen, sender:sender_id(name), receiver:receiver_id(name)')
        .or('sender_id.eq.$userId,receiver_id.eq.$userId')
        .order('sent_at', ascending: false);

    final grouped = <String, Map<String, dynamic>>{};
    final contactIds = <String>{};

    for (var msg in response) {
      final isSender = msg['sender_id'] == userId;
      final contactId = (isSender ? msg['receiver_id'] : msg['sender_id']).toString();
      final contactName = isSender ? (msg['receiver']?['name'] ?? '') : (msg['sender']?['name'] ?? '');

      if (!grouped.containsKey(contactId)) {
        grouped[contactId] = {
          'contactId': contactId,
          'contactName': contactName,
          'lastMessage': msg['content'],
          'isSeen': msg['is_seen'],
          'isSender': isSender,
        };
        contactIds.add(contactId);
      }
    }

    setState(() {
      messages = grouped.values.toList();
      _contactIds = contactIds;
    });

    // Ensure we listen to current contacts' name updates
    _subscribeToUserNames(_contactIds);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Messages', style: TextStyle(fontWeight: FontWeight.bold)),
        backgroundColor: Color(0xFFCB4154),
        actions: [
          IconButton(
            icon: Icon(Icons.notifications),
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (context) => const NotificationScreen()),
              );
            },
          ),
        ],
      ),
      body: ListView.builder(
        itemCount: messages.length,
        itemBuilder: (context, index) {
          final chat = messages[index];
          final isSeen = chat['isSeen'] ?? true;
          final isSender = chat['isSender'] ?? false;
          return ListTile(
            leading: CircleAvatar(
              child: Text(
                (chat['contactName'] ?? '?').toString().isNotEmpty
                    ? chat['contactName'][0].toUpperCase()
                    : '?',
                style: TextStyle(
                  fontWeight: !isSeen && !isSender ? FontWeight.bold : FontWeight.normal,
                ),
              ),
            ),
            title: Text(
              chat['contactName'] ?? '',
              style: TextStyle(
                fontWeight: !isSeen && !isSender ? FontWeight.bold : FontWeight.normal,
              ),
            ),
            subtitle: Text(
              chat['lastMessage'] ?? '',
              style: TextStyle(
                color: !isSeen && !isSender ? Colors.black : Colors.grey,
              ),
            ),
            tileColor: !isSeen && !isSender ? Color.fromARGB(255, 243, 216, 218) : null,
            onTap: () async {
              await Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => ChatDetailScreen(
                    userId: supabase.auth.currentUser!.id,
                    receiverId: chat['contactId'],
                    userName: chat['contactName'] ?? '',
                  ),
                ),
              );
              fetchMessages(); // Refresh the list on return
            },
          );
        },
      ),
    );
  }
}

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

  @override
  void initState() {
    super.initState();
    fetchMessages();
    setupRealtimeSubscription();
  }

  void setupRealtimeSubscription() {
    final channel = supabase.channel('public:messages');

    channel
        .on(
          RealtimeListenTypes.postgresChanges,
          ChannelFilter(
            event: 'INSERT',
            schema: 'public',
            table: 'messages',
          ),
          (payload, [ref]) {
            fetchMessages(); // Refresh the messages list on new insert
          },
        )
        .subscribe();
  }

  Future<void> fetchMessages() async {
    final userId = supabase.auth.currentUser?.id;
    if (userId == null) return;

    final response = await supabase
        .from('messages')
        .select('sender_id, receiver_id, content, sent_at, sender:sender_id(name), receiver:receiver_id(name)')
        .or('sender_id.eq.$userId,receiver_id.eq.$userId')
        .order('sent_at', ascending: false);

    final grouped = <String, Map<String, dynamic>>{};

    for (var msg in response) {
      final isSender = msg['sender_id'] == userId;
      final contactId = isSender ? msg['receiver_id'] : msg['sender_id'];
      final contactName = isSender ? msg['receiver']['name'] : msg['sender']['name'];

      if (!grouped.containsKey(contactId)) {
        grouped[contactId] = {
          'contactId': contactId,
          'contactName': contactName,
          'lastMessage': msg['content'],
        };
      }
    }

    setState(() {
      messages = grouped.values.toList();
    });
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
          return ListTile(
            leading: CircleAvatar(
              child: Text(chat['contactName'][0].toUpperCase()),
            ),
            title: Text(chat['contactName']),
            subtitle: Text(chat['lastMessage']),
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => ChatDetailScreen(
                    userId: supabase.auth.currentUser!.id,
                    receiverId: chat['contactId'],
                    userName: chat['contactName'],
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}

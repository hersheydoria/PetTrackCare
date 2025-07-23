import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class ChatDetailScreen extends StatefulWidget {
  final String userId;     // Current user
  final String receiverId; // Other user
  final String userName;

  ChatDetailScreen({
    required this.userId,
    required this.receiverId,
    required this.userName,
  });

  @override
  _ChatDetailScreenState createState() => _ChatDetailScreenState();
}

class _ChatDetailScreenState extends State<ChatDetailScreen> {
  final TextEditingController _messageController = TextEditingController();
  final SupabaseClient supabase = Supabase.instance.client;
  List<dynamic> messages = [];
  bool isTyping = false;
  bool otherUserTyping = false;

  @override
  void initState() {
    super.initState();
    fetchMessages();
    markMessagesAsSeen();
    subscribeToMessages();
    subscribeToTyping();
  }

  void subscribeToMessages() {
    supabase.channel('public:messages')
      .on(
        RealtimeListenTypes.postgresChanges,
        ChannelFilter(event: 'INSERT', schema: 'public', table: 'messages'),
        (payload, [ref]) {
          final msg = payload['new'];
          if ((msg['sender_id'] == widget.receiverId && msg['receiver_id'] == widget.userId) ||
              (msg['sender_id'] == widget.userId && msg['receiver_id'] == widget.receiverId)) {
            fetchMessages();
            markMessagesAsSeen();
          }
        },
      )
      .on(
        RealtimeListenTypes.postgresChanges,
        ChannelFilter(event: 'UPDATE', schema: 'public', table: 'messages'),
        (payload, [ref]) {
          final msg = payload['new'];
          if (msg['sender_id'] == widget.receiverId &&
              msg['receiver_id'] == widget.userId &&
              msg['is_typing'] != null) {
            setState(() {
              otherUserTyping = msg['is_typing'];
            });
          }
        },
      )
      .subscribe();
  }

  void subscribeToTyping() {
    _messageController.addListener(() {
      final typing = _messageController.text.isNotEmpty;
      if (typing != isTyping) {
        isTyping = typing;
        supabase.from('messages').update({'is_typing': isTyping}).match({
          'sender_id': widget.userId,
          'receiver_id': widget.receiverId
        });
      }
    });
  }

  Future<void> fetchMessages() async {
    final response = await supabase
        .from('messages')
        .select()
        .or('sender_id.eq.${widget.userId},receiver_id.eq.${widget.userId}')
        .order('sent_at', ascending: false);

    setState(() {
      messages = response;
    });
  }

  Future<void> _sendMessage() async {
    final content = _messageController.text.trim();
    if (content.isEmpty) return;

    await supabase.from('messages').insert({
      'sender_id': widget.userId,
      'receiver_id': widget.receiverId,
      'content': content,
      'is_seen': false,
      'is_typing': false,
    });

    _messageController.clear();
    fetchMessages();
  }

  Future<void> markMessagesAsSeen() async {
    await supabase.from('messages')
      .update({'is_seen': true})
      .match({
        'sender_id': widget.receiverId,
        'receiver_id': widget.userId,
        'is_seen': false,
      });
  }

  bool isSender(String senderId) => senderId == widget.userId;

  @override
  void dispose() {
    supabase.removeAllChannels();
    _messageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.userName),
            if (otherUserTyping)
              Text('Typing...', style: TextStyle(fontSize: 12, color: Colors.white70)),
          ],
        ),
        backgroundColor: Color(0xFFCB4154),
      ),
      body: Column(
        children: [
          Expanded(
            child: ListView.builder(
              reverse: true,
              itemCount: messages.length,
              itemBuilder: (_, index) {
                final msg = messages[index];
                final sentByMe = isSender(msg['sender_id']);
                return Align(
                  alignment: sentByMe ? Alignment.centerRight : Alignment.centerLeft,
                  child: Column(
                    crossAxisAlignment:
                        sentByMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
                    children: [
                      Container(
                        padding: EdgeInsets.all(12),
                        margin: EdgeInsets.symmetric(vertical: 4, horizontal: 8),
                        decoration: BoxDecoration(
                          color: sentByMe
                              ? Color(0xFFCB4154).withOpacity(0.2)
                              : Colors.grey.shade200,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Text(msg['content']),
                      ),
                      if (sentByMe && msg['is_seen'] == true)
                        Padding(
                          padding: const EdgeInsets.only(right: 12),
                          child: Text("Seen",
                              style: TextStyle(fontSize: 10, color: Colors.grey)),
                        ),
                    ],
                  ),
                );
              },
            ),
          ),
          Divider(height: 1),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8.0),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _messageController,
                    decoration: InputDecoration(
                      hintText: 'Type a message...',
                      border: InputBorder.none,
                    ),
                  ),
                ),
                IconButton(
                  icon: Icon(Icons.send, color: Color(0xFFCB4154)),
                  onPressed: _sendMessage,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

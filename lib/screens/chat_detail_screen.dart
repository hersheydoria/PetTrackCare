import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class ChatDetailScreen extends StatefulWidget {
  final String userId;
  final String receiverId;
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
    listenToTyping();
  }

  Future<void> fetchMessages() async {
    final response = await supabase
        .from('messages')
        .select()
        .or(
            'and(sender_id.eq.${widget.userId},receiver_id.eq.${widget.receiverId}),and(sender_id.eq.${widget.receiverId},receiver_id.eq.${widget.userId})')
        .order('sent_at', ascending: true);

    setState(() {
      messages = response;
    });
  }

  Future<void> markMessagesAsSeen() async {
    await supabase.from('messages').update({'is_seen': true}).match({
      'sender_id': widget.receiverId,
      'receiver_id': widget.userId,
      'is_seen': false,
    });
  }

  void subscribeToMessages() {
    supabase
        .channel('public:messages')
        .on(
          RealtimeListenTypes.postgresChanges,
          ChannelFilter(
              event: 'INSERT', schema: 'public', table: 'messages'),
          (payload, [ref]) async {
            final msg = payload['new'];
            final from = msg['sender_id'];
            final to = msg['receiver_id'];

            if ((from == widget.userId && to == widget.receiverId) ||
                (from == widget.receiverId && to == widget.userId)) {
              await fetchMessages();
              await markMessagesAsSeen();
            }
          },
        )
        .subscribe();
  }

  void subscribeToTyping() {
    _messageController.addListener(() async {
      final typing = _messageController.text.trim().isNotEmpty;
      if (typing != isTyping) {
        isTyping = typing;
        await supabase.from('typing_status').upsert({
          'user_id': widget.userId,
          'chat_with_id': widget.receiverId,
          'is_typing': isTyping
        });
      }
    });
  }

  void listenToTyping() {
    supabase
        .channel('public:typing_status')
        .on(
          RealtimeListenTypes.postgresChanges,
          ChannelFilter(
              event: 'UPDATE', schema: 'public', table: 'typing_status'),
          (payload, [ref]) {
            final data = payload['new'];
            if (data['user_id'] == widget.receiverId &&
                data['chat_with_id'] == widget.userId) {
              setState(() {
                otherUserTyping = data['is_typing'];
              });
            }
          },
        )
        .subscribe();
  }

  Future<void> _sendMessage() async {
    final content = _messageController.text.trim();
    if (content.isEmpty) return;

    await supabase.from('messages').insert({
      'sender_id': widget.userId,
      'receiver_id': widget.receiverId,
      'content': content,
      'is_seen': false,
    });

    _messageController.clear();
    await supabase.from('typing_status').upsert({
      'user_id': widget.userId,
      'chat_with_id': widget.receiverId,
      'is_typing': false,
    });

    await fetchMessages();
  }

  bool isSender(String id) => id == widget.userId;

  @override
  void dispose() {
    _messageController.dispose();
    supabase.removeAllChannels();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    String? lastSeenMessageId;
    for (var i = messages.length - 1; i >= 0; i--) {
      final msg = messages[i];
      if (msg['sender_id'] == widget.userId && msg['is_seen'] == true) {
        lastSeenMessageId = msg['id'].toString();
        break;
      }
    }

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.userName),
            if (otherUserTyping)
              Text('Typing...',
                  style: TextStyle(fontSize: 12, color: Colors.white70)),
          ],
        ),
        backgroundColor: Color(0xFFCB4154),
      ),
      body: Column(
        children: [
          Expanded(
            child: ListView.builder(
              padding: EdgeInsets.only(top: 12),
              itemCount: messages.length,
              reverse: false,
              itemBuilder: (_, index) {
                final msg = messages[index];
                final sentByMe = isSender(msg['sender_id']);
                final isLastSeen =
                    lastSeenMessageId != null &&
                    msg['id'].toString() == lastSeenMessageId;

                return Align(
                  alignment: sentByMe
                      ? Alignment.centerRight
                      : Alignment.centerLeft,
                  child: Column(
                    crossAxisAlignment: sentByMe
                        ? CrossAxisAlignment.end
                        : CrossAxisAlignment.start,
                    children: [
                      Container(
                        padding: EdgeInsets.all(12),
                        margin:
                            EdgeInsets.symmetric(vertical: 4, horizontal: 8),
                        decoration: BoxDecoration(
                          color: sentByMe
                              ? Color(0xFFCB4154).withOpacity(0.2)
                              : Colors.grey.shade200,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Text(msg['content']),
                      ),
                      if (sentByMe && isLastSeen)
                        Padding(
                          padding: const EdgeInsets.only(right: 12.0),
                          child: Text(
                            'Seen',
                            style:
                                TextStyle(fontSize: 10, color: Colors.grey),
                          ),
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

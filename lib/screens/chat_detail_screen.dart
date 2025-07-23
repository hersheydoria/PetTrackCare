import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_sound/flutter_sound.dart';
import 'package:image_picker/image_picker.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:zego_uikit_prebuilt_call/zego_uikit_prebuilt_call.dart';

const int appID = 1445580868; // Replace with your ZEGOCLOUD App ID
const String appSign = '2136993e53a5a7926531f24e693db2403af6e916e1f6dca8970c71c21e4b29be'; // Replace with your ZEGOCLOUD App Sign

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
  FlutterSoundRecorder? _recorder;
  bool isRecording = false;

  @override
  void initState() {
    super.initState();
    _recorder = FlutterSoundRecorder();
    _recorder!.openRecorder();
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
          ChannelFilter(event: 'INSERT', schema: 'public', table: 'messages'),
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
          ChannelFilter(event: 'UPDATE', schema: 'public', table: 'typing_status'),
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
      'type': 'text',
    });

    _messageController.clear();
    await supabase.from('typing_status').upsert({
      'user_id': widget.userId,
      'chat_with_id': widget.receiverId,
      'is_typing': false,
    });

    await fetchMessages();
  }

  Future<void> _recordOrSendVoice() async {
    if (!isRecording) {
      await Permission.microphone.request();
      await _recorder!.startRecorder(toFile: 'voice.aac');
    } else {
      String? path = await _recorder!.stopRecorder();
      final fileBytes = await File(path!).readAsBytes();

      final fileName = 'voice_${DateTime.now().millisecondsSinceEpoch}.aac';
      await supabase.storage.from('voice').uploadBinary(fileName, fileBytes);

      await supabase.from('messages').insert({
        'sender_id': widget.userId,
        'receiver_id': widget.receiverId,
        'content': '[voice]',
        'is_seen': false,
        'type': 'voice',
        'media_url': 'public/voice/$fileName',
      });

      fetchMessages();
    }

    setState(() {
      isRecording = !isRecording;
    });
  }

  Future<void> _pickImage() async {
    final picker = ImagePicker();
    final pickedFile = await picker.pickImage(source: ImageSource.gallery);
    if (pickedFile != null) await _uploadMedia(File(pickedFile.path), 'image');
  }

  Future<void> _captureImage() async {
    final picker = ImagePicker();
    final pickedFile = await picker.pickImage(source: ImageSource.camera);
    if (pickedFile != null) await _uploadMedia(File(pickedFile.path), 'image');
  }

  Future<void> _uploadMedia(File file, String type) async {
    final bytes = await file.readAsBytes();
    final filename = '${DateTime.now().millisecondsSinceEpoch}.${file.path.split('.').last}';
    await supabase.storage.from('chat-media').uploadBinary('images/$filename', bytes);

    await supabase.from('messages').insert({
      'sender_id': widget.userId,
      'receiver_id': widget.receiverId,
      'content': '[image]',
      'is_seen': false,
      'type': type,
      'media_url': 'public/chat-media/images/$filename',
    });

    fetchMessages();
  }

  void _startZegoCall(bool video) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => ZegoUIKitPrebuiltCall(
          appID: appID,
          appSign: appSign,
          userID: widget.userId,
          userName: widget.userId,
          callID: widget.receiverId,
          config: video
              ? ZegoUIKitPrebuiltCallConfig.oneOnOneVideoCall()
              : ZegoUIKitPrebuiltCallConfig.oneOnOneVoiceCall(),
        ),
      ),
    );
  }

  bool isSender(String id) => id == widget.userId;

  @override
  void dispose() {
    _messageController.dispose();
    _recorder?.closeRecorder();
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
              Text('Typing...', style: TextStyle(fontSize: 12, color: Colors.white70)),
          ],
        ),
        backgroundColor: Color(0xFFCB4154),
        actions: [
          IconButton(
            icon: Icon(Icons.call),
            onPressed: () => _startZegoCall(false),
          ),
          IconButton(
            icon: Icon(Icons.videocam),
            onPressed: () => _startZegoCall(true),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: ListView.builder(
              padding: EdgeInsets.only(top: 12),
              itemCount: messages.length,
              itemBuilder: (_, index) {
                final msg = messages[index];
                final sentByMe = isSender(msg['sender_id']);
                final isLastSeen = lastSeenMessageId != null &&
                    msg['id'].toString() == lastSeenMessageId;

                Widget content = msg['type'] == 'image'
                ? Image.network(supabase.storage.from('chat-media').getPublicUrl(msg['media_url']), fit: BoxFit.cover)
                : Text(msg['text']);
                if (msg['type'] == 'image') {
                  Image.network(
                    supabase.storage.from('chat-media').getPublicUrl(msg['media_url']),
                    fit: BoxFit.cover,
                  );
                } else if (msg['type'] == 'voice') {
                  content = Icon(Icons.play_arrow);
                } else {
                  content = Text(msg['content']);
                }

                return Align(
                  alignment: sentByMe ? Alignment.centerRight : Alignment.centerLeft,
                  child: Column(
                    crossAxisAlignment: sentByMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
                    children: [
                      Container(
                        padding: EdgeInsets.all(12),
                        margin: EdgeInsets.symmetric(vertical: 4, horizontal: 8),
                        decoration: BoxDecoration(
                          color: sentByMe ? Color(0xFFCB4154).withOpacity(0.2) : Colors.grey.shade200,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: content,
                      ),
                      if (sentByMe && isLastSeen)
                        Padding(
                          padding: const EdgeInsets.only(right: 12.0),
                          child: Text('Seen', style: TextStyle(fontSize: 10, color: Colors.grey)),
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
                IconButton(icon: Icon(Icons.mic, color: Color(0xFFCB4154)), onPressed: _recordOrSendVoice),
                IconButton(icon: Icon(Icons.image, color: Color(0xFFCB4154)), onPressed: _pickImage),
                IconButton(icon: Icon(Icons.camera_alt, color: Color(0xFFCB4154)), onPressed: _captureImage),
                Expanded(
                  child: TextField(
                    controller: _messageController,
                    decoration: InputDecoration(hintText: 'Type a message...', border: InputBorder.none),
                  ),
                ),
                IconButton(icon: Icon(Icons.send, color: Color(0xFFCB4154)), onPressed: _sendMessage),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

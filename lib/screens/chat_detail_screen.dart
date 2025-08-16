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

  // NEW: player state for voice playback
  FlutterSoundPlayer? _player;
  String? _playingMessageId;

  @override
  void initState() {
    super.initState();
    _recorder = FlutterSoundRecorder();
    _initAudio(); // ask mic permission, open recorder & player
    fetchMessages();
    markMessagesAsSeen();
    subscribeToMessages();
    subscribeToTyping();
    listenToTyping();
  }

  // Initialize recorder/player with permission
  Future<void> _initAudio() async {
    await Permission.microphone.request();
    try {
      await _recorder!.openRecorder();
    } catch (_) {}
    _player = FlutterSoundPlayer();
    try {
      await _player!.openPlayer();
    } catch (_) {}
  }

  // Build a signed URL for a storage object (works for private buckets), fallback to public URL
  Future<String?> _signedUrlFor(String bucket, String path, {int ttlSeconds = 60 * 60 * 24}) async {
    try {
      return await supabase.storage.from(bucket).createSignedUrl(path, ttlSeconds);
    } catch (_) {
      try {
        return supabase.storage.from(bucket).getPublicUrl(path);
      } catch (_) {
        return null;
      }
    }
  }

  // Normalize message media reference into bucket+path
  ({String bucket, String path}) _resolveStorage(String type, String? raw) {
    // Default bucket
    String bucket = 'chat-media';
    var value = (raw ?? '').trim();

    // Strip full public/signed URLs to a relative path: .../object/public/<bucket>/<path>
    final reFull = RegExp(r'.*/storage/v1/object/(?:public|sign)/([^/]+)/(.+)$');
    final m = reFull.firstMatch(value);
    if (m != null) {
      bucket = m.group(1)!;
      final path = m.group(2)!;
      return (bucket: bucket, path: path);
    }

    // Accept full http(s) later in _mediaUrl

    // Strip "public/<bucket>/<path>" shorthand
    if (value.startsWith('public/')) {
      final rest = value.substring('public/'.length);
      final slash = rest.indexOf('/');
      if (slash > 0) {
        bucket = rest.substring(0, slash);
        final path = rest.substring(slash + 1);
        return (bucket: bucket, path: path);
      }
    }

    // Remove leading slashes
    value = value.replaceFirst(RegExp(r'^/+'), '');

    // If prefixed with bucket name (e.g., chat-media/images/...), drop the bucket segment
    if (value.startsWith('chat-media/')) value = value.substring('chat-media/'.length);
    if (value.startsWith('voice/')) {
      // Ambiguous: could be folder or bucket. If type is voice, assume current default bucket.
      return (bucket: bucket, path: value);
    }
    if (value.startsWith('images/')) {
      return (bucket: bucket, path: value);
    }

    // Fallbacks by type
    if (type == 'voice') return (bucket: bucket, path: 'voice/$value');
    return (bucket: bucket, path: 'images/$value');
  }

  Future<String?> _mediaUrl(Map msg) async {
    final type = (msg['type'] ?? '').toString();
    final media = msg['media_url']?.toString();
    if (media == null || media.isEmpty) return null;

    // If a full URL was stored, use it directly
    if (media.startsWith('http://') || media.startsWith('https://')) {
      return media;
    }

    final ref = _resolveStorage(type, media);
    return _signedUrlFor(ref.bucket, ref.path);
  }

  // Toggle play/pause for a given voice message
  Future<void> _togglePlay(Map msg) async {
    final id = msg['id']?.toString();
    if (id == null || _player == null) return;

    if (_playingMessageId == id) {
      try {
        await _player!.stopPlayer();
      } catch (_) {}
      setState(() => _playingMessageId = null);
      return;
    }

    final url = await _mediaUrl(msg);
    if (url == null) return;
    try {
      await _player!.startPlayer(fromURI: url, codec: Codec.aacADTS, whenFinished: () {
        if (mounted) setState(() => _playingMessageId = null);
      });
      setState(() => _playingMessageId = id);
    } catch (_) {}
  }

  @override
  void dispose() {
    _messageController.dispose();
    _recorder?.closeRecorder();
    try {
      _player?.stopPlayer();
      _player?.closePlayer();
    } catch (_) {}
    supabase.removeAllChannels();
    super.dispose();
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
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'messages',
          callback: (payload, [ref]) async {
            final msg = payload.newRecord;
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
        .onPostgresChanges(
          event: PostgresChangeEvent.update,
          schema: 'public',
          table: 'typing_status',
          callback: (payload, [ref]) {
            final data = payload.newRecord;
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
      await supabase.storage.from('chat-media').uploadBinary(
        'voice/$fileName',
        fileBytes,
        fileOptions: const FileOptions(
          contentType: 'audio/aac',
          upsert: true,
        ),
      );

      await supabase.from('messages').insert({
        'sender_id': widget.userId,
        'receiver_id': widget.receiverId,
        'content': '[voice]',
        'is_seen': false,
        'type': 'voice',
        'media_url': 'voice/$fileName',
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
    final ext = file.path.split('.').last.toLowerCase();
    final filename = '${DateTime.now().millisecondsSinceEpoch}.$ext';
    final contentType = switch (ext) {
      'jpg' || 'jpeg' => 'image/jpeg',
      'png' => 'image/png',
      'gif' => 'image/gif',
      'webp' => 'image/webp',
      _ => 'application/octet-stream',
    };

    await supabase.storage.from('chat-media').uploadBinary(
      'images/$filename',
      bytes,
      fileOptions: FileOptions(contentType: contentType, upsert: true),
    );

    await supabase.from('messages').insert({
      'sender_id': widget.userId,
      'receiver_id': widget.receiverId,
      'content': '[image]',
      'is_seen': false,
      'type': type,
      'media_url': 'images/$filename',
    });

    fetchMessages();
  }

  String _sanitizeId(String s) {
    // Allow only letters, numbers, underscore (ZEGOCLOUD safe) and lowercase to avoid case drift
    final cleaned = s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9_]'), '');
    return cleaned.isEmpty ? 'user' : cleaned;
  }

  String _sharedCallId(String userA, String userB) {
    // Sort to make it order-independent
    final sorted = [userA, userB]..sort();
    final left = _sanitizeId(sorted[0]);
    final right = _sanitizeId(sorted[1]);

    // Keep a compact, deterministic ID: prefix + 12 chars from each side
    final leftShort = (left.length >= 12) ? left.substring(0, 12) : left.padRight(12, '0');
    final rightShort = (right.length >= 12) ? right.substring(0, 12) : right.padRight(12, '0');

    final id = 'ptc_${leftShort}_${rightShort}';
    // Max 64 characters (we are well under)
    return id;
  }

  void _startZegoCall(bool video) async {
    // Ensure permissions before entering call page
    final mic = await Permission.microphone.request();
    if (!mic.isGranted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Microphone permission denied')));
      return;
    }
    if (video) {
      final cam = await Permission.camera.request();
      if (!cam.isGranted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Camera permission denied')));
        return;
      }
    }

    final callId = _sharedCallId(widget.userId, widget.receiverId);
    debugPrint('Starting Zego call, callID=$callId, me=${_sanitizeId(widget.userId)}');

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => ZegoUIKitPrebuiltCall(
          appID: appID,
          appSign: appSign,
          userID: _sanitizeId(widget.userId),
          userName: widget.userName,
          callID: callId,
          config: video
              ? ZegoUIKitPrebuiltCallConfig.oneOnOneVideoCall()
              : ZegoUIKitPrebuiltCallConfig.oneOnOneVoiceCall(),
        ),
      ),
    );
  }

  bool isSender(String id) => id == widget.userId;

  DateTime? _parseMsgTime(dynamic v) {
    if (v == null) return null;
    if (v is DateTime) return v;
    return DateTime.tryParse(v.toString());
  }

  String _formatChatTimestamp(DateTime dt) {
    final local = dt.toLocal();
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final thatDay = DateTime(local.year, local.month, local.day);
    final diff = thatDay.difference(today).inDays;

    final months = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
    final dayLabel = diff == 0
        ? 'Today'
        : (diff == -1 ? 'Yesterday' : '${months[local.month - 1]} ${local.day}, ${local.year}');

    final hour12 = (local.hour % 12 == 0) ? 12 : (local.hour % 12);
    final minute = local.minute.toString().padLeft(2, '0');
    final ampm = local.hour >= 12 ? 'PM' : 'AM';

    return '$dayLabel • $hour12:$minute $ampm';
  }

  void _openImageViewer(String url, {String? tag}) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => Scaffold(
          backgroundColor: Colors.black,
          body: SafeArea(
            child: Stack(
              children: [
                Center(
                  child: InteractiveViewer(
                    minScale: 0.5,
                    maxScale: 4.0,
                    child: tag != null
                        ? Hero(tag: tag, child: Image.network(url))
                        : Image.network(url),
                  ),
                ),
                Positioned(
                  top: 8,
                  left: 8,
                  child: IconButton(
                    icon: const Icon(Icons.close, color: Colors.white),
                    onPressed: () => Navigator.pop(context),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
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

                final sentAt = _parseMsgTime(msg['sent_at']);
                final tsLabel = sentAt != null ? _formatChatTimestamp(sentAt) : null;

                Widget content;
                if (msg['type'] == 'image' && msg['media_url'] != null) {
                  content = FutureBuilder<String?>(
                    future: _mediaUrl(msg),
                    builder: (context, snap) {
                      final url = snap.data;
                      if (url == null) {
                        return const SizedBox(
                          width: 160,
                          height: 120,
                          child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
                        );
                      }
                      final heroTag = 'chat_img_${msg['id'] ?? url}';
                      return GestureDetector(
                        onTap: () => _openImageViewer(url, tag: heroTag),
                        child: Hero(
                          tag: heroTag,
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(8),
                            child: Image.network(
                              url,
                              fit: BoxFit.cover,
                              width: 200,
                              height: 200,
                              errorBuilder: (_, __, ___) => const Icon(Icons.broken_image),
                            ),
                          ),
                        ),
                      );
                    },
                  );
                } else if (msg['type'] == 'voice' && msg['media_url'] != null) {
                  final playing = _playingMessageId == msg['id']?.toString();
                  content = Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        icon: Icon(playing ? Icons.pause_circle_filled : Icons.play_circle_fill),
                        onPressed: () => _togglePlay(msg),
                        color: const Color(0xFFCB4154),
                      ),
                      const Text('Voice message'),
                    ],
                  );
                } else {
                  content = Text(msg['content'] ?? '[empty]');
                }

                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (tsLabel != null)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 6.0),
                        child: Center(
                          child: Container(
                            padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 10),
                            decoration: BoxDecoration(
                              color: Colors.black12,
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Text(
                              tsLabel,
                              style: const TextStyle(fontSize: 11, color: Colors.black54),
                            ),
                          ),
                        ),
                      ),
                    Align(
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
                    ),
                  ],
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

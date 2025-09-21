import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_sound/flutter_sound.dart';
import 'package:image_picker/image_picker.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:zego_uikit_prebuilt_call/zego_uikit_prebuilt_call.dart';
import 'package:realtime_client/realtime_client.dart' as r;
import 'package:realtime_client/src/types.dart' as rt;
import 'package:flutter_dotenv/flutter_dotenv.dart';
import '../services/notification_service.dart';

// Color palette
const deepRed = Color(0xFFB82132);
const coral = Color(0xFFD2665A);
const peach = Color(0xFFF2B28C);
const lightBlush = Color(0xFFF6DED8);

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
  String? _incomingPromptedCallId;
  bool _joiningCall = false;
  String? _myDisplayName; // current user's display name, used for Zego

  String? _outgoingCallId;
  String _outgoingCallMode = 'voice';
  bool _awaitingAccept = false;
  bool _callingDialogOpen = false;

  // NEW: realtime signaling channels cache
  RealtimeChannel? _callRx;
  final Map<String, RealtimeChannel> _sigChans = {};

  final ScrollController _scrollController = ScrollController();
  
  // Receiver profile picture
  String? _receiverProfilePicture;

  @override
  void initState() {
    super.initState();
    _recorder = FlutterSoundRecorder();
    _initAudio(); // ask mic permission, open recorder & player
    fetchMessages().then((_) => _scrollToBottom());
    markMessagesAsSeen();
    subscribeToMessages();
    subscribeToTyping();
    listenToTyping();
    _loadSelfName(); // load my display name for calls
    _loadReceiverProfile(); // load receiver's profile picture
    _initCallSignals(); // NEW: subscribe to my signaling channel
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

  Future<void> _loadSelfName() async {
    try {
      final row = await supabase
          .from('users')
          .select('name')
          .eq('id', widget.userId)
          .maybeSingle();
      if (mounted) {
        setState(() {
          _myDisplayName = (row?['name']?.toString() ?? '').trim();
        });
      }
    } catch (_) {
      // ignore
    }
  }

  Future<void> _loadReceiverProfile() async {
    try {
      final row = await supabase
          .from('users')
          .select('profile_picture')
          .eq('id', widget.receiverId)
          .maybeSingle();
      
      print('Receiver profile data: $row'); // Debug log
      
      if (mounted) {
        setState(() {
          _receiverProfilePicture = row?['profile_picture']?.toString();
        });
        print('Set receiver profile picture: $_receiverProfilePicture'); // Debug log
      }
    } catch (e) {
      print('Error loading receiver profile: $e'); // Debug log
    }
  }

  // Get full URL for profile picture
  String? _getProfilePictureUrl(String? profilePicture) {
    if (profilePicture == null || profilePicture.isEmpty) {
      print('Profile picture is null or empty'); // Debug log
      return null;
    }
    
    print('Processing profile picture: $profilePicture'); // Debug log
    
    // If it's already a full URL, return as is
    if (profilePicture.startsWith('http://') || profilePicture.startsWith('https://')) {
      print('Profile picture is already a full URL'); // Debug log
      return profilePicture;
    }
    
    // If it's a storage path, try different bucket names
    try {
      // Try common bucket names for profile pictures
      List<String> possibleBuckets = ['profile-pictures', 'avatars', 'users', 'images'];
      
      for (String bucket in possibleBuckets) {
        try {
          String url = supabase.storage.from(bucket).getPublicUrl(profilePicture);
          print('Generated URL for bucket $bucket: $url'); // Debug log
          return url;
        } catch (e) {
          print('Failed to get URL from bucket $bucket: $e'); // Debug log
          continue;
        }
      }
      
      // If all buckets failed, try the default one
      String url = supabase.storage.from('profile-pictures').getPublicUrl(profilePicture);
      print('Using default bucket URL: $url'); // Debug log
      return url;
    } catch (e) {
      print('Error generating profile picture URL: $e'); // Debug log
      return null;
    }
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

  // NEW: setup realtime signaling
  void _initCallSignals() {
    final myKey = _sanitizeId(widget.userId);
    _callRx = supabase.channel('call_sig:$myKey');
    _callRx!
        .onBroadcast(
          event: 'call_invite',
          callback: (payload, [ref]) async {
            final body = payload is Map ? Map<String, dynamic>.from(payload as Map) : null;
            if (body == null) return;
            final to = (body['to'] ?? '').toString();
            final from = (body['from'] ?? '').toString();
            final callId = (body['call_id'] ?? '').toString();
            final mode = (body['mode'] ?? 'voice').toString();
            if (to != widget.userId || callId.isEmpty) return;
            if (_incomingPromptedCallId == callId) return;
            _incomingPromptedCallId = callId;

            if (!mounted) return;
            final accept = await showDialog<bool>(
              context: context,
              barrierDismissible: true,
              builder: (_) => AlertDialog(
                title: Text(mode == 'video' ? 'Incoming video call' : 'Incoming voice call'),
                content: const Text('Join this call?'),
                actions: [
                  TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Decline')),
                  TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Accept')),
                ],
              ),
            );

            if (accept == true) {
              // DB record for history
              try {
                await supabase.from('messages').insert({
                  'sender_id': widget.userId,
                  'receiver_id': from,
                  'type': 'call_accept',
                  'call_id': callId,
                  'call_mode': mode,
                  'content': '[call_accept]',
                  'is_seen': false,
                });
              } catch (_) {}
              // Realtime acknowledge
              await _sendSignal(from, 'call_accept', {
                'from': widget.userId,
                'to': from,
                'call_id': callId,
                'mode': mode,
              });
              await _joinZegoCall(callId: callId, video: mode == 'video');
            } else {
              // DB record for history
              try {
                await supabase.from('messages').insert({
                  'sender_id': widget.userId,
                  'receiver_id': from,
                  'type': 'call_decline',
                  'call_id': callId,
                  'call_mode': mode,
                  'content': '[call_decline]',
                  'is_seen': false,
                });
              } catch (_) {}
              // Realtime decline
              await _sendSignal(from, 'call_decline', {
                'from': widget.userId,
                'to': from,
                'call_id': callId,
                'mode': mode,
              });
            }
          },
        )
        .onBroadcast(
          event: 'call_accept',
          callback: (payload, [ref]) async {
            final body = payload is Map ? Map<String, dynamic>.from(payload as Map) : null;
            if (body == null) return;
            final to = (body['to'] ?? '').toString();
            final callId = (body['call_id'] ?? '').toString();
            final mode = (body['mode'] ?? 'voice').toString();
            if (to != widget.userId || callId.isEmpty) return;
            if (_awaitingAccept && _outgoingCallId == callId) {
              _dismissCallingDialog();
              _awaitingAccept = false;
              await _joinZegoCall(callId: callId, video: mode == 'video');
            }
          },
        )
        .onBroadcast(
          event: 'call_decline',
          callback: (payload, [ref]) {
            final body = payload is Map ? Map<String, dynamic>.from(payload as Map) : null;
            if (body == null) return;
            final to = (body['to'] ?? '').toString();
            final callId = (body['call_id'] ?? '').toString();
            if (to != widget.userId || callId.isEmpty) return;
            if (_awaitingAccept && _outgoingCallId == callId) {
              _dismissCallingDialog();
              _awaitingAccept = false;
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Call declined')));
              }
            }
          },
        )
        .onBroadcast(
          event: 'call_cancel',
          callback: (payload, [ref]) {
            final body = payload is Map ? Map<String, dynamic>.from(payload as Map) : null;
            if (body == null) return;
            final to = (body['to'] ?? '').toString();
            final callId = (body['call_id'] ?? '').toString();
            if (to != widget.userId || callId.isEmpty) return;
            // If the caller canceled before accept, just clear prompt (if any)
            if (_incomingPromptedCallId == callId) {
              _incomingPromptedCallId = null;
            }
          },
        )
        .subscribe();
  }

  // NEW: send a broadcast signal to a user's channel
  Future<void> _sendSignal(String userId, String event, Map<String, dynamic> payload) async {
    final key = _sanitizeId(userId);
    var ch = _sigChans[key];
    ch ??= supabase.channel('call_sig:$key')..subscribe();
    _sigChans[key] = ch;
    try {
      await ch.send(
        type: rt.RealtimeListenTypes.broadcast,
        event: event,
        payload: payload,
      );
    } catch (_) {
      // ignore; DB insert path still delivers signaling via onPostgresChanges
    }
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
    // No-op: removeAllChannels() already cleans up _callRx/_sigChans
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
    _scrollToBottom();
  }

  void _scrollToBottom() {
    if (_scrollController.hasClients) {
      _scrollController.animateTo(
        0.0,
        duration: Duration(milliseconds: 300),
        curve: Curves.easeOut,
      );
    }
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

            // Refresh chat list
            if ((from == widget.userId && to == widget.receiverId) ||
                (from == widget.receiverId && to == widget.userId)) {
              await fetchMessages();
              await markMessagesAsSeen();
            }

            // Handle call invite when I am the receiver
            if (to == widget.userId && msg['type'] == 'call') {
              final callId = (msg['call_id'] ?? '').toString().trim();
              final mode = (msg['call_mode'] ?? 'voice').toString();
              if (callId.isEmpty) return;
              if (_incomingPromptedCallId == callId) return;
              _incomingPromptedCallId = callId;

              if (!mounted) return;
              final callerId = from?.toString();
              final accept = await showDialog<bool>(
                context: context,
                barrierDismissible: true,
                builder: (_) => AlertDialog(
                  title: Text(mode == 'video' ? 'Incoming video call' : 'Incoming voice call'),
                  content: const Text('Join this call?'),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(context, false),
                      child: const Text('Decline'),
                    ),
                    TextButton(
                      onPressed: () => Navigator.pop(context, true),
                      child: const Text('Accept'),
                    ),
                  ],
                ),
              );

              if (accept == true && mounted) {
                // Notify caller that callee accepted (DB + realtime)
                try {
                  await supabase.from('messages').insert({
                    'sender_id': widget.userId,
                    'receiver_id': callerId,
                    'type': 'call_accept',
                    'call_id': callId,
                    'call_mode': mode,
                    'content': '[call_accept]',
                    'is_seen': false,
                  });
                } catch (_) {}
                await _sendSignal(callerId!, 'call_accept', {
                  'from': widget.userId,
                  'to': callerId,
                  'call_id': callId,
                  'mode': mode,
                });
                await _joinZegoCall(callId: callId, video: mode == 'video');
              } else {
                // Notify decline (DB + realtime)
                try {
                  await supabase.from('messages').insert({
                    'sender_id': widget.userId,
                    'receiver_id': callerId,
                    'type': 'call_decline',
                    'call_id': callId,
                    'call_mode': mode,
                    'content': '[call_decline]',
                    'is_seen': false,
                  });
                } catch (_) {}
                await _sendSignal(callerId!, 'call_decline', {
                  'from': widget.userId,
                  'to': callerId,
                  'call_id': callId,
                  'mode': mode,
                });
              }
            }

            // Caller side: callee accepted -> join now
            if (from == widget.receiverId && to == widget.userId && msg['type'] == 'call_accept') {
              final callId = (msg['call_id'] ?? '').toString().trim();
              final mode = (msg['call_mode'] ?? 'voice').toString();
              if (callId.isEmpty) return;
              if (_awaitingAccept && _outgoingCallId == callId) {
                _dismissCallingDialog();
                _awaitingAccept = false;
                await _joinZegoCall(callId: callId, video: mode == 'video');
              }
            }

            // Caller side: callee canceled/declined -> dismiss dialog
            if (from == widget.receiverId && to == widget.userId &&
                (msg['type'] == 'call_cancel' || msg['type'] == 'call_decline')) {
              final callId = (msg['call_id'] ?? '').toString().trim();
              if (_awaitingAccept && _outgoingCallId == callId) {
                _dismissCallingDialog();
                _awaitingAccept = false;
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text(msg['type'] == 'call_decline' ? 'Call declined' : 'Call canceled')),
                  );
                }
              }
            }
          },
        )
        .subscribe();
  }

  void _dismissCallingDialog() {
    if (_callingDialogOpen && mounted) {
      Navigator.of(context, rootNavigator: true).maybePop();
      _callingDialogOpen = false;
    }
  }

  void _openCallingDialog(String callId, bool video) {
    if (_callingDialogOpen || !mounted) return;
    _callingDialogOpen = true;
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => WillPopScope(
        onWillPop: () async => false,
        child: AlertDialog(
          title: Text('Calling ${widget.userName}...'),
          content: const Text('Waiting for recipient to accept'),
          actions: [
            TextButton(
              onPressed: () async {
                // Send cancel to recipient (DB + realtime)
                try {
                  await supabase.from('messages').insert({
                    'sender_id': widget.userId,
                    'receiver_id': widget.receiverId,
                    'type': 'call_cancel',
                    'call_id': callId,
                    'call_mode': video ? 'video' : 'voice',
                    'content': '[call_cancel]',
                    'is_seen': false,
                  });
                } catch (_) {}
                await _sendSignal(widget.receiverId, 'call_cancel', {
                  'from': widget.userId,
                  'to': widget.receiverId,
                  'call_id': callId,
                  'mode': video ? 'video' : 'voice',
                });
                _awaitingAccept = false;
                _callingDialogOpen = false;
                if (mounted) Navigator.of(context, rootNavigator: true).pop();
              },
              child: const Text('Cancel'),
            ),
          ],
        ),
      ),
    ).then((_) {
      _callingDialogOpen = false;
    });

    // Optional timeout (e.g., 45s)
    Future.delayed(const Duration(seconds: 45), () {
      if (!mounted) return;
      if (_awaitingAccept && _outgoingCallId == callId) {
        _dismissCallingDialog();
        _awaitingAccept = false;
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('No answer')));
      }
    });
  }

  // Caller flow: send invite then wait for accept (do not auto-join)
  void _startZegoCall(bool video) async {
    final callId = _sharedCallId(widget.userId, widget.receiverId);

    try {
      await supabase.from('messages').insert({
        'sender_id': widget.userId,
        'receiver_id': widget.receiverId,
        'type': 'call',
        'content': video ? '[video_call]' : '[voice_call]',
        'call_id': callId,
        'call_mode': video ? 'video' : 'voice',
        'is_seen': false,
      });
    } catch (_) {}
    // NEW: realtime call invite
    await _sendSignal(widget.receiverId, 'call_invite', {
      'from': widget.userId,
      'to': widget.receiverId,
      'call_id': callId,
      'mode': video ? 'video' : 'voice',
    });

    _outgoingCallId = callId;
    _outgoingCallMode = video ? 'video' : 'voice';
    _awaitingAccept = true;
    _openCallingDialog(callId, video);
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

    // Send message notification
    try {
      final senderResponse = await supabase
          .from('users')
          .select('name')
          .eq('id', widget.userId)
          .single();
      
      final senderName = senderResponse['name'] as String? ?? 'Someone';
      
      await sendMessageNotification(
        recipientId: widget.receiverId,
        senderId: widget.userId,
        senderName: senderName,
        messagePreview: content,
      );
    } catch (e) {
      print('Error sending message notification: $e');
    }

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

      // Send voice message notification
      try {
        final senderResponse = await supabase
            .from('users')
            .select('name')
            .eq('id', widget.userId)
            .single();
        
        final senderName = senderResponse['name'] as String? ?? 'Someone';
        
        await sendMessageNotification(
          recipientId: widget.receiverId,
          senderId: widget.userId,
          senderName: senderName,
          messagePreview: '🎵 Voice message',
        );
      } catch (e) {
        print('Error sending voice message notification: $e');
      }

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

    // Send image message notification
    try {
      final senderResponse = await supabase
          .from('users')
          .select('name')
          .eq('id', widget.userId)
          .single();
      
      final senderName = senderResponse['name'] as String? ?? 'Someone';
      
      await sendMessageNotification(
        recipientId: widget.receiverId,
        senderId: widget.userId,
        senderName: senderName,
        messagePreview: '📷 Image',
      );
    } catch (e) {
      print('Error sending image message notification: $e');
    }

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

  // Join an existing call room (used by both caller and callee)
  Future<void> _joinZegoCall({required String callId, required bool video}) async {
    if (_joiningCall) return;
    _joiningCall = true;

    final mic = await Permission.microphone.request();
    if (!mic.isGranted) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Microphone permission denied')));
      }
      _joiningCall = false;
      return;
    }
    if (video) {
      final cam = await Permission.camera.request();
      if (!cam.isGranted) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Camera permission denied')));
        }
        _joiningCall = false;
        return;
      }
    }

    final me = _sanitizeId(widget.userId);
    final myName = (_myDisplayName != null && _myDisplayName!.isNotEmpty) ? _myDisplayName! : me;
    debugPrint('Joining Zego call, callID=$callId, me=$me, name=$myName');

    if (!mounted) {
      _joiningCall = false;
      return;
    }

    final config = video
        ? ZegoUIKitPrebuiltCallConfig.oneOnOneVideoCall()
        : ZegoUIKitPrebuiltCallConfig.oneOnOneVoiceCall();

    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => ZegoUIKitPrebuiltCall(
          appID: int.parse(dotenv.env['ZEGO_APP_ID'] ?? '0'),
          appSign: dotenv.env['ZEGO_APP_SIGN'] ?? '',
          userID: me,
          userName: myName,
          callID: callId,
          config: config,
        ),
      ),
    );

    _joiningCall = false;
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
      backgroundColor: lightBlush,
      appBar: AppBar(
        backgroundColor: deepRed,
        elevation: 0,
        leading: IconButton(
          icon: Container(
            padding: EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.2),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(
              Icons.arrow_back,
              color: Colors.white,
              size: 20,
            ),
          ),
          onPressed: () => Navigator.pop(context),
        ),
        title: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: _receiverProfilePicture == null
                    ? LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [coral.withOpacity(0.8), peach.withOpacity(0.8)],
                      )
                    : null,
                border: Border.all(color: Colors.white, width: 2),
              ),
              child: _receiverProfilePicture != null
                  ? ClipRRect(
                      borderRadius: BorderRadius.circular(20),
                      child: Image.network(
                        _getProfilePictureUrl(_receiverProfilePicture) ?? _receiverProfilePicture!,
                        fit: BoxFit.cover,
                        errorBuilder: (context, error, stackTrace) {
                          return Container(
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                begin: Alignment.topLeft,
                                end: Alignment.bottomRight,
                                colors: [coral.withOpacity(0.8), peach.withOpacity(0.8)],
                              ),
                            ),
                            child: Center(
                              child: Text(
                                widget.userName.isNotEmpty ? widget.userName[0].toUpperCase() : '?',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 16,
                                ),
                              ),
                            ),
                          );
                        },
                      ),
                    )
                  : Center(
                      child: Text(
                        widget.userName.isNotEmpty ? widget.userName[0].toUpperCase() : '?',
                        style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 16,
                        ),
                      ),
                    ),
            ),
            SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    widget.userName,
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (otherUserTyping)
                    Text(
                      'Typing...',
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.white70,
                        fontStyle: FontStyle.italic,
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          Container(
            margin: EdgeInsets.only(right: 4),
            child: IconButton(
              icon: Container(
                padding: EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.2),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(
                  Icons.call,
                  color: Colors.white,
                  size: 20,
                ),
              ),
              onPressed: () => _startZegoCall(false),
            ),
          ),
          Container(
            margin: EdgeInsets.only(right: 8),
            child: IconButton(
              icon: Container(
                padding: EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.2),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(
                  Icons.videocam,
                  color: Colors.white,
                  size: 20,
                ),
              ),
              onPressed: () => _startZegoCall(true),
            ),
          ),
        ],
      ),
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [lightBlush, Colors.white],
          ),
        ),
        child: Column(
          children: [
            Expanded(
              child: RefreshIndicator(
                onRefresh: _refreshAll,
                color: deepRed,
                backgroundColor: Colors.white,
                child: messages.isEmpty
                    ? _buildEmptyState()
                    : _buildMessagesList(lastSeenMessageId),
              ),
            ),
            _buildMessageInput(),
          ],
        ),
      ),
    );
  }

  // Enhanced empty state
  Widget _buildEmptyState() {
    return ListView(
      physics: AlwaysScrollableScrollPhysics(),
      children: [
        Container(
          height: MediaQuery.of(context).size.height * 0.6,
          child: Center(
            child: Padding(
              padding: EdgeInsets.all(32),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Container(
                    padding: EdgeInsets.all(24),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      shape: BoxShape.circle,
                      boxShadow: [
                        BoxShadow(
                          color: deepRed.withOpacity(0.1),
                          blurRadius: 20,
                          offset: Offset(0, 5),
                        ),
                      ],
                    ),
                    child: Icon(
                      Icons.chat_bubble_outline,
                      size: 48,
                      color: coral,
                    ),
                  ),
                  SizedBox(height: 20),
                  Text(
                    'Start the conversation!',
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                      color: deepRed,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  SizedBox(height: 8),
                  Text(
                    'Send a message to ${widget.userName}',
                    style: TextStyle(
                      fontSize: 14,
                      color: Colors.grey.shade600,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  // Enhanced messages list
  Widget _buildMessagesList(String? lastSeenMessageId) {
    return ListView.builder(
      controller: _scrollController,
      reverse: true,
      physics: const AlwaysScrollableScrollPhysics(),
      padding: EdgeInsets.all(16),
      itemCount: messages.length,
      itemBuilder: (_, index) {
        final msg = messages[messages.length - 1 - index];
        final sentByMe = isSender(msg['sender_id']);
        final isLastSeen = lastSeenMessageId != null &&
            msg['id'].toString() == lastSeenMessageId;

        final sentAt = _parseMsgTime(msg['sent_at']);
        final tsLabel = sentAt != null ? _formatChatTimestamp(sentAt) : null;

        return _buildMessageBubble(msg, sentByMe, isLastSeen, tsLabel);
      },
    );
  }

  // Enhanced message bubble
  Widget _buildMessageBubble(Map msg, bool sentByMe, bool isLastSeen, String? tsLabel) {
    Widget content = _buildMessageContent(msg);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (tsLabel != null)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8.0),
            child: Center(
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 12),
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.8),
                  borderRadius: BorderRadius.circular(16),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.grey.withOpacity(0.1),
                      blurRadius: 4,
                      offset: Offset(0, 2),
                    ),
                  ],
                ),
                child: Text(
                  tsLabel,
                  style: TextStyle(
                    fontSize: 11,
                    color: Colors.grey.shade600,
                    fontWeight: FontWeight.w500,
                  ),
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
                constraints: BoxConstraints(
                  maxWidth: MediaQuery.of(context).size.width * 0.75,
                ),
                padding: EdgeInsets.all(12),
                margin: EdgeInsets.symmetric(vertical: 2, horizontal: 4),
                decoration: BoxDecoration(
                  gradient: sentByMe
                      ? LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: [deepRed, coral],
                        )
                      : null,
                  color: sentByMe ? null : Colors.white,
                  borderRadius: BorderRadius.only(
                    topLeft: Radius.circular(16),
                    topRight: Radius.circular(16),
                    bottomLeft: Radius.circular(sentByMe ? 16 : 4),
                    bottomRight: Radius.circular(sentByMe ? 4 : 16),
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: sentByMe 
                        ? deepRed.withOpacity(0.2) 
                        : Colors.grey.withOpacity(0.1),
                      blurRadius: 8,
                      offset: Offset(0, 2),
                    ),
                  ],
                ),
                child: DefaultTextStyle(
                  style: TextStyle(
                    color: sentByMe ? Colors.white : Colors.grey.shade800,
                    fontSize: 15,
                  ),
                  child: content,
                ),
              ),
              if (sentByMe && isLastSeen)
                Padding(
                  padding: const EdgeInsets.only(right: 8.0, top: 2),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.done_all,
                        size: 12,
                        color: coral,
                      ),
                      SizedBox(width: 2),
                      Text(
                        'Seen',
                        style: TextStyle(
                          fontSize: 10,
                          color: coral,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  // Enhanced message content
  Widget _buildMessageContent(Map msg) {
    if (msg['type'] == 'image' && msg['media_url'] != null) {
      return FutureBuilder<String?>(
        future: _mediaUrl(msg),
        builder: (context, snap) {
          final url = snap.data;
          if (url == null) {
            return Container(
              width: 160,
              height: 120,
              decoration: BoxDecoration(
                color: Colors.grey.shade200,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Center(
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: coral,
                ),
              ),
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
                  errorBuilder: (_, __, ___) => Container(
                    width: 200,
                    height: 200,
                    decoration: BoxDecoration(
                      color: Colors.grey.shade200,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Icon(
                      Icons.broken_image,
                      color: Colors.grey.shade400,
                      size: 32,
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      );
    } else if (msg['type'] == 'voice' && msg['media_url'] != null) {
      final playing = _playingMessageId == msg['id']?.toString();
      return Container(
        padding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              decoration: BoxDecoration(
                color: playing ? Colors.white.withOpacity(0.2) : Colors.transparent,
                shape: BoxShape.circle,
              ),
              child: IconButton(
                icon: Icon(
                  playing ? Icons.pause_circle_filled : Icons.play_circle_fill,
                  size: 32,
                ),
                onPressed: () => _togglePlay(msg),
                color: isSender(msg['sender_id']) ? Colors.white : coral,
              ),
            ),
            SizedBox(width: 8),
            Icon(
              Icons.keyboard_voice,
              size: 16,
              color: isSender(msg['sender_id']) ? Colors.white70 : Colors.grey.shade600,
            ),
            SizedBox(width: 4),
            Text(
              'Voice message',
              style: TextStyle(
                fontSize: 14,
                fontStyle: FontStyle.italic,
                color: isSender(msg['sender_id']) ? Colors.white70 : Colors.grey.shade600,
              ),
            ),
          ],
        ),
      );
    } else {
      return Text(
        msg['content'] ?? '[empty]',
        style: TextStyle(fontSize: 15),
      );
    }
  }

  // Enhanced message input
  Widget _buildMessageInput() {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border(
          top: BorderSide(color: Colors.grey.shade200),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.grey.withOpacity(0.1),
            blurRadius: 8,
            offset: Offset(0, -2),
          ),
        ],
      ),
      padding: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 8.0),
      child: Row(
        children: [
          _buildInputButton(Icons.mic, isRecording ? coral : null, _recordOrSendVoice),
          _buildInputButton(Icons.image, null, _pickImage),
          _buildInputButton(Icons.camera_alt, null, _captureImage),
          Expanded(
            child: Container(
              margin: EdgeInsets.symmetric(horizontal: 8),
              decoration: BoxDecoration(
                color: Colors.grey.shade100,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: Colors.grey.shade300),
              ),
              child: TextField(
                controller: _messageController,
                decoration: InputDecoration(
                  hintText: 'Type a message...',
                  hintStyle: TextStyle(color: Colors.grey.shade500),
                  border: InputBorder.none,
                  contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                ),
                maxLines: null,
                textCapitalization: TextCapitalization.sentences,
              ),
            ),
          ),
          _buildInputButton(Icons.send, deepRed, _sendMessage),
        ],
      ),
    );
  }

  // Enhanced input button
  Widget _buildInputButton(IconData icon, Color? activeColor, VoidCallback onPressed) {
    return Container(
      margin: EdgeInsets.symmetric(horizontal: 2),
      child: IconButton(
        icon: Container(
          padding: EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: activeColor ?? Colors.transparent,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Icon(
            icon,
            color: activeColor != null ? Colors.white : coral,
            size: 20,
          ),
        ),
        onPressed: onPressed,
      ),
    );
  }

  // New: pull-to-refresh handler
  Future<void> _refreshAll() async {
    await fetchMessages();
    await markMessagesAsSeen();
  }
}

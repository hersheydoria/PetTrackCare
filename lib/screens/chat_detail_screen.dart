import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_sound/flutter_sound.dart';
import 'package:image_picker/image_picker.dart';
import 'package:image_cropper/image_cropper.dart';
import 'package:image/image.dart' as img;
import 'package:permission_handler/permission_handler.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:zego_uikit_prebuilt_call/zego_uikit_prebuilt_call.dart';
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
  String? _recordedFilePath;
  DateTime? _recordingStartTime;
  Duration _recordingDuration = Duration.zero;

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
  
  // Reply functionality
  Map<String, dynamic>? _replyingToMessage;
  
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

    final messageData = {
      'sender_id': widget.userId,
      'receiver_id': widget.receiverId,
      'content': content,
      'is_seen': false,
      'type': 'text',
    };

    // Add reply reference if replying to a message
    if (_replyingToMessage != null) {
      messageData['reply_to_message_id'] = _replyingToMessage!['id'];
      messageData['reply_to_content'] = _getReplyPreview(_replyingToMessage!);
      messageData['reply_to_sender_id'] = _replyingToMessage!['sender_id'];
    }

    await supabase.from('messages').insert(messageData);

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
    _clearReply(); // Clear reply after sending
    await supabase.from('typing_status').upsert({
      'user_id': widget.userId,
      'chat_with_id': widget.receiverId,
      'is_typing': false,
    });

    await fetchMessages();
  }

  Future<void> _recordOrSendVoice() async {
    if (!isRecording && _recordedFilePath == null) {
      // Start recording
      await _startRecording();
    } else if (isRecording) {
      // Stop recording and show preview
      await _stopRecording();
    }
    // If there's a recorded file but not currently recording, 
    // the button behavior is handled by the preview dialog
  }

  Future<void> _startRecording() async {
    await Permission.microphone.request();
    
    try {
      final tempDir = Directory.systemTemp;
      final fileName = 'voice_${DateTime.now().millisecondsSinceEpoch}.aac';
      final filePath = '${tempDir.path}/$fileName';
      
      await _recorder!.startRecorder(toFile: filePath);
      
      setState(() {
        isRecording = true;
        _recordingStartTime = DateTime.now();
        _recordedFilePath = filePath;
        _recordingDuration = Duration.zero;
      });
      
      // Start timer to update duration
      _startRecordingTimer();
      
    } catch (e) {
      print('Error starting recording: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to start recording. Please try again.'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  void _startRecordingTimer() {
    // Update recording duration every 100ms
    Future.doWhile(() async {
      await Future.delayed(Duration(milliseconds: 100));
      if (!isRecording || !mounted) return false;
      
      setState(() {
        if (_recordingStartTime != null) {
          _recordingDuration = DateTime.now().difference(_recordingStartTime!);
        }
      });
      
      return isRecording;
    });
  }

  Future<void> _stopRecording() async {
    try {
      await _recorder!.stopRecorder();
      
      setState(() {
        isRecording = false;
      });
      
      if (_recordedFilePath != null) {
        await _showVoicePreview();
      }
      
    } catch (e) {
      print('Error stopping recording: $e');
      setState(() {
        isRecording = false;
        _recordedFilePath = null;
        _recordingDuration = Duration.zero;
      });
    }
  }

  Future<void> _showVoicePreview() async {
    if (_recordedFilePath == null) return;
    
    final result = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext context) {
        return Dialog(
          backgroundColor: Colors.transparent,
          child: Container(
            constraints: BoxConstraints(
              maxWidth: MediaQuery.of(context).size.width * 0.9,
            ),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Header
                Container(
                  padding: EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: deepRed,
                    borderRadius: BorderRadius.only(
                      topLeft: Radius.circular(16),
                      topRight: Radius.circular(16),
                    ),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.keyboard_voice, color: Colors.white),
                      SizedBox(width: 8),
                      Text(
                        'Voice Message',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                ),
                
                // Voice preview content
                Container(
                  padding: EdgeInsets.all(24),
                  child: Column(
                    children: [
                      // Waveform visualization (simplified)
                      Container(
                        height: 80,
                        width: double.infinity,
                        decoration: BoxDecoration(
                          color: lightBlush,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: coral.withOpacity(0.3)),
                        ),
                        child: Center(
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(
                                Icons.graphic_eq,
                                size: 32,
                                color: coral,
                              ),
                              SizedBox(width: 12),
                              Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    'Voice Message',
                                    style: TextStyle(
                                      fontSize: 16,
                                      fontWeight: FontWeight.w600,
                                      color: deepRed,
                                    ),
                                  ),
                                  Text(
                                    _formatDuration(_recordingDuration),
                                    style: TextStyle(
                                      fontSize: 14,
                                      color: Colors.grey.shade600,
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),
                      
                      SizedBox(height: 16),
                      
                      // Play button
                      Container(
                        decoration: BoxDecoration(
                          color: coral.withOpacity(0.1),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: IconButton(
                          onPressed: () => _playRecordedVoice(),
                          icon: Icon(
                            Icons.play_circle_fill,
                            size: 48,
                            color: coral,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                
                // Action buttons
                Container(
                  padding: EdgeInsets.all(16),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      // Delete button
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: () => Navigator.of(context).pop('delete'),
                          icon: Icon(Icons.delete, color: Colors.red.shade600),
                          label: Text(
                            'Delete',
                            style: TextStyle(color: Colors.red.shade600),
                          ),
                          style: OutlinedButton.styleFrom(
                            padding: EdgeInsets.symmetric(vertical: 12),
                            side: BorderSide(color: Colors.red.shade300),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(8),
                            ),
                          ),
                        ),
                      ),
                      
                      SizedBox(width: 12),
                      
                      // Re-record button
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: () => Navigator.of(context).pop('redo'),
                          icon: Icon(Icons.refresh, color: coral),
                          label: Text(
                            'Redo',
                            style: TextStyle(color: coral),
                          ),
                          style: OutlinedButton.styleFrom(
                            padding: EdgeInsets.symmetric(vertical: 12),
                            side: BorderSide(color: coral),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(8),
                            ),
                          ),
                        ),
                      ),
                      
                      SizedBox(width: 12),
                      
                      // Send button
                      Expanded(
                        child: ElevatedButton.icon(
                          onPressed: () => Navigator.of(context).pop('send'),
                          icon: Icon(Icons.send, color: Colors.white),
                          label: Text(
                            'Send',
                            style: TextStyle(color: Colors.white),
                          ),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: deepRed,
                            padding: EdgeInsets.symmetric(vertical: 12),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(8),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );

    // Handle user choice
    if (result == 'send') {
      await _sendVoiceMessage();
    } else if (result == 'delete') {
      await _deleteRecording();
    } else if (result == 'redo') {
      await _redoRecording();
    }
  }

  Future<void> _playRecordedVoice() async {
    if (_recordedFilePath == null || _player == null) return;
    
    try {
      await _player!.startPlayer(
        fromURI: _recordedFilePath!,
        codec: Codec.aacADTS,
      );
    } catch (e) {
      print('Error playing recorded voice: $e');
    }
  }

  Future<void> _sendVoiceMessage() async {
    if (_recordedFilePath == null) return;
    
    try {
      // Show loading indicator
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Row(
              children: [
                SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                  ),
                ),
                SizedBox(width: 12),
                Text('Sending voice message...'),
              ],
            ),
            backgroundColor: deepRed,
            duration: Duration(seconds: 10),
          ),
        );
      }

      final fileBytes = await File(_recordedFilePath!).readAsBytes();
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
        // Add reply fields if replying
        if (_replyingToMessage != null) ...{
          'reply_to_message_id': _replyingToMessage!['id'],
          'reply_to_content': _getReplyPreview(_replyingToMessage!),
          'reply_to_sender_id': _replyingToMessage!['sender_id'],
        },
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

      // Clean up and refresh
      await _deleteRecording();
      _clearReply(); // Clear reply after sending
      
      if (mounted) {
        ScaffoldMessenger.of(context).hideCurrentSnackBar();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Voice message sent!'),
            backgroundColor: Colors.green,
            duration: Duration(seconds: 2),
          ),
        );
      }

      fetchMessages();
      
    } catch (e) {
      print('Error sending voice message: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).hideCurrentSnackBar();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to send voice message. Please try again.'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Future<void> _deleteRecording() async {
    if (_recordedFilePath != null) {
      try {
        await File(_recordedFilePath!).delete();
      } catch (e) {
        print('Error deleting recording file: $e');
      }
      
      setState(() {
        _recordedFilePath = null;
        _recordingDuration = Duration.zero;
        _recordingStartTime = null;
      });
    }
  }

  Future<void> _redoRecording() async {
    await _deleteRecording();
    await _startRecording();
  }

  String _formatDuration(Duration duration) {
    String twoDigits(int n) => n.toString().padLeft(2, '0');
    String minutes = twoDigits(duration.inMinutes);
    String seconds = twoDigits(duration.inSeconds.remainder(60));
    return '$minutes:$seconds';
  }

  // Preprocess large images before cropping to prevent memory crashes
  Future<File> _preprocessImageForCropping(File originalFile) async {
    try {
      // Get file info
      final fileSize = await originalFile.length();
      final fileSizeMB = (fileSize / 1024 / 1024);
      
      print('Preprocessing image for cropper safety: ${fileSizeMB.toStringAsFixed(2)} MB');
      
      // Decode the image to check if it's valid and get dimensions
      final img.Image? originalImage = img.decodeImage(await originalFile.readAsBytes());
      
      if (originalImage == null) {
        throw Exception('Invalid or corrupted image file');
      }
      
      print('Image dimensions: ${originalImage.width}x${originalImage.height}');
      
      // Determine if we need to resize based on size or dimensions
      bool needsResize = false;
      int targetWidth = originalImage.width;
      int targetHeight = originalImage.height;
      int quality = 80;
      
      // Check file size criteria
      if (fileSizeMB > 5) {
        needsResize = true;
        quality = 60;
        print('Large file detected, will resize');
      }
      
      // Check dimension criteria - very large or problematic dimensions
      if (originalImage.width > 3000 || originalImage.height > 3000) {
        needsResize = true;
        quality = 60;
        print('Large dimensions detected, will resize');
      }
      
      // Check for unusual aspect ratios that might cause issues
      final aspectRatio = originalImage.width / originalImage.height;
      if (aspectRatio > 10 || aspectRatio < 0.1) {
        needsResize = true;
        quality = 70;
        print('Unusual aspect ratio detected: ${aspectRatio.toStringAsFixed(2)}');
      }
      
      // For very small images, ensure minimum quality to prevent corruption
      if (fileSizeMB < 0.1) {
        quality = 90; // High quality for small images
        print('Very small file detected, using high quality');
      }
      
      // If we need to resize, calculate new dimensions
      if (needsResize) {
        // Calculate new dimensions maintaining aspect ratio
        if (originalImage.width > originalImage.height) {
          targetWidth = originalImage.width > 2000 ? 2000 : originalImage.width;
          targetHeight = (targetWidth * originalImage.height / originalImage.width).round();
        } else {
          targetHeight = originalImage.height > 2000 ? 2000 : originalImage.height;
          targetWidth = (targetHeight * originalImage.width / originalImage.height).round();
        }
        
        print('Resizing to: ${targetWidth}x${targetHeight}');
      }
      
      // Always re-encode to ensure compatible JPEG format
      img.Image processedImage = originalImage;
      
      // Resize if needed
      if (needsResize && (targetWidth != originalImage.width || targetHeight != originalImage.height)) {
        processedImage = img.copyResize(
          originalImage,
          width: targetWidth,
          height: targetHeight,
          interpolation: img.Interpolation.cubic,
        );
      }
      
      // Create temporary file with processed image
      final tempDir = Directory.systemTemp;
      final tempFile = File('${tempDir.path}/processed_image_${DateTime.now().millisecondsSinceEpoch}.jpg');
      
      // Encode as JPEG with appropriate quality
      final encodedImage = img.encodeJpg(processedImage, quality: quality);
      await tempFile.writeAsBytes(encodedImage);
      
      final newSize = await tempFile.length();
      final newSizeMB = (newSize / 1024 / 1024);
      print('Preprocessing complete. New size: ${newSizeMB.toStringAsFixed(2)} MB');
      
      return tempFile;
      
    } catch (e) {
      print('Error preprocessing image: $e');
      
      // If preprocessing fails, try a basic JPEG conversion
      try {
        final bytes = await originalFile.readAsBytes();
        final img.Image? image = img.decodeImage(bytes);
        
        if (image != null) {
          final tempDir = Directory.systemTemp;
          final tempFile = File('${tempDir.path}/fallback_image_${DateTime.now().millisecondsSinceEpoch}.jpg');
          
          // Basic JPEG encoding with safe quality
          final encodedImage = img.encodeJpg(image, quality: 80);
          await tempFile.writeAsBytes(encodedImage);
          
          print('Used fallback preprocessing');
          return tempFile;
        }
      } catch (fallbackError) {
        print('Fallback preprocessing also failed: $fallbackError');
      }
      
      // If all else fails, return original file and hope for the best
      print('Using original file without preprocessing');
      return originalFile;
    }
  }

  // Helper method to validate image file format by checking file headers
  bool _isValidImageFile(List<int> bytes) {
    if (bytes.length < 4) return false;
    
    // Check for common image file signatures
    // JPEG: FF D8 FF
    if (bytes[0] == 0xFF && bytes[1] == 0xD8 && bytes[2] == 0xFF) {
      return true;
    }
    
    // PNG: 89 50 4E 47
    if (bytes.length >= 8 && 
        bytes[0] == 0x89 && bytes[1] == 0x50 && 
        bytes[2] == 0x4E && bytes[3] == 0x47) {
      return true;
    }
    
    // GIF: 47 49 46 38
    if (bytes.length >= 6 &&
        bytes[0] == 0x47 && bytes[1] == 0x49 && 
        bytes[2] == 0x46 && bytes[3] == 0x38) {
      return true;
    }
    
    // WebP: 52 49 46 46 (RIFF) ... 57 45 42 50 (WEBP)
    if (bytes.length >= 12 &&
        bytes[0] == 0x52 && bytes[1] == 0x49 && 
        bytes[2] == 0x46 && bytes[3] == 0x46 &&
        bytes[8] == 0x57 && bytes[9] == 0x45 && 
        bytes[10] == 0x42 && bytes[11] == 0x50) {
      return true;
    }
    
    return false;
  }

  // Helper method to normalize image extensions for better compatibility
  String _normalizeImageExtension(String ext) {
    switch (ext.toLowerCase()) {
      case 'jpg':
      case 'jpeg':
        return 'jpg';
      case 'png':
        return 'png';
      case 'gif':
        return 'gif';
      case 'webp':
        return 'webp';
      default:
        // Default to jpg for unknown extensions
        return 'jpg';
    }
  }

  // Helper method to build image with fallback handling for decompression errors
  Widget _buildImageWithFallback({
    required String url,
    required double width,
    required double height,
  }) {
    return Image.network(
      url,
      fit: BoxFit.cover,
      width: width,
      height: height,
      loadingBuilder: (context, child, loadingProgress) {
        if (loadingProgress == null) return child;
        return Container(
          width: width,
          height: height,
          decoration: BoxDecoration(
            color: Colors.grey.shade100,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Center(
            child: CircularProgressIndicator(
              value: loadingProgress.expectedTotalBytes != null
                  ? loadingProgress.cumulativeBytesLoaded / 
                    loadingProgress.expectedTotalBytes!
                  : null,
              color: coral,
              strokeWidth: 2,
            ),
          ),
        );
      },
      errorBuilder: (context, error, stackTrace) {
        print('Error loading image: $error');
        print('Image URL: $url');
        
        // Check if it's a decompression error specifically
        final isDecompressionError = error.toString().contains('Could not decompress image') ||
                                   error.toString().contains('decompression') ||
                                   error.toString().contains('decode');
        
        return Container(
          width: width,
          height: height,
          decoration: BoxDecoration(
            color: Colors.grey.shade200,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: Colors.grey.shade300),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                isDecompressionError ? Icons.image_not_supported : Icons.broken_image,
                color: Colors.grey.shade400,
                size: 32,
              ),
              SizedBox(height: 4),
              Text(
                isDecompressionError ? 'Image format not supported' : 'Image failed to load',
                style: TextStyle(
                  fontSize: 10,
                  color: Colors.grey.shade500,
                ),
                textAlign: TextAlign.center,
              ),
              if (isDecompressionError) ...[
                SizedBox(height: 4),
                Text(
                  'Try sending a different image format',
                  style: TextStyle(
                    fontSize: 8,
                    color: Colors.grey.shade400,
                  ),
                  textAlign: TextAlign.center,
                ),
              ],
            ],
          ),
        );
      },
      // Add headers to help with caching and compatibility
      headers: {
        'Accept': 'image/jpeg,image/png,image/gif,image/webp,image/*,*/*;q=0.8',
        'Cache-Control': 'max-age=3600',
      },
    );
  }

  // Reply functionality
  void _setReplyMessage(Map message) {
    setState(() {
      _replyingToMessage = Map<String, dynamic>.from(message);
    });
  }

  void _clearReply() {
    setState(() {
      _replyingToMessage = null;
    });
  }

  String _getReplyPreview(Map<String, dynamic> message) {
    final type = message['type']?.toString() ?? 'text';
    final content = message['content']?.toString() ?? '';
    
    switch (type) {
      case 'image':
        return '📷 Image';
      case 'voice':
        return '🎵 Voice message';
      case 'call':
        return '📞 Call';
      default:
        // Limit text preview to 50 characters
        return content.length > 50 ? '${content.substring(0, 50)}...' : content;
    }
  }

  Future<void> _pickImage() async {
    final picker = ImagePicker();
    final pickedFile = await picker.pickImage(
      source: ImageSource.gallery,
      maxWidth: 2048,
      maxHeight: 2048,
      imageQuality: 85, // Slightly compress to ensure compatibility
    );
    if (pickedFile != null) {
      await _showImageEditOptions(File(pickedFile.path));
    }
  }

  Future<void> _captureImage() async {
    final picker = ImagePicker();
    final pickedFile = await picker.pickImage(
      source: ImageSource.camera,
      maxWidth: 2048,
      maxHeight: 2048,
      imageQuality: 85, // Slightly compress to ensure compatibility
    );
    if (pickedFile != null) {
      await _showImageEditOptions(File(pickedFile.path));
    }
  }

  Future<void> _showImageEditOptions(File imageFile) async {
    // Get image size for display
    final fileSize = await imageFile.length();
    final fileSizeMB = (fileSize / 1024 / 1024);
    
    // Show image preview with edit options
    final result = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext context) {
        return Dialog(
          backgroundColor: Colors.transparent,
          child: Container(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.of(context).size.height * 0.8,
              maxWidth: MediaQuery.of(context).size.width * 0.9,
            ),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Header with size info
                Container(
                  padding: EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: deepRed,
                    borderRadius: BorderRadius.only(
                      topLeft: Radius.circular(16),
                      topRight: Radius.circular(16),
                    ),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.image, color: Colors.white),
                      SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Image Preview',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                      Text(
                        '${fileSizeMB.toStringAsFixed(1)}MB',
                        style: TextStyle(
                          color: Colors.white70,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
                
                // Image preview
                Flexible(
                  child: Container(
                    padding: EdgeInsets.all(16),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: Image.file(
                        imageFile,
                        fit: BoxFit.contain,
                        errorBuilder: (context, error, stackTrace) {
                          return Container(
                            height: 200,
                            width: double.infinity,
                            color: Colors.grey.shade200,
                            child: Icon(
                              Icons.broken_image,
                              size: 48,
                              color: Colors.grey.shade400,
                            ),
                          );
                        },
                      ),
                    ),
                  ),
                ),
                
                // Action buttons
                Container(
                  padding: EdgeInsets.all(16),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      // Cancel button
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: () => Navigator.of(context).pop('cancel'),
                          icon: Icon(Icons.close, color: Colors.grey.shade600),
                          label: Text(
                            'Cancel',
                            style: TextStyle(color: Colors.grey.shade600),
                          ),
                          style: OutlinedButton.styleFrom(
                            padding: EdgeInsets.symmetric(vertical: 12),
                            side: BorderSide(color: Colors.grey.shade300),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(8),
                            ),
                          ),
                        ),
                      ),
                      
                      SizedBox(width: 12),
                      
                      // Edit/Crop button
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: () => Navigator.of(context).pop('edit'),
                          icon: Icon(Icons.crop, color: coral),
                          label: Text(
                            'Edit',
                            style: TextStyle(color: coral),
                          ),
                          style: OutlinedButton.styleFrom(
                            padding: EdgeInsets.symmetric(vertical: 12),
                            side: BorderSide(color: coral),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(8),
                            ),
                          ),
                        ),
                      ),
                      
                      SizedBox(width: 12),
                      
                      // Send button
                      Expanded(
                        child: ElevatedButton.icon(
                          onPressed: () => Navigator.of(context).pop('send'),
                          icon: Icon(Icons.send, color: Colors.white),
                          label: Text(
                            'Send',
                            style: TextStyle(color: Colors.white),
                          ),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: deepRed,
                            padding: EdgeInsets.symmetric(vertical: 12),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(8),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );

    // Handle user choice
    if (result == 'send') {
      await _uploadMedia(imageFile, 'image');
    } else if (result == 'edit') {
      await _cropImage(imageFile);
    }
    // If 'cancel' or null, do nothing
  }

  Future<void> _cropImage(File imageFile) async {
    try {
      // Check file size and get image info
      final fileSize = await imageFile.length();
      final fileSizeMB = (fileSize / 1024 / 1024);
      
      print('Original image size for cropping: ${fileSizeMB.toStringAsFixed(2)} MB');
      
      // Always preprocess images to ensure compatibility with the cropper
      // This handles format issues, corruption, and memory problems
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Preparing image for editing...'),
            backgroundColor: coral,
            duration: Duration(seconds: 2),
          ),
        );
      }
      
      // Preprocess ALL images to ensure they're in a compatible format
      final processedFile = await _preprocessImageForCropping(imageFile);
      
      final newSize = await processedFile.length();
      final newSizeMB = (newSize / 1024 / 1024);
      print('Preprocessed image size: ${newSizeMB.toStringAsFixed(2)} MB');
      
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Opening image editor...'),
            backgroundColor: coral,
            duration: Duration(seconds: 1),
          ),
        );
      }
      
      // Use safe settings for the cropper
      final croppedFile = await ImageCropper().cropImage(
        sourcePath: processedFile.path,
        compressFormat: ImageCompressFormat.jpg,
        compressQuality: 80, // Good quality but safe
        maxWidth: 1920, // Safe max dimensions
        maxHeight: 1920,
        uiSettings: [
          AndroidUiSettings(
            toolbarTitle: 'Crop Image',
            toolbarColor: deepRed,
            toolbarWidgetColor: Colors.white,
            activeControlsWidgetColor: deepRed,
            backgroundColor: Colors.white,
            cropGridColor: deepRed,
            cropFrameColor: deepRed,
            statusBarColor: deepRed,
            lockAspectRatio: false,
            hideBottomControls: false,
            initAspectRatio: CropAspectRatioPreset.original,
          ),
          IOSUiSettings(
            title: 'Crop Image',
            doneButtonTitle: 'Done',
            cancelButtonTitle: 'Cancel',
            rotateButtonsHidden: false,
            aspectRatioPickerButtonHidden: false,
            resetButtonHidden: false,
          ),
        ],
      );

      if (croppedFile != null) {
        // Check the size of the cropped image
        final croppedSize = await File(croppedFile.path).length();
        final croppedSizeMB = (croppedSize / 1024 / 1024);
        print('Cropped image size: ${croppedSizeMB.toStringAsFixed(2)} MB');
        
        if (mounted) {
          ScaffoldMessenger.of(context).hideCurrentSnackBar();
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Image edited successfully! Size: ${croppedSizeMB.toStringAsFixed(1)}MB'),
              backgroundColor: Colors.green,
              duration: Duration(seconds: 2),
            ),
          );
        }
        
        // Show edit options again with the cropped image
        await _showImageEditOptions(File(croppedFile.path));
      } else {
        // User cancelled cropping
        if (mounted) {
          ScaffoldMessenger.of(context).hideCurrentSnackBar();
        }
      }
    } catch (e) {
      print('Error cropping image: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).hideCurrentSnackBar();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error editing image. Try with a smaller image or send original.'),
            backgroundColor: Colors.red,
            duration: Duration(seconds: 4),
            action: SnackBarAction(
              label: 'Send Original',
              textColor: Colors.white,
              onPressed: () => _uploadMedia(imageFile, 'image'),
            ),
          ),
        );
      }
    }
  }

  Future<void> _uploadMedia(File file, String type) async {
    // Show loading indicator
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Row(
            children: [
              SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                ),
              ),
              SizedBox(width: 12),
              Text('Sending image...'),
            ],
          ),
          backgroundColor: deepRed,
          duration: Duration(seconds: 10),
        ),
      );
    }

    try {
      // File validation and size check
      final fileSize = await file.length();
      if (fileSize == 0) {
        throw Exception('File is empty');
      }

      print('Uploading image: ${file.path}, size: ${(fileSize / 1024).toStringAsFixed(1)}KB');

      // Read and validate file bytes
      final bytes = await file.readAsBytes();
      if (bytes.isEmpty) {
        throw Exception('Failed to read image data');
      }

      // Validate that it's actually an image by checking file header
      if (!_isValidImageFile(bytes)) {
        throw Exception('Invalid image file format');
      }
      
      // Get file extension and normalize it
      final ext = file.path.split('.').last.toLowerCase();
      final normalizedExt = _normalizeImageExtension(ext);
      final filename = '${DateTime.now().millisecondsSinceEpoch}.$normalizedExt';
      
      // Always use JPEG content type for better compatibility
      // Most image viewers can handle JPEG reliably
      final contentType = 'image/jpeg';

      print('Normalized extension: $normalizedExt, Content-Type: $contentType');

      // Upload with proper headers for image handling
      await supabase.storage.from('chat-media').uploadBinary(
        'images/$filename',
        bytes,
        fileOptions: FileOptions(
          contentType: contentType,
          upsert: true,
          // Add cache control headers for better performance
          cacheControl: '31536000', // 1 year cache
        ),
      );

      await supabase.from('messages').insert({
        'sender_id': widget.userId,
        'receiver_id': widget.receiverId,
        'content': '[image]',
        'is_seen': false,
        'type': type,
        'media_url': 'images/$filename',
        // Add reply fields if replying
        if (_replyingToMessage != null) ...{
          'reply_to_message_id': _replyingToMessage!['id'],
          'reply_to_content': _getReplyPreview(_replyingToMessage!),
          'reply_to_sender_id': _replyingToMessage!['sender_id'],
        },
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

      // Hide loading indicator
      if (mounted) {
        ScaffoldMessenger.of(context).hideCurrentSnackBar();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Image sent successfully!'),
            backgroundColor: Colors.green,
            duration: Duration(seconds: 2),
          ),
        );
      }

      _clearReply(); // Clear reply after sending
      fetchMessages();
    } catch (e) {
      print('Error uploading image: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).hideCurrentSnackBar();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to send image: ${e.toString().contains('413') ? 'File too large' : 'Upload error'}'),
            backgroundColor: Colors.red,
            action: SnackBarAction(
              label: 'Retry',
              textColor: Colors.white,
              onPressed: () => _uploadMedia(file, type),
            ),
          ),
        );
      }
    }
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
                        ? Hero(
                            tag: tag, 
                            child: Image.network(
                              url,
                              loadingBuilder: (context, child, loadingProgress) {
                                if (loadingProgress == null) return child;
                                return Container(
                                  width: MediaQuery.of(context).size.width,
                                  height: MediaQuery.of(context).size.height * 0.5,
                                  color: Colors.black,
                                  child: Center(
                                    child: Column(
                                      mainAxisAlignment: MainAxisAlignment.center,
                                      children: [
                                        CircularProgressIndicator(
                                          value: loadingProgress.expectedTotalBytes != null
                                              ? loadingProgress.cumulativeBytesLoaded / 
                                                loadingProgress.expectedTotalBytes!
                                              : null,
                                          color: Colors.white,
                                        ),
                                        SizedBox(height: 16),
                                        Text(
                                          'Loading image...',
                                          style: TextStyle(color: Colors.white),
                                        ),
                                      ],
                                    ),
                                  ),
                                );
                              },
                              errorBuilder: (context, error, stackTrace) {
                                print('Error loading full-size image: $error');
                                return Container(
                                  width: MediaQuery.of(context).size.width,
                                  height: MediaQuery.of(context).size.height * 0.5,
                                  color: Colors.black,
                                  child: Center(
                                    child: Column(
                                      mainAxisAlignment: MainAxisAlignment.center,
                                      children: [
                                        Icon(
                                          Icons.broken_image,
                                          color: Colors.white,
                                          size: 64,
                                        ),
                                        SizedBox(height: 16),
                                        Text(
                                          'Failed to load image',
                                          style: TextStyle(
                                            color: Colors.white,
                                            fontSize: 16,
                                          ),
                                        ),
                                        SizedBox(height: 8),
                                        Text(
                                          'The image may be corrupted or unavailable',
                                          style: TextStyle(
                                            color: Colors.white70,
                                            fontSize: 12,
                                          ),
                                          textAlign: TextAlign.center,
                                        ),
                                      ],
                                    ),
                                  ),
                                );
                              },
                            )
                          )
                        : Image.network(
                            url,
                            loadingBuilder: (context, child, loadingProgress) {
                              if (loadingProgress == null) return child;
                              return Container(
                                width: MediaQuery.of(context).size.width,
                                height: MediaQuery.of(context).size.height * 0.5,
                                color: Colors.black,
                                child: Center(
                                  child: Column(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      CircularProgressIndicator(
                                        value: loadingProgress.expectedTotalBytes != null
                                            ? loadingProgress.cumulativeBytesLoaded / 
                                              loadingProgress.expectedTotalBytes!
                                            : null,
                                        color: Colors.white,
                                      ),
                                      SizedBox(height: 16),
                                      Text(
                                        'Loading image...',
                                        style: TextStyle(color: Colors.white),
                                      ),
                                    ],
                                  ),
                                ),
                              );
                            },
                            errorBuilder: (context, error, stackTrace) {
                              print('Error loading full-size image: $error');
                              return Container(
                                width: MediaQuery.of(context).size.width,
                                height: MediaQuery.of(context).size.height * 0.5,
                                color: Colors.black,
                                child: Center(
                                  child: Column(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      Icon(
                                        Icons.broken_image,
                                        color: Colors.white,
                                        size: 64,
                                      ),
                                      SizedBox(height: 16),
                                      Text(
                                        'Failed to load image',
                                        style: TextStyle(
                                          color: Colors.white,
                                          fontSize: 16,
                                        ),
                                      ),
                                      SizedBox(height: 8),
                                      Text(
                                        'The image may be corrupted or unavailable',
                                        style: TextStyle(
                                          color: Colors.white70,
                                          fontSize: 12,
                                        ),
                                        textAlign: TextAlign.center,
                                      ),
                                    ],
                                  ),
                                ),
                              );
                            },
                          ),
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
    
    // Ensure audio and video are enabled
    config.turnOnCameraWhenJoining = video;
    config.turnOnMicrophoneWhenJoining = true;
    config.useSpeakerWhenJoining = true;
    
    // Enable audio/video settings
    config.audioVideoView.showCameraStateOnView = true;
    config.audioVideoView.showMicrophoneStateOnView = true;
    config.audioVideoView.showSoundWavesInAudioMode = true;

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

  // Enhanced message bubble with swipe-to-reply
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
        _buildSwipeableMessage(msg, sentByMe, isLastSeen, content),
      ],
    );
  }

  // Swipeable message wrapper with controlled swipe distance
  Widget _buildSwipeableMessage(Map msg, bool sentByMe, bool isLastSeen, Widget content) {
    return _SwipeToReplyWidget(
      onReply: () => _setReplyMessage(msg),
      swipeDirection: sentByMe ? SwipeDirection.rightToLeft : SwipeDirection.leftToRight,
      child: Align(
        alignment: sentByMe ? Alignment.centerRight : Alignment.centerLeft,
        child: Column(
          crossAxisAlignment: sentByMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
          children: [
            // Show reply context if this message is a reply
            if (msg['reply_to_message_id'] != null)
              _buildReplyContext(msg),
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
    );
  }

  // Reply context widget
  Widget _buildReplyContext(Map msg) {
    final sentByMe = isSender(msg['sender_id']);
    final replyContent = msg['reply_to_content']?.toString() ?? '';
    final replySenderId = msg['reply_to_sender_id']?.toString() ?? '';
    final isReplyFromMe = replySenderId == widget.userId;
    
    return Container(
      margin: EdgeInsets.only(
        left: sentByMe ? 40 : 8,
        right: sentByMe ? 8 : 40,
        bottom: 4,
      ),
      padding: EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: Colors.grey.shade100,
        borderRadius: BorderRadius.circular(8),
        border: Border(
          left: BorderSide(
            color: isReplyFromMe ? deepRed : coral,
            width: 3,
          ),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            isReplyFromMe ? 'You' : widget.userName,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: isReplyFromMe ? deepRed : coral,
            ),
          ),
          SizedBox(height: 2),
          Text(
            replyContent,
            style: TextStyle(
              fontSize: 12,
              color: Colors.grey.shade600,
            ),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
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
                child: _buildImageWithFallback(
                  url: url,
                  width: 200,
                  height: 200,
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

  // Enhanced message input with reply preview
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
      child: Column(
        children: [
          // Reply preview
          if (_replyingToMessage != null)
            _buildReplyPreview(),
          // Input row
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 8.0),
            child: Row(
              children: [
                _buildVoiceButton(),
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
                        hintText: _replyingToMessage != null 
                          ? 'Reply to ${isSender(_replyingToMessage!['sender_id']) ? 'yourself' : widget.userName}...'
                          : 'Type a message...',
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
          ),
        ],
      ),
    );
  }

  // Reply preview widget
  Widget _buildReplyPreview() {
    if (_replyingToMessage == null) return SizedBox.shrink();
    
    final isReplyToMe = isSender(_replyingToMessage!['sender_id']);
    final replyContent = _getReplyPreview(_replyingToMessage!);
    
    return Container(
      width: double.infinity,
      padding: EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.grey.shade50,
        border: Border(
          bottom: BorderSide(color: Colors.grey.shade200),
          left: BorderSide(
            color: isReplyToMe ? deepRed : coral,
            width: 4,
          ),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Replying to ${isReplyToMe ? 'yourself' : widget.userName}',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: isReplyToMe ? deepRed : coral,
                  ),
                ),
                SizedBox(height: 2),
                Text(
                  replyContent,
                  style: TextStyle(
                    fontSize: 13,
                    color: Colors.grey.shade600,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          IconButton(
            icon: Icon(
              Icons.close,
              size: 20,
              color: Colors.grey.shade500,
            ),
            onPressed: _clearReply,
            padding: EdgeInsets.zero,
            constraints: BoxConstraints(
              minWidth: 32,
              minHeight: 32,
            ),
          ),
        ],
      ),
    );
  }

  // Enhanced input button
  Widget _buildVoiceButton() {
    return Container(
      margin: EdgeInsets.symmetric(horizontal: 2),
      child: GestureDetector(
        onTap: _recordOrSendVoice,
        child: Container(
          padding: EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: isRecording ? Colors.red : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
          ),
          child: isRecording 
            ? Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.stop,
                    color: Colors.white,
                    size: 20,
                  ),
                  SizedBox(width: 4),
                  Text(
                    _formatDuration(_recordingDuration),
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              )
            : Icon(
                Icons.mic,
                color: coral,
                size: 20,
              ),
        ),
      ),
    );
  }

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

// Enum for swipe direction
enum SwipeDirection {
  leftToRight,
  rightToLeft,
}

// Custom swipe-to-reply widget with limited swipe distance
class _SwipeToReplyWidget extends StatefulWidget {
  final Widget child;
  final VoidCallback onReply;
  final SwipeDirection swipeDirection;

  const _SwipeToReplyWidget({
    required this.child,
    required this.onReply,
    required this.swipeDirection,
  });

  @override
  _SwipeToReplyWidgetState createState() => _SwipeToReplyWidgetState();
}

class _SwipeToReplyWidgetState extends State<_SwipeToReplyWidget>
    with SingleTickerProviderStateMixin {
  late AnimationController _animationController;
  
  double _dragDistance = 0;
  final double _maxSwipeDistance = 80; // Maximum swipe distance
  final double _replyThreshold = 50; // Threshold to trigger reply
  bool _hasTriggered = false;

  @override
  void initState() {
    super.initState();
    _animationController = AnimationController(
      duration: Duration(milliseconds: 200),
      vsync: this,
    );
  }

  @override
  void dispose() {
    _animationController.dispose();
    super.dispose();
  }

  void _onPanUpdate(DragUpdateDetails details) {
    final delta = details.delta.dx;
    
    // Check if swipe is in the correct direction
    bool isValidDirection = false;
    if (widget.swipeDirection == SwipeDirection.rightToLeft && delta < 0) {
      isValidDirection = true;
    } else if (widget.swipeDirection == SwipeDirection.leftToRight && delta > 0) {
      isValidDirection = true;
    }
    
    if (!isValidDirection) return;
    
    setState(() {
      _dragDistance = (_dragDistance + delta.abs()).clamp(0, _maxSwipeDistance);
    });

    // Trigger haptic feedback when threshold is reached
    if (_dragDistance >= _replyThreshold && !_hasTriggered) {
      _hasTriggered = true;
      // Light haptic feedback to indicate reply will be triggered
      // HapticFeedback.lightImpact(); // Uncomment if you want haptic feedback
    }
  }

  void _onPanEnd(DragEndDetails details) {
    if (_dragDistance >= _replyThreshold) {
      widget.onReply();
      // Add a small animation to indicate reply was triggered
      _animationController.forward().then((_) {
        _animationController.reverse();
      });
    }
    
    // Reset state
    setState(() {
      _dragDistance = 0;
      _hasTriggered = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final isLeftToRight = widget.swipeDirection == SwipeDirection.leftToRight;
    final replyIconOpacity = (_dragDistance / _replyThreshold).clamp(0.0, 1.0);
    
    return GestureDetector(
      onPanUpdate: _onPanUpdate,
      onPanEnd: _onPanEnd,
      child: Stack(
        children: [
          // Reply icon background
          if (_dragDistance > 0)
            Positioned(
              left: isLeftToRight ? 16 : null,
              right: !isLeftToRight ? 16 : null,
              top: 0,
              bottom: 0,
              child: AnimatedOpacity(
                opacity: replyIconOpacity,
                duration: Duration(milliseconds: 100),
                child: Center(
                  child: Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      color: _hasTriggered ? coral : Colors.grey.shade300,
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      Icons.reply,
                      color: _hasTriggered ? Colors.white : Colors.grey.shade600,
                      size: 18,
                    ),
                  ),
                ),
              ),
            ),
          
          // Message content with transform
          Transform.translate(
            offset: Offset(
              isLeftToRight ? _dragDistance : -_dragDistance,
              0,
            ),
            child: widget.child,
          ),
        ],
      ),
    );
  }
}

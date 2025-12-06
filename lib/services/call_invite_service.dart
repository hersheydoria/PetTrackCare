import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_ringtone_player/flutter_ringtone_player.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:zego_uikit_prebuilt_call/zego_uikit_prebuilt_call.dart';

import '../services/fastapi_service.dart';
import '../widgets/call_dialogs.dart';

class CallInviteService {
  static final CallInviteService _instance = CallInviteService._internal();
  factory CallInviteService() => _instance;

  CallInviteService._internal();

  final FastApiService _fastApi = FastApiService.instance;
  final Duration _pollInterval = const Duration(seconds: 5);
  final Duration _userRefreshInterval = const Duration(seconds: 20);

  BuildContext? _context;
  GlobalKey<NavigatorState>? _navigatorKey;
  NavigatorState? _activeDialogNavigator;
  BuildContext? _activeDialogContext;

  String? _currentUserId;
  String? _activeCallId;
  Timer? _callPollTimer;
  DateTime? _lastUserRefresh;

  bool _isInitialized = false;
  bool _isStartingMonitoring = false;
  bool _isFetchingUser = false;
  bool _isPolling = false;
  bool _isShowingDialog = false;
  bool _isRingtonePlaying = false;
  bool _disposed = false;

  final Set<String> _activeCallGuards = {};
  final Map<String, String> _latestMessageByPeer = {};

  Future<void> initialize(BuildContext context) async {
    print('📞 CallInviteService: Initializing with context');
    _context = context;
    if (_isInitialized || _isStartingMonitoring) {
      print('📞 CallInviteService: Already initialized or starting, skipping');
      return;
    }
    _isStartingMonitoring = true;
    await _startCallMonitoring();
    _isInitialized = true;
    _isStartingMonitoring = false;
  }

  void updateContext(BuildContext context) {
    print('📞 CallInviteService: Updating context');
    _context = context;
  }

  void registerNavigatorKey(GlobalKey<NavigatorState>? navigatorKey) {
    _navigatorKey = navigatorKey;
  }

  BuildContext? _currentContext() {
    final navContext = _navigatorKey?.currentContext;
    if (navContext != null) {
      return navContext;
    }
    return _context;
  }

  Future<void> _startCallMonitoring() async {
    if (_callPollTimer != null) return;

    print('📞 CallInviteService: Starting FastAPI polling for call signals');
    await _pollForCallSignals();
    _callPollTimer = Timer.periodic(_pollInterval, (_) => _pollForCallSignals());
  }

  Future<void> _pollForCallSignals() async {
    if (_disposed || _isPolling) return;
    _isPolling = true;

    try {
      if (_currentUserId == null || _shouldRefreshUser()) {
        await _refreshCurrentUser();
      }
      if (_currentUserId == null) return;

      final conversations = await _fastApi.fetchConversations(limit: 32);
      if (_disposed) return;

      for (final convo in conversations) {
        if (_disposed) break;
        final lastType = (convo['last_message_type'] ?? '').toString().toLowerCase();
        if (!lastType.startsWith('call')) continue;

        final peerId = convo['contact_id']?.toString();
        if (peerId == null || peerId.isEmpty) continue;

        final latest = await _fastApi.fetchLatestMessage(peerId);
        if (latest == null) continue;
        final messageId = latest['id']?.toString();
        if (messageId == null || messageId.isEmpty) continue;
        if (_latestMessageByPeer[peerId] == messageId) continue;

        _latestMessageByPeer[peerId] = messageId;
        await _processCallMessage(latest);
      }
    } catch (e) {
      print('📞 CallInviteService: Polling error: $e');
      if (e.toString().contains('401')) {
        _currentUserId = null;
        _activeCallGuards.clear();
        _latestMessageByPeer.clear();
        _isShowingDialog = false;
        _activeCallId = null;
      }
    } finally {
      _isPolling = false;
    }
  }

  bool _shouldRefreshUser() {
    final last = _lastUserRefresh;
    if (last == null) return true;
    return DateTime.now().difference(last) > _userRefreshInterval;
  }

  Future<void> _refreshCurrentUser() async {
    if (_isFetchingUser) return;
    _isFetchingUser = true;
    try {
      final user = await _fastApi.fetchCurrentUser();
      final newUserId = user['id']?.toString();
      if (newUserId != null && newUserId.isNotEmpty) {
        if (_currentUserId != newUserId) {
          _currentUserId = newUserId;
          _latestMessageByPeer.clear();
          _activeCallGuards.clear();
        }
      } else {
        _currentUserId = null;
        _activeCallGuards.clear();
        _latestMessageByPeer.clear();
      }
    } catch (e) {
      print('📞 CallInviteService: Unable to refresh user: $e');
      _currentUserId = null;
      _activeCallGuards.clear();
      _latestMessageByPeer.clear();
    } finally {
      _lastUserRefresh = DateTime.now();
      _isFetchingUser = false;
    }
  }

  Future<void> _processCallMessage(Map<String, dynamic> message) async {
    final type = (message['type'] ?? '').toString().toLowerCase();
    if (!type.startsWith('call')) return;

    final callId = message['call_id']?.toString() ?? '';
    if (callId.isEmpty) return;

    final senderId = message['sender_id']?.toString();
    final receiverId = message['receiver_id']?.toString();
    if (senderId == null || receiverId == null) return;

    switch (type) {
      case 'call_invite':
        await _handleIncomingInvite(senderId, receiverId, callId, message['call_mode']?.toString());
        break;
      case 'call_cancel':
        _handleCallCancel(callId);
        break;
      case 'call_hangup':
        _handleCallHangup(callId);
        break;
      default:
        break;
    }
  }

  Future<void> _handleIncomingInvite(String from, String to, String callId, String? mode) async {
    if (_currentUserId == null || to != _currentUserId) return;
    if (_activeCallGuards.contains(callId)) return;
    if (_isShowingDialog) {
      print('📞 CallInviteService: Dialog already open, ignoring invite');
      return;
    }

    _activeCallGuards.add(callId);
    _isShowingDialog = true;

    final callerName = await _getCallerName(from);
    final callMode = mode == 'video' ? 'video' : 'voice';
    final activeContext = _currentContext();
    if (activeContext != null && activeContext.mounted) {
      _showIncomingCallDialog(from, to, callId, callMode, callerName);
    } else {
      print('📞 CallInviteService: No context available to show dialog');
      _isShowingDialog = false;
    }
  }

  void _handleCallCancel(String callId) {
    print('📞 CallInviteService: Call canceled: $callId');
    _stopRingtone();
    if (_isShowingDialog && (_activeCallId == null || _activeCallId == callId)) {
      _dismissDialog();
    }
    _activeCallGuards.remove(callId);
  }

  void _handleCallHangup(String callId) {
    print('📞 CallInviteService: Call hangup received: $callId');
    if (_activeCallId != callId) return;
    final activeContext = _currentContext();
    if (activeContext != null && activeContext.mounted) {
      Navigator.of(activeContext, rootNavigator: true).popUntil((route) => route.isFirst);
    }
    _activeCallGuards.remove(callId);
  }

  Future<String> _getCallerName(String userId) async {
    try {
      final profile = await _fastApi.fetchUserById(userId);
      return profile['display_name']?.toString() ??
          profile['name']?.toString() ??
          profile['email']?.toString() ??
          'Someone';
    } catch (e) {
      print('📞 CallInviteService: Error fetching caller name: $e');
      return 'Someone';
    }
  }

  void _showIncomingCallDialog(String from, String to, String callId, String mode, String callerName) {
    final activeContext = _currentContext();
    if (activeContext == null || !activeContext.mounted) {
      print('📞 CallInviteService: Context not available for dialog');
      _isShowingDialog = false;
      _activeCallGuards.remove(callId);
      return;
    }

    _activeCallId = callId;
    final isVideo = mode == 'video';
    _playRingtone();

    try {
      Future.microtask(() {
        if (!activeContext.mounted) {
          _isShowingDialog = false;
          return;
        }

        showDialog<bool>(
          context: activeContext,
          barrierDismissible: false,
          useRootNavigator: true,
          builder: (dialogContext) {
            _activeDialogNavigator = Navigator.of(dialogContext, rootNavigator: true);
            _activeDialogContext = dialogContext;
            return IncomingCallDialog(
              callerName: callerName,
              isVideo: isVideo,
              subtitle: 'is calling you right now',
              onAccept: (ctx) async => _acceptCall(ctx, from, to, callId, isVideo),
              onDecline: (ctx) async => _declineCall(ctx, from, to, callId),
            );
          },
        ).then((_) {
          print('📞 CallInviteService: Incoming dialog dismissed');
          _isShowingDialog = false;
          if (callId.isNotEmpty) {
            _activeCallGuards.remove(callId);
          }
          _activeCallId = null;
          _activeDialogNavigator = null;
          _activeDialogContext = null;
        });
      });
    } catch (e) {
      print('📞 CallInviteService: Error showing dialog: $e');
      _isShowingDialog = false;
      if (callId.isNotEmpty) {
        _activeCallGuards.remove(callId);
      }
      _activeCallId = null;
    }
  }

  Future<void> _acceptCall(BuildContext dialogContext, String from, String to, String callId, bool isVideo) async {
    print('📞 CallInviteService: Accepting call: $callId');
    _stopRingtone();
    Navigator.of(dialogContext).pop(true);
    _activeDialogNavigator = null;
    _activeDialogContext = null;
    _isShowingDialog = false;

    await _sendSignal(from, 'call_accept', {
      'from': to,
      'to': from,
      'call_id': callId,
      'mode': isVideo ? 'video' : 'voice',
    });

    await _persistCallMessage(
      senderId: to,
      receiverId: from,
      type: 'call_accept',
      content: '[call_accept]',
      callId: callId,
    );

    print('📞 CallInviteService: Waiting for caller to join…');
    await Future.delayed(const Duration(milliseconds: 1500));
    await _joinZegoCall(callId: callId, video: isVideo, userId: to);
  }

  Future<void> _declineCall(BuildContext dialogContext, String from, String to, String callId) async {
    print('📞 CallInviteService: Declining call: $callId');
    _stopRingtone();
    Navigator.of(dialogContext).pop(false);
    _activeDialogNavigator = null;
    _activeDialogContext = null;
    _isShowingDialog = false;

    await _sendSignal(from, 'call_decline', {
      'from': to,
      'to': from,
      'call_id': callId,
    });

    await _persistCallMessage(
      senderId: to,
      receiverId: from,
      type: 'call_decline',
      content: '[call_decline]',
      callId: callId,
    );

    if (callId.isNotEmpty) {
      _activeCallGuards.remove(callId);
    }
  }

  Future<void> _joinZegoCall({required String callId, required bool video, required String userId}) async {
    final activeContext = _currentContext();
    if (activeContext == null || !activeContext.mounted) return;

    final mic = await Permission.microphone.request();
    if (!mic.isGranted) {
      print('📞 CallInviteService: Microphone permission denied');
      return;
    }

    if (video) {
      final cam = await Permission.camera.request();
      if (!cam.isGranted) {
        print('📞 CallInviteService: Camera permission denied');
        return;
      }
    }

    final sanitizedUserId = _sanitizeId(userId);
    final userName = await _getCallerName(userId);

    final config = video
        ? ZegoUIKitPrebuiltCallConfig.oneOnOneVideoCall()
        : ZegoUIKitPrebuiltCallConfig.oneOnOneVoiceCall();

    config.turnOnCameraWhenJoining = video;
    config.turnOnMicrophoneWhenJoining = true;
    config.useSpeakerWhenJoining = true;
    config.audioVideoView.showCameraStateOnView = true;
    config.audioVideoView.showMicrophoneStateOnView = true;
    config.audioVideoView.showSoundWavesInAudioMode = true;
    config.audioVideoView.useVideoViewAspectFill = true;
    config.audioVideoView.isVideoMirror = true;
    config.layout = ZegoUIKitPrebuiltCallConfig.oneOnOneVideoCall().layout;

    config.topMenuBar.isVisible = true;
    config.topMenuBar.buttons = [
      ZegoCallMenuBarButtonName.showMemberListButton,
    ];

    config.bottomMenuBar.buttons = [
      ZegoCallMenuBarButtonName.toggleCameraButton,
      ZegoCallMenuBarButtonName.switchCameraButton,
      ZegoCallMenuBarButtonName.toggleMicrophoneButton,
      ZegoCallMenuBarButtonName.switchAudioOutputButton,
      ZegoCallMenuBarButtonName.hangUpButton,
    ];

    final appId = int.tryParse(dotenv.env['ZEGO_APP_ID'] ?? '') ?? 129707582;
    final appSign = dotenv.env['ZEGO_APP_SIGN']?.isNotEmpty == true
        ? dotenv.env['ZEGO_APP_SIGN']!
        : 'ce6c20f99a76f7068d60f00d91a059b4ae2e660c2092048d2847acc4807cee8f';

    print('📞 CallInviteService: Joining Zego call $callId (video: $video)');

    await Navigator.push(
      activeContext,
      MaterialPageRoute(
        builder: (context) => ZegoUIKitPrebuiltCall(
          appID: appId,
          appSign: appSign,
          userID: sanitizedUserId,
          userName: userName,
          callID: callId,
          config: config,
        ),
      ),
    );

    print('📞 CallInviteService: Call ended, clearing state');
    if (callId.isNotEmpty) {
      _activeCallGuards.remove(callId);
    }
  }

  Future<void> _sendSignal(String userId, String event, Map<String, dynamic> payload) async {
    final senderId = payload['from']?.toString() ?? _currentUserId;
    if (senderId == null || senderId.isEmpty) {
      print('📞 CallInviteService: Sender ID missing for signal $event');
      return;
    }

    final callId = payload['call_id']?.toString();
    final callMode = payload['mode']?.toString() ?? payload['call_mode']?.toString();
    final message = payload['content']?.toString() ?? '[signal:$event]';
    Map<String, dynamic>? metadata;
    if (payload['metadata'] is Map<String, dynamic>) {
      metadata = Map<String, dynamic>.from(payload['metadata'] as Map);
    }

    try {
      await _fastApi.sendCallSignal(
        recipientId: userId,
        senderId: senderId,
        type: event,
        message: message,
        callId: callId,
        callMode: callMode,
        metadata: metadata,
      );
      print('📞 CallInviteService: Signal $event sent to $userId');
    } catch (e) {
      print('📞 CallInviteService: Error sending signal $event: $e');
    }
  }

  String _sanitizeId(String s) {
    final cleaned = s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9_]'), '');
    return cleaned.isEmpty ? 'user' : cleaned;
  }

  Future<void> _persistCallMessage({
    required String senderId,
    required String receiverId,
    required String type,
    required String content,
    required String callId,
  }) async {
    try {
      await _fastApi.sendMessage({
        'sender_id': senderId,
        'receiver_id': receiverId,
        'type': type,
        'content': content,
        'call_id': callId,
        'is_seen': false,
      });
      print('📞 CallInviteService: Recorded $type message');
    } catch (e) {
      print('📞 CallInviteService: Error recording $type message: $e');
    }
  }

  void _dismissDialog() {
    if (!_isShowingDialog) {
      _stopRingtone();
      return;
    }

    _stopRingtone();
    bool dismissed = false;

    if (_activeDialogNavigator != null) {
      try {
        if (_activeDialogNavigator!.canPop()) {
          _activeDialogNavigator!.pop();
        } else {
          _activeDialogNavigator!.maybePop();
        }
        dismissed = true;
      } catch (e) {
        print('📞 CallInviteService: Error popping dialog navigator: $e');
      }
      _activeDialogNavigator = null;
    }

    if (!dismissed && _activeDialogContext != null) {
      try {
        Navigator.of(_activeDialogContext!, rootNavigator: true).maybePop();
        dismissed = true;
      } catch (e) {
        print('📞 CallInviteService: Error dismissing via dialog context: $e');
      }
      _activeDialogContext = null;
    }

    if (!dismissed) {
      final active = _currentContext();
      if (active != null && active.mounted) {
        Navigator.of(active, rootNavigator: true).maybePop();
      }
    }

    _isShowingDialog = false;
    if (_activeCallId != null) {
      _activeCallGuards.remove(_activeCallId!);
    }
    _activeCallId = null;
    _activeDialogContext = null;
  }

  void _playRingtone() {
    if (_isRingtonePlaying) return;
    try {
      FlutterRingtonePlayer().play(
        android: AndroidSounds.ringtone,
        ios: IosSounds.electronic,
        looping: true,
        volume: 1.0,
      );
      _isRingtonePlaying = true;
    } catch (e) {
      print('📞 CallInviteService: Error playing ringtone: $e');
    }
  }

  void _stopRingtone() {
    if (!_isRingtonePlaying) return;
    try {
      FlutterRingtonePlayer().stop();
      _isRingtonePlaying = false;
    } catch (e) {
      print('📞 CallInviteService: Error stopping ringtone: $e');
    }
  }

  void dispose() {
    print('📞 CallInviteService: Disposing');
    _disposed = true;
    _stopRingtone();
    _callPollTimer?.cancel();
    _callPollTimer = null;
    _isInitialized = false;
    _isShowingDialog = false;
    _activeCallGuards.clear();
  }
}

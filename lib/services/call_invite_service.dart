import 'dart:async';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:zego_uikit_prebuilt_call/zego_uikit_prebuilt_call.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_ringtone_player/flutter_ringtone_player.dart';
import '../widgets/call_dialogs.dart';

class CallInviteService {
  static final CallInviteService _instance = CallInviteService._internal();
  factory CallInviteService() => _instance;
  CallInviteService._internal() {
    // Listen for auth state changes
    _supabase.auth.onAuthStateChange.listen((data) async {
      print('📞 CallInviteService: Auth state changed - session: ${data.session != null}');
      if (data.session != null && !_isInitialized && !_isStartingMonitoring) {
        _currentUserId = data.session?.user.id;
        print('📞 CallInviteService: User logged in, starting call monitoring for: $_currentUserId');
        if (_context != null && _currentUserId != null) {
          _isStartingMonitoring = true;
          await _startCallMonitoring();
          _isInitialized = true;
          _isStartingMonitoring = false;
        } else {
          print('📞 CallInviteService: Context not available yet, will initialize when context is set');
        }
      } else if (data.session == null && _isInitialized) {
        print('📞 CallInviteService: User logged out, cleaning up');
        dispose();
      }
    });
  }

  BuildContext? _context;
  GlobalKey<NavigatorState>? _navigatorKey;
  NavigatorState? _activeDialogNavigator;
  BuildContext? _activeDialogContext;
  bool _isInitialized = false;
  bool _isStartingMonitoring = false; // Prevent double initialization
  RealtimeChannel? _callChannel;
  String? _currentUserId;
  final Set<String> _activeCallGuards = {};
  bool _isShowingDialog = false;
  String? _activeCallId;
  bool _isRingtonePlaying = false;

  final SupabaseClient _supabase = Supabase.instance.client;

  // Initialize the service with the app's main context
  void initialize(BuildContext context) async {
    print('📞 CallInviteService: Initializing with context');
    _context = context;
    
    if (!_isInitialized && !_isStartingMonitoring) {
      _currentUserId = _supabase.auth.currentUser?.id;
      if (_currentUserId != null) {
        print('📞 CallInviteService: Starting call monitoring for user: $_currentUserId');
        _isStartingMonitoring = true;
        await _startCallMonitoring();
        _isInitialized = true;
        _isStartingMonitoring = false;
      } else {
        print('📞 CallInviteService: No user ID yet, waiting for auth state change');
      }
    } else if (_isStartingMonitoring) {
      print('📞 CallInviteService: Already starting monitoring, skipping duplicate call');
    } else {
      print('📞 CallInviteService: Already initialized, just updating context');
    }
  }
  void updateContext(BuildContext context) {
    print('📞 CallInviteService: Updating context');
    _context = context;
  }

  // Register navigator key so dialogs can be shown regardless of current page
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

  // Start monitoring for incoming calls
  Future<void> _startCallMonitoring() async {
    if (_currentUserId == null) return;

    final sanitizedUserId = _sanitizeId(_currentUserId!);
    print('📞 CallInviteService: ===========================================');
    print('📞 CallInviteService: SUBSCRIBING TO CHANNEL');
    print('📞 CallInviteService: Raw User ID: $_currentUserId');
    print('📞 CallInviteService: Sanitized ID: $sanitizedUserId');
    print('📞 CallInviteService: Channel Name: call_sig:$sanitizedUserId');
    print('📞 CallInviteService: ===========================================');

    // Create channel with broadcast configuration
    _callChannel = _supabase.channel(
      'call_sig:$sanitizedUserId',
      opts: const RealtimeChannelConfig(
        self: true, // Receive broadcasts from self
        ack: true,  // Request acknowledgments
      ),
    );
    
    print('📞 CallInviteService: Registering broadcast listeners...');
    _callChannel!
        .onBroadcast(
          event: 'test',
          callback: (payload, [ref]) {
            print('📞 CallInviteService: 🧪🧪🧪 RECEIVED TEST BROADCAST! 🧪🧪🧪');
            print('📞 CallInviteService: Test payload: $payload');
            print('📞 CallInviteService: ✅ BROADCASTS ARE WORKING! ✅');
          },
        )
        .onBroadcast(
          event: 'call_invite',
          callback: (payload, [ref]) async {
            print('📞 CallInviteService: 🔔🔔🔔 RECEIVED call_invite BROADCAST! 🔔🔔🔔');
            Map<String, dynamic>? body;
            try {
              body = Map<String, dynamic>.from(payload as Map);
            } catch (_) {
              body = null;
            }
            if (body == null) {
              print('📞 CallInviteService: Invalid payload');
              return;
            }

            final to = (body['to'] ?? '').toString();
            final from = (body['from'] ?? '').toString();
            final callId = (body['call_id'] ?? '').toString();
            final mode = (body['mode'] ?? 'voice').toString();

            print('📞 CallInviteService: Call invite details:');
            print('   From: $from');
            print('   To: $to');
            print('   CallID: $callId');
            print('   Mode: $mode');
            print('   Current User: $_currentUserId');

            if (to != _currentUserId || callId.isEmpty) {
              print('📞 CallInviteService: Call not for me or invalid callId, ignoring');
              return;
            }

            if (_activeCallGuards.contains(callId)) {
              print('📞 CallInviteService: Call already processed, ignoring');
              return;
            }

            if (_isShowingDialog) {
              print('📞 CallInviteService: Already showing a call dialog, ignoring');
              return;
            }

            _activeCallGuards.add(callId);
            _isShowingDialog = true;

            // Get caller info
            final callerName = await _getCallerName(from);

            final activeContext = _currentContext();
            if (activeContext != null && activeContext.mounted) {
              print('📞 CallInviteService: Showing incoming call dialog');
              _showIncomingCallDialog(from, to, callId, mode, callerName);
            } else {
              print('📞 CallInviteService: No context available for dialog');
              _isShowingDialog = false;
            }
          },
        )
        .onBroadcast(
          event: 'call_cancel',
          callback: (payload, [ref]) {
            print('📞 CallInviteService: Received call_cancel broadcast');
            Map<String, dynamic>? body;
            try {
              body = Map<String, dynamic>.from(payload as Map);
            } catch (_) {
              body = null;
            }
            if (body == null) return;

            final callId = (body['call_id'] ?? '').toString();
            print('📞 CallInviteService: Call canceled: $callId');
            print('📞 CallInviteService: Current state - showing dialog: $_isShowingDialog, active call: $_activeCallId');

            // Always stop ringtone when call is canceled
            _stopRingtone();

            final matchesActiveCall = _activeCallId == null || callId.isEmpty || _activeCallId == callId;
            if (_isShowingDialog && matchesActiveCall) {
              print('📞 CallInviteService: Dismissing call dialog due to cancellation');
              _dismissDialog();
            } else {
              print('📞 CallInviteService: No matching dialog to dismiss (dialog showing: $_isShowingDialog, callId match: ${_activeCallId == callId})');
            }
            _activeCallGuards.remove(callId);
          },
        )
        .onBroadcast(
          event: 'call_hangup',
          callback: (payload, [ref]) {
            print('📞 CallInviteService: Received call_hangup broadcast');
            Map<String, dynamic>? body;
            try {
              body = Map<String, dynamic>.from(payload as Map);
            } catch (_) {
              body = null;
            }
            if (body == null) return;

            final callId = (body['call_id'] ?? '').toString();
            print('📞 CallInviteService: Call hung up: $callId');

            if (_activeCallId == callId) {
              print('📞 CallInviteService: Active call ended, navigating back');
              final activeContext = _currentContext();
              if (activeContext != null && activeContext.mounted) {
                Navigator.of(activeContext, rootNavigator: true).popUntil((route) => route.isFirst);
              }
            }
            _activeCallGuards.remove(callId);
          },
        )
        .subscribe((status, [error]) {
      print('📞 CallInviteService: 📡📡📡 SUBSCRIPTION STATUS CHANGED: $status 📡📡📡');
      if (error != null) {
        print('📞 CallInviteService: ❌ Subscription error: $error');
      }
      if (status == RealtimeSubscribeStatus.subscribed) {
        print('📞 CallInviteService: ✅✅✅ CHANNEL IS NOW SUBSCRIBED AND READY! ✅✅✅');
      }
    });

    // Wait for subscription to be established (increased timeout)
    print('📞 CallInviteService: ⏳ Waiting for channel to be ready...');
    await Future.delayed(Duration(milliseconds: 2000)); // Increased to 2 seconds
    print('📞 CallInviteService: ✅ Call monitoring setup complete - ready to receive broadcasts');
    
    // TEST: Send a test broadcast to verify broadcasts are working
    try {
      print('📞 CallInviteService: 🧪 SENDING TEST BROADCAST to verify broadcasts work...');
      await _callChannel!.sendBroadcastMessage(
        event: 'test',
        payload: {'message': 'test broadcast', 'timestamp': DateTime.now().toIso8601String()},
      );
      print('📞 CallInviteService: ✅ Test broadcast sent successfully');
    } catch (e) {
      print('📞 CallInviteService: ❌ Test broadcast failed: $e');
    }
  }

  // Get caller's name from database
  Future<String> _getCallerName(String userId) async {
    try {
      final response = await _supabase
          .from('users')
          .select('name')
          .eq('id', userId)
          .maybeSingle();
      
      return response?['name']?.toString() ?? 'Someone';
    } catch (e) {
      print('📞 CallInviteService: Error fetching caller name: $e');
      return 'Someone';
    }
  }

  // Show incoming call dialog
  void _showIncomingCallDialog(String from, String to, String callId, String mode, String callerName) {
    final activeContext = _currentContext();
    if (activeContext == null || !activeContext.mounted) {
      print('📞 CallInviteService: Context is null or unmounted - cannot show dialog');
      print('   _context == null: ${_context == null}');
      if (_context != null) {
        print('   _context.mounted: ${_context!.mounted}');
      }
      if (_navigatorKey == null) {
        print('   _navigatorKey is null - no navigator context available');
      }
      return;
    }

    _activeCallId = callId;
    final isVideo = mode == 'video';

    // Play ringtone when showing the dialog
    _playRingtone();

    print('📞 CallInviteService: About to show dialog...');
    print('   From: $from');
    print('   To: $to');
    print('   CallID: $callId');
    print('   Mode: $mode');
    print('   Caller: $callerName');

    try {
      Future.microtask(() {
        if (!activeContext.mounted) {
          print('📞 CallInviteService: Active context unmounted before showing dialog');
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
          print('📞 CallInviteService: Dialog dismissed/closed');
          _isShowingDialog = false;
          if (callId.isNotEmpty) {
            _activeCallGuards.remove(callId);
          }
          _activeCallId = null;
          _activeDialogNavigator = null;
          _activeDialogContext = null;
        });
        print('📞 CallInviteService: Dialog shown successfully');
      });
    } catch (e) {
      print('📞 CallInviteService: ERROR showing dialog: $e');
      _isShowingDialog = false;
      if (callId.isNotEmpty) {
        _activeCallGuards.remove(callId);
      }
      _activeCallId = null;
    }
  }

  // Accept the call
  Future<void> _acceptCall(BuildContext dialogContext, String from, String to, String callId, bool isVideo) async {
    print('📞 CallInviteService: Call accepted - joining Zego');
    
    // Stop ringtone when accepting
    _stopRingtone();
    
    // Close the dialog
    Navigator.of(dialogContext).pop(true);
    _activeDialogNavigator = null;
    _activeDialogContext = null;
    _isShowingDialog = false;

    // Send accept signal
    await _sendSignal(from, 'call_accept', {
      'from': to,
      'to': from,
      'call_id': callId,
      'mode': isVideo ? 'video' : 'voice',
    });

    // Insert acceptance message in database
    try {
      await _supabase.from('messages').insert({
        'sender_id': to,
        'receiver_id': from,
        'type': 'call_accept',
        'content': '[call_accept]',
        'call_id': callId,
        'is_seen': false,
      });
    } catch (e) {
      print('📞 CallInviteService: Error inserting accept message: $e');
    }

    // Add delay for receiver to let caller initialize room first
    print('📞 CallInviteService: Waiting 1.5 seconds for room initialization...');
    await Future.delayed(Duration(milliseconds: 1500));

    // Join the call
    await _joinZegoCall(callId: callId, video: isVideo, userId: to);
  }

  // Decline the call
  Future<void> _declineCall(BuildContext dialogContext, String from, String to, String callId) async {
    print('📞 CallInviteService: Call declined');
    
    // Stop ringtone when declining
    _stopRingtone();
    
    // Close the dialog
    Navigator.of(dialogContext).pop(false);
    _activeDialogNavigator = null;
    _activeDialogContext = null;
    _isShowingDialog = false;

    // Send decline signal
    await _sendSignal(from, 'call_decline', {
      'from': to,
      'to': from,
      'call_id': callId,
    });

    // Insert decline message in database
    try {
      await _supabase.from('messages').insert({
        'sender_id': to,
        'receiver_id': from,
        'type': 'call_decline',
        'content': '[call_decline]',
        'call_id': callId,
        'is_seen': false,
      });
    } catch (e) {
      print('📞 CallInviteService: Error inserting decline message: $e');
    }

    if (callId.isNotEmpty) {
      _activeCallGuards.remove(callId);
    }
  }

  // Join Zego call
  Future<void> _joinZegoCall({required String callId, required bool video, required String userId}) async {
    final activeContext = _currentContext();
    if (activeContext == null || !activeContext.mounted) return;

    // Request permissions
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

    // Get user info
    final sanitizedUserId = _sanitizeId(userId);
    final userName = await _getCallerName(userId);

    // Configure call
    final config = video
        ? ZegoUIKitPrebuiltCallConfig.oneOnOneVideoCall()
        : ZegoUIKitPrebuiltCallConfig.oneOnOneVoiceCall();

    config.turnOnCameraWhenJoining = video;
    config.turnOnMicrophoneWhenJoining = true;
    config.useSpeakerWhenJoining = true;
    config.audioVideoView.showCameraStateOnView = true;
    config.audioVideoView.showMicrophoneStateOnView = true;
    config.audioVideoView.isVideoMirror = true;
    config.layout = ZegoUIKitPrebuiltCallConfig.oneOnOneVideoCall().layout;

    // Configure UI buttons
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

    // Get Zego credentials
    final appId = int.tryParse(dotenv.env['ZEGO_APP_ID'] ?? '') ?? 129707582;
    final appSign = dotenv.env['ZEGO_APP_SIGN']?.isNotEmpty == true
        ? dotenv.env['ZEGO_APP_SIGN']!
        : 'ce6c20f99a76f7068d60f00d91a059b4ae2e660c2092048d2847acc4807cee8f';

    print('📞 CallInviteService: Joining Zego call with ID: $callId');

    // Navigate to call screen
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

    print('📞 CallInviteService: Call ended, returned from Zego');
    if (callId.isNotEmpty) {
      _activeCallGuards.remove(callId);
    }
  }

  // Send signal to another user
  Future<void> _sendSignal(String userId, String event, Map<String, dynamic> payload) async {
    final key = _sanitizeId(userId);
    final channel = _supabase.channel('call_sig:$key');
    
    try {
      await channel.subscribe();
      await channel.sendBroadcastMessage(
        event: event,
        payload: payload,
      );
      print('📞 CallInviteService: Sent signal $event to $userId');
    } catch (e) {
      print('📞 CallInviteService: Error sending signal: $e');
    } finally {
      await channel.unsubscribe();
    }
  }

  // Sanitize user ID for Zego
  String _sanitizeId(String s) {
    final cleaned = s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9_]'), '');
    return cleaned.isEmpty ? 'user' : cleaned;
  }

  // Dismiss dialog
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
      final activeContext = _currentContext();
      if (activeContext != null && activeContext.mounted) {
        Navigator.of(activeContext, rootNavigator: true).maybePop();
      }
    }

    _isShowingDialog = false;
    if (_activeCallId != null) {
      _activeCallGuards.remove(_activeCallId!);
    }
    _activeCallId = null;
    _activeDialogContext = null;
  }

  // Play ringtone for incoming call
  void _playRingtone() {
    if (!_isRingtonePlaying) {
      try {
        print('📞 CallInviteService: Playing ringtone');
        FlutterRingtonePlayer().play(
          android: AndroidSounds.ringtone,
          ios: IosSounds.electronic,
          looping: true, // Loop until answered or declined
          volume: 1.0,
        );
        _isRingtonePlaying = true;
      } catch (e) {
        print('📞 CallInviteService: Error playing ringtone: $e');
      }
    }
  }

  // Stop ringtone
  void _stopRingtone() {
    if (_isRingtonePlaying) {
      try {
        print('📞 CallInviteService: Stopping ringtone');
        FlutterRingtonePlayer().stop();
        _isRingtonePlaying = false;
      } catch (e) {
        print('📞 CallInviteService: Error stopping ringtone: $e');
      }
    }
  }

  // Dispose the service
  void dispose() {
    print('📞 CallInviteService: Disposing');
    _stopRingtone(); // Stop ringtone on dispose
    _callChannel?.unsubscribe();
    _callChannel = null;
    _isInitialized = false;
    _activeCallGuards.clear();
  }
}

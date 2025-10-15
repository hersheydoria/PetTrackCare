import 'dart:async';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:zego_uikit_prebuilt_call/zego_uikit_prebuilt_call.dart';
import 'package:realtime_client/src/types.dart' as rt;
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_ringtone_player/flutter_ringtone_player.dart';

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
  bool _isInitialized = false;
  bool _isStartingMonitoring = false; // Prevent double initialization
  RealtimeChannel? _callChannel;
  String? _currentUserId;
  Set<String> _processedCallIds = {};
  bool _isShowingDialog = false;
  String? _activeCallId;
  bool _isRingtonePlaying = false;

  final SupabaseClient _supabase = Supabase.instance.client;

  // Initialize the service with the app's main context
  void initialize(BuildContext context) async {
    print('📞 CallInviteService: Initializing with context');
    _context = context;
    
    // Try to initialize if we have a user but haven't started monitoring yet
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

  // Update context when navigating between screens
  void updateContext(BuildContext context) {
    print('📞 CallInviteService: Updating context');
    _context = context;
  }

  // Start monitoring for incoming calls
  Future<void> _startCallMonitoring() async {
    if (_currentUserId == null) return;

    final sanitizedUserId = _sanitizeId(_currentUserId!);
    print('📞 CallInviteService: Subscribing to call channel: call_sig:$sanitizedUserId');

    _callChannel = _supabase.channel('call_sig:$sanitizedUserId');
    _callChannel!
        .onBroadcast(
          event: 'call_invite',
          callback: (payload, [ref]) async {
            print('📞 CallInviteService: Received call_invite broadcast');
            final body = payload is Map ? Map<String, dynamic>.from(payload as Map) : null;
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

            if (_processedCallIds.contains(callId)) {
              print('📞 CallInviteService: Call already processed, ignoring');
              return;
            }

            if (_isShowingDialog) {
              print('📞 CallInviteService: Already showing a call dialog, ignoring');
              return;
            }

            _processedCallIds.add(callId);
            _isShowingDialog = true;

            // Get caller info
            final callerName = await _getCallerName(from);

            if (_context != null && _context!.mounted) {
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
            final body = payload is Map ? Map<String, dynamic>.from(payload as Map) : null;
            if (body == null) return;

            final callId = (body['call_id'] ?? '').toString();
            print('📞 CallInviteService: Call canceled: $callId');
            print('📞 CallInviteService: Current state - showing dialog: $_isShowingDialog, active call: $_activeCallId');

            // Always stop ringtone when call is canceled
            _stopRingtone();

            if (_isShowingDialog && _activeCallId == callId) {
              print('📞 CallInviteService: Dismissing call dialog due to cancellation');
              _dismissDialog();
            } else {
              print('📞 CallInviteService: No matching dialog to dismiss (dialog showing: $_isShowingDialog, callId match: ${_activeCallId == callId})');
            }
          },
        )
        .onBroadcast(
          event: 'call_hangup',
          callback: (payload, [ref]) {
            print('📞 CallInviteService: Received call_hangup broadcast');
            final body = payload is Map ? Map<String, dynamic>.from(payload as Map) : null;
            if (body == null) return;

            final callId = (body['call_id'] ?? '').toString();
            print('📞 CallInviteService: Call hung up: $callId');

            if (_activeCallId == callId) {
              print('📞 CallInviteService: Active call ended, navigating back');
              if (_context != null && _context!.mounted) {
                Navigator.of(_context!, rootNavigator: true).popUntil((route) => route.isFirst);
              }
            }
          },
        )
        .subscribe((status, [error]) {
      print('📞 CallInviteService: 📡 Subscription status: $status');
      if (error != null) {
        print('📞 CallInviteService: ❌ Subscription error: $error');
      }
    });

    // Wait for subscription to be established
    print('📞 CallInviteService: ⏳ Waiting for channel to be ready...');
    await Future.delayed(Duration(milliseconds: 1000)); // Give it more time
    print('📞 CallInviteService: ✅ Call monitoring setup complete - ready to receive broadcasts');
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
    if (_context == null || !_context!.mounted) return;

    _activeCallId = callId;
    final isVideo = mode == 'video';

    // Play ringtone when showing the dialog
    _playRingtone();

    showDialog<bool>(
      context: _context!,
      barrierDismissible: false,
      builder: (dialogContext) => WillPopScope(
        onWillPop: () async => false,
        child: AlertDialog(
          title: Row(
            children: [
              Icon(
                isVideo ? Icons.videocam : Icons.phone,
                color: Color(0xFFB82132),
                size: 28,
              ),
              SizedBox(width: 12),
              Expanded(
                child: Text(
                  'Incoming ${isVideo ? "Video" : "Voice"} Call',
                  style: TextStyle(fontSize: 18),
                ),
              ),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircleAvatar(
                radius: 40,
                backgroundColor: Color(0xFFB82132).withOpacity(0.1),
                child: Icon(
                  Icons.person,
                  size: 40,
                  color: Color(0xFFB82132),
                ),
              ),
              SizedBox(height: 16),
              Text(
                callerName,
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                ),
              ),
              SizedBox(height: 8),
              Text(
                'is calling you...',
                style: TextStyle(
                  fontSize: 14,
                  color: Colors.grey[600],
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => _declineCall(dialogContext, from, to, callId),
              style: TextButton.styleFrom(
                backgroundColor: Colors.red.withOpacity(0.1),
                padding: EdgeInsets.symmetric(horizontal: 24, vertical: 12),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.call_end, color: Colors.red),
                  SizedBox(width: 8),
                  Text('Decline', style: TextStyle(color: Colors.red)),
                ],
              ),
            ),
            SizedBox(width: 8),
            ElevatedButton(
              onPressed: () => _acceptCall(dialogContext, from, to, callId, isVideo),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.green,
                padding: EdgeInsets.symmetric(horizontal: 24, vertical: 12),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.call, color: Colors.white),
                  SizedBox(width: 8),
                  Text('Accept', style: TextStyle(color: Colors.white)),
                ],
              ),
            ),
          ],
        ),
      ),
    ).then((_) {
      _isShowingDialog = false;
      _activeCallId = null;
    });
  }

  // Accept the call
  Future<void> _acceptCall(BuildContext dialogContext, String from, String to, String callId, bool isVideo) async {
    print('📞 CallInviteService: Call accepted - joining Zego');
    
    // Stop ringtone when accepting
    _stopRingtone();
    
    // Close the dialog
    Navigator.of(dialogContext).pop(true);
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
  }

  // Join Zego call
  Future<void> _joinZegoCall({required String callId, required bool video, required String userId}) async {
    if (_context == null || !_context!.mounted) return;

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
      _context!,
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
  }

  // Send signal to another user
  Future<void> _sendSignal(String userId, String event, Map<String, dynamic> payload) async {
    final key = _sanitizeId(userId);
    final channel = _supabase.channel('call_sig:$key');
    
    try {
      await channel.subscribe();
      await channel.send(
        type: rt.RealtimeListenTypes.broadcast,
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
    if (_context != null && _context!.mounted && _isShowingDialog) {
      _stopRingtone(); // Stop ringtone when dialog is dismissed
      Navigator.of(_context!, rootNavigator: true).pop();
      _isShowingDialog = false;
      _activeCallId = null;
    }
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
    _processedCallIds.clear();
  }
}

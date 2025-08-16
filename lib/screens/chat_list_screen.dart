import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'chat_detail_screen.dart';
import 'notification_screen.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:zego_uikit_prebuilt_call/zego_uikit_prebuilt_call.dart';

class ChatListScreen extends StatefulWidget {
  @override
  _ChatListScreenState createState() => _ChatListScreenState();
}

class _ChatListScreenState extends State<ChatListScreen> {
  final supabase = Supabase.instance.client;
  List<Map<String, dynamic>> messages = [];

  // Track prompted call_ids to avoid duplicate dialogs
  final Set<String> _promptedCallIds = {};

  // Zego app credentials (same as in chat_detail_screen.dart)
  static const int appID = 1445580868;
  static const String appSign = '2136993e53a5a7926531f24e693db2403af6e916e1f6dca8970c71c21e4b29be';

  String _sanitizeId(String s) => s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9_]'), '').isEmpty
      ? 'user'
      : s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9_]'), '');

  Future<void> _joinZegoCall({required String callId, required bool video}) async {
    final meRaw = supabase.auth.currentUser?.id ?? '';
    final me = _sanitizeId(meRaw);

    final mic = await Permission.microphone.request();
    if (!mic.isGranted) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Microphone permission denied')));
      }
      return;
    }
    if (video) {
      final cam = await Permission.camera.request();
      if (!cam.isGranted) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Camera permission denied')));
        }
        return;
      }
    }

    if (!mounted) return;
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ZegoUIKitPrebuiltCall(
          appID: appID,
          appSign: appSign,
          userID: me,
          userName: me, // or fetch/display your own name here if needed
          callID: callId,
          config: video
              ? ZegoUIKitPrebuiltCallConfig.oneOnOneVideoCall()
              : ZegoUIKitPrebuiltCallConfig.oneOnOneVoiceCall(),
        ),
      ),
    );
  }

  @override
  void initState() {
    super.initState();
    fetchMessages();
    setupRealtimeSubscription();
  }

  void setupRealtimeSubscription() {
    final channel = supabase.channel('public:messages');

    channel
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'messages',
          callback: (payload, [ref]) async {
            fetchMessages(); // Refresh list on new message

            // Handle call invite globally (even when not inside ChatDetailScreen)
            final newRow = payload.newRecord;
            if (newRow == null) return;

            final me = supabase.auth.currentUser?.id;
            if (me == null) return;

            final String type = (newRow['type'] ?? '').toString();
            final String to = (newRow['receiver_id'] ?? '').toString();
            final String from = (newRow['sender_id'] ?? '').toString();
            final String callId = (newRow['call_id'] ?? '').toString();
            final String mode = (newRow['call_mode'] ?? 'voice').toString();

            // Only prompt when this user is the callee and it's a new call invite
            if (type == 'call' && to == me && callId.isNotEmpty) {
              if (_promptedCallIds.contains(callId)) return;
              _promptedCallIds.add(callId);

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

              if (accept == true && mounted) {
                // Notify caller
                try {
                  await supabase.from('messages').insert({
                    'sender_id': me,
                    'receiver_id': from,
                    'type': 'call_accept',
                    'call_id': callId,
                    'call_mode': mode,
                    'content': '[call_accept]',
                    'is_seen': false,
                  });
                } catch (_) {}
                await _joinZegoCall(callId: callId, video: mode == 'video');
              } else {
                // Notify decline
                try {
                  await supabase.from('messages').insert({
                    'sender_id': me,
                    'receiver_id': from,
                    'type': 'call_decline',
                    'call_id': callId,
                    'call_mode': mode,
                    'content': '[call_decline]',
                    'is_seen': false,
                  });
                } catch (_) {}
              }
            }
          },
        )
        .subscribe();
  }

  Future<void> fetchMessages() async {
    final userId = supabase.auth.currentUser?.id;
    if (userId == null) return;

    final response = await supabase
        .from('messages')
        .select('sender_id, receiver_id, content, sent_at, is_seen, sender:sender_id(name), receiver:receiver_id(name)')
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
          'isSeen': msg['is_seen'],
          'isSender': isSender,
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
          final isSeen = chat['isSeen'] ?? true;
          final isSender = chat['isSender'] ?? false;
          return ListTile(
            leading: CircleAvatar(
              child: Text(
                chat['contactName'][0].toUpperCase(),
                style: TextStyle(
                  fontWeight: !isSeen && !isSender ? FontWeight.bold : FontWeight.normal,
                ),
              ),
            ),
            title: Text(
              chat['contactName'],
              style: TextStyle(
                fontWeight: !isSeen && !isSender ? FontWeight.bold : FontWeight.normal,
              ),
            ),
            subtitle: Text(
              chat['lastMessage'],
              style: TextStyle(
                color: !isSeen && !isSender ? Colors.black : Colors.grey,
              ),
            ),
            tileColor: !isSeen && !isSender ? Color.fromARGB(255, 243, 216, 218) : null,
            onTap: () async {
              await Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => ChatDetailScreen(
                    userId: supabase.auth.currentUser!.id,
                    receiverId: chat['contactId'],
                    userName: chat['contactName'],
                  ),
                ),
              );
              fetchMessages();
            },
          );
        },
      ),
    );
  }
}

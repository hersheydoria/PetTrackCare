import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'chat_detail_screen.dart';
import 'notification_screen.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:zego_uikit_prebuilt_call/zego_uikit_prebuilt_call.dart';
import '../services/notification_service.dart';

// Color palette
const deepRed = Color(0xFFB82132);
const coral = Color(0xFFD2665A);
const peach = Color(0xFFF2B28C);
const lightBlush = Color(0xFFF6DED8);

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

  // New: pull-to-refresh handler
  Future<void> _refreshAll() async {
    await fetchMessages();
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

            // Handle new message notification
            final newRow = payload.newRecord;
            final currentUserId = supabase.auth.currentUser?.id;
            final receiverId = newRow['receiver_id']?.toString();
            final senderId = newRow['sender_id']?.toString();
            final messageType = newRow['type']?.toString() ?? 'text';
            final content = newRow['content']?.toString() ?? '';

            // Show notification if this user is the receiver and it's not a system message
            if (receiverId == currentUserId && senderId != currentUserId && senderId != null && receiverId != null && messageType != 'call_accept' && messageType != 'call_decline') {
              // Get sender name for notification
              try {
                final senderResponse = await supabase
                    .from('users')
                    .select('name')
                    .eq('id', senderId)
                    .single();
                
                final senderName = senderResponse['name'] as String? ?? 'Someone';
                
                // Format message preview
                String messagePreview = content;
                if (content.startsWith('[call_')) {
                  if (content.contains('accept')) messagePreview = '📞 Call accepted';
                  else if (content.contains('decline')) messagePreview = '📞 Call declined';
                  else messagePreview = '📞 Incoming call';
                } else if (content.length > 50) {
                  messagePreview = '${content.substring(0, 47)}...';
                }
                
                await sendMessageNotification(
                  recipientId: receiverId,
                  senderId: senderId,
                  senderName: senderName,
                  messagePreview: messagePreview,
                );
              } catch (e) {
                // Fallback notification without sender name
                await sendMessageNotification(
                  recipientId: receiverId,
                  senderId: senderId,
                  senderName: 'New Message',
                  messagePreview: content,
                );
              }
            }

            // Handle call invite globally (even when not inside ChatDetailScreen)
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

    // Fetch message list with sender/receiver profile_picture from users table
    final response = await supabase
        .from('messages')
        .select('''
          sender_id,
          receiver_id,
          content,
          sent_at,
          is_seen,
          sender:sender_id(id, name, profile_picture),
          receiver:receiver_id(id, name, profile_picture)
        ''')
        .or('sender_id.eq.$userId,receiver_id.eq.$userId')
        .order('sent_at', ascending: false);

    final grouped = <String, Map<String, dynamic>>{};
    for (var msg in response) {
      final isSender = msg['sender_id'] == userId;
      final senderUser = msg['sender'] as Map<String, dynamic>? ?? {};
      final receiverUser = msg['receiver'] as Map<String, dynamic>? ?? {};

      final contactId = isSender ? msg['receiver_id'].toString() : msg['sender_id'].toString();
      final contactUser = isSender ? receiverUser : senderUser;
      final contactName = contactUser['name'] ?? 'Unknown';
      final contactProfilePictureUrl = contactUser['profile_picture'] as String?;

      if (!grouped.containsKey(contactId)) {
        grouped[contactId] = {
          'contactId': contactId,
          'contactName': contactName,
          'lastMessage': msg['content'],
          'isSeen': msg['is_seen'],
          'isSender': isSender,
          'contactProfilePictureUrl': contactProfilePictureUrl,
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
      backgroundColor: lightBlush,
      appBar: AppBar(
        backgroundColor: deepRed,
        elevation: 0,
        title: Row(
          children: [
            SizedBox(width: 8),
            Text(
              'Messages',
              style: TextStyle(
                fontWeight: FontWeight.bold,
                color: Colors.white,
                fontSize: 20,
              ),
            ),
          ],
        ),
        actions: [
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
                  Icons.notifications_outlined,
                  color: Colors.white,
                  size: 20,
                ),
              ),
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (context) => const NotificationScreen()),
                );
              },
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
        child: RefreshIndicator(
          onRefresh: _refreshAll,
          color: deepRed,
          backgroundColor: Colors.white,
          child: messages.isEmpty
              ? _buildEmptyState()
              : _buildChatList(),
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
          height: MediaQuery.of(context).size.height * 0.7,
          child: Center(
            child: Padding(
              padding: EdgeInsets.all(32),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Container(
                    padding: EdgeInsets.all(32),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      shape: BoxShape.circle,
                      boxShadow: [
                        BoxShadow(
                          color: deepRed.withOpacity(0.1),
                          blurRadius: 30,
                          offset: Offset(0, 10),
                        ),
                      ],
                    ),
                    child: Icon(
                      Icons.chat_bubble_outline,
                      size: 64,
                      color: coral,
                    ),
                  ),
                  SizedBox(height: 24),
                  Text(
                    'No Messages Yet',
                    style: TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.bold,
                      color: deepRed,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  SizedBox(height: 12),
                  Text(
                    'Start a conversation by exploring\nthe community and connecting with other pet owners',
                    style: TextStyle(
                      fontSize: 16,
                      color: Colors.grey.shade600,
                      height: 1.5,
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

  // Enhanced chat list
  Widget _buildChatList() {
    return ListView.builder(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: EdgeInsets.all(16),
      itemCount: messages.length,
      itemBuilder: (context, index) {
        final chat = messages[index];
        return _buildChatCard(chat, index);
      },
    );
  }

  // Enhanced chat card
  Widget _buildChatCard(Map<String, dynamic> chat, int index) {
    final isSeen = chat['isSeen'] ?? true;
    final isSender = chat['isSender'] ?? false;
    final String? avatarUrl = chat['contactProfilePictureUrl'];
    final String contactName = (chat['contactName'] as String?) ?? '';
    final String lastMessage = (chat['lastMessage'] as String?) ?? '';
    final String initial = contactName.isNotEmpty ? contactName[0].toUpperCase() : '?';
    final bool hasUnread = !isSeen && !isSender;

    return Container(
      margin: EdgeInsets.only(bottom: 12),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
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
          borderRadius: BorderRadius.circular(16),
          child: AnimatedContainer(
            duration: Duration(milliseconds: 300),
            padding: EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: hasUnread ? Colors.white : Colors.white.withOpacity(0.8),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: hasUnread ? coral.withOpacity(0.5) : Colors.grey.shade200,
                width: hasUnread ? 2 : 1,
              ),
              boxShadow: [
                BoxShadow(
                  color: hasUnread 
                    ? deepRed.withOpacity(0.15) 
                    : Colors.grey.withOpacity(0.1),
                  blurRadius: hasUnread ? 12 : 8,
                  offset: Offset(0, hasUnread ? 4 : 2),
                ),
              ],
            ),
            child: Row(
              children: [
                // Enhanced avatar
                Stack(
                  children: [
                    Container(
                      width: 56,
                      height: 56,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: hasUnread ? coral : Colors.grey.shade300,
                          width: 2,
                        ),
                      ),
                      child: ClipOval(
                        child: avatarUrl != null && avatarUrl.isNotEmpty
                            ? Image.network(
                                avatarUrl,
                                width: 52,
                                height: 52,
                                fit: BoxFit.cover,
                                errorBuilder: (_, __, ___) => _buildDefaultAvatar(initial, hasUnread),
                              )
                            : _buildDefaultAvatar(initial, hasUnread),
                      ),
                    ),
                    if (hasUnread)
                      Positioned(
                        bottom: 0,
                        right: 0,
                        child: Container(
                          width: 16,
                          height: 16,
                          decoration: BoxDecoration(
                            color: deepRed,
                            shape: BoxShape.circle,
                            border: Border.all(color: Colors.white, width: 2),
                          ),
                        ),
                      ),
                  ],
                ),
                
                SizedBox(width: 16),
                
                // Chat content
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              contactName,
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight: hasUnread ? FontWeight.bold : FontWeight.w600,
                                color: hasUnread ? deepRed : Colors.grey.shade800,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          if (hasUnread)
                            Container(
                              padding: EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                              decoration: BoxDecoration(
                                color: deepRed,
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: Text(
                                'NEW',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 10,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                        ],
                      ),
                      SizedBox(height: 6),
                      Row(
                        children: [
                          if (isSender) ...[
                            Icon(
                              Icons.reply,
                              size: 14,
                              color: Colors.grey.shade500,
                            ),
                            SizedBox(width: 4),
                          ],
                          Expanded(
                            child: Text(
                              _formatMessagePreview(lastMessage),
                              style: TextStyle(
                                fontSize: 14,
                                color: hasUnread ? Colors.grey.shade800 : Colors.grey.shade600,
                                fontWeight: hasUnread ? FontWeight.w500 : FontWeight.normal,
                              ),
                              overflow: TextOverflow.ellipsis,
                              maxLines: 1,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                
                // Arrow indicator
                Icon(
                  Icons.chevron_right,
                  color: hasUnread ? coral : Colors.grey.shade400,
                  size: 20,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // Default avatar with gradient
  Widget _buildDefaultAvatar(String initial, bool hasUnread) {
    return Container(
      width: 52,
      height: 52,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: hasUnread
              ? [coral.withOpacity(0.9), peach.withOpacity(0.9)]
              : [Colors.grey.shade400, Colors.grey.shade500],
        ),
      ),
      child: Center(
        child: Text(
          initial,
          style: TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.bold,
            color: Colors.white,
          ),
        ),
      ),
    );
  }

  // Format message preview
  String _formatMessagePreview(String message) {
    if (message.isEmpty) return 'No message';
    
    // Handle special message types
    if (message.startsWith('[call_')) {
      if (message.contains('accept')) return '📞 Call accepted';
      if (message.contains('decline')) return '📞 Call declined';
      return '📞 Call';
    }
    
    // Truncate long messages
    if (message.length > 50) {
      return '${message.substring(0, 47)}...';
    }
    
    return message;
  }
}

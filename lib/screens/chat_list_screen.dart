import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'chat_detail_screen.dart';
import 'notification_screen.dart';
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
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();
  String _searchQuery = '';
  String _activeFilter = 'all';

  // REMOVED: Call handling is now done by CallInviteService
  // final Set<String> _promptedCallIds = {};
  // String _sanitizeId(String s) => ...
  // Future<void> _joinZegoCall(...) async { ... }

  @override
  void initState() {
    super.initState();
    fetchMessages();
    setupRealtimeSubscription();
    _searchController.addListener(() {
      if (mounted) {
        setState(() {
          _searchQuery = _searchController.text.trim();
        });
      }
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    _searchFocusNode.dispose();
    super.dispose();
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
            print('🔄 Realtime message received in chat_list_screen');
            fetchMessages(); // Refresh list on new message

            // Handle new message notification
            final newRow = payload.newRecord;
            final currentUserId = supabase.auth.currentUser?.id;
            final receiverId = newRow['receiver_id']?.toString();
            final senderId = newRow['sender_id']?.toString();
            final messageType = newRow['type']?.toString() ?? 'text';
            final content = newRow['content']?.toString() ?? '';

            print('📩 Realtime message details:');
            print('   Current User: $currentUserId');
            print('   Receiver: $receiverId');
            print('   Sender: $senderId');
            print('   Type: $messageType');
            print('   Content: $content');

            // Show notification if this user is the receiver and it's not a system message
            if (receiverId == currentUserId && senderId != currentUserId && senderId != null && receiverId != null && messageType != 'call_accept' && messageType != 'call_decline') {
              print('✅ This user should receive notification - processing...');
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
                print('✅ sendMessageNotification called successfully');
              } catch (e) {
                print('⚠️ Error getting sender name, using fallback notification');
                // Fallback notification without sender name
                await sendMessageNotification(
                  recipientId: receiverId,
                  senderId: senderId,
                  senderName: 'New Message',
                  messagePreview: content,
                );
              }
            } else {
              print('❌ Notification conditions not met:');
              print('   receiverId == currentUserId: ${receiverId == currentUserId}');
              print('   senderId != currentUserId: ${senderId != currentUserId}');
              print('   messageType: $messageType (excluded: call_accept, call_decline)');
            }

            // DISABLED: Call invite handling is now done globally by CallInviteService
            // This prevents duplicate dialogs and notifications
            /*
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
            */
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

  int get _unreadCount => messages.where((chat) {
        final isSeen = chat['isSeen'] ?? true;
        final isSender = chat['isSender'] ?? false;
        return !isSeen && !isSender;
      }).length;

  List<Map<String, dynamic>> get _filteredMessages {
    final base = messages.where((chat) {
      if (_activeFilter == 'unread') {
        final isSeen = chat['isSeen'] ?? true;
        final isSender = chat['isSender'] ?? false;
        if (isSeen || isSender) return false;
      }
      return true;
    });

    if (_searchQuery.isEmpty) return base.toList();

    final lowerQuery = _searchQuery.toLowerCase();
    return base
        .where((chat) {
          final name = (chat['contactName'] ?? '').toString().toLowerCase();
          final last = (chat['lastMessage'] ?? '').toString().toLowerCase();
          return name.contains(lowerQuery) || last.contains(lowerQuery);
        })
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    final double heroHeight = kToolbarHeight + 150;
    final filteredChats = _filteredMessages;
    return Scaffold(
      backgroundColor: lightBlush,
      appBar: PreferredSize(
        preferredSize: Size.fromHeight(heroHeight),
        child: AppBar(
          automaticallyImplyLeading: false,
          backgroundColor: Colors.transparent,
          elevation: 0,
          flexibleSpace: Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [deepRed, deepRed.withOpacity(0.9), coral.withOpacity(0.85)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
            ),
            child: SafeArea(
              bottom: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: const [
                              Text(
                                'Inbox',
                                style: TextStyle(
                                  fontSize: 26,
                                  fontWeight: FontWeight.w700,
                                  color: Colors.white,
                                ),
                              ),
                              SizedBox(height: 4),
                              Text(
                                'Stay in sync with pet sitters',
                                style: TextStyle(color: Colors.white70, fontSize: 13),
                              ),
                            ],
                          ),
                        ),
                        IconButton(
                          icon: Container(
                            padding: const EdgeInsets.all(10),
                            decoration: BoxDecoration(
                              color: Colors.white.withOpacity(0.2),
                              borderRadius: BorderRadius.circular(14),
                            ),
                            child: const Icon(Icons.notifications_outlined, color: Colors.white, size: 22),
                          ),
                          onPressed: () {
                            Navigator.push(
                              context,
                              MaterialPageRoute(builder: (context) => const NotificationScreen()),
                            );
                          },
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    _buildSummaryRow(filteredChats.length),
                  ],
                ),
              ),
            ),
          ),
        ),
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
            _buildSearchAndFilters(),
            Expanded(
              child: RefreshIndicator(
                onRefresh: _refreshAll,
                color: deepRed,
                backgroundColor: Colors.white,
                child: filteredChats.isEmpty
                    ? _buildEmptyState()
                    : _buildChatList(filteredChats),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSummaryRow(int visibleCount) {
    return Row(
      children: [
        Expanded(
          child: _buildSummaryCard(
            label: 'Conversations',
            value: visibleCount.toString(),
            icon: Icons.chat_bubble_outline,
            accent: Colors.white,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _buildSummaryCard(
            label: 'Unread',
            value: _unreadCount.toString(),
            icon: Icons.mark_email_unread_outlined,
            accent: _unreadCount > 0 ? Colors.white : Colors.white70,
            highlight: _unreadCount > 0,
          ),
        ),
      ],
    );
  }

  Widget _buildSummaryCard({
    required String label,
    required String value,
    required IconData icon,
    required Color accent,
    bool highlight = false,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(highlight ? 0.18 : 0.12),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: Colors.white.withOpacity(highlight ? 0.8 : 0.2),
          width: 1,
        ),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.2),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(icon, color: accent, size: 20),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: TextStyle(
                    color: accent,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  value,
                  style: TextStyle(
                    color: accent,
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSearchAndFilters() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 10),
      decoration: const BoxDecoration(color: Colors.transparent),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(20),
              boxShadow: [
                BoxShadow(
                  color: deepRed.withOpacity(0.08),
                  blurRadius: 16,
                  offset: const Offset(0, 6),
                ),
              ],
            ),
            child: TextField(
              controller: _searchController,
              focusNode: _searchFocusNode,
              decoration: InputDecoration(
                hintText: 'Search conversations or notes',
                hintStyle: TextStyle(color: Colors.grey.shade500),
                prefixIcon: const Icon(Icons.search, color: deepRed),
                suffixIcon: _searchQuery.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.close, color: deepRed, size: 20),
                        onPressed: () {
                          _searchController.clear();
                          _searchFocusNode.unfocus();
                        },
                      )
                    : Icon(Icons.tune_rounded, color: Colors.grey.shade400),
                border: InputBorder.none,
                contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              ),
            ),
          ),
          const SizedBox(height: 14),
          SizedBox(
            height: 40,
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: [
                _buildFilterChip('all', 'All chats', Icons.all_inclusive),
                _buildFilterChip('unread', 'Unread (${_unreadCount})', Icons.mark_chat_unread_outlined),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFilterChip(String value, String label, IconData icon) {
    final bool isActive = _activeFilter == value;
    return GestureDetector(
      onTap: () {
        if (_activeFilter == value) return;
        setState(() {
          _activeFilter = value;
        });
      },
      child: Container(
        margin: const EdgeInsets.only(right: 10),
        padding: const EdgeInsets.symmetric(horizontal: 16),
        decoration: BoxDecoration(
          color: isActive ? deepRed : Colors.white,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: isActive ? deepRed : Colors.grey.shade300),
          boxShadow: [
            if (isActive)
              BoxShadow(
                color: deepRed.withOpacity(0.2),
                blurRadius: 12,
                offset: const Offset(0, 4),
              ),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 16, color: isActive ? Colors.white : deepRed),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                color: isActive ? Colors.white : deepRed,
                fontWeight: FontWeight.w600,
              ),
            ),
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
  Widget _buildChatList(List<Map<String, dynamic>> source) {
    return ListView.builder(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: EdgeInsets.all(16),
      itemCount: source.length,
      itemBuilder: (context, index) {
        final chat = source[index];
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

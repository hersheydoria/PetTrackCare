import 'dart:io';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:intl/intl.dart';
import 'notification_screen.dart';
import '../services/notification_service.dart';

Map<String, bool> likedPosts = {};
Map<String, TextEditingController> commentControllers = {};
Map<String, int> likeCounts = {};
Map<String, int> commentCounts = {};
Map<String, List<Map<String, dynamic>>> postComments = {};
Map<String, bool> likedComments = {};
Map<String, TextEditingController> editCommentControllers = {};
Map<String, bool> commentLoading = {}; // commentId -> loading state
Map<String, bool> showReplyInput = {};
Map<String, TextEditingController> replyControllers = {};
Map<String, List<Map<String, dynamic>>> commentReplies = {};
Map<String, int> replyPage = {};
Map<String, bool> replyHasMore = {};
Map<String, bool> locallyUpdatedPosts = {}; // Track posts with local comment updates
Map<String, bool> bookmarkedPosts = {}; // Track bookmarked posts

// Mention feature state
Map<String, bool> showUserSuggestions = {}; // postId/commentId -> show suggestions
Map<String, List<Map<String, dynamic>>> userSuggestions = {}; // postId/commentId -> user list
Map<String, String> currentMentionText = {}; // postId/commentId -> current @text being typed
Map<String, int> mentionStartPosition = {}; // postId/commentId -> cursor position where @ started

const int replyDisplayThreshold = 3; // only show "View more" when replies >= threshold


const deepRed = Color(0xFFB82132);
const lightBlush = Color(0xFFF6DED8);
const ownerColor = Color(0xFFECA1A6); 
const sitterColor = Color(0xFFF2B28C); 

// Helper functions for Philippines timezone conversion
DateTime convertToPhilippinesTime(DateTime utcTime) {
  // Convert UTC time to Philippines time (UTC+8)
  return utcTime.add(Duration(hours: 8));
}

String formatPhilippinesTime(DateTime dateTime) {
  // Assume the input dateTime is in UTC and convert to Philippines time
  final phTime = convertToPhilippinesTime(dateTime);
  final now = convertToPhilippinesTime(DateTime.now().toUtc());
  final difference = now.difference(phTime);
  
  if (difference.inMinutes < 1) {
    return 'Just now';
  } else if (difference.inMinutes < 60) {
    return '${difference.inMinutes}m ago';
  } else if (difference.inHours < 24) {
    return '${difference.inHours}h ago';
  } else if (difference.inDays < 7) {
    return '${difference.inDays}d ago';
  } else {
    final formatter = DateFormat('MMM d, y');
    return formatter.format(phTime);
  }
}

String getDetailedPhilippinesTime(DateTime dateTime) {
  // Assume the input dateTime is in UTC and convert to Philippines time
  final phTime = convertToPhilippinesTime(dateTime);
  final formatter = DateFormat('MMM d, y \'at\' h:mm a');
  return formatter.format(phTime);
}

class CommunityScreen extends StatefulWidget {
  final String userId;
  final String? targetPostId; // Optional post ID to scroll to

  const CommunityScreen({required this.userId, this.targetPostId});

  @override
  _CommunityScreenState createState() => _CommunityScreenState();
}

class _CommunityScreenState extends State<CommunityScreen> with RouteAware {
  List<dynamic> posts = [];
  bool isLoading = false;
  String selectedFilter = 'all';
  Map<String, bool> showCommentInput = {};
  late ScrollController _scrollController;
  String? highlightedPostId; // Track which post to highlight
  GlobalKey targetPostKey = GlobalKey(); // Key for the target post

  @override
  void initState() {
    super.initState();
    _scrollController = ScrollController();
    highlightedPostId = widget.targetPostId; // Set target post for highlighting
    fetchPosts();
    loadCommentCounts();
    loadCommentReplies(); // Load replies on initialization
    loadBookmarkedPosts(); // Load bookmarked posts
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    
    // Handle route arguments from missing pet alert
    try {
      final args = ModalRoute.of(context)?.settings.arguments as Map<String, dynamic>?;
      if (args != null && args['scrollToPost'] == true) {
        final postId = args['postId'] as String?;
        if (postId != null && postId.isNotEmpty) {
          print('🔔 CommunityScreen: Received route argument to scroll to post: $postId');
          highlightedPostId = postId;
          // Schedule scroll after a short delay to ensure posts are loaded and rendered
          Future.delayed(Duration(milliseconds: 500), () {
            _scrollToPost(postId);
          });
        }
      }
    } catch (e) {
      print('⚠️ CommunityScreen: Error handling route arguments: $e');
    }
    
    // Completely remove automatic refresh when navigating back
    // The user can manually refresh if they want to see new posts
  }

  @override
  void dispose() {
    // Clean up the state when the widget is disposed
    _scrollController.dispose();
    showCommentInput.clear();
    super.dispose();
  }

  // Save comment counts to persistent storage
  Future<void> saveCommentCounts() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final Map<String, String> countsToSave = {};
      commentCounts.forEach((postId, count) {
        countsToSave[postId] = count.toString();
      });
      await prefs.setString('comment_counts_${widget.userId}', 
          countsToSave.entries.map((e) => '${e.key}:${e.value}').join(','));
      print('Saved comment counts: $countsToSave');
    } catch (e) {
      print('Error saving comment counts: $e');
    }
  }

  // Load comment counts from persistent storage
  Future<void> loadCommentCounts() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getString('comment_counts_${widget.userId}');
      if (saved != null && saved.isNotEmpty) {
        final Map<String, int> loadedCounts = {};
        saved.split(',').forEach((entry) {
          final parts = entry.split(':');
          if (parts.length == 2) {
            loadedCounts[parts[0]] = int.tryParse(parts[1]) ?? 0;
          }
        });
        commentCounts.addAll(loadedCounts);
        print('Loaded comment counts: $loadedCounts');
      }
    } catch (e) {
      print('Error loading comment counts: $e');
    }
  }

  // Save comment replies to persistent storage
  Future<void> saveCommentReplies() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final Map<String, String> repliesToSave = {};
      commentReplies.forEach((commentId, replies) {
        repliesToSave[commentId] = replies
            .map((reply) => '${reply['userId']}:${reply['text']}')
            .join('|');
      });
      await prefs.setString('comment_replies_${widget.userId}', 
          repliesToSave.entries.map((e) => '${e.key}=>${e.value}').join(','));
      print('Saved comment replies: $repliesToSave');
    } catch (e) {
      print('Error saving comment replies: $e');
    }
  }

  // Load comment replies from persistent storage
  Future<void> loadCommentReplies() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getString('comment_replies_${widget.userId}');
      if (saved != null && saved.isNotEmpty) {
        final Map<String, List<Map<String, dynamic>>> loadedReplies = {};
        saved.split(',').forEach((entry) {
          final parts = entry.split('=>');
          if (parts.length == 2) {
            final commentId = parts[0];
            final replies = parts[1]
                .split('|')
                .map((reply) {
                  final replyParts = reply.split(':');
                  if (replyParts.length == 2) {
                    return {
                      'userId': replyParts[0],
                      'text': replyParts[1],
                    };
                  }
                  return null;
                })
                .where((reply) => reply != null)
                .toList();
            loadedReplies[commentId] = List<Map<String, dynamic>>.from(replies);
          }
        });
        commentReplies.addAll(loadedReplies);
        print('Loaded comment replies: $loadedReplies');
      }
    } catch (e) {
      print('Error loading comment replies: $e');
    }
  }

  // Handle adding a new comment with proper state management
  Future<void> addComment(String postId, String commentText) async {
    print('ADDCOMMENT CALLED - PostId: $postId, Text: "$commentText"');
    if (commentText.trim().isEmpty) {
      print('ADDCOMMENT ABORTED - Empty comment text');
      return;
    }

    try {
      print('ADDCOMMENT - Starting database insertion...');
      
      // Extract mentions from comment text
      final mentions = extractMentions(commentText);
      
      // Insert comment into database
      final newComment = await Supabase.instance.client
          .from('comments')
          .insert({
        'post_id': postId,
        'user_id': widget.userId,
        'content': commentText,
      }).select('id, content, created_at, user_id').single();

      print('Comment inserted: $newComment');

      // Wait a moment for any database triggers to create notifications
      await Future.delayed(Duration(milliseconds: 500));
      
      // Send comment notification using new service
      final postData = await Supabase.instance.client
          .from('community_posts')
          .select('user_id')
          .eq('id', postId)
          .single();
      
      final postOwnerId = postData['user_id'];
      if (postOwnerId != widget.userId) {
        // Get current user name
        final currentUserResponse = await Supabase.instance.client
            .from('users')
            .select('name')
            .eq('id', widget.userId)
            .single();
        final currentUserName = currentUserResponse['name'] as String? ?? 'Someone';
        
        await sendCommunityNotification(
          recipientId: postOwnerId,
          actorId: widget.userId,
          type: 'comment',
          message: '$currentUserName commented on your post',
          postId: postId,
          commentId: newComment['id'].toString(),
          actorName: currentUserName,
        );
      }

      // Send mention notifications
      if (mentions.isNotEmpty) {
        await sendMentionNotifications(mentions, postId, commentId: newComment['id'].toString());
      }

      // Get user data
      final userData = await Supabase.instance.client
          .from('users')
          .select('name, profile_picture') // <-- add profile_picture
          .eq('id', widget.userId)
          .single();

      print('User data fetched: $userData');

      // Combine comment and user data
      final fullComment = {
        ...Map<String, dynamic>.from(newComment),
        'users': userData,
        'comment_likes': []
      };

      setState(() {
        if (postComments[postId] == null) {
          postComments[postId] = [];
        }
        postComments[postId]!.insert(0, fullComment);
  commentCounts[postId] = postComments[postId]!.length; // Always use postComments[postId]?.length
        // Mark this post as locally updated
        locallyUpdatedPosts[postId] = true;
        print('COMMENT ADDED - Post $postId marked as locally updated with ${commentCounts[postId]} comments');
        print('COMMENT ADDED - commentCounts map: $commentCounts');
        print('COMMENT ADDED - postComments length for $postId: ${postComments[postId]?.length}');
        print('COMMENT ADDED - Full comment: $fullComment');
      });

      // Save the updated counts to persistent storage
      await saveCommentCounts();

      // Force a UI rebuild to ensure comment count is updated
      _updateCommentCountInUI(postId);

      // Clear the input
      commentControllers[postId]?.clear();
      
      // Hide mention suggestions
      final fieldId = 'comment_$postId';
      setState(() {
        showUserSuggestions[fieldId] = false;
        userSuggestions[fieldId] = [];
        currentMentionText[fieldId] = '';
      });
      
      // Keep the comment input open so user can see the new comment
      // Don't automatically hide it
      // showCommentInput[postId] = false;

    } catch (e) {
      print('Error posting comment: $e');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Failed to post comment. Please try again.'),
          duration: Duration(seconds: 3),
        )
      );
      // Restore the comment text if posting failed
      commentControllers[postId]?.text = commentText;
    }
  }

  // Load bookmarked posts for current user
  Future<void> loadBookmarkedPosts() async {
    try {
      final response = await Supabase.instance.client
          .from('bookmarks')
          .select('post_id')
          .eq('user_id', widget.userId);
      
      setState(() {
        bookmarkedPosts.clear();
        for (var bookmark in response) {
          bookmarkedPosts[bookmark['post_id'].toString()] = true;
        }
      });
    } catch (e) {
      print('Error loading bookmarks: $e');
    }
  }

  // Search users for mentions
  Future<void> searchUsersForMention(String fieldId, String query) async {
    if (query.length < 1) {
      setState(() {
        showUserSuggestions[fieldId] = false;
        userSuggestions[fieldId] = [];
      });
      return;
    }

    try {
      final response = await Supabase.instance.client
          .from('users')
          .select('id, name, profile_picture')
          .ilike('name', '%$query%')
          .limit(5);

      setState(() {
        userSuggestions[fieldId] = List<Map<String, dynamic>>.from(response);
        showUserSuggestions[fieldId] = userSuggestions[fieldId]!.isNotEmpty;
      });
    } catch (e) {
      print('Error searching users: $e');
    }
  }

  // Handle mention selection
  void selectMention(String fieldId, Map<String, dynamic> user) {
    final controller = fieldId.startsWith('comment_') 
        ? commentControllers[fieldId.substring(8)] 
        : replyControllers[fieldId];
    
    if (controller == null) return;

    final currentText = controller.text;
    final mentionStart = mentionStartPosition[fieldId] ?? 0;
    final beforeMention = currentText.substring(0, mentionStart);
    final afterMention = currentText.substring(controller.selection.start);
    
    final newText = '$beforeMention@${user['name']} $afterMention';
    controller.text = newText;
    controller.selection = TextSelection.collapsed(
      offset: (beforeMention.length + user['name'].toString().length + 2),
    );

    setState(() {
      showUserSuggestions[fieldId] = false;
      userSuggestions[fieldId] = [];
      currentMentionText[fieldId] = '';
    });
  }

  // Handle text changes for mention detection
  void handleTextChange(String fieldId, String text, int cursorPosition) {
    // Find @ symbol before cursor
    int atPosition = -1;
    for (int i = cursorPosition - 1; i >= 0; i--) {
      if (text[i] == '@') {
        atPosition = i;
        break;
      } else if (text[i] == ' ' || text[i] == '\n') {
        break;
      }
    }

    if (atPosition >= 0) {
      final mentionText = text.substring(atPosition + 1, cursorPosition);
      if (!mentionText.contains(' ') && !mentionText.contains('\n')) {
        setState(() {
          mentionStartPosition[fieldId] = atPosition;
          currentMentionText[fieldId] = mentionText;
        });
        searchUsersForMention(fieldId, mentionText);
        return;
      }
    }

    // Hide suggestions if no valid mention detected
    setState(() {
      showUserSuggestions[fieldId] = false;
      userSuggestions[fieldId] = [];
      currentMentionText[fieldId] = '';
    });
  }

  // Extract mentions from text
  List<String> extractMentions(String text) {
    final mentionRegex = RegExp(r'@(\w+)');
    final matches = mentionRegex.allMatches(text);
    return matches.map((match) => match.group(1)!).toList();
  }

  // Send mention notifications
  Future<void> sendMentionNotifications(List<String> mentionedUsernames, String postId, {String? commentId}) async {
    if (mentionedUsernames.isEmpty) return;

    try {
      // Get current user name for notification
      final currentUserResponse = await Supabase.instance.client
          .from('users')
          .select('name')
          .eq('id', widget.userId)
          .single();
      final currentUserName = currentUserResponse['name'] as String? ?? 'Someone';

      // Get user IDs for mentioned usernames
      final userResponse = await Supabase.instance.client
          .from('users')
          .select('id, name')
          .inFilter('name', mentionedUsernames);

      for (var user in userResponse) {
        final mentionedUserId = user['id'];
        if (mentionedUserId == widget.userId) continue; // Don't notify self

        final message = '$currentUserName mentioned you in a ${commentId != null ? 'comment' : 'post'}';
        
        // Use the new notification service
        await sendCommunityNotification(
          recipientId: mentionedUserId,
          actorId: widget.userId,
          type: 'mention',
          message: message,
          postId: postId,
          commentId: commentId,
          actorName: currentUserName,
        );
      }
    } catch (e) {
      print('Error sending mention notifications: $e');
    }
  }

  // Build text with clickable mentions
  Widget buildTextWithMentions(String text) {
    final mentionRegex = RegExp(r'@(\w+)');
    final matches = mentionRegex.allMatches(text).toList();
    
    if (matches.isEmpty) {
      return Text(text);
    }

    List<TextSpan> spans = [];
    int lastMatchEnd = 0;

    for (var match in matches) {
      // Add text before mention
      if (match.start > lastMatchEnd) {
        spans.add(TextSpan(
          text: text.substring(lastMatchEnd, match.start),
        ));
      }

      // Add clickable mention
      spans.add(TextSpan(
        text: match.group(0),
        style: TextStyle(
          color: deepRed,
          fontWeight: FontWeight.bold,
        ),
        // Note: Would need GestureRecognizer for actual clicks in production
      ));

      lastMatchEnd = match.end;
    }

    // Add remaining text
    if (lastMatchEnd < text.length) {
      spans.add(TextSpan(
        text: text.substring(lastMatchEnd),
      ));
    }

    return RichText(
      text: TextSpan(
        style: DefaultTextStyle.of(context).style,
        children: spans,
      ),
    );
  }

  // Toggle bookmark status
  Future<void> toggleBookmark(String postId) async {
    final isCurrentlyBookmarked = bookmarkedPosts[postId] ?? false;
    
    try {
      if (isCurrentlyBookmarked) {
        // Remove bookmark
        await Supabase.instance.client
            .from('bookmarks')
            .delete()
            .eq('user_id', widget.userId)
            .eq('post_id', postId);
        
        setState(() {
          bookmarkedPosts[postId] = false;
        });
        
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Removed from saved posts'),
            backgroundColor: Colors.grey[600],
            duration: Duration(seconds: 2),
          ),
        );
      } else {
        // Add bookmark
        await Supabase.instance.client
            .from('bookmarks')
            .insert({
          'user_id': widget.userId,
          'post_id': postId,
        });
        
        setState(() {
          bookmarkedPosts[postId] = true;
        });
        
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Added to saved posts'),
            backgroundColor: deepRed,
            duration: Duration(seconds: 2),
          ),
        );
      }
    } catch (e) {
      print('Error toggling bookmark: $e');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Failed to update saved posts. Please try again.'),
          backgroundColor: Colors.red,
          duration: Duration(seconds: 2),
        ),
      );
    }
  }

  // Force refresh all data (clears local state)
  Future<void> forceRefreshPosts() async {
    // Clear persisted comment counts
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('comment_counts_${widget.userId}');
    
    setState(() {
      showCommentInput.clear();
      postComments.clear();
      commentCounts.clear();
      locallyUpdatedPosts.clear();
    });
    await fetchPosts();
  }

  // Get comment count for a post with fallback logic
  int _getCommentCount(String postId) {
    // Always get the most up-to-date count
    final count = commentCounts[postId];
    final comments = postComments[postId];
    final result = count ?? comments?.length ?? 0;
    print('Getting comment count for post $postId: $result (from commentCounts: $count, from postComments: ${comments?.length})');
    return result;
  }

  // Immediately update comment count in UI
  void _updateCommentCountInUI(String postId) {
    setState(() {
      final currentComments = postComments[postId];
      if (currentComments != null) {
        commentCounts[postId] = currentComments.length;
        print('UI UPDATED - Comment count for post $postId set to ${commentCounts[postId]}');
      }
    });
  }

  // Scroll to a specific post by ID
  void _scrollToPost(String postId) {
    print('🔔 CommunityScreen: Attempting to scroll to post $postId');
    
    // Find the index of the post with the given ID
    int postIndex = -1;
    for (int i = 0; i < posts.length; i++) {
      if (posts[i]['id'].toString() == postId) {
        postIndex = i;
        break;
      }
    }
    
    if (postIndex >= 0) {
      print('🔔 CommunityScreen: Found post at index $postIndex, scrolling...');
      // Each post takes up approximately 500 pixels (adjust if needed)
      final offset = postIndex * 500.0;
      
      _scrollController.animateTo(
        offset,
        duration: Duration(milliseconds: 800),
        curve: Curves.easeInOut,
      );
      
      // Highlight the post temporarily
      setState(() {
        highlightedPostId = postId;
      });
      
      // Remove highlight after 3 seconds
      Future.delayed(Duration(seconds: 3), () {
        if (mounted) {
          setState(() {
            highlightedPostId = null;
          });
        }
      });
    } else {
      print('🔔 CommunityScreen: Post $postId not found in current list (${posts.length} posts loaded)');
    }
  }

  Future<void> fetchPosts() async {
    setState(() => isLoading = true);
    try {
      // First fetch the posts with basic information
      final response = await Supabase.instance.client
          .from('community_posts')
          .select('''
            *,
            users!community_posts_user_id_fkey (
              name,
              role,
              profile_picture
            ),
            likes (
              user_id
            ),
            comments (
              id,
              content,
              user_id,
              created_at,
              users!comments_user_id_fkey (
                name,
                profile_picture
              ),
              comment_likes (
                user_id
              )
            )
          ''')
          .order('created_at', ascending: false);

      print('Fetched posts response: ${response.toString()}');

      setState(() {
        posts = response;
        // Process each post's data
        for (var post in posts) {
          final postId = post['id'].toString();
          print('Processing post ID: $postId');

          // Handle likes
          final likes = post['likes'] as List? ?? [];
          likedPosts[postId] = likes.any((like) => like['user_id'] == widget.userId);
          likeCounts[postId] = likes.length;
          
          // Initialize comment controllers if not exists
          if (!commentControllers.containsKey(postId)) {
            commentControllers[postId] = TextEditingController();
          }

          // Process comments
          try {
            List<Map<String, dynamic>> comments = [];
            if (post['comments'] != null && post['comments'] is List) {
              comments = (post['comments'] as List).map((comment) {
                if (comment is! Map<String, dynamic>) {
                  return Map<String, dynamic>.from(comment);
                }
                return comment;
              }).toList();

              // Sort comments by created_at date (newest first) - SAFE parsing
              comments.sort((a, b) {
                final dateA = DateTime.tryParse((a['created_at'] ?? '').toString()) ??
                    DateTime.fromMillisecondsSinceEpoch(0);
                final dateB = DateTime.tryParse((b['created_at'] ?? '').toString()) ??
                    DateTime.fromMillisecondsSinceEpoch(0);
                return dateB.compareTo(dateA);
              });
            }
            
            // Preserve existing comment data - only update if fetched count is higher
            final existingCount = commentCounts[postId];
            final fetchedCount = comments.length;
            
            // Only update if we don't have a local count or if fetched count is higher
            if (existingCount == null || fetchedCount > existingCount) {
              postComments[postId] = comments;
              commentCounts[postId] = fetchedCount;
              print('Updated comment data for post $postId: $fetchedCount comments');
            } else {
              // Keep existing count but update postComments if we don't have it
              if (postComments[postId] == null) {
                postComments[postId] = comments;
              }
              // Ensure the count is properly set even if we're preserving
              commentCounts[postId] = existingCount;
              print('Preserved existing comment count for post $postId: $existingCount comments (fetched $fetchedCount)');
            }
          } catch (e) {
            print('Error processing comments for post $postId: $e');
            // Only clear if there's no existing data to preserve
            if (postComments[postId] == null) {
              postComments[postId] = [];
            }
          }

          // Initialize comment input state
          showCommentInput[postId] = showCommentInput[postId] ?? false;
          // Initialize reply input state
          showReplyInput[postId] = showReplyInput[postId] ?? false;
          replyControllers.putIfAbsent(postId, () => TextEditingController());
        }
      });

      // After posts and comments are processed, prefetch replies for all comments so they persist across restarts
      try {
        final allCommentIds = <String>{};
        postComments.forEach((postId, comments) {
          for (var c in comments) {
            final cid = c['id']?.toString();
            if (cid != null) allCommentIds.add(cid);
          }
        });

        if (allCommentIds.isNotEmpty) {
          final commentIdList = allCommentIds.toList();
          final responses = await Future.wait(commentIdList.map((cid) async {
            final res = await Supabase.instance.client
                .from('replies')
                .select('*, users!replies_user_id_fkey(name, profile_picture)')
                .eq('comment_id', cid)
                .order('created_at', ascending: false);
            return res as List<dynamic>;
          }));

          for (var i = 0; i < commentIdList.length; i++) {
            final cid = commentIdList[i];
            final res = responses[i];
            commentReplies[cid] = List<Map<String, dynamic>>.from(res.map((r) => Map<String, dynamic>.from(r)));
          }
        }
      } catch (e) {
        print('Error prefetching replies: $e');
      }
    } catch (e) {
      print('Error fetching posts: $e');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error loading posts. Please try again.'))
      );
    } finally {
      setState(() => isLoading = false);
      // After posts are loaded, scroll to target post if specified
      if (widget.targetPostId != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _scrollToTargetPost();
        });
      }
    }
  }

  // Method to scroll to the target post and highlight it
  void _scrollToTargetPost() {
    if (widget.targetPostId == null) return;
    
    // Find the index of the target post
    final targetIndex = posts.indexWhere((post) => post['id'].toString() == widget.targetPostId);
    
    if (targetIndex != -1) {
      // Calculate the position to scroll to (approximate)
      final double itemHeight = 300.0; // Approximate height of each post card
      final double targetPosition = targetIndex * itemHeight;
      
      // Scroll to the target position
      _scrollController.animateTo(
        targetPosition,
        duration: Duration(milliseconds: 800),
        curve: Curves.easeInOut,
      );
      
      // Remove highlight after a few seconds
      Future.delayed(Duration(seconds: 3), () {
        if (mounted) {
          setState(() {
            highlightedPostId = null;
          });
        }
      });
    }
  }

  Future<String?> uploadImage(File imageFile) async {
    final fileName = p.basename(imageFile.path);
    final filePath = 'uploads/$fileName';

    try {
      final bytes = await imageFile.readAsBytes();
      final storageResponse = await Supabase.instance.client.storage
          .from('community-posts')
          .uploadBinary(
            filePath,
            bytes,
            fileOptions: const FileOptions(upsert: true),
          );

      print('Upload response: $storageResponse'); // should be path

      final publicUrl = Supabase.instance.client.storage
          .from('community-posts')
          .getPublicUrl(filePath);

      // Do NOT update users.profile_picture here!
      // Only return the image URL for use in community_posts.image_url

      print('✅ Community post image uploaded!');

      return publicUrl;
    } catch (e) {
      print('Upload failed: $e');
      return null;
    }
  }

  // Fetch replies with simple pagination. Page starts at 0. limit controls items per page.
  Future<void> fetchRepliesForComment(String commentId, {int limit = 5, bool refresh = false}) async {
    try {
      final currentPage = refresh ? 0 : (replyPage[commentId] ?? 0);

      final response = await Supabase.instance.client
          .from('replies')
          .select('*, users!replies_user_id_fkey(name, profile_picture)')
          .eq('comment_id', commentId)
          .order('created_at', ascending: false)
          .range(currentPage * limit, currentPage * limit + limit - 1);

      final List<dynamic> rows = response as List<dynamic>;

      setState(() {
        if (refresh) {
          commentReplies[commentId] = List<Map<String, dynamic>>.from(rows.map((r) => Map<String, dynamic>.from(r)));
          replyPage[commentId] = 1;
        } else {
          commentReplies.putIfAbsent(commentId, () => []);
          commentReplies[commentId]!.addAll(rows.map((r) => Map<String, dynamic>.from(r)));
          replyPage[commentId] = (replyPage[commentId] ?? 0) + 1;
        }

        // If fewer rows than limit returned, no more pages
        replyHasMore[commentId] = rows.length >= limit;
      });
    } catch (e) {
      print('Error fetching replies for $commentId: $e');
    }
  }

  Future<void> postReply(String commentId, String content) async {
    if (content.trim().isEmpty) return;
    try {
      // Extract mentions from reply content
      final mentions = extractMentions(content);
      
      final newReply = await Supabase.instance.client
          .from('replies')
          .insert({
        'comment_id': commentId,
        'user_id': widget.userId,
        'content': content,
      }).select('id, content, created_at, user_id').single();

      final userData = await Supabase.instance.client
          .from('users')
          .select('name, profile_picture') // <-- add profile_picture
          .eq('id', widget.userId)
          .single();

      final fullReply = {
        ...Map<String, dynamic>.from(newReply),
        'users': userData,
      };

      // Wait a moment for any database triggers to create notifications
      await Future.delayed(Duration(milliseconds: 500));
      
      // Update any existing notifications for this reply to include actor_id
      // We need to get the comment owner to send notification to
      final commentOwner = await Supabase.instance.client
          .from('comments')
          .select('user_id, post_id')
          .eq('id', commentId)
          .single();
      
      final commentOwnerId = commentOwner['user_id'];
      final postId = commentOwner['post_id'];
      if (commentOwnerId != widget.userId) {
        // Get current user name
        final currentUserResponse = await Supabase.instance.client
            .from('users')
            .select('name')
            .eq('id', widget.userId)
            .single();
        final currentUserName = currentUserResponse['name'] as String? ?? 'Someone';
        
        await sendCommunityNotification(
          recipientId: commentOwnerId,
          actorId: widget.userId,
          type: 'reply',
          message: '$currentUserName replied to your comment',
          postId: postId,
          commentId: commentId,
          actorName: currentUserName,
        );
      }

      // Send mention notifications
      if (mentions.isNotEmpty) {
        await sendMentionNotifications(mentions, postId, commentId: commentId);
      }

      setState(() {
        commentReplies.putIfAbsent(commentId, () => []);
        commentReplies[commentId]!.insert(0, fullReply);
        // reset pagination so next fetch includes this new reply if user views more
        replyPage[commentId] = 1;
        replyHasMore[commentId] = true;

        // Removed: dummy insert and forced comment count updates for replies
        // Replies do not change top-level comment counts

        // Hide the reply input after posting
        showReplyInput[commentId] = false;
        
        // Hide mention suggestions
        final fieldId = 'reply_$commentId';
        showUserSuggestions[fieldId] = false;
        userSuggestions[fieldId] = [];
        currentMentionText[fieldId] = '';
      });
    } catch (e) {
      print('Error posting reply: $e');
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed to post reply')));
    }
  }

  Future<void> editReply(String commentId, String replyId, String newContent, int replyIndex) async {
  final original = (commentReplies[commentId] != null && commentReplies[commentId]!.length > replyIndex)
    ? commentReplies[commentId]![replyIndex]['content']
    : null;
    if (original == null) return;

    setState(() {
      commentReplies[commentId]?[replyIndex]['content'] = newContent;
    });

    try {
      await Supabase.instance.client
          .from('replies')
          .update({'content': newContent})
          .eq('id', replyId);
    } catch (e) {
      // rollback
      setState(() {
        commentReplies[commentId]?[replyIndex]['content'] = original;
      });
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed to update reply')));
    }
  }

  Future<void> deleteReply(String commentId, String replyId, int replyIndex) async {
  final deleted = (commentReplies[commentId] != null && commentReplies[commentId]!.length > replyIndex)
    ? Map<String, dynamic>.from(commentReplies[commentId]![replyIndex])
    : <String, dynamic>{};
    setState(() {
      commentReplies[commentId]?.removeAt(replyIndex);
    });

    try {
      await Supabase.instance.client.from('replies').delete().eq('id', replyId);
    } catch (e) {
      // rollback
      setState(() {
        if (commentReplies[commentId] == null) commentReplies[commentId] = [];
  commentReplies[commentId]!.insert(replyIndex, deleted);
      });
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed to delete reply')));
    }
  }

  Future<void> createPost(String type, String content, File? imageFile) async {
  if (content.trim().isEmpty) return;
  try {
    // Extract mentions from post content
    final mentions = extractMentions(content);
    
    String? imageUrl;
    if (imageFile != null) {
      // Upload image to Supabase Storage and get public URL
      final fileName = p.basename(imageFile.path);
      final filePath = 'uploads/$fileName';
      final bytes = await imageFile.readAsBytes();
      await Supabase.instance.client.storage
          .from('community-posts')
          .uploadBinary(
            filePath,
            bytes,
            fileOptions: const FileOptions(upsert: true),
          );
      imageUrl = Supabase.instance.client.storage
          .from('community-posts')
          .getPublicUrl(filePath);
    }

    final newPost = await Supabase.instance.client.from('community_posts').insert({
      'user_id': widget.userId,
      'type': type,
      'content': content,
      'image_url': imageUrl,
    }).select('id').single();

    // Send mention notifications for posts
    if (mentions.isNotEmpty) {
      await sendMentionNotifications(mentions, newPost['id'].toString());
    }

    fetchPosts();
    Navigator.pop(context);
  } catch (e) {
    print('Error creating post: $e');
  }
}

  void showCreatePostModal() {
    String selectedType = 'general';
    TextEditingController contentController = TextEditingController();
    File? selectedImage;
    final String postFieldId = 'create_post';

    // Initialize mention state for this modal
    showUserSuggestions[postFieldId] = false;
    userSuggestions[postFieldId] = [];
    currentMentionText[postFieldId] = '';

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) {
        return Container(
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.only(
              topLeft: Radius.circular(20),
              topRight: Radius.circular(20),
            ),
          ),
          child: Padding(
            // Make space for the keyboard
            padding: EdgeInsets.only(
              bottom: MediaQuery.of(context).viewInsets.bottom,
              top: 16,
              left: 16,
              right: 16,
            ),
            child: StatefulBuilder(
              builder: (context, setModalState) {
                return SingleChildScrollView(
                  child: SafeArea(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // Handle bar
                        Container(
                          width: 40,
                          height: 4,
                          decoration: BoxDecoration(
                            color: Colors.grey[300],
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                        SizedBox(height: 16),
                        Row(
                          children: [
                            Icon(Icons.edit, color: deepRed),
                            SizedBox(width: 8),
                            Text(
                              'Create Post',
                              style: TextStyle(
                                fontSize: 20,
                                fontWeight: FontWeight.w600,
                                color: Colors.black87,
                              ),
                            ),
                          ],
                        ),
                        SizedBox(height: 20),
                        Container(
                          padding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                          decoration: BoxDecoration(
                            border: Border.all(color: Colors.grey[300]!),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: DropdownButton<String>(
                            value: selectedType,
                            isExpanded: true,
                            underline: SizedBox(),
                            icon: Icon(Icons.arrow_drop_down, color: deepRed),
                            items: ['general', 'missing', 'found']
                                .map((type) => DropdownMenuItem(
                                      value: type,
                                      child: Row(
                                        children: [
                                          Icon(
                                            type == 'general' ? Icons.forum
                                                : type == 'missing' ? Icons.search
                                                : Icons.pets,
                                            color: type == 'general' ? Colors.blue
                                                : type == 'missing' ? Colors.red
                                                : Colors.green,
                                            size: 20,
                                          ),
                                          SizedBox(width: 8),
                                          Text(
                                            type[0].toUpperCase() + type.substring(1),
                                            style: TextStyle(
                                              fontWeight: FontWeight.w500,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ))
                                .toList(),
                            onChanged: (val) {
                              if (val != null) {
                                setModalState(() => selectedType = val);
                              }
                            },
                          ),
                        ),
                        SizedBox(height: 16),
                        // Enhanced text input
                        Container(
                          decoration: BoxDecoration(
                            border: Border.all(color: Colors.grey[300]!),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              TextField(
                                controller: contentController,
                                decoration: InputDecoration(
                                  hintText: 'Write something... (use @username to mention)',
                                  hintStyle: TextStyle(color: Colors.grey[500]),
                                  border: InputBorder.none,
                                  contentPadding: EdgeInsets.all(16),
                                ),
                                maxLines: 4,
                                minLines: 3,
                                onChanged: (text) {
                                  // Handle mention detection for post creation
                                  int cursorPosition = contentController.selection.start;
                                  
                                  // Find @ symbol before cursor
                                  int atPosition = -1;
                                  for (int i = cursorPosition - 1; i >= 0; i--) {
                                    if (text[i] == '@') {
                                      atPosition = i;
                                      break;
                                    } else if (text[i] == ' ' || text[i] == '\n') {
                                      break;
                                    }
                                  }

                                  if (atPosition >= 0) {
                                    final mentionText = text.substring(atPosition + 1, cursorPosition);
                                    if (!mentionText.contains(' ') && !mentionText.contains('\n')) {
                                      mentionStartPosition[postFieldId] = atPosition;
                                      currentMentionText[postFieldId] = mentionText;
                                      searchUsersForMention(postFieldId, mentionText).then((_) {
                                        setModalState(() {}); // Refresh modal state for suggestions
                                      });
                                      return;
                                    }
                                  }

                                  // Hide suggestions if no valid mention detected
                                  setModalState(() {
                                    showUserSuggestions[postFieldId] = false;
                                    userSuggestions[postFieldId] = [];
                                    currentMentionText[postFieldId] = '';
                                  });
                                },
                              ),
                              if ((showUserSuggestions[postFieldId] ?? false) && 
                                  (userSuggestions[postFieldId]?.isNotEmpty ?? false))
                                Container(
                                  constraints: BoxConstraints(maxHeight: 150),
                                  decoration: BoxDecoration(
                                    border: Border(top: BorderSide(color: Colors.grey[200]!)),
                                  ),
                                  child: ListView.builder(
                                    shrinkWrap: true,
                                    itemCount: userSuggestions[postFieldId]?.length ?? 0,
                                    itemBuilder: (context, index) {
                                      final user = userSuggestions[postFieldId]![index];
                                      return ListTile(
                                        dense: true,
                                        leading: CircleAvatar(
                                          radius: 16,
                                          backgroundImage: user['profile_picture'] != null && 
                                              user['profile_picture'].toString().isNotEmpty
                                              ? NetworkImage(user['profile_picture'])
                                              : AssetImage('assets/logo.png') as ImageProvider,
                                        ),
                                        title: Text('@${user['name']}'),
                                        onTap: () {
                                          // Handle mention selection
                                          final currentText = contentController.text;
                                          final mentionStart = mentionStartPosition[postFieldId] ?? 0;
                                          final beforeMention = currentText.substring(0, mentionStart);
                                          final afterMention = currentText.substring(contentController.selection.start);
                                          
                                          final newText = '$beforeMention@${user['name']} $afterMention';
                                          contentController.text = newText;
                                          contentController.selection = TextSelection.collapsed(
                                            offset: (beforeMention.length + user['name'].toString().length + 2),
                                          );

                                          setModalState(() {
                                            showUserSuggestions[postFieldId] = false;
                                            userSuggestions[postFieldId] = [];
                                            currentMentionText[postFieldId] = '';
                                          });
                                        },
                                      );
                                    },
                                  ),
                                ),
                            ],
                          ),
                        ),
                        SizedBox(height: 16),
                        if (selectedImage != null)
                          Container(
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(color: Colors.grey[300]!),
                            ),
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(12),
                              child: Image.file(
                                selectedImage!,
                                height: 150,
                                width: double.infinity,
                                fit: BoxFit.cover,
                              ),
                            ),
                          ),
                        if (selectedImage != null) SizedBox(height: 16),
                        Row(
                          children: [
                            Expanded(
                              child: OutlinedButton.icon(
                                onPressed: () async {
                                  final picked = await ImagePicker().pickImage(source: ImageSource.gallery);
                                  if (picked != null) {
                                    setModalState(() => selectedImage = File(picked.path));
                                  }
                                },
                                icon: Icon(Icons.add_a_photo, color: deepRed),
                                label: Text(
                                  selectedImage != null ? 'Change Image' : 'Add Image',
                                  style: TextStyle(color: deepRed),
                                ),
                                style: OutlinedButton.styleFrom(
                                  side: BorderSide(color: deepRed),
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                                  padding: EdgeInsets.symmetric(vertical: 12),
                                ),
                              ),
                            ),
                            if (selectedImage != null) ...[
                              SizedBox(width: 12),
                              OutlinedButton.icon(
                                onPressed: () {
                                  setModalState(() => selectedImage = null);
                                },
                                icon: Icon(Icons.close, color: Colors.red),
                                label: Text('Remove', style: TextStyle(color: Colors.red)),
                                style: OutlinedButton.styleFrom(
                                  side: BorderSide(color: Colors.red),
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                                  padding: EdgeInsets.symmetric(vertical: 12),
                                ),
                              ),
                            ],
                          ],
                        ),
                        SizedBox(height: 20),
                        SizedBox(
                          width: double.infinity,
                          child: ElevatedButton(
                            onPressed: () async {
                              final content = contentController.text.trim();
                              if (content.isNotEmpty) {
                                // Clean up mention state when posting
                                showUserSuggestions.remove(postFieldId);
                                userSuggestions.remove(postFieldId);
                                currentMentionText.remove(postFieldId);
                                mentionStartPosition.remove(postFieldId);
                                
                                await createPost(selectedType, content, selectedImage);
                              } else {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(content: Text('Please write something before posting')),
                                );
                              }
                            },
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.green,
                              foregroundColor: Colors.white,
                              padding: EdgeInsets.symmetric(vertical: 16),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                            ),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(Icons.send),
                                SizedBox(width: 8),
                                Text(
                                  'Share Post',
                                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                                ),
                              ],
                            ),
                          ),
                        ),
                        SizedBox(height: 16),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        );
      },
    );
  }

  // Enhanced Report Post Modal
  void _showReportModal(BuildContext context, Map post) {
    final List<Map<String, dynamic>> violationTypes = [
      {
        'type': 'Unattended or Missing Pet Reports',
        'icon': Icons.pets,
        'description': 'Reports about lost, missing, or unattended pets'
      },
      {
        'type': 'Irresponsible Sitter Behavior',
        'icon': Icons.person_off,
        'description': 'Negligent or inappropriate behavior by pet sitters'
      },
      {
        'type': 'False or Misleading Posts',
        'icon': Icons.warning,
        'description': 'Incorrect, fake, or deceptive information'
      },
      {
        'type': 'Inappropriate Content',
        'icon': Icons.block,
        'description': 'Offensive, harmful, or inappropriate material'
      },
      {
        'type': 'Pet Endangerment',
        'icon': Icons.dangerous,
        'description': 'Content showing or promoting harm to animals'
      },
      {
        'type': 'Neglect or Poor Care Practices',
        'icon': Icons.health_and_safety,
        'description': 'Evidence of animal neglect or poor care'
      },
      {
        'type': 'Spam or Commercial Misuse',
        'icon': Icons.block_outlined,
        'description': 'Unwanted advertising or spam content'
      },
      {
        'type': 'Privacy Violation',
        'icon': Icons.privacy_tip,
        'description': 'Sharing personal information without consent'
      },
      {
        'type': 'Other',
        'icon': Icons.more_horiz,
        'description': 'Other violations not listed above'
      },
    ];

    String selectedViolation = '';
    TextEditingController detailsController = TextEditingController();
    bool isAnonymous = false;
    bool isSubmitting = false;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) {
        return Container(
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.only(
              topLeft: Radius.circular(20),
              topRight: Radius.circular(20),
            ),
          ),
          child: Padding(
            padding: EdgeInsets.only(
              bottom: MediaQuery.of(context).viewInsets.bottom,
              top: 16,
              left: 16,
              right: 16,
            ),
            child: StatefulBuilder(
              builder: (context, setModalState) {
                return SingleChildScrollView(
                  child: SafeArea(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // Handle bar
                        Center(
                          child: Container(
                            width: 40,
                            height: 4,
                            decoration: BoxDecoration(
                              color: Colors.grey[300],
                              borderRadius: BorderRadius.circular(2),
                            ),
                          ),
                        ),
                        SizedBox(height: 20),
                        
                        // Header
                        Row(
                          children: [
                            Container(
                              padding: EdgeInsets.all(8),
                              decoration: BoxDecoration(
                                color: Colors.red[50],
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Icon(
                                Icons.report_outlined,
                                color: Colors.red[600],
                                size: 24,
                              ),
                            ),
                            SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    'Report Post',
                                    style: TextStyle(
                                      fontSize: 20,
                                      fontWeight: FontWeight.bold,
                                      color: Colors.black87,
                                    ),
                                  ),
                                  Text(
                                    'Help us maintain a safe community',
                                    style: TextStyle(
                                      fontSize: 14,
                                      color: Colors.grey[600],
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                        SizedBox(height: 24),
                        
                        // Violation Types
                        Text(
                          'What type of violation is this?',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                            color: Colors.black87,
                          ),
                        ),
                        SizedBox(height: 12),
                        
                        // Violation type options
                        ...violationTypes.map((violation) {
                          final bool isSelected = selectedViolation == violation['type'];
                          return Container(
                            margin: EdgeInsets.only(bottom: 8),
                            child: Material(
                              color: Colors.transparent,
                              child: InkWell(
                                borderRadius: BorderRadius.circular(12),
                                onTap: () {
                                  setModalState(() {
                                    selectedViolation = violation['type'];
                                  });
                                },
                                child: Container(
                                  padding: EdgeInsets.all(16),
                                  decoration: BoxDecoration(
                                    border: Border.all(
                                      color: isSelected ? deepRed : Colors.grey[300]!,
                                      width: isSelected ? 2 : 1,
                                    ),
                                    borderRadius: BorderRadius.circular(12),
                                    color: isSelected ? deepRed.withOpacity(0.05) : Colors.white,
                                  ),
                                  child: Row(
                                    children: [
                                      Container(
                                        padding: EdgeInsets.all(8),
                                        decoration: BoxDecoration(
                                          color: isSelected 
                                              ? deepRed.withOpacity(0.1)
                                              : Colors.grey[100],
                                          borderRadius: BorderRadius.circular(8),
                                        ),
                                        child: Icon(
                                          violation['icon'],
                                          color: isSelected ? deepRed : Colors.grey[600],
                                          size: 20,
                                        ),
                                      ),
                                      SizedBox(width: 12),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment: CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              violation['type'],
                                              style: TextStyle(
                                                fontWeight: FontWeight.w600,
                                                color: isSelected ? deepRed : Colors.black87,
                                                fontSize: 14,
                                              ),
                                            ),
                                            SizedBox(height: 2),
                                            Text(
                                              violation['description'],
                                              style: TextStyle(
                                                color: Colors.grey[600],
                                                fontSize: 12,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                      if (isSelected)
                                        Icon(
                                          Icons.check_circle,
                                          color: deepRed,
                                          size: 20,
                                        ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          );
                        }).toList(),
                        
                        SizedBox(height: 20),
                        
                        // Additional details section
                        Text(
                          'Additional Details (Optional)',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                            color: Colors.black87,
                          ),
                        ),
                        SizedBox(height: 8),
                        Container(
                          decoration: BoxDecoration(
                            border: Border.all(color: Colors.grey[300]!),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: TextField(
                            controller: detailsController,
                            maxLines: 3,
                            decoration: InputDecoration(
                              hintText: 'Provide any additional context that might help us understand the issue...',
                              hintStyle: TextStyle(color: Colors.grey[500]),
                              border: InputBorder.none,
                              contentPadding: EdgeInsets.all(16),
                            ),
                          ),
                        ),
                        SizedBox(height: 16),
                        
                        // Anonymous reporting option
                        Container(
                          padding: EdgeInsets.all(16),
                          decoration: BoxDecoration(
                            color: Colors.blue[50],
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: Colors.blue[100]!),
                          ),
                          child: Row(
                            children: [
                              Checkbox(
                                value: isAnonymous,
                                onChanged: (value) {
                                  setModalState(() {
                                    isAnonymous = value ?? false;
                                  });
                                },
                                activeColor: deepRed,
                              ),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      'Submit anonymously',
                                      style: TextStyle(
                                        fontWeight: FontWeight.w600,
                                        color: Colors.black87,
                                      ),
                                    ),
                                    Text(
                                      'Your identity will not be shared with the post author',
                                      style: TextStyle(
                                        color: Colors.grey[600],
                                        fontSize: 12,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                        SizedBox(height: 24),
                        
                        // Action buttons
                        Row(
                          children: [
                            Expanded(
                              child: TextButton(
                                onPressed: () => Navigator.pop(context),
                                style: TextButton.styleFrom(
                                  padding: EdgeInsets.symmetric(vertical: 16),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(12),
                                    side: BorderSide(color: Colors.red.shade300),
                                  ),
                                ),
                                child: Text(
                                  'Cancel',
                                  style: TextStyle(
                                    color: Colors.red,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                            ),
                            SizedBox(width: 12),
                            Expanded(
                              child: ElevatedButton(
                                onPressed: selectedViolation.isEmpty || isSubmitting
                                    ? null
                                    : () async {
                                        setModalState(() {
                                          isSubmitting = true;
                                        });
                                        
                                        String reason = selectedViolation;
                                        if (selectedViolation == 'Other' && detailsController.text.trim().isNotEmpty) {
                                          reason = detailsController.text.trim();
                                        } else if (selectedViolation == 'Other') {
                                          ScaffoldMessenger.of(context).showSnackBar(
                                            SnackBar(
                                              content: Text('Please provide details for "Other" violation type.'),
                                              backgroundColor: Colors.orange,
                                            ),
                                          );
                                          setModalState(() {
                                            isSubmitting = false;
                                          });
                                          return;
                                        }
                                        
                                        try {
                                          // Submit report to database
                                          String finalReason = reason;
                                          if (isAnonymous) {
                                            finalReason = '[Anonymous] $reason';
                                          }
                                          if (detailsController.text.trim().isNotEmpty) {
                                            finalReason += ' - ${detailsController.text.trim()}';
                                          }
                                          
                                          await Supabase.instance.client
                                              .from('reports')
                                              .insert({
                                            'post_id': post['id'],
                                            'user_id': widget.userId,
                                            'reason': finalReason,
                                          });
                                          
                                          // Update the reported status of the post
                                          await Supabase.instance.client
                                              .from('community_posts')
                                              .update({'reported': true})
                                              .eq('id', post['id']);
                                          
                                          Navigator.pop(context);
                                          ScaffoldMessenger.of(context).showSnackBar(
                                            SnackBar(
                                              content: Row(
                                                children: [
                                                  Icon(Icons.check_circle, color: Colors.white),
                                                  SizedBox(width: 8),
                                                  Expanded(
                                                    child: Text('Report submitted successfully. Thank you for helping keep our community safe!'),
                                                  ),
                                                ],
                                              ),
                                              backgroundColor: Colors.green,
                                              duration: Duration(seconds: 4),
                                            ),
                                          );
                                        } catch (e) {
                                          Navigator.pop(context);
                                          ScaffoldMessenger.of(context).showSnackBar(
                                            SnackBar(
                                              content: Row(
                                                children: [
                                                  Icon(Icons.error, color: Colors.white),
                                                  SizedBox(width: 8),
                                                  Expanded(
                                                    child: Text('Failed to submit report. Please try again.'),
                                                  ),
                                                ],
                                              ),
                                              backgroundColor: Colors.red,
                                            ),
                                          );
                                        }
                                      },
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: Colors.green,
                                  foregroundColor: Colors.white,
                                  padding: EdgeInsets.symmetric(vertical: 16),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  elevation: 0,
                                ),
                                child: isSubmitting
                                    ? SizedBox(
                                        height: 20,
                                        width: 20,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                          valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                                        ),
                                      )
                                    : Text(
                                        'Submit Report',
                                        style: TextStyle(
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                              ),
                            ),
                          ],
                        ),
                        SizedBox(height: 16),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        );
      },
    );
  }

  // Mark missing pet as found
  Future<void> markAsFound(BuildContext context, Map post) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text('Mark Pet as Found'),
        content: Text('Mark this missing pet as found? This will update the post type and add a "Found" update to the caption.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text('Cancel', style: TextStyle(color: Colors.red))),
          ElevatedButton(onPressed: () => Navigator.pop(context, true), child: Text('Mark as Found'), style: ElevatedButton.styleFrom(backgroundColor: Colors.green)),
        ],
      ),
    );

    if (confirm != true) return;

    try {
      final currentContent = post['content']?.toString() ?? '';
      final foundTime = getDetailedPhilippinesTime(DateTime.now().toUtc());
      final updatedContent = '$currentContent\n\nUPDATE: Pet has been found! - $foundTime';
      
      await Supabase.instance.client
          .from('community_posts')
          .update({
            'type': 'found',
            'content': updatedContent,
          })
          .eq('id', post['id']);

      // Also update the is_missing status in the pets table for the post owner
      try {
        final userId = post['user_id'];
        if (userId != null) {
          // Get all pets owned by this user that are currently marked as missing
          final missingPets = await Supabase.instance.client
              .from('pets')
              .select('id, name')
              .eq('owner_id', userId)
              .eq('is_missing', true);
          
          if (missingPets is List && missingPets.isNotEmpty) {
            // Try to match the pet by name in the post content
            for (var pet in missingPets) {
              final petName = pet['name']?.toString() ?? '';
              if (petName.isNotEmpty && currentContent.contains(petName)) {
                // Found matching pet - update is_missing status
                await Supabase.instance.client
                    .from('pets')
                    .update({'is_missing': false})
                    .eq('id', pet['id']);
                print('✅ Updated pet ${pet['id']} is_missing status to false');
                break;
              }
            }
          }
        }
      } catch (e) {
        print('⚠️ Warning: Could not update pet is_missing status: $e');
        // Don't fail the entire operation if pet update fails
      }

      // Update local state
      setState(() {
        final postIndex = posts.indexWhere((p) => p['id'] == post['id']);
        if (postIndex != -1) {
          posts[postIndex]['type'] = 'found';
          posts[postIndex]['content'] = updatedContent;
        }
      });

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Pet marked as found!'),
          backgroundColor: Colors.green,
        ),
      );
    } catch (e) {
      print('Error marking pet as found: $e');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Failed to mark pet as found. Please try again.'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  Future<void> deletePost(BuildContext context, String postId) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text('Delete Post'),
        content: Text('Are you sure you want to delete this post? This will also delete all comments and notifications related to this post.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text('Cancel', style: TextStyle(color: Colors.red))),
          ElevatedButton(onPressed: () => Navigator.pop(context, true), child: Text('Delete'), style: ElevatedButton.styleFrom(backgroundColor: Colors.green)),
        ],
      ),
    );

    if (confirm != true) return;

    try {
      // Delete in the correct order to handle foreign key constraints
      
      // 1. First delete all notifications related to comments on this post
      final commentIds = await Supabase.instance.client
          .from('comments')
          .select('id')
          .eq('post_id', postId);
      
      if (commentIds.isNotEmpty) {
        final commentIdList = commentIds.map((c) => c['id']).toList();
        
        // Delete notifications for these comments
        await Supabase.instance.client
            .from('notifications')
            .delete()
            .inFilter('comment_id', commentIdList);
        
        // Delete replies to these comments
        await Supabase.instance.client
            .from('replies')
            .delete()
            .inFilter('comment_id', commentIdList);
        
        // Delete comment likes
        await Supabase.instance.client
            .from('comment_likes')
            .delete()
            .inFilter('comment_id', commentIdList);
      }
      
      // 2. Delete all notifications related to this post
      await Supabase.instance.client
          .from('notifications')
          .delete()
          .eq('post_id', postId);
      
      // 3. Delete all comments on this post
      await Supabase.instance.client
          .from('comments')
          .delete()
          .eq('post_id', postId);
      
      // 4. Delete all likes on this post
      await Supabase.instance.client
          .from('likes')
          .delete()
          .eq('post_id', postId);
      
      // 5. Delete all bookmarks for this post
      await Supabase.instance.client
          .from('bookmarks')
          .delete()
          .eq('post_id', postId);
      
      // 6. Finally delete the post itself
      await Supabase.instance.client
          .from('community_posts')
          .delete()
          .eq('id', postId);

      // Clean up local state
      setState(() {
        posts.removeWhere((post) => post['id'].toString() == postId);
        postComments.remove(postId);
        commentCounts.remove(postId);
        locallyUpdatedPosts.remove(postId);
        likedPosts.remove(postId);
        likeCounts.remove(postId);
        bookmarkedPosts.remove(postId);
        showCommentInput.remove(postId);
        commentControllers.remove(postId);
      });

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Post deleted successfully'),
          backgroundColor: deepRed,
        ),
      );
    } catch (e) {
      print('Error deleting post: $e');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Failed to delete post. Please try again.'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

void showEditPostModal(Map post) {
  TextEditingController contentController = TextEditingController(text: post['content']);
  File? selectedImage;

  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    builder: (_) => Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom + 20,
        top: 16,
        left: 16,
        right: 16,
      ),
      child: StatefulBuilder(
        builder: (context, setModalState) => Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Edit Post', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            TextField(
              controller: contentController,
              decoration: InputDecoration(hintText: 'Update your content...'),
              maxLines: 3,
            ),
            if (selectedImage != null)
              Image.file(selectedImage!, height: 100)
            else if (post['image_url'] != null)
              Image.network(post['image_url'], height: 100),
            TextButton.icon(
              onPressed: () async {
                final picked = await ImagePicker().pickImage(source: ImageSource.gallery);
                if (picked != null) {
                  setModalState(() => selectedImage = File(picked.path));
                }
              },
              icon: Icon(Icons.image),
              label: Text('Change Image'),
            ),
            ElevatedButton(
              onPressed: () async {
                final trimmedContent = contentController.text.trim();

                if (trimmedContent.isEmpty) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('Content cannot be empty.')),
                  );
                  return;
                }

                final originalContent = post['content']?.toString().trim() ?? '';
                final originalImageUrl = post['image_url']?.toString();

                bool contentChanged = trimmedContent != originalContent;
                bool imageChanged = selectedImage != null;

                if (!contentChanged && !imageChanged) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('No changes made to the post.')),
                  );
                  return;
                }

                String? newImageUrl = originalImageUrl;
                if (imageChanged) {
                  newImageUrl = await uploadImage(selectedImage!);
                }

                // Build update map dynamically
                final Map<String, dynamic> updatedFields = {};
                if (contentChanged) updatedFields['content'] = trimmedContent;
                if (imageChanged) updatedFields['image_url'] = newImageUrl;

                try {
                  final response = await Supabase.instance.client
                    .from('community_posts')
                    .update(updatedFields)
                    .eq('id', post['id'])
                    .select('*');

                  if (response.isEmpty) {
                    print('No post updated.');
                  } else {
                    print('Post updated successfully.');
                    Navigator.pop(context);
                    fetchPosts(); // Refresh the list
                  }
                } catch (e) {
                  print('Error updating post: $e');
                }
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.green,
                foregroundColor: Colors.white,
              ),
              child: Text('Save Changes'),
            ),
          ],
        ),
      ),
    ),
  );
}

  List<dynamic> getFilteredPosts(String filterType) {
    return posts.where((post) {
      if (filterType == 'all') return true;
      return post['type'] == filterType;
    }).toList();
  }

  String? getCurrentUserProfilePicture() {
  // This function is deprecated - profile pictures should come from public.users table
  // The query already includes profile_picture from the users table
  return null;
}

  Widget buildPostList(List<dynamic> postList) {
    if (postList.isEmpty) return Center(child: Text('No posts to show.'));
    return ListView.builder(
      controller: _scrollController,
      itemCount: postList.length,
      itemBuilder: (context, index) {
        final post = postList[index];
        final postId = post['id'].toString();
        final userData = post['users'] ?? {};
        final userName = userData['name'] ?? 'Unknown';
        final userRole = userData['role'] ?? 'User';
        String? profilePic = userData['profile_picture'];

        // Profile picture should already be from public.users table via the query

        final createdAt = DateTime.tryParse(post['created_at'] ?? '') ?? DateTime.now();
        final timeAgo = formatPhilippinesTime(createdAt);

        // Only initialize if not already set
        if (!likedPosts.containsKey(postId)) {
          final likes = post['likes'] as List? ?? [];
          likedPosts[postId] = likes.any((like) => like['user_id'] == widget.userId);
        }
        showCommentInput.putIfAbsent(postId, () => false);
        commentControllers.putIfAbsent(postId, () => TextEditingController());

      int likeCount = (post['likes'] != null && post['likes'] is List) ? post['likes'].length : 0;
      if (!postComments.containsKey(postId)) {
        List<Map<String, dynamic>> comments = [];
        if (post['comments'] != null && post['comments'] is List) {
          comments = (post['comments'] as List).map((e) => Map<String, dynamic>.from(e)).toList();
        }
        postComments[postId] = comments;
      }

        return Card(
          key: postId == widget.targetPostId ? targetPostKey : null,
          margin: EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          elevation: highlightedPostId == postId ? 8 : 3,
          shadowColor: highlightedPostId == postId ? deepRed.withOpacity(0.3) : Colors.black.withOpacity(0.1),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          color: Colors.white,
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              gradient: highlightedPostId == postId 
                  ? LinearGradient(
                      colors: [Colors.yellow[50]!, Colors.white],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    )
                  : null,
              border: highlightedPostId == postId 
                  ? Border.all(color: deepRed, width: 2)
                  : null,
            ),
            child: Padding(
              padding: EdgeInsets.all(16),
              child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withOpacity(0.1),
                            blurRadius: 4,
                            offset: Offset(0, 2),
                          ),
                        ],
                      ),
                      child: CircleAvatar(
                        radius: 22,
                        backgroundColor: Colors.grey[200],
                        backgroundImage: profilePic != null && profilePic.toString().isNotEmpty
                            ? NetworkImage(profilePic)
                            : AssetImage('assets/logo.png') as ImageProvider,
                      ),
                    ),
                    SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Wrap(
                            crossAxisAlignment: WrapCrossAlignment.center,
                            spacing: 8,
                            runSpacing: 4,
                            children: [
                              Text(
                                userName,
                                style: TextStyle(
                                  fontWeight: FontWeight.w600,
                                  fontSize: 16,
                                  color: Colors.black87,
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                              GestureDetector(
                                onTap: () {
                                  // Show detailed timestamp on tap
                                  showDialog(
                                    context: context,
                                    builder: (context) => AlertDialog(
                                      title: Text('Posted Time'),
                                      content: Text(getDetailedPhilippinesTime(createdAt)),
                                      actions: [
                                        TextButton(
                                          onPressed: () => Navigator.pop(context),
                                          child: Text('OK'),
                                        ),
                                      ],
                                    ),
                                  );
                                },
                                child: Container(
                                  padding: EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                  decoration: BoxDecoration(
                                    color: Colors.grey[100],
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  child: Text(
                                    timeAgo,
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: Colors.grey[600],
                                      fontWeight: FontWeight.w500,
                                    ),
                                  ),
                                ),
                              ),
                              // Post type label
                              if (post['type'] != null && post['type'].toString().isNotEmpty)
                                Container(
                                  padding: EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                  decoration: BoxDecoration(
                                    gradient: LinearGradient(
                                      colors: post['type'] == 'general'
                                          ? [Colors.blue[400]!, Colors.blue[600]!]
                                          : post['type'] == 'missing'
                                              ? [Colors.red[400]!, Colors.red[600]!]
                                              : post['type'] == 'found'
                                                  ? [Colors.green[400]!, Colors.green[600]!]
                                                  : [Colors.grey[400]!, Colors.grey[600]!],
                                      begin: Alignment.topLeft,
                                      end: Alignment.bottomRight,
                                    ),
                                    borderRadius: BorderRadius.circular(10),
                                    boxShadow: [
                                      BoxShadow(
                                        color: Colors.black.withOpacity(0.1),
                                        blurRadius: 2,
                                        offset: Offset(0, 1),
                                      ),
                                    ],
                                  ),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [

                                      SizedBox(width: 3),
                                      Text(
                                        post['type'] == 'found' 
                                            ? 'FOUND'
                                            : post['type'].toString().toUpperCase(),
                                        style: TextStyle(
                                          fontSize: 10,
                                          color: Colors.white,
                                          fontWeight: FontWeight.bold,
                                          letterSpacing: 0.3,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                            ],
                          ),
                          SizedBox(height: 6),
                          Container(
                            padding: EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                colors: userRole == 'Pet Owner' 
                                    ? [sitterColor, sitterColor.withOpacity(0.8)]
                                    : [ownerColor, ownerColor.withOpacity(0.8)],
                                begin: Alignment.topLeft,
                                end: Alignment.bottomRight,
                              ),
                              borderRadius: BorderRadius.circular(12),
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.black.withOpacity(0.05),
                                  blurRadius: 2,
                                  offset: Offset(0, 1),
                                ),
                              ],
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  userRole == 'Pet Owner' ? Icons.pets : Icons.person,
                                  size: 12,
                                  color: Colors.white,
                                ),
                                SizedBox(width: 4),
                                Text(
                                  userRole,
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: Colors.white,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                    Container(
                      width: 85, // Match IconButton size for alignment
                      alignment: Alignment.topCenter,
                      child: post['user_id'] == widget.userId
                          ? PopupMenuButton<String>(
                              onSelected: (value) {
                                if (value == 'edit') {
                                  showEditPostModal(post);
                                } else if (value == 'delete') {
                                  deletePost(context, post['id']);
                                } else if (value == 'mark_found') {
                                  markAsFound(context, post);
                                }
                              },
                              itemBuilder: (_) {
                                List<PopupMenuEntry<String>> items = [
                                  PopupMenuItem(value: 'edit', child: Row(
                                    children: [
                                      Icon(Icons.edit, size: 18, color: Colors.grey[600]),
                                      SizedBox(width: 8),
                                      Text('Edit'),
                                    ],
                                  )),
                                ];
                                
                                // Add "Mark as Found" option only for missing pet posts
                                if (post['type'] == 'missing') {
                                  items.add(PopupMenuItem(
                                    value: 'mark_found', 
                                    child: Row(
                                      children: [
                                        Icon(Icons.pets, size: 18, color: Colors.green[600]),
                                        SizedBox(width: 8),
                                        Text('Mark as Found', style: TextStyle(color: Colors.green[600])),
                                      ],
                                    ),
                                  ));
                                }
                                
                                items.add(PopupMenuItem(value: 'delete', child: Row(
                                  children: [
                                    Icon(Icons.delete, size: 18, color: Colors.red[600]),
                                    SizedBox(width: 8),
                                    Text('Delete', style: TextStyle(color: Colors.red[600])),
                                  ],
                                )));
                                
                                return items;
                              },
                            )
                          : IconButton(
                              icon: Icon(Icons.report_outlined, color: Colors.deepOrange),
                              tooltip: 'Report Post',
                              onPressed: () => _showReportModal(context, post),
                            ),
                    ),
                  ],
                ),
                SizedBox(height: 12),
                Container(
                  padding: EdgeInsets.all(2),
                  child: buildTextWithMentions(post['content'] ?? ''),
                ),
                SizedBox(height: 12),
                if (post['image_url'] != null)
                  Container(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(12),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withOpacity(0.1),
                          blurRadius: 8,
                          offset: Offset(0, 4),
                        ),
                      ],
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: Image.network(
                        post['image_url'],
                        fit: BoxFit.cover,
                        width: double.infinity,
                        loadingBuilder: (context, child, loadingProgress) {
                          if (loadingProgress == null) return child;
                          return Container(
                            height: 200,
                            child: Center(
                              child: CircularProgressIndicator(
                                color: deepRed,
                                value: loadingProgress.expectedTotalBytes != null
                                    ? loadingProgress.cumulativeBytesLoaded /
                                        loadingProgress.expectedTotalBytes!
                                    : null,
                              ),
                            ),
                          );
                        },
                        errorBuilder: (context, error, stackTrace) {
                          return Container(
                            height: 200,
                            decoration: BoxDecoration(
                              color: Colors.grey[200],
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Center(
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Icon(Icons.error_outline, color: Colors.grey[600]),
                                  SizedBox(height: 8),
                                  Text('Failed to load image', style: TextStyle(color: Colors.grey[600])),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ),
                SizedBox(height: 12),
                Padding(
                  padding: EdgeInsets.symmetric(horizontal: 16),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            iconSize: 20,
                            padding: EdgeInsets.all(4),
                            constraints: BoxConstraints(minWidth: 32, minHeight: 32),
                            icon: Icon(
                              (likedPosts[postId] ?? false) ? Icons.favorite : Icons.favorite_border,
                              color: (likedPosts[postId] ?? false) ? Colors.red : deepRed,
                            ),
                            onPressed: () async {
                              // Any user can like/unlike any post
                              final bool currentLikeState = likedPosts[postId] ?? false;
                              final bool newLikeState = !currentLikeState;
                              setState(() {
                                likedPosts[postId] = newLikeState;
                                if (newLikeState) {
                                  likeCounts[postId] = (likeCounts[postId] ?? 0) + 1;
                                } else {
                                  likeCounts[postId] = (likeCounts[postId] ?? 1) - 1;
                                }
                              });
                              try {
                                if (newLikeState) {
                                  await Supabase.instance.client
                                    .from('likes')
                                    .insert({'post_id': postId, 'user_id': widget.userId});
                                  
                                  // Send like notification using new service
                                  if (post['user_id'] != widget.userId) {
                                    // Get current user name
                                    final currentUserResponse = await Supabase.instance.client
                                        .from('users')
                                        .select('name')
                                        .eq('id', widget.userId)
                                        .single();
                                    final currentUserName = currentUserResponse['name'] as String? ?? 'Someone';
                                    
                                    await sendCommunityNotification(
                                      recipientId: post['user_id'],
                                      actorId: widget.userId,
                                      type: 'like',
                                      message: '$currentUserName liked your post',
                                      postId: postId,
                                      actorName: currentUserName,
                                    );
                                  }
                                } else {
                                  await Supabase.instance.client
                                    .from('likes')
                                    .delete()
                                    .eq('post_id', postId)
                                    .eq('user_id', widget.userId);
                                }
                                final updatedPost = await Supabase.instance.client
                                  .from('community_posts')
                                  .select('*, likes(user_id)')
                                  .eq('id', postId)
                                  .single();
                                setState(() {
                                  final index = posts.indexWhere((p) => p['id'].toString() == postId);
                                  if (index != -1) {
                                    posts[index]['likes'] = updatedPost['likes'];
                                    likeCounts[postId] = updatedPost['likes']?.length ?? 0;
                                  }
                                });
                              } catch (e) {
                                print('Error updating like: $e');
                                setState(() {
                                  likedPosts[postId] = currentLikeState;
                                  if (currentLikeState) {
                                    likeCounts[postId] = (likeCounts[postId] ?? 0) + 1;
                                  } else {
                                    likeCounts[postId] = (likeCounts[postId] ?? 1) - 1;
                                  }
                                });
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    content: Text('Failed to update like. Please try again.'),
                                    duration: Duration(seconds: 2),
                                  )
                                );
                              }
                            },
                          ),
                          if (likeCount > 0)
                            Text(
                              '$likeCount', 
                              style: TextStyle(fontSize: 12),
                              overflow: TextOverflow.ellipsis,
                            ),
                        ],
                      ),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            iconSize: 20,
                            padding: EdgeInsets.all(4),
                            constraints: BoxConstraints(minWidth: 32, minHeight: 32),
                            icon: Icon(Icons.comment_outlined, color: deepRed),
                            onPressed: () {
                              // Any user can comment on any post
                              setState(() {
                                showCommentInput[postId] = !(showCommentInput[postId] ?? false);
                              });
                            },
                          ),
                          Text(
                            '${_getCommentCount(postId)} comments',
                            style: TextStyle(fontSize: 12),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                      IconButton(
                        iconSize: 20,
                        padding: EdgeInsets.all(4),
                        constraints: BoxConstraints(minWidth: 32, minHeight: 32),
                        icon: Icon(
                          bookmarkedPosts[postId] == true ? Icons.bookmark : Icons.bookmark_border,
                          color: deepRed,
                        ),
                        onPressed: () async {
                          print('� Bookmark clicked for post: $postId');
                          await toggleBookmark(postId);
                        },
                      ),
                    ],
                  ),
                ),
                if (showCommentInput[postId] == true)
                  Padding(
                    padding: const EdgeInsets.only(top: 8.0),
                    child: Column(
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: buildMentionTextField(
                                fieldId: 'comment_$postId',
                                controller: commentControllers[postId]!,
                                hintText: 'Add a comment... (use @username to mention)',
                                onSubmit: () async {
                                  final commentText = commentControllers[postId]?.text.trim();
                                  if (commentText != null && commentText.isNotEmpty) {
                                    await addComment(postId, commentText);
                                  }
                                  FocusScope.of(context).unfocus();
                                },
                              ),
                            ),
                            IconButton(
                              icon: Icon(Icons.send, color: deepRed),
                              onPressed: () async {
                                final commentText = commentControllers[postId]?.text.trim();
                                print('BUTTON PRESSED - Comment text: "$commentText" for post $postId');
                                if (commentText != null && commentText.isNotEmpty) {
                                  print('CALLING addComment for post $postId with text: "$commentText"');
                                  await addComment(postId, commentText);
                                  print('FINISHED addComment for post $postId');
                                }
                                
                                // Hide keyboard after comment attempt
                                FocusScope.of(context).unfocus();
                              },
                            ),
                          ],
                        ),
                        if ((postComments[postId]?.length ?? 0) > 0)
                          ListView.builder(
                            shrinkWrap: true,
                            physics: NeverScrollableScrollPhysics(),
                            itemCount: postComments[postId]?.length ?? 0,
                            itemBuilder: (context, idx) {
                              final comment = postComments[postId]![idx];
                              final user = comment['users'] ?? {};
                              final commentId = comment['id'].toString();
                              final commentProfilePic = user['profile_picture']; // <-- Add this line
                              final commentLikes = comment['comment_likes'] as List? ?? [];
                              final isLiked = commentLikes.any((like) => like['user_id'] == widget.userId);
                              likedComments[commentId] = isLiked;

                              return Container(
                                margin: EdgeInsets.symmetric(vertical: 6, horizontal: 8),
                                decoration: BoxDecoration(
                                  color: Colors.white,
                                  borderRadius: BorderRadius.circular(12),
                                  boxShadow: [
                                    BoxShadow(
                                      color: Colors.black.withOpacity(0.05),
                                      blurRadius: 4,
                                      offset: Offset(0, 2),
                                    ),
                                  ],
                                  border: Border.all(color: Colors.grey[200]!),
                                ),
                                child: Stack(
                                  children: [
                                    Padding(
                                      padding: EdgeInsets.all(12),
                                      child: Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                      Row(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          Container(
                                            decoration: BoxDecoration(
                                              shape: BoxShape.circle,
                                              boxShadow: [
                                                BoxShadow(
                                                  color: Colors.black.withOpacity(0.1),
                                                  blurRadius: 3,
                                                  offset: Offset(0, 1),
                                                ),
                                              ],
                                            ),
                                            child: CircleAvatar(
                                              radius: 18,
                                              backgroundColor: Colors.grey[200],
                                              backgroundImage: commentProfilePic != null && commentProfilePic.toString().isNotEmpty
                                                  ? NetworkImage(commentProfilePic)
                                                  : AssetImage('assets/logo.png') as ImageProvider,
                                            ),
                                          ),
                                          SizedBox(width: 10),
                                          Expanded(
                                            child: Column(
                                              crossAxisAlignment: CrossAxisAlignment.start,
                                              children: [
                                                Row(
                                                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                                  children: [
                                                    Row(
                                                      children: [
                                                        Text(
                                                          user['name'] ?? 'Unknown',
                                                          style: TextStyle(
                                                            fontWeight: FontWeight.w600,
                                                            fontSize: 14,
                                                            color: Colors.black87,
                                                          ),
                                                        ),
                                                        SizedBox(width: 8),
                                                        Container(
                                                          padding: EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                                          decoration: BoxDecoration(
                                                            color: Colors.grey[100],
                                                            borderRadius: BorderRadius.circular(6),
                                                          ),
                                                          child: Text(
                                                            _getTimeAgo(
                                                              DateTime.tryParse((comment['created_at'] ?? '').toString()) ??
                                                              DateTime.now(),
                                                            ),
                                                            style: TextStyle(
                                                              fontSize: 11,
                                                              color: Colors.grey[600],
                                                              fontWeight: FontWeight.w500,
                                                            ),
                                                          ),
                                                        ),
                                                      ],
                                                    ),
                                                    if (comment['user_id'] == widget.userId)
                                                      PopupMenuButton<String>(
                                                        icon: Icon(Icons.more_vert, size: 16),
                                                        onSelected: (value) async {
                                                          if (value == 'edit') {
                                                            editCommentControllers.putIfAbsent(
                                                                commentId, () => TextEditingController(text: comment['content']));
                                                            showDialog(
                                                              context: context,
                                                              builder: (context) => AlertDialog(
                                                                title: Text('Edit Comment'),
                                                                content: TextField(
                                                                  controller: editCommentControllers[commentId],
                                                                  decoration: InputDecoration(
                                                                    hintText: 'Edit your comment...',
                                                                    border: OutlineInputBorder(),
                                                                  ),
                                                                  maxLines: 3,
                                                                ),
                                                                actions: [
                                                                  TextButton(
                                                                    onPressed: () => Navigator.pop(context),
                                                                    child: Text('Cancel', style: TextStyle(color: Colors.red)),
                                                                  ),
                                                                  ElevatedButton(
                                                                    onPressed: () async {
                                                                      final newContent = editCommentControllers[commentId]?.text.trim();
                                                                      if (newContent?.isNotEmpty ?? false) {
                                                                        final originalContent = comment['content'];
                                                                        setState(() { commentLoading[commentId] = true; });
                                                                        Navigator.pop(context);
                                                                        try {
                                                                          await Supabase.instance.client
                                                                              .from('comments')
                                                                              .update({'content': newContent})
                                                                              .eq('id', commentId);
                                                                          setState(() {
                                                                            comment['content'] = newContent;
                                                                            commentLoading[commentId] = false;
                                                                          });
                                                                        } catch (e) {
                                                                          print('Error updating comment: $e');
                                                                          setState(() {
                                                                            comment['content'] = originalContent;
                                                                            commentLoading[commentId] = false;
                                                                          });
                                                                          ScaffoldMessenger.of(context).showSnackBar(
                                                                            SnackBar(content: Text('Failed to update comment'))
                                                                          );
                                                                        }
                                                                      }
                                                                    },
                                                                    style: ElevatedButton.styleFrom(
                                                                      backgroundColor: Colors.green,
                                                                    ),
                                                                    child: Text('Save'),
                                                                  ),
                                                                ],
                                                              ),
                                                            );
                                                          } else if (value == 'delete') {
                                                            final confirm = await showDialog<bool>(
                                                              context: context,
                                                              builder: (context) => AlertDialog(
                                                                title: Text('Delete Comment'),
                                                                content: Text('Are you sure you want to delete this comment?'),
                                                                actions: [
                                                                  TextButton(
                                                                    onPressed: () => Navigator.pop(context, false),
                                                                    child: Text('Cancel', style: TextStyle(color: Colors.red)),
                                                                  ),
                                                                  ElevatedButton(
                                                                    onPressed: () => Navigator.pop(context, true),
                                                                    child: Text('Delete'),
                                                                    style: ElevatedButton.styleFrom(
                                                                      backgroundColor: Colors.green,
                                                                    ),
                                                                  ),
                                                                ],
                                                              ),
                                                            );
                                                            if (confirm == true) {
                                                              final deletedComment = {...comment};
                                                              final commentIndex = postComments[postId]!.indexOf(comment);
                                                              setState(() { commentLoading[commentId] = true; });
                                                              try {
                                                                await Supabase.instance.client
                                                                  .from('comments')
                                                                  .delete()
                                                                  .eq('id', commentId);
                                                                setState(() {
                                                                  // Remove from original storage so future renders stay clean
                                                                  postComments[postId]?.removeWhere((c) =>
                                                                      c['id']?.toString() == commentId);
                                                                  commentCounts[postId] = postComments[postId]?.length ?? 0;
                                                                  commentLoading[commentId] = false;
                                                                });
                                                              } catch (e) {
                                                                print('Error deleting comment: $e');
                                                                setState(() {
                                                                  // Rollback visualization only
                                                                  if (!postComments[postId]!.contains(deletedComment)) {
                                                                    postComments[postId]!.insert(commentIndex, deletedComment);
                                                                  }
                                                                  commentCounts[postId] = postComments[postId]!.length;
                                                                  commentLoading[commentId] = false;
                                                                });
                                                                ScaffoldMessenger.of(context).showSnackBar(
                                                                  SnackBar(content: Text('Failed to delete comment'))
                                                                );
                                                              }
                                                            }
                                                          }
                                                        },
                                                        itemBuilder: (_) => [
                                                          PopupMenuItem(value: 'edit', child: Text('Edit')),
                                                          PopupMenuItem(value: 'delete', child: Text('Delete')),
                                                        ],
                                                      ),
                                                  ],
                                                ),
                                                SizedBox(height: 6),
                                                Container(
                                                  padding: EdgeInsets.only(left: 2, right: 2),
                                                  child: buildTextWithMentions(comment['content'] ?? ''),
                                                ),
                                              ],
                                            ),
                                          ),
                                        ],
                                      ),
                                      Container(
                                        margin: EdgeInsets.only(left: 44, top: 8),
                                        padding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                        decoration: BoxDecoration(
                                          color: Colors.grey[50],
                                          borderRadius: BorderRadius.circular(8),
                                        ),
                                        child: Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            InkWell(
                                              onTap: () async {
                                                // Any user can like/unlike any comment
                                                final currentLikeState = likedComments[commentId] ?? false;
                                                final newLikeState = !currentLikeState;
                                                final oldLikes = comment['comment_likes'] as List? ?? [];
                                                setState(() {
                                                  likedComments[commentId] = newLikeState;
                                                  if (newLikeState) {
                                                    comment['comment_likes'] = [...oldLikes, {'user_id': widget.userId}];
                                                  } else {
                                                    comment['comment_likes'] = oldLikes.where((like) => like['user_id'] != widget.userId).toList();
                                                  }
                                                });
                                                try {
                                                  if (newLikeState) {
                                                    await Supabase.instance.client
                                                        .from('comment_likes')
                                                        .insert({
                                                      'comment_id': commentId,
                                                      'user_id': widget.userId
                                                    });
                                                    
                                                    // Send comment like notification using new service
                                                    final commentOwnerId = comment['user_id'];
                                                    if (commentOwnerId != widget.userId) {
                                                      // Get current user name
                                                      final currentUserResponse = await Supabase.instance.client
                                                          .from('users')
                                                          .select('name')
                                                          .eq('id', widget.userId)
                                                          .single();
                                                      final currentUserName = currentUserResponse['name'] as String? ?? 'Someone';
                                                      
                                                      await sendCommunityNotification(
                                                        recipientId: commentOwnerId,
                                                        actorId: widget.userId,
                                                        type: 'comment_like',
                                                        message: '$currentUserName liked your comment',
                                                        commentId: commentId,
                                                        actorName: currentUserName,
                                                      );
                                                    }
                                                  } else {
                                                    await Supabase.instance.client
                                                        .from('comment_likes')
                                                        .delete()
                                                        .eq('comment_id', commentId)
                                                        .eq('user_id', widget.userId);
                                                  }
                                                  final updatedComment = await Supabase.instance.client
                                                    .from('comments')
                                                    .select('comment_likes(*)')
                                                    .eq('id', commentId)
                                                    .single();
                                                  setState(() {
                                                    comment['comment_likes'] = updatedComment['comment_likes'];
                                                  });
                                                } catch (e) {
                                                  print('Error updating comment like: $e');
                                                  setState(() {
                                                    likedComments[commentId] = currentLikeState;
                                                    comment['comment_likes'] = oldLikes;
                                                  });
                                                  ScaffoldMessenger.of(context).showSnackBar(
                                                    SnackBar(
                                                      content: Text('Failed to update comment like. Please try again.'),
                                                      duration: Duration(seconds: 2),
                                                    )
                                                  );
                                                }
                                              },
                                              child: Icon(
                                                (likedComments[commentId] ?? false) ? Icons.favorite : Icons.favorite_border,
                                                size: 16,
                                                color: (likedComments[commentId] ?? false) ? Colors.red : Colors.grey,
                                              ),
                                            ),
                                            SizedBox(width: 4),
                                            Text(
                                              '${(comment['comment_likes']?.length ?? 0)} likes',
                                              style: TextStyle(fontSize: 12, color: Colors.grey),
                                            ),
                                            SizedBox(width: 16),
                                            SizedBox(width: 4),
                                          ],
                                        ),
                                      ),
                                      // Replies section (paginated)
                                      if ((commentReplies[commentId]?.length ?? 0) > 0)
                                        Padding(
                                          padding: const EdgeInsets.only(left: 40.0, top: 8),
                                          child: Column(
                                            children: [
                                              ...List.generate(commentReplies[commentId]!.length, (ri) {
                                                final r = commentReplies[commentId]![ri];
                                                final replyProfilePic = r['users']?['profile_picture'];
                                                return Padding(
                                                  padding: const EdgeInsets.symmetric(vertical: 4.0),
                                                  child: Row(
                                                    crossAxisAlignment: CrossAxisAlignment.start,
                                                    children: [
                                                      CircleAvatar(
                                                        radius: 12,
                                                        backgroundImage: replyProfilePic != null && replyProfilePic.toString().isNotEmpty
                                                            ? NetworkImage(replyProfilePic)
                                                            : AssetImage('assets/logo.png') as ImageProvider,
                                                      ),
                                                      SizedBox(width: 8),
                                                      Expanded(
                                                        child: Column(
                                                          crossAxisAlignment: CrossAxisAlignment.start,
                                                          children: [
                                                            Row(
                                                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                                              children: [
                                                                Text(r['users']?['name'] ?? 'Unknown', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                                                                Text(
                                                                  _getTimeAgo(DateTime.tryParse(r['created_at']) ?? DateTime.now()),
                                                                  style: TextStyle(fontSize: 10, color: Colors.grey),
                                                                ),
                                                                if (r['user_id'] == widget.userId)
                                                                  PopupMenuButton<String>(
                                                                    padding: EdgeInsets.zero,
                                                                    itemBuilder: (_) => [
                                                                      PopupMenuItem(value: 'edit', child: Text('Edit')),
                                                                      PopupMenuItem(value: 'delete', child: Text('Delete')),
                                                                    ],
                                                                    onSelected: (value) async {
                                                                      if (value == 'edit') {
                                                                        final controller = TextEditingController(text: r['content'] ?? '');
                                                                        showDialog(
                                                                          context: context,
                                                                          builder: (context) => AlertDialog(
                                                                            title: Text('Edit Reply'),
                                                                            content: TextField(
                                                                              controller: controller,
                                                                              maxLines: 3,
                                                                              decoration: InputDecoration(border: OutlineInputBorder()),
                                                                            ),
                                                                            actions: [
                                                                              TextButton(onPressed: () => Navigator.pop(context), child: Text('Cancel', style: TextStyle(color: Colors.red))),
                                                                              ElevatedButton(
                                                                                onPressed: () async {
                                                                                  final newText = controller.text.trim();
                                                                                  if (newText.isNotEmpty) {
                                                                                    Navigator.pop(context);
                                                                                    await editReply(commentId, r['id'].toString(), newText, ri);
                                                                                  }
                                                                                },
                                                                                style: ElevatedButton.styleFrom(
                                                                                  backgroundColor: Colors.green,
                                                                                ),
                                                                                child: Text('Save'),
                                                                              ),
                                                                            ],
                                                                          ),
                                                                        );
                                                                      } else if (value == 'delete') {
                                                                        final confirm = await showDialog<bool>(
                                                                          context: context,
                                                                          builder: (context) => AlertDialog(
                                                                            title: Text('Delete Reply'),
                                                                            content: Text('Delete this reply?'),
                                                                            actions: [
                                                                              TextButton(onPressed: () => Navigator.pop(context, false), child: Text('Cancel', style: TextStyle(color: Colors.red))),
                                                                              ElevatedButton(onPressed: () => Navigator.pop(context, true), child: Text('Delete'), style: ElevatedButton.styleFrom(backgroundColor: Colors.green)),
                                                                            ],
                                                                          ),
                                                                        );
                                                                        if (confirm == true) {
                                                                          await deleteReply(commentId, r['id'].toString(), ri);
                                                                        }
                                                                      }
                                                                    },
                                                                  ),
                                                              ],
                                                            ),
                                                            SizedBox(height: 2),
                                                            buildTextWithMentions(r['content'] ?? ''),
                                                          ],
                                                        ),
                                                      ),
                                                    ],
                                                  ),
                                                );
                                              }),
                                              // Only show 'View more' when we actually have more and current loaded >= threshold
                                              if (replyHasMore[commentId] == true && (commentReplies[commentId]?.length ?? 0) >= replyDisplayThreshold)
                                                TextButton(
                                                  onPressed: () async {
                                                    await fetchRepliesForComment(commentId);
                                                  },
                                                  child: Text('View more replies', style: TextStyle(color: deepRed, fontSize: 12)),
                                                ),
                                            ],
                                          ),
                                        ),

                                      // Reply input toggle and field
                                      Padding(
                                        padding: const EdgeInsets.only(left: 20.0, top: 6),
                                        child: Row(
                                          children: [
                                            TextButton(
                                              onPressed: () async {
                                                // Toggle reply input
                                                setState(() {
                                                  showReplyInput[commentId] = !(showReplyInput[commentId] ?? false);
                                                });
                                                if (showReplyInput[commentId] == true) {
                                                  await fetchRepliesForComment(commentId, limit: 5, refresh: true);
                                                }
                                              },
                                              child: Text('Reply', style: TextStyle(color: deepRed, fontSize: 12)),
                                            ),
                                            if (showReplyInput[commentId] == true)
                                              Expanded(
                                                child: Row(
                                                  children: [
                                                    Expanded(
                                                      child: buildMentionTextField(
                                                        fieldId: 'reply_$commentId',
                                                        controller: replyControllers.putIfAbsent(commentId, () => TextEditingController()),
                                                        hintText: 'Write a reply... (use @username to mention)',
                                                        onSubmit: () async {
                                                          final text = replyControllers[commentId]?.text.trim();
                                                          if (text != null && text.isNotEmpty) {
                                                            replyControllers[commentId]?.clear();
                                                            await postReply(commentId, text);
                                                            FocusScope.of(context).unfocus();
                                                          }
                                                        },
                                                      ),
                                                    ),
                                                    IconButton(
                                                      icon: Icon(Icons.send, size: 18, color: deepRed),
                                                      onPressed: () async {
                                                        final text = replyControllers[commentId]?.text.trim();
                                                        if (text != null && text.isNotEmpty) {
                                                          // Clear immediately
                                                          replyControllers[commentId]?.clear();
                                                          await postReply(commentId, text);
                                                          FocusScope.of(context).unfocus();
                                                        }
                                                      },
                                                    ),
                                                  ],
                                                ),
                                              ),
                                          ],
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                    if (commentLoading[commentId] == true)
                                      Positioned.fill(
                                        child: Container(
                                          color: Colors.white.withOpacity(0.7),
                                          child: Center(child: SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2))),
                                        ),
                                      ),
                                  ],
                                ),
                              );
                            },
                          ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: deepRed,
        foregroundColor: Colors.white,
        elevation: 0,
        centerTitle: false,
        title: Row(
          children: [
            SizedBox(width: 8),
            Text(
              'Community',
              style: TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 20,
                color: Colors.white,
              ),
            ),
          ],
        ),
        actions: [
          Container(
            margin: EdgeInsets.symmetric(vertical: 6, horizontal: 4),
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.15),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.white.withOpacity(0.3), width: 1),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.1),
                  blurRadius: 4,
                  offset: Offset(0, 2),
                ),
              ],
            ),
            child: DropdownButtonHideUnderline(
              child: DropdownButton<String>(
                value: selectedFilter,
                isDense: true,
                style: const TextStyle(color: Colors.white),
                alignment: Alignment.center,
                borderRadius: BorderRadius.circular(12),
                menuMaxHeight: 300,
                items: [
                  DropdownMenuItem(
                    value: 'all',
                    child: Container(
                      width: 200, // Fixed width to prevent overflow
                      child: Row(
                        children: [
                          Icon(Icons.dashboard, color: deepRed, size: 16),
                          SizedBox(width: 6),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  'All Posts',
                                  style: TextStyle(
                                    color: Colors.black87,
                                    fontWeight: FontWeight.w600,
                                    fontSize: 13,
                                  ),
                                ),
                                Text(
                                  'Show all community posts',
                                  style: TextStyle(
                                    color: Colors.grey[600],
                                    fontSize: 11,
                                  ),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  DropdownMenuItem(
                    value: 'missing',
                    child: Container(
                      width: 200, // Fixed width to prevent overflow
                      child: Row(
                        children: [
                          Icon(Icons.search, color: Colors.orange[700], size: 16),
                          SizedBox(width: 6),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  'Missing Pets',
                                  style: TextStyle(
                                    color: Colors.black87,
                                    fontWeight: FontWeight.w600,
                                    fontSize: 13,
                                  ),
                                ),
                                Text(
                                  'Posts about lost pets',
                                  style: TextStyle(
                                    color: Colors.grey[600],
                                    fontSize: 11,
                                  ),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  DropdownMenuItem(
                    value: 'found',
                    child: Container(
                      width: 200, // Fixed width to prevent overflow
                      child: Row(
                        children: [
                          Icon(Icons.pets, color: Colors.green[700], size: 16),
                          SizedBox(width: 6),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  'Found Pets',
                                  style: TextStyle(
                                    color: Colors.black87,
                                    fontWeight: FontWeight.w600,
                                    fontSize: 13,
                                  ),
                                ),
                                Text(
                                  'Posts about found pets',
                                  style: TextStyle(
                                    color: Colors.grey[600],
                                    fontSize: 11,
                                  ),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  DropdownMenuItem(
                    value: 'my posts',
                    child: Container(
                      width: 200, // Fixed width to prevent overflow
                      child: Row(
                        children: [
                          Icon(Icons.person, color: deepRed, size: 16),
                          SizedBox(width: 6),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  'My Posts',
                                  style: TextStyle(
                                    color: Colors.black87,
                                    fontWeight: FontWeight.w600,
                                    fontSize: 13,
                                  ),
                                ),
                                Text(
                                  'Only your posts',
                                  style: TextStyle(
                                    color: Colors.grey[600],
                                    fontSize: 11,
                                  ),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
                onChanged: (val) {
                  if (val != null) {
                    setState(() => selectedFilter = val);
                  }
                },
                icon: Icon(Icons.tune, color: Colors.white, size: 20),
                dropdownColor: Colors.white,
                elevation: 8,
                selectedItemBuilder: (context) {
                  return ['all', 'missing', 'found', 'my posts'].map((type) {
                    IconData getFilterIcon() {
                      switch (type) {
                        case 'all':
                          return Icons.dashboard;
                        case 'missing':
                          return Icons.search;
                        case 'found':
                          return Icons.pets;
                        case 'my posts':
                          return Icons.person;
                        default:
                          return Icons.filter_list;
                      }
                    }
                    
                    String getFilterLabel() {
                      switch (type) {
                        case 'all':
                          return 'All Posts';
                        case 'missing':
                          return 'Missing';
                        case 'found':
                          return 'Found';
                        case 'my posts':
                          return 'My Posts';
                        default:
                          return type[0].toUpperCase() + type.substring(1);
                      }
                    }
                    
                    return Container(
                      padding: EdgeInsets.symmetric(horizontal: 8),
                      alignment: Alignment.center,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            getFilterIcon(),
                            color: Colors.white,
                            size: 16,
                          ),
                          SizedBox(width: 6),
                          Text(
                            getFilterLabel(),
                            style: TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w600,
                              fontSize: 13,
                            ),
                          ),
                        ],
                      ),
                    );
                  }).toList();
                },
              ),
            ),
          ),
          Container(
            margin: EdgeInsets.symmetric(vertical: 8, horizontal: 8),
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.1),
              borderRadius: BorderRadius.circular(8),
            ),
            child: IconButton(
              icon: Icon(
                Icons.notifications_outlined,
                color: Colors.white,
                size: 22,
              ),
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) => const NotificationScreen(),
                  ),
                );
              },
              tooltip: 'Notifications',
            ),
          ),
        ],
        flexibleSpace: Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                deepRed,
                deepRed.withOpacity(0.8),
              ],
            ),
          ),
        ),
      ),
      body: isLoading
          ? Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: () async {
                // Refresh posts while preserving local comment updates
                await fetchPosts();
              },
              child: buildPostList(
                selectedFilter == 'my posts'
                    ? posts.where((p) => p['user_id'] == widget.userId).toList()
                    : getFilteredPosts(selectedFilter),
              ),
            ),
      floatingActionButton: FloatingActionButton(
        onPressed: showCreatePostModal,
        backgroundColor: deepRed, // Change to any color you want
        child: Icon(Icons.add, color: Colors.white), // Optional: change icon color
      ),
    );
  }

  String _getTimeAgo(DateTime dateTime) {
    // Assume the input dateTime is in UTC and convert to Philippines time
    final phTime = convertToPhilippinesTime(dateTime);
    final now = convertToPhilippinesTime(DateTime.now().toUtc());
    final difference = now.difference(phTime);
    
    if (difference.inMinutes < 1) {
      return 'Just now';
    } else if (difference.inHours < 1) {
      return '${difference.inMinutes}m';
    } else if (difference.inDays < 1) {
      return '${difference.inHours}h';
    } else if (difference.inDays < 7) {
      return '${difference.inDays}d';
    } else {
      final formatter = DateFormat('MMM d, y');
      return formatter.format(phTime);
    }
  }

  // Build mention-enabled text field widget
  Widget buildMentionTextField({
    required String fieldId,
    required TextEditingController controller,
    required String hintText,
    required VoidCallback onSubmit,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: controller,
          decoration: InputDecoration(hintText: hintText),
          onChanged: (text) {
            handleTextChange(fieldId, text, controller.selection.start);
          },
          onSubmitted: (_) => onSubmit(),
        ),
        if (showUserSuggestions[fieldId] == true && (userSuggestions[fieldId]?.isNotEmpty ?? false))
          Container(
            constraints: BoxConstraints(maxHeight: 200),
            margin: EdgeInsets.only(top: 4),
            decoration: BoxDecoration(
              color: Colors.white,
              border: Border.all(color: Colors.grey.shade300),
              borderRadius: BorderRadius.circular(8),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.1),
                  blurRadius: 4,
                  offset: Offset(0, 2),
                ),
              ],
            ),
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: userSuggestions[fieldId]?.length ?? 0,
              itemBuilder: (context, index) {
                final user = userSuggestions[fieldId]![index];
                return ListTile(
                  dense: true,
                  leading: CircleAvatar(
                    radius: 16,
                    backgroundImage: user['profile_picture'] != null && user['profile_picture'].toString().isNotEmpty
                        ? NetworkImage(user['profile_picture'])
                        : AssetImage('assets/logo.png') as ImageProvider,
                  ),
                  title: Text('@${user['name']}'),
                  onTap: () => selectMention(fieldId, user),
                );
              },
            ),
          ),
      ],
    );
  }
}

extension StringCasing on String {
  String capitalize() => isNotEmpty ? '${this[0].toUpperCase()}${substring(1)}' : '';
  String capitalizeEachWord() => split(' ').map((w) => w.capitalize()).join(' ');
}
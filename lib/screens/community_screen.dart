import 'dart:io';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'notification_screen.dart';

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
const int replyDisplayThreshold = 3; // only show "View more" when replies >= threshold


const deepRed = Color(0xFFB82132);
const lightBlush = Color(0xFFF6DED8);
const ownerColor = Color(0xFFECA1A6); 
const sitterColor = Color(0xFFF2B28C); 

class CommunityScreen extends StatefulWidget {
  final String userId;

  const CommunityScreen({required this.userId});

  @override
  _CommunityScreenState createState() => _CommunityScreenState();
}

class _CommunityScreenState extends State<CommunityScreen> with RouteAware {
  List<dynamic> posts = [];
  bool isLoading = false;
  String selectedFilter = 'all';
  Map<String, bool> showCommentInput = {};
  late ScrollController _scrollController;

  @override
  void initState() {
    super.initState();
    _scrollController = ScrollController();
    fetchPosts();
    loadCommentCounts();
    loadCommentReplies(); // Load replies on initialization
    loadBookmarkedPosts(); // Load bookmarked posts
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
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
      // Insert comment into database
      final newComment = await Supabase.instance.client
          .from('comments')
          .insert({
        'post_id': postId,
        'user_id': widget.userId,
        'content': commentText,
      }).select('id, content, created_at, user_id').single();

      print('Comment inserted: $newComment');

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

    await Supabase.instance.client.from('community_posts').insert({
      'user_id': widget.userId,
      'type': type,
      'content': content,
      'image_url': imageUrl,
      'created_at': DateTime.now().toIso8601String(),
    });

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

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      builder: (context) {
        return Padding(
          // Make space for the keyboard
          padding: EdgeInsets.only(
            bottom: MediaQuery.of(context).viewInsets.bottom,
          ),
          child: StatefulBuilder(
            builder: (context, setModalState) {
              return SingleChildScrollView(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 16),
                  child: SafeArea(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text('Create Post', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                        DropdownButton<String>(
                          value: selectedType,
                          items: ['general', 'missing', 'found']
                              .map((type) => DropdownMenuItem(
                                    value: type,
                                    child: Text(type[0].toUpperCase() + type.substring(1)),
                                  ))
                              .toList(),
                          onChanged: (val) {
                            if (val != null) {
                              setModalState(() => selectedType = val);
                            }
                          },
                        ),
                        TextField(
                          controller: contentController,
                          decoration: InputDecoration(hintText: 'Write something...'),
                          maxLines: 3,
                        ),
                        if (selectedImage != null)
                          Padding(
                            padding: const EdgeInsets.only(top: 8.0),
                            child: Image.file(selectedImage!, height: 100),
                          ),
                        TextButton.icon(
                          onPressed: () async {
                            showModalBottomSheet(
                              context: context,
                              builder: (_) => Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  ListTile(
                                    leading: Icon(Icons.photo_library),
                                    title: Text('Pick Image from Gallery'),
                                    onTap: () async {
                                      final picked = await ImagePicker().pickImage(source: ImageSource.gallery);
                                      if (picked != null) {
                                        setModalState(() => selectedImage = File(picked.path));
                                      }
                                      Navigator.pop(context);
                                    },
                                  ),
                                  ListTile(
                                    leading: Icon(Icons.camera_alt),
                                    title: Text('Take Photo'),
                                    onTap: () async {
                                      final picked = await ImagePicker().pickImage(source: ImageSource.camera);
                                      if (picked != null) {
                                        setModalState(() => selectedImage = File(picked.path));
                                      }
                                      Navigator.pop(context);
                                    },
                                  ),
                                ],
                              ),
                            );
                          },
                          icon: Icon(Icons.add_a_photo),
                          label: Text('Add Media'),
                        ),
                        SizedBox(height: 10),
                        ElevatedButton(
                          onPressed: () => createPost(selectedType, contentController.text, selectedImage),
                          child: Text('Post'),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        );
      },
    );
  }

  Future<void> deletePost(BuildContext context, String postId) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text('Delete Post'),
        content: Text('Are you sure you want to delete this post?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text('Cancel')),
          ElevatedButton(onPressed: () => Navigator.pop(context, true), child: Text('Delete')),
        ],
      ),
    );

    if (confirm != true) return;

    try {
      await Supabase.instance.client
          .from('community_posts')
          .delete()
          .eq('id', postId);

      fetchPosts();
    } catch (e) {
      print('Error deleting post: $e');
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

        final createdAt = DateTime.tryParse(post['created_at'] ?? '')?.toLocal() ?? DateTime.now();
        final timeDiff = DateTime.now().difference(createdAt);
        final timeAgo = timeDiff.inMinutes < 1
            ? 'Just now'
            : timeDiff.inMinutes < 60
                ? '${timeDiff.inMinutes}m ago'
                : timeDiff.inHours < 24
                    ? '${timeDiff.inHours}h ago'
                    : '${timeDiff.inDays}d ago';

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
          margin: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          elevation: 4,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          child: Padding(
            padding: EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    CircleAvatar(
                      radius: 20,
                      backgroundImage: profilePic != null && profilePic.toString().isNotEmpty
                          ? NetworkImage(profilePic)
                          : AssetImage('assets/logo.png') as ImageProvider,
                    ),
                    SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Text(
                                userName,
                                style: TextStyle(fontWeight: FontWeight.bold),
                              ),
                              SizedBox(width: 8),
                              Text(
                                timeAgo,
                                style: TextStyle(fontSize: 12, color: Colors.grey),
                              ),
                            ],
                          ),
                          Container(
                            padding: EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                            decoration: BoxDecoration(
                              color: userRole == 'Pet Owner' ? sitterColor : ownerColor,
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Text(
                              userRole,
                              style: TextStyle(
                                fontSize: 12,
                                color: Colors.white,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (post['user_id'] == widget.userId)
                      Container(
                        width: 85, // Match IconButton size for alignment
                        alignment: Alignment.topCenter,
                        child: PopupMenuButton<String>(
                          onSelected: (value) {
                            if (value == 'edit') {
                              showEditPostModal(post);
                            } else if (value == 'delete') {
                              deletePost(context, post['id']);
                            }
                          },
                          itemBuilder: (_) => [
                            PopupMenuItem(value: 'edit', child: Text('Edit')),
                            PopupMenuItem(value: 'delete', child: Text('Delete')),
                          ],
                        ),
                      ),
                  ],
                ),
                SizedBox(height: 10),
                Text(post['content'] ?? ''),
                SizedBox(height: 10),
                if (post['image_url'] != null)
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: Image.network(post['image_url'], fit: BoxFit.cover),
                  ),
                SizedBox(height: 10),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceAround,
                  children: [
                    Row(
                      children: [
                        IconButton(
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
                          Text('$likeCount'),
                      ],
                    ),
                    Row(
                      children: [
                        IconButton(
                          icon: Icon(Icons.comment_outlined, color: deepRed),
                          onPressed: () {
                            // Any user can comment on any post
                            setState(() {
                              showCommentInput[postId] = !(showCommentInput[postId] ?? false);
                            });
                          },
                        ),
                                  Text('${_getCommentCount(postId)} comments'),
                      ],
                    ),
                    IconButton(
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
                if (showCommentInput[postId] == true)
                  Padding(
                    padding: const EdgeInsets.only(top: 8.0),
                    child: Column(
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: TextField(
                                controller: commentControllers[postId],
                                decoration: InputDecoration(
                                  hintText: 'Add a comment...',
                                  border: OutlineInputBorder(),
                                ),
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

                              return Card(
                                elevation: 1,
                                margin: EdgeInsets.symmetric(vertical: 4, horizontal: 8),
                                child: Stack(
                                  children: [
                                    Padding(
                                      padding: EdgeInsets.all(8),
                                      child: Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                      Row(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          CircleAvatar(
                                            radius: 16,
                                            backgroundImage: commentProfilePic != null && commentProfilePic.toString().isNotEmpty
                                                ? NetworkImage(commentProfilePic)
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
                                                    Row(
                                                      children: [
                                                        Text(
                                                          user['name'] ?? 'Unknown',
                                                          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                                                        ),
                                                        SizedBox(width: 8),
                                                        Text(
                                                          _getTimeAgo(
                                                            DateTime.tryParse((comment['created_at'] ?? '').toString()) ??
                                                            DateTime.now(),
                                                          ),
                                                          style: TextStyle(fontSize: 12, color: Colors.grey),
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
                                                                    child: Text('Cancel'),
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
                                                                    child: Text('Cancel'),
                                                                  ),
                                                                  ElevatedButton(
                                                                    onPressed: () => Navigator.pop(context, true),
                                                                    child: Text('Delete'),
                                                                    style: ElevatedButton.styleFrom(
                                                                      backgroundColor: Colors.red,
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
                                                SizedBox(height: 4),
                                                Text(
                                                  comment['content'] ?? '',
                                                  style: TextStyle(fontSize: 13),
                                                ),
                                              ],
                                            ),
                                          ),
                                        ],
                                      ),
                                      Padding(
                                        padding: EdgeInsets.only(left: 40, top: 8),
                                        child: Row(
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
                                                                              TextButton(onPressed: () => Navigator.pop(context), child: Text('Cancel')),
                                                                              ElevatedButton(
                                                                                onPressed: () async {
                                                                                  final newText = controller.text.trim();
                                                                                  if (newText.isNotEmpty) {
                                                                                    Navigator.pop(context);
                                                                                    await editReply(commentId, r['id'].toString(), newText, ri);
                                                                                  }
                                                                                },
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
                                                                              TextButton(onPressed: () => Navigator.pop(context, false), child: Text('Cancel')),
                                                                              ElevatedButton(onPressed: () => Navigator.pop(context, true), child: Text('Delete')),
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
                                                            Text(r['content'] ?? '', style: TextStyle(fontSize: 12)),
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
                                                      child: TextField(
                                                        controller: replyControllers.putIfAbsent(commentId, () => TextEditingController()),
                                                        decoration: InputDecoration(hintText: 'Write a reply...', isDense: true, contentPadding: EdgeInsets.symmetric(vertical: 8, horizontal: 8)),
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
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: const Color(0xFFCB4154),
        title: Text('Community', style: TextStyle(fontWeight: FontWeight.bold)),
        actions: [
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8.0),
            child: DropdownButtonHideUnderline(
              child: DropdownButton<String>(
                value: selectedFilter,
                isDense: true,
                style: const TextStyle(color: Colors.white),
                alignment: Alignment.center,
                items: ['all', 'missing', 'found', 'my posts']
                    .map(
                      (type) => DropdownMenuItem(
                        value: type,
                        child: Text(
                          type[0].toUpperCase() + type.substring(1),
                          style: TextStyle(color: Colors.black),
                        ),
                      ),
                    )
                    .toList(),
                onChanged: (val) {
                  if (val != null) {
                    setState(() => selectedFilter = val);
                  }
                },
                icon: Icon(Icons.filter_list, color: Colors.white),
                dropdownColor: Colors.white,
                selectedItemBuilder: (context) {
                  return ['all', 'missing', 'found', 'my posts'].map((type) {
                    return Align(
                      alignment: Alignment.center,
                      child: Text(
                        type[0].toUpperCase() + type.substring(1),
                        style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                      ),
                    );
                  }).toList();
                },
              ),
            ),
          ),
          IconButton(
            icon: Icon(Icons.notifications),
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => const NotificationScreen(),
                ),
              );
            },
          ),
        ],
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
    final difference = DateTime.now().difference(dateTime);
    
    if (difference.inMinutes < 1) {
      return 'Just now';
    } else if (difference.inHours < 1) {
      return '${difference.inMinutes}m';
    } else if (difference.inDays < 1) {
      return '${difference.inHours}h';
    } else if (difference.inDays < 7) {
      return '${difference.inDays}d';
    } else {
      return '${dateTime.year}-${dateTime.month.toString().padLeft(2, '0')}-${dateTime.day.toString().padLeft(2, '0')}';
    }
  }
}

extension StringCasing on String {
  String capitalize() => isNotEmpty ? '${this[0].toUpperCase()}${substring(1)}' : '';
  String capitalizeEachWord() => split(' ').map((w) => w.capitalize()).join(' ');
}
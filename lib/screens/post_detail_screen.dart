import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

// Colors from community_screen
const deepRed = Color(0xFFB82132);
const ownerColor = Color(0xFFECA1A6);
const sitterColor = Color(0xFFF2B28C);

class PostDetailScreen extends StatefulWidget {
  final String postId;
  const PostDetailScreen({Key? key, required this.postId}) : super(key: key);

  static PostDetailScreen fromRoute(BuildContext context) {
    final args = ModalRoute.of(context)?.settings.arguments as Map?;
    final postId = args?['postId']?.toString() ?? '';
    return PostDetailScreen(postId: postId);
  }

  @override
  State<PostDetailScreen> createState() => _PostDetailScreenState();
}

class _PostDetailScreenState extends State<PostDetailScreen> {
  Map<String, dynamic>? post;
  bool isLoading = true;
  String? error;

  // Local state for comment actions
  final Map<String, TextEditingController> editCommentControllers = {};
  final Map<String, bool> commentLoading = {};
  final Map<String, bool> likedComments = {};
  final Map<String, bool> showReplyInput = {};
  final Map<String, TextEditingController> replyControllers = {};
  final TextEditingController newCommentController = TextEditingController();
  bool isPostingComment = false;

  @override
  void initState() {
    super.initState();
    _fetchPost();
  }

  Future<void> _fetchPost() async {
    setState(() {
      isLoading = true;
      error = null;
    });
    try {
      final res = await Supabase.instance.client
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
          .eq('id', widget.postId)
          .maybeSingle();
      if (res == null) {
        error = 'Post not found';
      } else {
        post = res;
      }
    } catch (e) {
      error = 'Failed to load post';
    }
    setState(() {
      isLoading = false;
    });
  }

  String _getTimeAgo(DateTime dateTime) {
    final difference = DateTime.now().difference(dateTime);
    if (difference.inMinutes < 1) {
      return 'Just now';
    } else if (difference.inHours < 1) {
      return '${difference.inMinutes}m ago';
    } else if (difference.inDays < 1) {
      return '${difference.inHours}h ago';
    } else if (difference.inDays < 7) {
      return '${difference.inDays}d ago';
    } else {
      return '${dateTime.year}-${dateTime.month.toString().padLeft(2, '0')}-${dateTime.day.toString().padLeft(2, '0')}';
    }
  }

  Future<void> _editComment(String commentId, String newContent, int idx) async {
    final original = post!['comments'][idx]['content'];
    setState(() {
      post!['comments'][idx]['content'] = newContent;
      commentLoading[commentId] = true;
    });
    try {
      await Supabase.instance.client
          .from('comments')
          .update({'content': newContent})
          .eq('id', commentId);
    } catch (e) {
      setState(() {
        post!['comments'][idx]['content'] = original;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to update comment'))
      );
    }
    setState(() {
      commentLoading[commentId] = false;
    });
  }

  Future<void> _deleteComment(String commentId, int idx) async {
    final deleted = Map<String, dynamic>.from(post!['comments'][idx]);
    setState(() {
      post!['comments'].removeAt(idx);
      commentLoading[commentId] = true;
    });
    try {
      await Supabase.instance.client
          .from('comments')
          .delete()
          .eq('id', commentId);
    } catch (e) {
      setState(() {
        post!['comments'].insert(idx, deleted);
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to delete comment'))
      );
    }
    setState(() {
      commentLoading[commentId] = false;
    });
  }

  Future<void> _likeComment(String commentId, bool isLiked, int idx) async {
    final oldLikes = post!['comments'][idx]['comment_likes'] as List? ?? [];
    final currentUserId = Supabase.instance.client.auth.currentUser?.id;
    if (currentUserId == null) return; // Ensure non-null
    setState(() {
      likedComments[commentId] = !isLiked;
      if (!isLiked) {
        post!['comments'][idx]['comment_likes'] = [...oldLikes, {'user_id': currentUserId}];
      } else {
        post!['comments'][idx]['comment_likes'] = oldLikes.where((like) => like['user_id'] != currentUserId).toList();
      }
    });
    try {
      if (!isLiked) {
        await Supabase.instance.client
            .from('comment_likes')
            .insert({'comment_id': commentId, 'user_id': currentUserId});
      } else {
        await Supabase.instance.client
            .from('comment_likes')
            .delete()
            .eq('comment_id', commentId)
            .eq('user_id', currentUserId);
      }
      final updatedComment = await Supabase.instance.client
          .from('comments')
          .select('comment_likes(*)')
          .eq('id', commentId)
          .single();
      setState(() {
        post!['comments'][idx]['comment_likes'] = updatedComment['comment_likes'];
      });
    } catch (e) {
      setState(() {
        likedComments[commentId] = isLiked;
        post!['comments'][idx]['comment_likes'] = oldLikes;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to update comment like'))
      );
    }
  }

  Future<void> _replyComment(String commentId, String content, int idx) async {
    if (content.trim().isEmpty) return;
    final currentUserId = Supabase.instance.client.auth.currentUser?.id;
    if (currentUserId == null) return; // Ensure non-null
    try {
      final newReply = await Supabase.instance.client
          .from('replies')
          .insert({
        'comment_id': commentId,
        'user_id': currentUserId,
        'content': content,
      }).select('id, content, created_at, user_id').single();

      final userData = await Supabase.instance.client
          .from('users')
          .select('name, profile_picture')
          .eq('id', currentUserId)
          .single();

      final fullReply = {
        ...Map<String, dynamic>.from(newReply),
        'users': userData,
      };

      setState(() {
        post!['comments'][idx]['replies'] = (post!['comments'][idx]['replies'] ?? [])..insert(0, fullReply);
        replyControllers[commentId]?.clear();
        showReplyInput[commentId] = false;
      });
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed to post reply')));
    }
  }

  Future<void> _addComment() async {
    final text = newCommentController.text.trim();
    if (text.isEmpty) return;
    setState(() => isPostingComment = true);
    final currentUserId = Supabase.instance.client.auth.currentUser?.id;
    if (currentUserId == null) {
      setState(() => isPostingComment = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('You must be signed in to comment.')));
      return;
    }
    try {
      final newComment = await Supabase.instance.client
          .from('comments')
          .insert({
            'post_id': widget.postId,
            'user_id': currentUserId,
            'content': text,
          })
          .select('id, content, created_at, user_id')
          .single();

      final userData = await Supabase.instance.client
          .from('users')
          .select('name, profile_picture')
          .eq('id', currentUserId)
          .single();

      final fullComment = {
        ...Map<String, dynamic>.from(newComment),
        'users': userData,
        'comment_likes': [],
        'replies': [],
      };

      setState(() {
        post!['comments'] = [fullComment, ...((post!['comments'] as List?) ?? [])];
        newCommentController.clear();
      });
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed to post comment')));
    }
    setState(() => isPostingComment = false);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Post Details')),
      body: isLoading
          ? const Center(child: CircularProgressIndicator())
          : error != null
              ? Center(child: Text(error!))
              : post == null
                  ? const Center(child: Text('No post data'))
                  : SingleChildScrollView(
                      padding: const EdgeInsets.all(16),
                      child: Card(
                        margin: EdgeInsets.zero,
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
                                    backgroundImage: post!['users']?['profile_picture'] != null &&
                                            post!['users']!['profile_picture'].toString().isNotEmpty
                                        ? NetworkImage(post!['users']!['profile_picture'])
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
                                              post!['users']?['name'] ?? 'Unknown',
                                              style: TextStyle(fontWeight: FontWeight.bold),
                                            ),
                                            SizedBox(width: 8),
                                            Text(
                                              _getTimeAgo(DateTime.tryParse(post!['created_at'] ?? '')?.toLocal() ?? DateTime.now()),
                                              style: TextStyle(fontSize: 12, color: Colors.grey),
                                            ),
                                          ],
                                        ),
                                        Container(
                                          padding: EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                          decoration: BoxDecoration(
                                            color: post!['users']?['role'] == 'Pet Owner' ? sitterColor : ownerColor,
                                            borderRadius: BorderRadius.circular(12),
                                          ),
                                          child: Text(
                                            post!['users']?['role'] ?? 'User',
                                            style: TextStyle(
                                              fontSize: 12,
                                              color: Colors.white,
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                              SizedBox(height: 10),
                              Text(post!['content'] ?? ''),
                              SizedBox(height: 10),
                              if (post!['image_url'] != null)
                                ClipRRect(
                                  borderRadius: BorderRadius.circular(8),
                                  child: Image.network(post!['image_url'], fit: BoxFit.cover),
                                ),
                              SizedBox(height: 10),
                              Row(
                                mainAxisAlignment: MainAxisAlignment.spaceAround,
                                children: [
                                  Row(
                                    children: [
                                      Icon(Icons.favorite_border, color: deepRed),
                                      SizedBox(width: 4),
                                      Text('${(post!['likes'] as List?)?.length ?? 0}'),
                                    ],
                                  ),
                                  Row(
                                    children: [
                                      Icon(Icons.comment_outlined, color: deepRed),
                                      SizedBox(width: 4),
                                      Text('${(post!['comments'] as List?)?.length ?? 0} comments'),
                                    ],
                                  ),
                                  Icon(Icons.bookmark_border, color: deepRed),
                                ],
                              ),
                              SizedBox(height: 18),
                              Text(
                                'Comments',
                                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                              ),
                              SizedBox(height: 8),
                              if ((post!['comments'] as List?)?.isEmpty ?? true)
                                Text('No comments yet.', style: TextStyle(color: Colors.grey)),
                              ...((post!['comments'] as List?) ?? []).asMap().entries.map((entry) {
                                final idx = entry.key;
                                final comment = entry.value;
                                final user = comment['users'] ?? {};
                                final commentId = comment['id'].toString();
                                final commentProfilePic = user['profile_picture'];
                                final commentLikes = comment['comment_likes'] as List? ?? [];
                                final isLiked = commentLikes.any((like) => like['user_id'] == Supabase.instance.client.auth.currentUser?.id);
                                likedComments[commentId] = isLiked;

                                return Stack(
                                  children: [
                                    Padding(
                                      padding: EdgeInsets.symmetric(vertical: 6),
                                      child: Card(
                                        elevation: 1,
                                        child: Padding(
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
                                                                  _getTimeAgo(DateTime.tryParse(comment['created_at'] ?? '') ?? DateTime.now()),
                                                                  style: TextStyle(fontSize: 12, color: Colors.grey),
                                                                ),
                                                              ],
                                                            ),
                                                            if (comment['user_id'] == Supabase.instance.client.auth.currentUser?.id)
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
                                                                                Navigator.pop(context);
                                                                                await _editComment(commentId, newContent!, idx);
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
                                                                      await _deleteComment(commentId, idx);
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
                                                        await _likeComment(commentId, isLiked, idx);
                                                      },
                                                      child: Icon(
                                                        isLiked ? Icons.favorite : Icons.favorite_border,
                                                        size: 16,
                                                        color: isLiked ? Colors.red : Colors.grey,
                                                      ),
                                                    ),
                                                    SizedBox(width: 4),
                                                    Text(
                                                      '${commentLikes.length} likes',
                                                      style: TextStyle(fontSize: 12, color: Colors.grey),
                                                    ),
                                                    SizedBox(width: 16),
                                                    TextButton(
                                                      onPressed: () {
                                                        setState(() {
                                                          showReplyInput[commentId] = !(showReplyInput[commentId] ?? false);
                                                        });
                                                      },
                                                      child: Text('Reply', style: TextStyle(color: deepRed, fontSize: 12)),
                                                    ),
                                                  ],
                                                ),
                                              ),
                                              if (showReplyInput[commentId] == true)
                                                Padding(
                                                  padding: EdgeInsets.only(left: 40, top: 6),
                                                  child: Row(
                                                    children: [
                                                      Expanded(
                                                        child: TextField(
                                                          controller: replyControllers.putIfAbsent(commentId, () => TextEditingController()),
                                                          decoration: InputDecoration(
                                                            hintText: 'Write a reply...',
                                                            isDense: true,
                                                            contentPadding: EdgeInsets.symmetric(vertical: 8, horizontal: 8),
                                                          ),
                                                        ),
                                                      ),
                                                      IconButton(
                                                        icon: Icon(Icons.send, size: 18, color: deepRed),
                                                        onPressed: () async {
                                                          final text = replyControllers[commentId]?.text.trim();
                                                          if (text != null && text.isNotEmpty) {
                                                            await _replyComment(commentId, text, idx);
                                                            FocusScope.of(context).unfocus();
                                                          }
                                                        },
                                                      ),
                                                    ],
                                                  ),
                                                ),
                                              // Display replies if present
                                              if ((comment['replies'] as List?)?.isNotEmpty ?? false)
                                                Padding(
                                                  padding: EdgeInsets.only(left: 40, top: 8),
                                                  child: Column(
                                                    children: [
                                                      ...((comment['replies'] as List?) ?? []).map((r) {
                                                        final replyProfilePic = r['users']?['profile_picture'];
                                                        return Row(
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
                                                                    children: [
                                                                      Text(r['users']?['name'] ?? 'Unknown', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                                                                      SizedBox(width: 8),
                                                                      Text(
                                                                        _getTimeAgo(DateTime.tryParse(r['created_at']) ?? DateTime.now()),
                                                                        style: TextStyle(fontSize: 10, color: Colors.grey),
                                                                      ),
                                                                    ],
                                                                  ),
                                                                  SizedBox(height: 2),
                                                                  Text(r['content'] ?? '', style: TextStyle(fontSize: 12)),
                                                                ],
                                                              ),
                                                            ),
                                                          ],
                                                        );
                                                      }).toList(),
                                                    ],
                                                  ),
                                                ),
                                            ],
                                          ),
                                        ),
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
                                );
                              }).toList(),
                              // Add new comment field
                              Padding(
                                padding: const EdgeInsets.only(top: 12.0),
                                child: Row(
                                  children: [
                                    Expanded(
                                      child: TextField(
                                        controller: newCommentController,
                                        decoration: InputDecoration(
                                          hintText: 'Add a comment...',
                                          border: OutlineInputBorder(),
                                          isDense: true,
                                          contentPadding: EdgeInsets.symmetric(vertical: 8, horizontal: 8),
                                        ),
                                      ),
                                    ),
                                    SizedBox(width: 8),
                                    isPostingComment
                                        ? SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2))
                                        : IconButton(
                                            icon: Icon(Icons.send, color: deepRed),
                                            onPressed: _addComment,
                                          ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
    );
  }
}

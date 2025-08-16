import 'dart:io';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import 'package:supabase_flutter/supabase_flutter.dart';
import 'notification_screen.dart';

Map<String, bool> likedPosts = {};
Map<String, TextEditingController> commentControllers = {};
Map<String, int> likeCounts = {};
Map<String, int> commentCounts = {};
Map<String, List<Map<String, dynamic>>> postComments = {};
Map<String, bool> likedComments = {};
Map<String, TextEditingController> editCommentControllers = {};

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

class _CommunityScreenState extends State<CommunityScreen> {
  List<dynamic> posts = [];
  bool isLoading = false;
  String selectedFilter = 'all';
  Map<String, bool> showCommentInput = {};

  @override
  void initState() {
    super.initState();
    // Reset all comment-related state when screen is initialized
    showCommentInput.clear();
    commentControllers.clear();
    postComments.clear();
    commentCounts.clear();
    fetchPosts();
  }

  @override
  void dispose() {
    // Clean up the state when the widget is disposed
    showCommentInput.clear();
    super.dispose();
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
              profile
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
                profile
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

              // Sort comments by created_at date (newest first)
              comments.sort((a, b) {
                final dateA = DateTime.parse(a['created_at'] as String);
                final dateB = DateTime.parse(b['created_at'] as String);
                return dateB.compareTo(dateA);
              });
            }
            postComments[postId] = comments;
            print('Processed ${comments.length} comments for post $postId');
          } catch (e) {
            print('Error processing comments for post $postId: $e');
            postComments[postId] = [];
          }

          // Initialize comment input state
          showCommentInput[postId] = showCommentInput[postId] ?? false;
        }
      });
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

      print('Public URL: $publicUrl');
      return publicUrl;
    } catch (e) {
      print('Upload failed: $e');
      return null;
    }
  }

  Future<void> createPost(String type, String content, File? imageFile) async {
    if (content.trim().isEmpty) return;
    try {
      String? imageUrl;
      if (imageFile != null) {
        imageUrl = await uploadImage(imageFile);
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
                          items: ['general', 'lost', 'found']
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

  Widget buildPostList(List<dynamic> postList) {
    if (postList.isEmpty) return Center(child: Text('No posts to show.'));
    return ListView.builder(
      itemCount: postList.length,
      itemBuilder: (context, index) {
        final post = postList[index];
        final postId = post['id'].toString();
        final userData = post['users'] ?? {};
        final userName = userData['name'] ?? 'Unknown';
        final userRole = userData['role'] ?? 'User';

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
                      backgroundImage: post['users']?['profile'] != null
                          ? NetworkImage(post['users']!['profile'])
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
                        width: 120, // Match IconButton size for alignment
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
                        Text('${(postComments[postId]?.length ?? 0)} comments'),
                      ],
                    ),
                    IconButton(
                      icon: Icon(Icons.bookmark_border, color: deepRed),
                      onPressed: () {},
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
                                if (commentText != null && commentText.isNotEmpty) {
                                  print('Preparing to post comment on post $postId');
                                  
                                  // Clear the input field immediately
                                  commentControllers[postId]?.clear();
                                  
                                  try {
                                    // Insert the comment - allow any user to comment on any post
                                    print('Inserting comment into database');
                                    final newComment = await Supabase.instance.client
                                      .from('comments')
                                      .insert({
                                        'post_id': postId,
                                        'user_id': widget.userId,
                                        'content': commentText,
                                      })
                                      .select('id, content, created_at, user_id')
                                      .single();
                                      
                                    print('Comment inserted: $newComment');

                                    // Get user data
                                    final userData = await Supabase.instance.client
                                      .from('users')
                                      .select('name, profile')
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
                                    });
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
                                  
                                  // Hide keyboard after comment attempt
                                  FocusScope.of(context).unfocus();
                                }
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
                              final commentLikes = comment['comment_likes'] as List? ?? [];
                              final isLiked = commentLikes.any((like) => like['user_id'] == widget.userId);
                              likedComments[commentId] = isLiked;

                              return Card(
                                elevation: 1,
                                margin: EdgeInsets.symmetric(vertical: 4, horizontal: 8),
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
                                            backgroundImage: user['profile'] != null
                                                ? NetworkImage(user['profile'])
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
                                                          _getTimeAgo(DateTime.parse(comment['created_at'])),
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
                                                                        // Store the original content for rollback
                                                                        final originalContent = comment['content'];
                                                                        
                                                                        // Optimistically update the comment
                                                                        setState(() {
                                                                          comment['content'] = newContent;
                                                                          comment['isEditing'] = true;
                                                                        });
                                                                        Navigator.pop(context);

                                                                        try {
                                                                          await Supabase.instance.client
                                                                              .from('comments')
                                                                              .update({'content': newContent})
                                                                              .eq('id', commentId);
                                                                          
                                                                          setState(() {
                                                                            comment['isEditing'] = false;
                                                                          });
                                                                        } catch (e) {
                                                                          print('Error updating comment: $e');
                                                                          // Rollback on error
                                                                          setState(() {
                                                                            comment['content'] = originalContent;
                                                                            comment['isEditing'] = false;
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
                                                              // Store comment for potential rollback
                                                              final deletedComment = {...comment};
                                                              final commentIndex = postComments[postId]!.indexOf(comment);
                                                              
                                                              // Optimistically remove the comment
                                                              setState(() {
                                                                postComments[postId]!.removeAt(commentIndex);
                                                                commentCounts[postId] = (commentCounts[postId] ?? 1) - 1;
                                                              });

                                                              try {
                                                                await Supabase.instance.client
                                                                  .from('comments')
                                                                  .delete()
                                                                  .eq('id', commentId);
                                                              } catch (e) {
                                                                print('Error deleting comment: $e');
                                                                // Rollback on error
                                                                setState(() {
                                                                  postComments[postId]!.insert(commentIndex, deletedComment);
                                                                  commentCounts[postId] = (commentCounts[postId] ?? 0) + 1;
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
                                    ],
                                  ),
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
                items: ['all', 'lost', 'found', 'my posts']
                    .map(
                      (type) => DropdownMenuItem(
                        value: type,
                        child: Text(
                          type.capitalizeEachWord(),
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
                  return ['all', 'lost', 'found', 'my posts'].map((type) {
                    return Align(
                      alignment: Alignment.center,
                      child: Text(
                        type.capitalizeEachWord(),
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
          : buildPostList(
              selectedFilter == 'my posts'
                  ? posts.where((p) => p['user_id'] == widget.userId).toList()
                  : getFilteredPosts(selectedFilter),
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
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../screens/community_screen.dart';

class SavedPostsModal extends StatefulWidget {
  final String userId;

  const SavedPostsModal({
    Key? key,
    required this.userId,
  }) : super(key: key);

  @override
  _SavedPostsModalState createState() => _SavedPostsModalState();
}

class _SavedPostsModalState extends State<SavedPostsModal> {
  static const deepRed = Color(0xFFB22222);
  List<Map<String, dynamic>> savedPosts = [];
  bool isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadSavedPosts();
  }

  Future<void> _loadSavedPosts() async {
    try {
      final response = await Supabase.instance.client
          .from('bookmarks')
          .select('''
            post_id,
            community_posts:post_id (
              id,
              content,
              image_url,
              created_at,
              profiles:user_id (
                name,
                profile_picture
              )
            )
          ''')
          .eq('user_id', widget.userId);

      setState(() {
        savedPosts = (response as List<dynamic>).map((bookmark) {
          final post = bookmark['community_posts'] as Map<String, dynamic>?;
          if (post != null) {
            return {
              'id': post['id'],
              'content': post['content'],
              'image_url': post['image_url'],
              'created_at': post['created_at'],
              'user': post['profiles'],
            };
          }
          return null;
        }).where((post) => post != null).cast<Map<String, dynamic>>().toList();
        isLoading = false;
      });
    } catch (e) {
      print('Error loading saved posts: $e');
      setState(() {
        isLoading = false;
      });
    }
  }

  Future<void> _removeFromSaved(String postId) async {
    try {
      await Supabase.instance.client
          .from('bookmarks')
          .delete()
          .eq('user_id', widget.userId)
          .eq('post_id', postId);

      setState(() {
        savedPosts.removeWhere((post) => post['id'] == postId);
      });

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Removed from saved posts'),
          backgroundColor: deepRed,
          duration: Duration(seconds: 2),
        ),
      );
    } catch (e) {
      print('Error removing bookmark: $e');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Failed to remove bookmark'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  String _formatDate(String dateString) {
    try {
      final date = DateTime.parse(dateString);
      final now = DateTime.now();
      final difference = now.difference(date);

      if (difference.inDays > 0) {
        return '${difference.inDays}d ago';
      } else if (difference.inHours > 0) {
        return '${difference.inHours}h ago';
      } else if (difference.inMinutes > 0) {
        return '${difference.inMinutes}m ago';
      } else {
        return 'Just now';
      }
    } catch (e) {
      return 'Unknown';
    }
  }

  void _navigateToPost(BuildContext context, String postId) {
    Navigator.of(context).pop(); // Close the saved posts modal first
    
    // Navigate to the community screen with the specific post ID
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => CommunityScreen(
          userId: widget.userId,
          targetPostId: postId,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Container(
        color: const Color(0xFFF6DED8), // lightBlush, matches profile screen
        height: MediaQuery.of(context).size.height * 0.8,
        child: Column(
          children: [
            Padding(
              padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8), // less vertical space
              child: Row(
                children: [
                  IconButton(
                    icon: Icon(Icons.arrow_back, color: deepRed),
                    onPressed: () => Navigator.pop(context),
                  ),
                  Expanded(
                    child: Center(
                      child: Text(
                        'Saved Posts',
                        style: TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.bold,
                          color: deepRed,
                        ),
                      ),
                    ),
                  ),
                  SizedBox(width: 48),
                ],
              ),
            ),
            Expanded(
              child: isLoading
                  ? Center(
                      child: CircularProgressIndicator(
                        color: deepRed,
                      ),
                    )
                  : savedPosts.isEmpty
                      ? Container(
                          padding: EdgeInsets.symmetric(horizontal: 16),
                          child: Container(
                            decoration: BoxDecoration(
                              border: Border.all(color: Colors.grey.shade300),
                              borderRadius: BorderRadius.zero,
                              color: Colors.white,
                            ),
                            padding: EdgeInsets.all(16),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  Icons.bookmark_border,
                                  size: 64,
                                  color: Colors.grey[400],
                                ),
                                SizedBox(height: 16),
                                Text(
                                  'No Saved Posts Yet',
                                  style: TextStyle(
                                    fontSize: 18,
                                    fontWeight: FontWeight.bold,
                                    color: Colors.grey[600],
                                  ),
                                ),
                                SizedBox(height: 8),
                                Text(
                                  'Posts you bookmark will appear here. Tap the bookmark icon on any community post to save it for later.',
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                    fontSize: 14,
                                    color: Colors.grey[600],
                                  ),
                                ),
                              ],
                            ),
                          ),
                        )
                      : ListView.builder(
                          padding: EdgeInsets.symmetric(horizontal: 16),
                          itemCount: savedPosts.length,
                          itemBuilder: (context, index) {
                            final post = savedPosts[index];
                            final user = post['user'] as Map<String, dynamic>?;
                            return GestureDetector(
                              onTap: () => _navigateToPost(context, post['id'].toString()),
                              child: Container(
                                margin: EdgeInsets.only(bottom: 10),
                                decoration: BoxDecoration(
                                  color: Colors.white,
                                  border: Border.all(color: Colors.grey.shade300),
                                  borderRadius: BorderRadius.circular(12),
                                ),
                              child: Padding(
                                padding: EdgeInsets.all(16),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      children: [
                                        CircleAvatar(
                                          radius: 20,
                                          backgroundImage: user?['profile_picture'] != null
                                              ? NetworkImage(user!['profile_picture'])
                                              : AssetImage('assets/logo.png') as ImageProvider,
                                        ),
                                        SizedBox(width: 12),
                                        Expanded(
                                          child: Column(
                                            crossAxisAlignment: CrossAxisAlignment.start,
                                            children: [
                                              Text(
                                                '${user?['name'] ?? 'Unknown'}',
                                                style: TextStyle(
                                                  fontWeight: FontWeight.bold,
                                                  fontSize: 16,
                                                ),
                                              ),
                                              Text(
                                                _formatDate(post['created_at'] ?? ''),
                                                style: TextStyle(
                                                  color: Colors.grey[600],
                                                  fontSize: 12,
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                        IconButton(
                                          icon: Icon(
                                            Icons.bookmark,
                                            color: deepRed,
                                          ),
                                          onPressed: () => _removeFromSaved(post['id']),
                                        ),
                                      ],
                                    ),
                                    SizedBox(height: 12),
                                    if (post['content'] != null && post['content'].isNotEmpty)
                                      Text(
                                        post['content'],
                                        style: TextStyle(fontSize: 14),
                                      ),
                                    if (post['image_url'] != null && post['image_url'].isNotEmpty)
                                      Padding(
                                        padding: EdgeInsets.only(top: 12),
                                        child: ClipRRect(
                                          borderRadius: BorderRadius.circular(8),
                                          child: Image.network(
                                            post['image_url'],
                                            fit: BoxFit.cover,
                                            width: double.infinity,
                                            height: 200,
                                            errorBuilder: (context, error, stackTrace) {
                                              return Container(
                                                height: 200,
                                                color: Colors.grey[300],
                                                child: Icon(
                                                  Icons.broken_image,
                                                  color: Colors.grey[600],
                                                ),
                                              );
                                            },
                                          ),
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                            ),
                            );
                          },
                        ),
            ),
          ],
        ),
      ),
    );
  }
}

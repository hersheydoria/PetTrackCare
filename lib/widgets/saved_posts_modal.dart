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
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Colors.white,
            const Color(0xFFF6DED8).withOpacity(0.3), // lightBlush
          ],
        ),
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.1),
            blurRadius: 20,
            offset: Offset(0, -5),
          ),
        ],
      ),
      child: SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Enhanced Header with modern design
            Container(
              padding: EdgeInsets.symmetric(horizontal: 20, vertical: 16),
              decoration: BoxDecoration(
                color: deepRed.withOpacity(0.05),
                borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
              ),
              child: Row(
                children: [
                  Container(
                    padding: EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: deepRed.withOpacity(0.1),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Icon(Icons.bookmark, color: deepRed, size: 20),
                  ),
                  SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      'Saved Posts',
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                        color: deepRed,
                      ),
                    ),
                  ),
                  Container(
                    decoration: BoxDecoration(
                      color: Colors.grey.withOpacity(0.1),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: IconButton(
                      icon: Icon(Icons.close, color: Colors.grey[600]),
                      onPressed: () => Navigator.pop(context),
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: isLoading
                    ? Center(
                        child: CircularProgressIndicator(
                          color: deepRed,
                        ),
                      )
                    : savedPosts.isEmpty
                        ? Container(
                            decoration: BoxDecoration(
                              color: Colors.white,
                              borderRadius: BorderRadius.circular(16),
                              border: Border.all(color: const Color(0xFFD2665A).withOpacity(0.3)), // coral
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.black.withOpacity(0.05),
                                  blurRadius: 10,
                                  offset: Offset(0, 2),
                                ),
                              ],
                            ),
                            padding: EdgeInsets.all(32),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Container(
                                  padding: EdgeInsets.all(16),
                                  decoration: BoxDecoration(
                                    color: deepRed.withOpacity(0.1),
                                    borderRadius: BorderRadius.circular(50),
                                  ),
                                  child: Icon(
                                    Icons.bookmark_border,
                                    size: 48,
                                    color: deepRed,
                                  ),
                                ),
                                SizedBox(height: 24),
                                Text(
                                  'No Saved Posts Yet',
                                  style: TextStyle(
                                    fontSize: 20,
                                    fontWeight: FontWeight.bold,
                                    color: deepRed,
                                  ),
                                ),
                                SizedBox(height: 12),
                                Text(
                                  'Posts you bookmark will appear here. Tap the bookmark icon on any community post to save it for later.',
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                    fontSize: 14,
                                    color: Colors.grey[600],
                                    height: 1.5,
                                  ),
                                ),
                              ],
                            ),
                          )
                        : ListView.builder(
                            itemCount: savedPosts.length,
                            itemBuilder: (context, index) {
                              final post = savedPosts[index];
                              final user = post['user'] as Map<String, dynamic>?;
                              return GestureDetector(
                                onTap: () => _navigateToPost(context, post['id'].toString()),
                                child: Container(
                                  margin: EdgeInsets.only(bottom: 20),
                                  decoration: BoxDecoration(
                                    color: Colors.white,
                                    borderRadius: BorderRadius.circular(16),
                                    border: Border.all(color: const Color(0xFFD2665A).withOpacity(0.3)), // coral
                                    boxShadow: [
                                      BoxShadow(
                                        color: Colors.black.withOpacity(0.05),
                                        blurRadius: 10,
                                        offset: Offset(0, 2),
                                      ),
                                    ],
                                  ),
                                  child: Padding(
                                    padding: EdgeInsets.all(20),
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Row(
                                          children: [
                                            CircleAvatar(
                                              radius: 22,
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
                                                      color: deepRed,
                                                    ),
                                                  ),
                                                  SizedBox(height: 2),
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
                                            Container(
                                              decoration: BoxDecoration(
                                                color: deepRed.withOpacity(0.1),
                                                borderRadius: BorderRadius.circular(8),
                                              ),
                                              child: IconButton(
                                                icon: Icon(
                                                  Icons.bookmark,
                                                  color: deepRed,
                                                  size: 20,
                                                ),
                                                onPressed: () => _removeFromSaved(post['id']),
                                              ),
                                            ),
                                          ],
                                        ),
                                        SizedBox(height: 16),
                                        if (post['content'] != null && post['content'].isNotEmpty)
                                          Padding(
                                            padding: EdgeInsets.only(bottom: 12),
                                            child: Text(
                                              post['content'],
                                              style: TextStyle(
                                                fontSize: 15,
                                                height: 1.4,
                                                color: Colors.grey[800],
                                              ),
                                            ),
                                          ),
                                        if (post['image_url'] != null && post['image_url'].isNotEmpty)
                                          ClipRRect(
                                            borderRadius: BorderRadius.circular(12),
                                            child: Image.network(
                                              post['image_url'],
                                              fit: BoxFit.cover,
                                              width: double.infinity,
                                              height: 200,
                                              errorBuilder: (context, error, stackTrace) {
                                                return Container(
                                                  height: 200,
                                                  decoration: BoxDecoration(
                                                    color: Colors.grey[100],
                                                    borderRadius: BorderRadius.circular(12),
                                                  ),
                                                  child: Column(
                                                    mainAxisAlignment: MainAxisAlignment.center,
                                                    children: [
                                                      Icon(
                                                        Icons.broken_image,
                                                        color: Colors.grey[400],
                                                        size: 40,
                                                      ),
                                                      SizedBox(height: 8),
                                                      Text(
                                                        'Image failed to load',
                                                        style: TextStyle(
                                                          color: Colors.grey[500],
                                                          fontSize: 12,
                                                        ),
                                                      ),
                                                    ],
                                                  ),
                                                );
                                              },
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
              ),
          ],
        ),
      ),
    );
  }
}

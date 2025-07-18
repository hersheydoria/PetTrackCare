import 'dart:io';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import 'package:supabase_flutter/supabase_flutter.dart';

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

  @override
  void initState() {
    super.initState();
    fetchPosts();
  }

  Future<void> fetchPosts() async {
    setState(() => isLoading = true);
    try {
      final response = await Supabase.instance.client
          .from('community_posts')
          .select('*, users(name, role, profile)')
          .order('created_at', ascending: false);
      setState(() {
        posts = response;
      });
    } catch (e) {
      print('Error fetching posts: $e');
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

                  if (response == null || response.isEmpty) {
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
                  children: [
                    CircleAvatar(
                      radius: 20,
                      backgroundImage: post['users']?['profile'] != null
                          ? NetworkImage(post['users']!['profile'])
                          : AssetImage('assets/logo.png') as ImageProvider,
                    ),
                    SizedBox(width: 10),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          userName,
                          style: TextStyle(fontWeight: FontWeight.bold),
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
                    Spacer(),
                      if (post['user_id'] == widget.userId)
                        PopupMenuButton<String>(
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
                        )
                      else
                        Text(
                          timeAgo,
                          style: TextStyle(fontSize: 12, color: Colors.grey),
                        ),
                  ],
                ),
                SizedBox(height: 10),
                if (post['image_url'] != null)
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: Image.network(post['image_url'], fit: BoxFit.cover),
                  ),
                SizedBox(height: 10),
                Text(post['content'] ?? ''),
                SizedBox(height: 10),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceAround,
                  children: [
                    IconButton(icon: Icon(Icons.favorite_border, color: deepRed), onPressed: () {}),
                    IconButton(icon: Icon(Icons.comment_outlined, color: deepRed), onPressed: () {}),
                    IconButton(icon: Icon(Icons.bookmark_border, color: deepRed), onPressed: () {}),
                  ],
                )
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
          IconButton(icon: Icon(Icons.notifications), onPressed: () {}),
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
}

extension StringCasing on String {
  String capitalize() => isNotEmpty ? '${this[0].toUpperCase()}${substring(1)}' : '';
  String capitalizeEachWord() => split(' ').map((w) => w.capitalize()).join(' ');
}
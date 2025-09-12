import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:image_picker/image_picker.dart';
import 'dart:io';
import '../widgets/saved_posts_modal.dart';

// Reuse owner's color palette
const deepRed = Color(0xFFB82132);
const coral = Color(0xFFD2665A);
const peach = Color(0xFFF2B28C);
const lightBlush = Color(0xFFF6DED8);

class SitterProfileScreen extends StatefulWidget {
  final bool openSavedPosts;
  
  const SitterProfileScreen({Key? key, this.openSavedPosts = false}) : super(key: key);
  
  @override
  State<SitterProfileScreen> createState() => _SitterProfileScreenState();
}

class _SitterProfileScreenState extends State<SitterProfileScreen>
    with SingleTickerProviderStateMixin {
  final user = Supabase.instance.client.auth.currentUser;
  final metadata = Supabase.instance.client.auth.currentUser?.userMetadata ?? {};
  Map<String, dynamic> userData = {}; // Store user data from public.users table

  late TabController _tabController;

  String get name => userData['name'] ?? metadata['name'] ?? 'Pet Sitter';
  String get role => metadata['role'] ?? 'Pet Sitter';
  String get email => user?.email ?? 'No email';
  String get address => metadata['address'] ?? metadata['location'] ?? 'No address provided';

  File? _profileImage;
  final ImagePicker _picker = ImagePicker();
  
  // Helper to refresh user and metadata after update
  Future<void> _refreshUserMetadata() async {
    // Load user data from public.users table (only name and profile_picture)
    try {
      final response = await Supabase.instance.client
          .from('users')
          .select('name, profile_picture')
          .eq('id', user?.id ?? '')
          .single();
      
      setState(() {
        userData = response;
      });
    } catch (e) {
      print('Error loading user data: $e');
    }
  }

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _refreshUserMetadata(); // Load user data from database
    
    // If openSavedPosts is true, switch to settings tab and open saved posts
    if (widget.openSavedPosts) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _tabController.animateTo(1); // Switch to settings tab (index 1)
        Future.delayed(Duration(milliseconds: 300), () {
          _openSavedPosts(); // Open saved posts modal
        });
      });
    }
  }

  void _logout(BuildContext context) async {
    await Supabase.instance.client.auth.signOut();
    Navigator.pushNamedAndRemoveUntil(context, '/login', (route) => false);
  }

  // Add settings dialog handlers (copied from profile_owner_screen.dart)
  void _openAccountSettings() async {
    // ...same logic as owner, but for sitter...
  }
  void _openNotificationPreferences() async {
    // ...same logic as owner...
  }
  void _openPrivacySettings() async {
    // ...same logic as owner...
  }
  void _openChangePassword() async {
    // ...same logic as owner...
  }
  void _openHelpSupport() {
    // ...same logic as owner...
  }
  void _openAbout() {
    // ...same logic as owner...
  }
  void _openSavedPosts() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        return SavedPostsModal(userId: user?.id ?? '');
      },
    );
  }

  Future<void> _pickProfileImage() async {
    final pickedFile = await _picker.pickImage(source: ImageSource.gallery);
    if (pickedFile == null) return;

    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text('Confirm Profile Picture'),
          content: Image.file(File(pickedFile.path)),
          actions: [
            TextButton(
              child: Text('Cancel', style: TextStyle(color: Colors.grey)),
              onPressed: () => Navigator.of(context).pop(false),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: deepRed),
              child: Text('Confirm'),
              onPressed: () => Navigator.of(context).pop(true),
            ),
          ],
        );
      },
    );

    if (confirm != true) return;

    final file = File(pickedFile.path);
    final fileBytes = await file.readAsBytes();
    final fileName =
        'profile_images/${user!.id}_${DateTime.now().millisecondsSinceEpoch}.jpg';

    try {
      final supabase = Supabase.instance.client;
      final bucket = supabase.storage.from('profile-pictures');

      await bucket.uploadBinary(
        fileName,
        fileBytes,
        fileOptions: const FileOptions(contentType: 'image/jpeg'),
      );

      final publicUrl = bucket.getPublicUrl(fileName);

      // Store profile_picture in public.users table, not auth.users
      await supabase
        .from('users')
        .update({'profile_picture': publicUrl})
        .eq('id', user!.id);

      setState(() {
        _profileImage = file;
        userData['profile_picture'] = publicUrl;
        metadata['profile_picture'] = publicUrl;
      });

      print('✅ Profile picture updated!');
    } catch (e) {
      print('❌ Error uploading profile image: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: lightBlush,
      appBar: AppBar(
        title: Text('Sitter Profile', style: TextStyle(fontWeight: FontWeight.bold)),
        backgroundColor: Color(0xFFCB4154),
        elevation: 0,
        actions: [
          IconButton(
            icon: Icon(Icons.more_vert),
            onPressed: () {
              showModalBottomSheet(
                context: context,
                builder: (_) => Wrap(
                  children: [
                    ListTile(
                      leading: Icon(Icons.logout, color: Colors.red),
                      title: Text('Logout', style: TextStyle(color: Colors.red)),
                      onTap: () => _logout(context),
                    ),
                  ],
                ),
              );
            },
          ),
        ],
      ),
      body: Column(
        children: [
          // Profile Info (same as owner, but for sitter)
          Container(
            margin: EdgeInsets.only(top: 16),
            child: Stack(
              alignment: Alignment.bottomRight,
              children: [
                Container(
                  padding: EdgeInsets.all(4),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(color: deepRed, width: 2),
                  ),
                  child: CircleAvatar(
                    radius: 60,
                    backgroundColor: Colors.white,
                    backgroundImage: _profileImage != null
                        ? FileImage(_profileImage!)
                        : (userData['profile_picture'] != null && userData['profile_picture'].toString().isNotEmpty
                            ? NetworkImage(userData['profile_picture'])
                            : null),
                    child: (_profileImage == null && (userData['profile_picture'] == null || userData['profile_picture'].toString().isEmpty))
                        ? Icon(Icons.person, size: 60, color: Colors.grey[400])
                        : null,
                  ),
                ),
                Positioned(
                  bottom: 4,
                  right: 4,
                  child: GestureDetector(
                    onTap: _pickProfileImage,
                    child: Container(
                      padding: EdgeInsets.all(6),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: deepRed,
                      ),
                      child: Icon(
                        Icons.camera_alt,
                        size: 20,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          SizedBox(height: 12),
          Text(
            name,
            style: TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.bold,
              color: deepRed,
            ),
          ),
          Text(
            email,
            style: TextStyle(
              fontSize: 16,
            ),
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.location_on, color: Colors.grey[600], size: 16),
              SizedBox(width: 4),
              Text(
                address,
                style: TextStyle(fontSize: 14, color: Colors.grey[700]),
              ),
            ],
          ),
          SizedBox(height: 16),

          // White rounded container with tabs and tab content
          Expanded(
            child: Container(
              margin: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.grey.shade300),
              ),
              child: Column(
                children: [
                  TabBar(
                    controller: _tabController,
                    indicatorColor: deepRed,
                    labelColor: deepRed,
                    unselectedLabelColor: Colors.grey,
                    tabs: [
                      Tab(icon: Icon(Icons.pets), text: 'Assigned Pets'),
                      Tab(icon: Icon(Icons.settings), text: 'Settings'),
                    ],
                  ),
                  Divider(height: 1, color: Colors.grey.shade300),
                  Expanded(
                    child: TabBarView(
                      controller: _tabController,
                      children: [
                        AssignedPetsTab(),
                        ListView(
                          padding: EdgeInsets.all(16),
                          children: [
                            _settingsTile(Icons.person, 'Account', onTap: _openAccountSettings),
                            _settingsTile(Icons.lock, 'Change Password', onTap: _openChangePassword),
                            _settingsTile(Icons.bookmark, 'Saved Posts', onTap: _openSavedPosts),
                            _settingsTile(Icons.notifications, 'Notification Preferences', onTap: _openNotificationPreferences),
                            _settingsTile(Icons.privacy_tip, 'Privacy Settings', onTap: _openPrivacySettings),
                            _settingsTile(Icons.help_outline, 'Help & Support', onTap: _openHelpSupport),
                            _settingsTile(Icons.info_outline, 'About', onTap: _openAbout),
                            SizedBox(height: 16),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _settingsTile(IconData icon, String title, {VoidCallback? onTap}) {
    return Container(
      margin: EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        border: Border.all(color: Colors.grey.shade300),
        borderRadius: BorderRadius.circular(12),
        color: Colors.white,
      ),
      child: ListTile(
        leading: Icon(icon, color: deepRed),
        title: Text(title),
        onTap: onTap ?? () {},
      ),
    );
  }
}

class AssignedPetsTab extends StatefulWidget {
  @override
  _AssignedPetsTabState createState() => _AssignedPetsTabState();
}

class _AssignedPetsTabState extends State<AssignedPetsTab> {
  final supabase = Supabase.instance.client;
  List<Map<String, dynamic>> assignedPets = [];
  bool isLoading = true;

  @override
  void initState() {
    super.initState();
    fetchAssignedPets();
  }

  Future<void> fetchAssignedPets() async {
    final sitterId = supabase.auth.currentUser?.id;

    if (sitterId == null) {
      setState(() {
        isLoading = false;
      });
      return;
    }

    try {
      final response = await supabase
      .from('sitting_jobs')
      .select('''
        pets (
          id, name, breed, age, owner_id,
          users!owner_id (
            name
          )
        )
      ''')
      .eq('sitter_id', sitterId)
      .or('status.eq.Accepted,status.eq.Active');

      setState(() {
        assignedPets = List<Map<String, dynamic>>.from(response);
        isLoading = false;
      });
    } catch (e) {
      print('Error fetching assigned pets: $e');
      setState(() => isLoading = false);
    }
  }

  // New: pull-to-refresh handler
  Future<void> _refreshAll() async {
    await fetchAssignedPets();
  }

  @override
  Widget build(BuildContext context) {
    if (isLoading) {
      return Center(child: CircularProgressIndicator(color: deepRed));
    }

    return RefreshIndicator(
      onRefresh: _refreshAll,
      child: assignedPets.isEmpty
          ? ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              children: const [
                SizedBox(height: 120),
                Center(child: Text('No assigned pets yet.', style: TextStyle(color: Colors.grey))),
              ],
            )
          : ListView.builder(
              physics: const AlwaysScrollableScrollPhysics(),
              itemCount: assignedPets.length,
              itemBuilder: (context, index) {
                final pet = assignedPets[index]['pets'];
                final owner = pet['users'];
                return Container(
                  margin: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    border: Border.all(color: Colors.grey.shade300),
                    borderRadius: BorderRadius.circular(12),
                    color: Colors.white,
                  ),
                  child: ListTile(
                    leading: Icon(Icons.pets, color: deepRed),
                    title: Text(pet['name'] ?? 'Unnamed'),
                    subtitle: Text(
                      'Breed: ${pet['breed'] ?? 'N/A'} | Age: ${pet['age'] ?? 'N/A'}\nOwner: ${owner?['name'] ?? 'Unknown'}',
                    ),
                  ),
                );
              },
            ),
    );
  }
}

class SitterSettingsTab extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: EdgeInsets.all(16),
      children: [
        _settingsTile(Icons.lock, 'Change Password'),
        _settingsTile(Icons.notifications, 'Notification Preferences'),
        _settingsTile(Icons.privacy_tip, 'Privacy Settings'),
        _settingsTile(Icons.help_outline, 'Help & Support'),
        _settingsTile(Icons.info_outline, 'About'),
        SizedBox(height: 16),
      ],
    );
  }

  Widget _settingsTile(IconData icon, String title) {
    return Container(
      margin: EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        border: Border.all(color: Colors.grey.shade300),
        borderRadius: BorderRadius.circular(12),
        color: Colors.white,
      ),
      child: ListTile(
        leading: Icon(icon, color: deepRed),
        title: Text(title),
        onTap: () {},
      ),
    );
  }
}

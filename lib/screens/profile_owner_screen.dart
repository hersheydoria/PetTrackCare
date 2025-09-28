import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:image_picker/image_picker.dart';
import 'package:url_launcher/url_launcher.dart';
import 'dart:io';
import 'pets_screen.dart';
import '../widgets/saved_posts_modal.dart';

// Color palette
const deepRed = Color(0xFFB82132);
const coral = Color(0xFFD2665A);
const peach = Color(0xFFF2B28C);
const lightBlush = Color(0xFFF6DED8);

class OwnerProfileScreen extends StatefulWidget {
  final bool openSavedPosts;
  
  const OwnerProfileScreen({Key? key, this.openSavedPosts = false}) : super(key: key);
  
  @override
  State<OwnerProfileScreen> createState() => _OwnerProfileScreenState();
}

class _OwnerProfileScreenState extends State<OwnerProfileScreen> with SingleTickerProviderStateMixin {
  User? user = Supabase.instance.client.auth.currentUser;
  Map<String, dynamic> metadata = Supabase.instance.client.auth.currentUser?.userMetadata ?? {};
  Map<String, dynamic> userData = {}; // Store user data from public.users table
  File? _profileImage;
  final ImagePicker _picker = ImagePicker();
  
  // Helper to refresh user and metadata after update
  Future<void> _refreshUserMetadata() async {
    final updatedUser = Supabase.instance.client.auth.currentUser;
    
    // Load user data from public.users table (name, profile_picture, and address)
    try {
      final response = await Supabase.instance.client
          .from('users')
          .select('name, profile_picture, address')
          .eq('id', updatedUser?.id ?? '')
          .single();
      
      setState(() {
        user = updatedUser;
        metadata = updatedUser?.userMetadata ?? {};
        userData = response;
      });
    } catch (e) {
      print('Error loading user data: $e');
      setState(() {
        user = updatedUser;
        metadata = updatedUser?.userMetadata ?? {};
      });
    }
  }

  late TabController _tabController;

  String get name => userData['name'] ?? metadata['name'] ?? 'Pet Owner';
  String get email => user?.email ?? 'No email';
  String get address =>
      userData['address'] ?? metadata['address'] ?? metadata['location'] ?? 'No address provided';

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    
    // Load user data from database
    _refreshUserMetadata();
    
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

 void _addPet() {
  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: lightBlush,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
    ),
    builder: (context) {
      return Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              Colors.white,
              lightBlush.withOpacity(0.2),
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
          child: Padding(
            padding: EdgeInsets.only(
              bottom: MediaQuery.of(context).viewInsets.bottom,
              top: 20,
              left: 24,
              right: 24,
            ),
            child: _AddPetForm(onPetAdded: () => setState(() {})),
          ),
        ),
      );
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
      metadata['profile_picture'] = publicUrl;
      userData['profile_picture'] = publicUrl;
    });

    print('✅ Profile picture updated!');
  } catch (e) {
    print('❌ Error uploading profile image: $e');
  }
}

Future<void> pickAndUploadImage() async {
  final ImagePicker picker = ImagePicker();
  final XFile? pickedFile = await picker.pickImage(source: ImageSource.gallery);

  if (pickedFile == null) {
    print('No image selected.');
    return;
  }

  final file = File(pickedFile.path);
  final fileBytes = await file.readAsBytes();

  final fileName = 'user_uploads/${DateTime.now().millisecondsSinceEpoch}.jpg';

  try {
    final supabase = Supabase.instance.client;

    await supabase.storage
        .from('your-bucket-name') // Replace with your actual bucket name
        .uploadBinary(fileName, fileBytes,
            fileOptions: const FileOptions(contentType: 'image/jpeg'));

    final publicUrl = supabase.storage
        .from('your-bucket-name')
        .getPublicUrl(fileName);

    print('✅ Uploaded! Image URL: $publicUrl');
  } catch (e) {
    print('❌ Upload failed: $e');
  }
}

  Future<List<Map<String, dynamic>>> _fetchPets() async {
    final ownerId = user?.id;
    if (ownerId == null) return [];
    final response = await Supabase.instance.client
        .from('pets')
        .select()
        .eq('owner_id', ownerId);
    return List<Map<String, dynamic>>.from(response);
  }

  // Enhanced pet tile with modern styling
  Widget _petListTile(Map<String, dynamic> pet) {
    return Container(
      margin: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.08),
            blurRadius: 15,
            offset: Offset(0, 3),
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: () {
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => PetProfileScreen(initialPet: pet),
              ),
            );
          },
          child: Padding(
            padding: EdgeInsets.all(16),
            child: Row(
              children: [
                Container(
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(color: coral.withOpacity(0.3), width: 2),
                  ),
                  child: CircleAvatar(
                    radius: 30,
                    backgroundColor: lightBlush,
                    backgroundImage: (pet['profile_picture'] != null &&
                            pet['profile_picture'].toString().isNotEmpty)
                        ? NetworkImage(pet['profile_picture'])
                        : null,
                    child: (pet['profile_picture'] == null ||
                            pet['profile_picture'].toString().isEmpty)
                        ? Icon(Icons.pets, color: coral, size: 30)
                        : null,
                  ),
                ),
                SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        pet['name'] ?? 'Unnamed',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                          color: deepRed,
                        ),
                      ),
                      SizedBox(height: 4),
                      Text(
                        '${pet['breed'] ?? 'Unknown'} • ${pet['age'] ?? 0} ${(pet['age'] ?? 0) == 1 ? 'year' : 'years'} old',
                        style: TextStyle(
                          fontSize: 14,
                          color: Colors.grey[600],
                        ),
                      ),
                      if (pet['gender'] != null) ...[
                        SizedBox(height: 2),
                        Container(
                          padding: EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                          decoration: BoxDecoration(
                            color: peach.withOpacity(0.2),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Text(
                            pet['gender'],
                            style: TextStyle(
                              fontSize: 12,
                              color: deepRed,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      decoration: BoxDecoration(
                        color: coral.withOpacity(0.1),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: IconButton(
                        icon: Icon(Icons.edit, color: coral, size: 20),
                        onPressed: () {
                          showModalBottomSheet(
                            context: context,
                            isScrollControlled: true,
                            backgroundColor: lightBlush,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
                            ),
                            builder: (context) {
                              return Container(
                                decoration: BoxDecoration(
                                  gradient: LinearGradient(
                                    begin: Alignment.topCenter,
                                    end: Alignment.bottomCenter,
                                    colors: [
                                      Colors.white,
                                      lightBlush.withOpacity(0.2),
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
                                  child: Padding(
                                    padding: EdgeInsets.only(
                                      bottom: MediaQuery.of(context).viewInsets.bottom,
                                      top: 20,
                                      left: 24,
                                      right: 24,
                                    ),
                                    child: _AddPetForm(
                                      onPetAdded: () => setState(() {}),
                                      initialPet: pet,
                                    ),
                                  ),
                                ),
                              );
                            },
                          );
                        },
                      ),
                    ),
                    SizedBox(width: 8),
                    Container(
                      decoration: BoxDecoration(
                        color: Colors.red.withOpacity(0.1),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: IconButton(
                        icon: Icon(Icons.delete, color: Colors.red[400], size: 20),
                        onPressed: () => _deletePet(pet['id']?.toString() ?? ''),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }  // Delete pet with confirmation dialog, refresh UI (FutureBuilder will refetch)
  Future<void> _deletePet(String petId) async {
    if (petId.isEmpty) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text("Delete pet?"),
        content: Text("This will permanently delete the pet record."),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text("Cancel")),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: deepRed),
            onPressed: () => Navigator.pop(context, true),
            child: Text("Delete"),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await Supabase.instance.client.from('pets').delete().eq('id', petId);
      // Supabase client returns list for select/delete depending on setup; we ignore details
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Pet deleted")));
      setState(() {}); // triggers rebuild -> FutureBuilder will refetch
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Failed to delete pet: $e")));
    }
  }
 
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: lightBlush,
      appBar: AppBar(
        backgroundColor: deepRed,
        elevation: 0,
        title: Text(
          'Owner Profile',
          style: TextStyle(
            fontWeight: FontWeight.bold,
            color: Colors.white,
            fontSize: 20,
            letterSpacing: 0.5,
          ),
        ),
        actions: [
          Container(
            margin: EdgeInsets.only(right: 8),
            child: IconButton(
              icon: Container(
                padding: EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.2),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: Colors.white.withOpacity(0.3),
                    width: 1,
                  ),
                ),
                child: Icon(
                  Icons.logout,
                  color: Colors.white,
                  size: 20,
                ),
              ),
              tooltip: 'Logout',
              onPressed: () async {
                final confirm = await showDialog<bool>(
                context: context,
                builder: (context) => AlertDialog(
                  title: Text('Confirm Logout'),
                  content: Text('Are you sure you want to log out?'),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(context, false),
                      child: Text('Cancel'),
                    ),
                    ElevatedButton(
                      style: ElevatedButton.styleFrom(backgroundColor: deepRed),
                      onPressed: () => Navigator.pop(context, true),
                      child: Text('Logout'),
                    ),
                  ],
                ),
              );
              if (confirm == true) {
                _logout(context);
              }
            },
          ),
          ),
        ],
      ),
      body: Container(
        margin: EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(20),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.1),
              blurRadius: 20,
              offset: Offset(0, 5),
            ),
          ],
        ),
        child: Column(
          children: [
            // Enhanced Profile Info Section with gradient design
            Container(
              margin: EdgeInsets.all(16),
              child: Card(
                elevation: 8,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                child: Container(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(20),
                    gradient: LinearGradient(
                      colors: [deepRed.withOpacity(0.8), coral],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                  ),
                  padding: EdgeInsets.all(20),
                  child: Column(
                    children: [
                      // Profile picture with camera overlay
                      Stack(
                        alignment: Alignment.bottomRight,
                        children: [
                          CircleAvatar(
                            radius: 60,
                            backgroundColor: Colors.white,
                            backgroundImage: _profileImage != null
                                ? FileImage(_profileImage!)
                                : (userData['profile_picture'] != null
                                    ? NetworkImage(userData['profile_picture'])
                                    : (metadata['profile_picture'] != null
                                        ? NetworkImage(metadata['profile_picture'])
                                        : null)),
                            child: (_profileImage == null && 
                                   userData['profile_picture'] == null && 
                                   metadata['profile_picture'] == null)
                                ? Icon(Icons.person, size: 60, color: deepRed)
                                : null,
                          ),
                          Positioned(
                            bottom: 4,
                            right: 4,
                            child: GestureDetector(
                              onTap: _pickProfileImage,
                              child: Container(
                                padding: EdgeInsets.all(8),
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: Colors.white,
                                  boxShadow: [
                                    BoxShadow(
                                      color: Colors.black.withOpacity(0.2),
                                      blurRadius: 8,
                                      offset: Offset(0, 2),
                                    ),
                                  ],
                                ),
                                child: Icon(
                                  Icons.camera_alt,
                                  size: 18,
                                  color: deepRed,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                      SizedBox(height: 16),
                      // User name centered below picture
                      Text(
                        name,
                        style: TextStyle(
                          fontSize: 26,
                          fontWeight: FontWeight.bold,
                          color: Colors.white,
                        ),
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                      ),
                      SizedBox(height: 12),
                      // Email and role in a single row
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                        children: [
                          Expanded(
                            child: _buildUserInfoCard(
                              icon: Icons.email,
                              title: 'Email',
                              value: email.length > 15 ? '${email.substring(0, 15)}...' : email,
                              color: Colors.white,
                            ),
                          ),
                          SizedBox(width: 8),
                          Expanded(
                            child: _buildUserInfoCard(
                              icon: Icons.location_on,
                              title: 'Location',
                              value: address == 'No address provided' ? 'Not set' : 
                                     (address.length > 12 ? '${address.substring(0, 12)}...' : address),
                              color: Colors.white,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),

            // Tab Section
            Container(
              decoration: BoxDecoration(
                color: lightBlush.withOpacity(0.5),
                borderRadius: BorderRadius.only(
                  topLeft: Radius.circular(20),
                  topRight: Radius.circular(20),
                ),
              ),
              child: TabBar(
                controller: _tabController,
                indicator: BoxDecoration(
                  color: deepRed,
                  borderRadius: BorderRadius.circular(12),
                ),
                indicatorSize: TabBarIndicatorSize.tab,
                indicatorPadding: EdgeInsets.all(8),
                labelColor: Colors.white,
                unselectedLabelColor: Colors.grey[600],
                labelStyle: TextStyle(fontWeight: FontWeight.w600),
                unselectedLabelStyle: TextStyle(fontWeight: FontWeight.w500),
                tabs: [
                  Tab(
                    icon: Icon(Icons.pets),
                    text: 'My Pets',
                    height: 60,
                  ),
                  Tab(
                    icon: Icon(Icons.settings),
                    text: 'Settings',
                    height: 60,
                  ),
                ],
              ),
            ),

            // Tab Content
            Expanded(
              child: TabBarView(
                controller: _tabController,
                children: [
                  // Pets Tab
                  Column(
                    children: [
                      Container(
                        width: double.infinity,
                        margin: EdgeInsets.all(16),
                        child: ElevatedButton.icon(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: deepRed,
                            padding: EdgeInsets.symmetric(vertical: 12),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                          onPressed: _addPet,
                          icon: Icon(Icons.add, color: Colors.white),
                          label: Text(
                            'Add New Pet',
                            style: TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ),
                      Expanded(
                        child: FutureBuilder<List<Map<String, dynamic>>>(
                          future: _fetchPets(),
                          builder: (context, snapshot) {
                            if (snapshot.connectionState == ConnectionState.waiting) {
                              return Center(child: CircularProgressIndicator(color: deepRed));
                            }
                            if (snapshot.hasError) {
                              return Center(child: Text('Error: ${snapshot.error}'));
                            }
                            final pets = snapshot.data ?? [];
                            if (pets.isEmpty) {
                              return Center(
                                child: Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    Icon(Icons.pets, size: 64, color: Colors.grey[400]),
                                    SizedBox(height: 16),
                                    Text(
                                      'No pets added yet.',
                                      style: TextStyle(fontSize: 18, color: Colors.grey[600]),
                                    ),
                                    SizedBox(height: 8),
                                    Text(
                                      'Tap "Add New Pet" to get started!',
                                      style: TextStyle(color: Colors.grey[500]),
                                    ),
                                  ],
                                ),
                              );
                            }
                            return ListView.builder(
                              itemCount: pets.length,
                              itemBuilder: (context, index) => _petListTile(pets[index]),
                            );
                          },
                        ),
                      ),
                    ],
                  ),
                  // Settings Tab
                  ListView(
                    padding: EdgeInsets.all(16),
                    children: [
                      _settingsTile(Icons.person, 'Account', onTap: _openAccountSettings),
                      _settingsTile(Icons.lock, 'Change Password', onTap: _openChangePassword),
                      _settingsTile(Icons.bookmark, 'Saved Posts', onTap: _openSavedPosts),
                      _notificationSettingsTile(),
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

  Widget _notificationSettingsTile() {
    final currentPrefs = metadata['notification_preferences'] ?? {'enabled': true};
    final enabled = currentPrefs['enabled'] ?? true;
    
    return Container(
      margin: EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        border: Border.all(color: Colors.grey.shade300),
        borderRadius: BorderRadius.circular(12),
        color: Colors.white,
      ),
      child: ListTile(
        leading: Icon(Icons.notifications, color: deepRed),
        title: Text('Notification Preferences'),
        subtitle: Text(enabled ? 'System notifications enabled' : 'System notifications disabled'),
        trailing: Icon(
          enabled ? Icons.notifications_active : Icons.notifications_off,
          color: enabled ? Colors.green : Colors.grey,
          size: 20,
        ),
        onTap: _openNotificationPreferences,
      ),
    );
  }

  // Open dialog for account settings
  void _openAccountSettings() async {
    String newName = name;
    String newAddress = address == 'No address provided' ? '' : address;
    bool isLoading = false;

    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: lightBlush,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setSt) {
            return Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.white,
                    lightBlush.withOpacity(0.3),
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
                            child: Icon(Icons.person, color: deepRed, size: 20),
                          ),
                          SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              'Account Settings',
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
                              onPressed: () => Navigator.pop(ctx),
                            ),
                          ),
                        ],
                      ),
                    ),
                    SingleChildScrollView(
                      padding: EdgeInsets.all(24),
                      child: Column(
                        children: [
                          // Email field with modern styling
                          Container(
                            decoration: BoxDecoration(
                              color: Colors.grey.shade50,
                              borderRadius: BorderRadius.circular(16),
                              border: Border.all(color: Colors.grey.shade200),
                            ),
                            margin: EdgeInsets.only(bottom: 20),
                            child: TextFormField(
                              enabled: false,
                              initialValue: email,
                              decoration: InputDecoration(
                                labelText: 'Email Address',
                                labelStyle: TextStyle(color: Colors.grey[600], fontWeight: FontWeight.w500),
                                border: InputBorder.none,
                                contentPadding: EdgeInsets.symmetric(horizontal: 20, vertical: 16),
                                prefixIcon: Icon(Icons.email_outlined, color: Colors.grey[500]),
                                suffixIcon: Icon(Icons.lock_outline, color: Colors.grey[400]),
                              ),
                              style: TextStyle(color: Colors.grey[600]),
                            ),
                          ),
                          // Name field with enhanced styling
                          Container(
                            decoration: BoxDecoration(
                              color: Colors.white,
                              borderRadius: BorderRadius.circular(16),
                              border: Border.all(color: coral.withOpacity(0.3)),
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.black.withOpacity(0.05),
                                  blurRadius: 10,
                                  offset: Offset(0, 2),
                                ),
                              ],
                            ),
                            margin: EdgeInsets.only(bottom: 20),
                            child: TextFormField(
                              initialValue: newName,
                              decoration: InputDecoration(
                                labelText: 'Full Name',
                                labelStyle: TextStyle(color: deepRed, fontWeight: FontWeight.w500),
                                border: InputBorder.none,
                                contentPadding: EdgeInsets.symmetric(horizontal: 20, vertical: 16),
                                prefixIcon: Icon(Icons.person_outline, color: deepRed),
                              ),
                              onChanged: (v) => setSt(() => newName = v),
                              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
                            ),
                          ),
                          // Address field with enhanced styling
                          Container(
                            decoration: BoxDecoration(
                              color: Colors.white,
                              borderRadius: BorderRadius.circular(16),
                              border: Border.all(color: coral.withOpacity(0.3)),
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.black.withOpacity(0.05),
                                  blurRadius: 10,
                                  offset: Offset(0, 2),
                                ),
                              ],
                            ),
                            margin: EdgeInsets.only(bottom: 32),
                            child: TextFormField(
                              initialValue: newAddress,
                              decoration: InputDecoration(
                                labelText: 'Address',
                                labelStyle: TextStyle(color: deepRed, fontWeight: FontWeight.w500),
                                border: InputBorder.none,
                                contentPadding: EdgeInsets.symmetric(horizontal: 20, vertical: 16),
                                prefixIcon: Icon(Icons.location_on_outlined, color: deepRed),
                              ),
                              onChanged: (v) => setSt(() => newAddress = v),
                              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
                            ),
                          ),
                          // Enhanced Save button
                          Container(
                            width: double.infinity,
                            height: 56,
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                colors: [deepRed, coral],
                                begin: Alignment.centerLeft,
                                end: Alignment.centerRight,
                              ),
                              borderRadius: BorderRadius.circular(16),
                              boxShadow: [
                                BoxShadow(
                                  color: deepRed.withOpacity(0.3),
                                  blurRadius: 15,
                                  offset: Offset(0, 5),
                                ),
                              ],
                            ),
                            child: ElevatedButton(
                              style: ElevatedButton.styleFrom(
                                backgroundColor: Colors.transparent,
                                shadowColor: Colors.transparent,
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(16),
                                ),
                              ),
                              onPressed: () async {
                                setSt(() => isLoading = true);
                                try {
                                  final supabase = Supabase.instance.client;
                                  
                                  // Update public.users table (name and address)
                                  await supabase
                                      .from('users')
                                      .update({
                                        'name': newName,
                                        'address': newAddress,
                                      })
                                      .eq('id', user!.id);
                                  
                                  // Update auth metadata (name and address for backward compatibility)
                                  await supabase.auth.updateUser(UserAttributes(data: {
                                    'name': newName,
                                    'address': newAddress,
                                  }));
                                  
                                  await _refreshUserMetadata();
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(
                                      content: Row(
                                        children: [
                                          Icon(Icons.check_circle, color: Colors.white),
                                          SizedBox(width: 8),
                                          Text('Account updated successfully'),
                                        ],
                                      ),
                                      backgroundColor: Colors.green,
                                      behavior: SnackBarBehavior.floating,
                                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                                    ),
                                  );
                                  Navigator.pop(ctx);
                                } catch (e) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(
                                      content: Row(
                                        children: [
                                          Icon(Icons.error, color: Colors.white),
                                          SizedBox(width: 8),
                                          Expanded(child: Text('Failed to update account: ${e.toString()}')),
                                        ],
                                      ),
                                      backgroundColor: Colors.red,
                                      behavior: SnackBarBehavior.floating,
                                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                                    ),
                                  );
                                }
                                setSt(() => isLoading = false);
                              },
                              child: isLoading
                                  ? SizedBox(
                                      width: 24,
                                      height: 24,
                                      child: CircularProgressIndicator(
                                        color: Colors.white,
                                        strokeWidth: 2.5,
                                      ),
                                    )
                                  : Row(
                                      mainAxisAlignment: MainAxisAlignment.center,
                                      children: [
                                        Icon(Icons.save, color: Colors.white),
                                        SizedBox(width: 8),
                                        Text(
                                          'Save Changes',
                                          style: TextStyle(
                                            fontSize: 16,
                                            fontWeight: FontWeight.bold,
                                            color: Colors.white,
                                          ),
                                        ),
                                      ],
                                    ),
                            ),
                          ),
                          SizedBox(height: 20),
                          // Enhanced Delete button
                          Container(
                            width: double.infinity,
                            height: 50,
                            child: OutlinedButton(
                              style: OutlinedButton.styleFrom(
                                side: BorderSide(color: Colors.red.shade300, width: 1.5),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(16),
                                ),
                              ),
                              onPressed: () async {
                                final confirm = await showDialog<bool>(
                                  context: context,
                                  builder: (context) => AlertDialog(
                                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                                    title: Row(
                                      children: [
                                        Icon(Icons.warning, color: Colors.red),
                                        SizedBox(width: 8),
                                        Text('Delete Account', style: TextStyle(color: Colors.red)),
                                      ],
                                    ),
                                    content: Text('Are you sure you want to delete your account? This action cannot be undone.'),
                                    actions: [
                                      TextButton(
                                        onPressed: () => Navigator.pop(context, false),
                                        child: Text('Cancel', style: TextStyle(color: Colors.grey)),
                                      ),
                                      ElevatedButton(
                                        style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
                                        onPressed: () => Navigator.pop(context, true),
                                        child: Text('Delete'),
                                      ),
                                    ],
                                  ),
                                );
                                
                                if (confirm == true) {
                                  try {
                                    await Supabase.instance.client.auth.signOut();
                                    await Supabase.instance.client.from('users').delete().eq('id', user!.id);
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      SnackBar(
                                        content: Text('Account deleted successfully'),
                                        backgroundColor: Colors.red,
                                      ),
                                    );
                                    Navigator.pushNamedAndRemoveUntil(context, '/login', (r) => false);
                                  } catch (e) {
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      SnackBar(content: Text('Error deleting account: $e')),
                                    );
                                  }
                                }
                              },
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Icon(Icons.delete_outline, color: Colors.red),
                                  SizedBox(width: 8),
                                  Text(
                                    'Delete Account',
                                    style: TextStyle(
                                      color: Colors.red,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                          SizedBox(height: 20),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  // Open dialog for notification preferences
  void _openNotificationPreferences() async {
    final currentPrefs = metadata['notification_preferences'] ?? {'enabled': true};

    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: lightBlush,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) {
        bool enabled = currentPrefs['enabled'] ?? true;
        bool isLoading = false;
        return StatefulBuilder(
          builder: (ctx, setSt) {
            return Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.white,
                    lightBlush.withOpacity(0.2),
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
                    // Enhanced Header
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
                            child: Icon(Icons.notifications, color: deepRed, size: 20),
                          ),
                          SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              'Notification Settings',
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
                              onPressed: () => Navigator.pop(ctx),
                            ),
                          ),
                        ],
                      ),
                    ),
                    SingleChildScrollView(
                      padding: EdgeInsets.all(24),
                      child: Column(
                        children: [
                          // Modern notification toggle card
                          Container(
                            decoration: BoxDecoration(
                              color: Colors.white,
                              borderRadius: BorderRadius.circular(16),
                              border: Border.all(color: coral.withOpacity(0.3)),
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.black.withOpacity(0.05),
                                  blurRadius: 10,
                                  offset: Offset(0, 2),
                                ),
                              ],
                            ),
                            margin: EdgeInsets.only(bottom: 24),
                            child: Padding(
                              padding: EdgeInsets.all(20),
                              child: Row(
                                children: [
                                  Container(
                                    padding: EdgeInsets.all(12),
                                    decoration: BoxDecoration(
                                      color: enabled ? deepRed.withOpacity(0.1) : Colors.grey.withOpacity(0.1),
                                      borderRadius: BorderRadius.circular(12),
                                    ),
                                    child: Icon(
                                      enabled ? Icons.notifications_active : Icons.notifications_off,
                                      color: enabled ? deepRed : Colors.grey,
                                      size: 24,
                                    ),
                                  ),
                                  SizedBox(width: 16),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          'Push Notifications',
                                          style: TextStyle(
                                            fontSize: 16,
                                            fontWeight: FontWeight.bold,
                                            color: Colors.black87,
                                          ),
                                        ),
                                        SizedBox(height: 4),
                                        Text(
                                          'Receive notifications when the app is closed',
                                          style: TextStyle(
                                            fontSize: 14,
                                            color: Colors.grey[600],
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  SizedBox(width: 12),
                                  Transform.scale(
                                    scale: 1.2,
                                    child: Switch(
                                      value: enabled,
                                      onChanged: (v) => setSt(() => enabled = v),
                                      activeColor: deepRed,
                                      activeTrackColor: deepRed.withOpacity(0.3),
                                      inactiveThumbColor: Colors.grey,
                                      inactiveTrackColor: Colors.grey.withOpacity(0.3),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                          // Notification types preview
                          Container(
                            padding: EdgeInsets.all(20),
                            decoration: BoxDecoration(
                              color: lightBlush.withOpacity(0.5),
                              borderRadius: BorderRadius.circular(16),
                              border: Border.all(color: coral.withOpacity(0.2)),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Icon(Icons.info_outline, color: coral, size: 20),
                                    SizedBox(width: 8),
                                    Text(
                                      'Notification Types',
                                      style: TextStyle(
                                        fontSize: 16,
                                        fontWeight: FontWeight.bold,
                                        color: deepRed,
                                      ),
                                    ),
                                  ],
                                ),
                                SizedBox(height: 12),
                                _notificationTypeItem('Pet care reminders', Icons.pets),
                                _notificationTypeItem('Chat messages', Icons.message),
                                _notificationTypeItem('Pet health alerts', Icons.health_and_safety),
                                _notificationTypeItem('Appointment updates', Icons.calendar_today),
                              ],
                            ),
                          ),
                          SizedBox(height: 32),
                          // Enhanced Save button
                          Container(
                            width: double.infinity,
                            height: 56,
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                colors: [deepRed, coral],
                                begin: Alignment.centerLeft,
                                end: Alignment.centerRight,
                              ),
                              borderRadius: BorderRadius.circular(16),
                              boxShadow: [
                                BoxShadow(
                                  color: deepRed.withOpacity(0.3),
                                  blurRadius: 15,
                                  offset: Offset(0, 5),
                                ),
                              ],
                            ),
                            child: ElevatedButton(
                              style: ElevatedButton.styleFrom(
                                backgroundColor: Colors.transparent,
                                shadowColor: Colors.transparent,
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(16),
                                ),
                              ),
                              onPressed: () async {
                                setSt(() => isLoading = true);
                                try {
                                  await Supabase.instance.client.auth.updateUser(
                                    UserAttributes(data: {
                                      'notification_preferences': {'enabled': enabled}
                                    })
                                  );
                                  // Refresh user metadata to ensure changes take effect
                                  await _refreshUserMetadata();
                                  Navigator.pop(ctx);
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(
                                      content: Row(
                                        children: [
                                          Icon(Icons.check_circle, color: Colors.white),
                                          SizedBox(width: 8),
                                          Text('Notification preferences updated'),
                                        ],
                                      ),
                                      backgroundColor: Colors.green,
                                      behavior: SnackBarBehavior.floating,
                                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                                    ),
                                  );
                                } catch (e) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(
                                      content: Row(
                                        children: [
                                          Icon(Icons.error, color: Colors.white),
                                          SizedBox(width: 8),
                                          Expanded(child: Text('Failed to update preferences: ${e.toString()}')),
                                        ],
                                      ),
                                      backgroundColor: Colors.red,
                                      behavior: SnackBarBehavior.floating,
                                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                                    ),
                                  );
                                }
                                setSt(() => isLoading = false);
                              },
                              child: isLoading
                                  ? SizedBox(
                                      width: 24,
                                      height: 24,
                                      child: CircularProgressIndicator(
                                        color: Colors.white,
                                        strokeWidth: 2.5,
                                      ),
                                    )
                                  : Row(
                                      mainAxisAlignment: MainAxisAlignment.center,
                                      children: [
                                        Icon(Icons.save, color: Colors.white),
                                        SizedBox(width: 8),
                                        Text(
                                          'Save Preferences',
                                          style: TextStyle(
                                            fontSize: 16,
                                            fontWeight: FontWeight.bold,
                                            color: Colors.white,
                                          ),
                                        ),
                                      ],
                                    ),
                            ),
                          ),
                          SizedBox(height: 20),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  Widget _notificationTypeItem(String title, IconData icon) {
    return Padding(
      padding: EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Icon(icon, color: coral, size: 16),
          SizedBox(width: 8),
          Text(
            title,
            style: TextStyle(
              fontSize: 14,
              color: Colors.grey[700],
            ),
          ),
        ],
      ),
    );
  }

  // Open dialog for change password
  void _openChangePassword() async {
    final _currentPasswordController = TextEditingController();
    final _newPasswordController = TextEditingController();
    final _confirmPasswordController = TextEditingController();
    bool _showCurrentPassword = false;
    bool _showNewPassword = false;
    bool _showConfirmPassword = false;
    bool _isLoading = false;

    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: lightBlush,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setSt) {
            bool _hasValidLength = _newPasswordController.text.length >= 8;
            bool _hasUppercase = RegExp(r'[A-Z]').hasMatch(_newPasswordController.text);
            bool _hasLowercase = RegExp(r'[a-z]').hasMatch(_newPasswordController.text);
            bool _hasNumber = RegExp(r'[0-9]').hasMatch(_newPasswordController.text);
            bool _hasSpecialChar = RegExp(r'[!@#\$&*~_.,%^()\-\+=]').hasMatch(_newPasswordController.text);
            bool _passwordsMatch = _newPasswordController.text == _confirmPasswordController.text && _newPasswordController.text.isNotEmpty;

            return Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.white,
                    lightBlush.withOpacity(0.2),
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
                    // Enhanced Header
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
                            child: Icon(Icons.lock, color: deepRed, size: 20),
                          ),
                          SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              'Change Password',
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
                              onPressed: () => Navigator.pop(ctx),
                            ),
                          ),
                        ],
                      ),
                    ),
                    Flexible(
                      child: SingleChildScrollView(
                        padding: EdgeInsets.all(24),
                        child: Column(
                          children: [
                            // Current Password field
                            Container(
                              decoration: BoxDecoration(
                                color: Colors.white,
                                borderRadius: BorderRadius.circular(16),
                                border: Border.all(color: coral.withOpacity(0.3)),
                                boxShadow: [
                                  BoxShadow(
                                    color: Colors.black.withOpacity(0.05),
                                    blurRadius: 10,
                                    offset: Offset(0, 2),
                                  ),
                                ],
                              ),
                              margin: EdgeInsets.only(bottom: 20),
                              child: TextFormField(
                                controller: _currentPasswordController,
                                obscureText: !_showCurrentPassword,
                                decoration: InputDecoration(
                                  labelText: 'Current Password',
                                  labelStyle: TextStyle(color: deepRed, fontWeight: FontWeight.w500),
                                  border: InputBorder.none,
                                  contentPadding: EdgeInsets.symmetric(horizontal: 20, vertical: 16),
                                  prefixIcon: Icon(Icons.lock_outline, color: deepRed),
                                  suffixIcon: IconButton(
                                    icon: Icon(
                                      _showCurrentPassword ? Icons.visibility_off : Icons.visibility,
                                      color: Colors.grey[600],
                                    ),
                                    onPressed: () => setSt(() => _showCurrentPassword = !_showCurrentPassword),
                                  ),
                                ),
                                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
                              ),
                            ),
                            // New Password field
                            Container(
                              decoration: BoxDecoration(
                                color: Colors.white,
                                borderRadius: BorderRadius.circular(16),
                                border: Border.all(color: coral.withOpacity(0.3)),
                                boxShadow: [
                                  BoxShadow(
                                    color: Colors.black.withOpacity(0.05),
                                    blurRadius: 10,
                                    offset: Offset(0, 2),
                                  ),
                                ],
                              ),
                              margin: EdgeInsets.only(bottom: 20),
                              child: TextFormField(
                                controller: _newPasswordController,
                                obscureText: !_showNewPassword,
                                onChanged: (value) => setSt(() {}),
                                decoration: InputDecoration(
                                  labelText: 'New Password',
                                  labelStyle: TextStyle(color: deepRed, fontWeight: FontWeight.w500),
                                  border: InputBorder.none,
                                  contentPadding: EdgeInsets.symmetric(horizontal: 20, vertical: 16),
                                  prefixIcon: Icon(Icons.lock_reset, color: deepRed),
                                  suffixIcon: IconButton(
                                    icon: Icon(
                                      _showNewPassword ? Icons.visibility_off : Icons.visibility,
                                      color: Colors.grey[600],
                                    ),
                                    onPressed: () => setSt(() => _showNewPassword = !_showNewPassword),
                                  ),
                                ),
                                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
                              ),
                            ),
                            // Confirm Password field
                            Container(
                              decoration: BoxDecoration(
                                color: Colors.white,
                                borderRadius: BorderRadius.circular(16),
                                border: Border.all(
                                  color: _newPasswordController.text.isNotEmpty
                                      ? (_passwordsMatch ? Colors.green.withOpacity(0.5) : Colors.red.withOpacity(0.5))
                                      : coral.withOpacity(0.3),
                                ),
                                boxShadow: [
                                  BoxShadow(
                                    color: Colors.black.withOpacity(0.05),
                                    blurRadius: 10,
                                    offset: Offset(0, 2),
                                  ),
                                ],
                              ),
                              margin: EdgeInsets.only(bottom: 20),
                              child: TextFormField(
                                controller: _confirmPasswordController,
                                obscureText: !_showConfirmPassword,
                                onChanged: (value) => setSt(() {}),
                                decoration: InputDecoration(
                                  labelText: 'Confirm New Password',
                                  labelStyle: TextStyle(color: deepRed, fontWeight: FontWeight.w500),
                                  border: InputBorder.none,
                                  contentPadding: EdgeInsets.symmetric(horizontal: 20, vertical: 16),
                                  prefixIcon: Icon(Icons.check_circle_outline, color: deepRed),
                                  suffixIcon: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      if (_newPasswordController.text.isNotEmpty && _confirmPasswordController.text.isNotEmpty)
                                        Icon(
                                          _passwordsMatch ? Icons.check_circle : Icons.error,
                                          color: _passwordsMatch ? Colors.green : Colors.red,
                                          size: 20,
                                        ),
                                      IconButton(
                                        icon: Icon(
                                          _showConfirmPassword ? Icons.visibility_off : Icons.visibility,
                                          color: Colors.grey[600],
                                        ),
                                        onPressed: () => setSt(() => _showConfirmPassword = !_showConfirmPassword),
                                      ),
                                    ],
                                  ),
                                ),
                                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
                              ),
                            ),
                            // Password Requirements with visual indicators
                            Container(
                              padding: EdgeInsets.all(20),
                              decoration: BoxDecoration(
                                color: lightBlush.withOpacity(0.5),
                                borderRadius: BorderRadius.circular(16),
                                border: Border.all(color: coral.withOpacity(0.2)),
                              ),
                              margin: EdgeInsets.only(bottom: 32),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      Icon(Icons.security, color: coral, size: 20),
                                      SizedBox(width: 8),
                                      Text(
                                        'Password Requirements',
                                        style: TextStyle(
                                          fontSize: 16,
                                          fontWeight: FontWeight.bold,
                                          color: deepRed,
                                        ),
                                      ),
                                    ],
                                  ),
                                  SizedBox(height: 12),
                                  _passwordRequirement('At least 8 characters', _hasValidLength),
                                  _passwordRequirement('One uppercase letter', _hasUppercase),
                                  _passwordRequirement('One lowercase letter', _hasLowercase),
                                  _passwordRequirement('One number', _hasNumber),
                                  _passwordRequirement('One special character', _hasSpecialChar),
                                  if (_newPasswordController.text.isNotEmpty && _confirmPasswordController.text.isNotEmpty)
                                    _passwordRequirement('Passwords match', _passwordsMatch),
                                ],
                              ),
                            ),
                            // Enhanced Update button
                            Container(
                              width: double.infinity,
                              height: 56,
                              decoration: BoxDecoration(
                                gradient: LinearGradient(
                                  colors: [deepRed, coral],
                                  begin: Alignment.centerLeft,
                                  end: Alignment.centerRight,
                                ),
                                borderRadius: BorderRadius.circular(16),
                                boxShadow: [
                                  BoxShadow(
                                    color: deepRed.withOpacity(0.3),
                                    blurRadius: 15,
                                    offset: Offset(0, 5),
                                  ),
                                ],
                              ),
                              child: ElevatedButton(
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: Colors.transparent,
                                  shadowColor: Colors.transparent,
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(16),
                                  ),
                                ),
                                onPressed: _isLoading ? null : () async {
                                  if (_newPasswordController.text.isEmpty ||
                                      _currentPasswordController.text.isEmpty ||
                                      _confirmPasswordController.text.isEmpty) {
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      SnackBar(
                                        content: Row(
                                          children: [
                                            Icon(Icons.warning, color: Colors.white),
                                            SizedBox(width: 8),
                                            Text('Please fill in all fields'),
                                          ],
                                        ),
                                        backgroundColor: Colors.orange,
                                        behavior: SnackBarBehavior.floating,
                                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                                      ),
                                    );
                                    return;
                                  }

                                  if (!_passwordsMatch) {
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      SnackBar(
                                        content: Row(
                                          children: [
                                            Icon(Icons.error, color: Colors.white),
                                            SizedBox(width: 8),
                                            Text('New passwords do not match'),
                                          ],
                                        ),
                                        backgroundColor: Colors.red,
                                        behavior: SnackBarBehavior.floating,
                                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                                      ),
                                    );
                                    return;
                                  }

                                  if (!(_hasValidLength && _hasUppercase && _hasLowercase && _hasNumber && _hasSpecialChar)) {
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      SnackBar(
                                        content: Row(
                                          children: [
                                            Icon(Icons.error, color: Colors.white),
                                            SizedBox(width: 8),
                                            Text('Password does not meet requirements'),
                                          ],
                                        ),
                                        backgroundColor: Colors.red,
                                        behavior: SnackBarBehavior.floating,
                                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                                      ),
                                    );
                                    return;
                                  }

                                  setSt(() => _isLoading = true);
                                  try {
                                    await Supabase.instance.client.auth.updateUser(
                                      UserAttributes(password: _newPasswordController.text.trim()),
                                    );
                                    Navigator.pop(ctx);
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      SnackBar(
                                        content: Row(
                                          children: [
                                            Icon(Icons.check_circle, color: Colors.white),
                                            SizedBox(width: 8),
                                            Text('Password updated successfully'),
                                          ],
                                        ),
                                        backgroundColor: Colors.green,
                                        behavior: SnackBarBehavior.floating,
                                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                                      ),
                                    );
                                  } catch (e) {
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      SnackBar(
                                        content: Row(
                                          children: [
                                            Icon(Icons.error, color: Colors.white),
                                            SizedBox(width: 8),
                                            Expanded(child: Text('Failed to update password: ${e.toString()}')),
                                          ],
                                        ),
                                        backgroundColor: Colors.red,
                                        behavior: SnackBarBehavior.floating,
                                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                                      ),
                                    );
                                  }
                                  setSt(() => _isLoading = false);
                                },
                                child: _isLoading
                                    ? SizedBox(
                                        width: 24,
                                        height: 24,
                                        child: CircularProgressIndicator(
                                          color: Colors.white,
                                          strokeWidth: 2.5,
                                        ),
                                      )
                                    : Row(
                                        mainAxisAlignment: MainAxisAlignment.center,
                                        children: [
                                          Icon(Icons.lock_reset, color: Colors.white),
                                          SizedBox(width: 8),
                                          Text(
                                            'Update Password',
                                            style: TextStyle(
                                              fontSize: 16,
                                              fontWeight: FontWeight.bold,
                                              color: Colors.white,
                                            ),
                                          ),
                                        ],
                                      ),
                              ),
                            ),
                            SizedBox(height: 20),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  Widget _passwordRequirement(String text, bool isValid) {
    return Padding(
      padding: EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Icon(
            isValid ? Icons.check_circle : Icons.radio_button_unchecked,
            color: isValid ? Colors.green : Colors.grey,
            size: 16,
          ),
          SizedBox(width: 8),
          Text(
            text,
            style: TextStyle(
              fontSize: 14,
              color: isValid ? Colors.green : Colors.grey[700],
              fontWeight: isValid ? FontWeight.w500 : FontWeight.normal,
            ),
          ),
        ],
      ),
    );
  }

  // Open dialog for theme settings
  // Helper methods for Help & Support functionality
  void _launchEmail(String email) async {
    final Uri emailUri = Uri(
      scheme: 'mailto',
      path: email,
      query: 'subject=PetTrackCare Support Request',
    );
    try {
      if (await canLaunchUrl(emailUri)) {
        await launchUrl(emailUri);
      } else {
        // Fallback: show email address to copy
        _showEmailFallback(email);
      }
    } catch (e) {
      _showEmailFallback(email);
    }
  }

  void _showEmailFallback(String email) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Email Support'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Could not open email app. Please contact us at:'),
            SizedBox(height: 8),
            SelectableText(
              email,
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            SizedBox(height: 8),
            Text('Subject: PetTrackCare Support Request'),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text('Close'),
          ),
        ],
      ),
    );
  }

  void _launchPhone(String phone) async {
    final Uri phoneUri = Uri(scheme: 'tel', path: phone);
    if (await canLaunchUrl(phoneUri)) {
      await launchUrl(phoneUri);
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not open phone app')),
      );
    }
  }

  void _showFAQs() {
    showDialog(
      context: context,
      builder: (context) => Dialog(
        backgroundColor: lightBlush,
        child: Container(
          constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.8),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Colors.white,
                lightBlush.withOpacity(0.2),
              ],
            ),
            borderRadius: BorderRadius.circular(24),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.2),
                blurRadius: 20,
                offset: Offset(0, 10),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Enhanced Header
              Container(
                padding: EdgeInsets.all(20),
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
                      child: Icon(Icons.quiz, color: deepRed, size: 20),
                    ),
                    SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        'Frequently Asked Questions',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                          color: deepRed,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              // Enhanced Content
              Flexible(
                child: SingleChildScrollView(
                  padding: EdgeInsets.all(24),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _faqItem(
                        'How do I add a new pet?',
                        'Go to the "Owned Pets" tab and tap the "Add Pet" button.',
                        Icons.pets,
                      ),
                      _faqItem(
                        'How do I find a pet sitter?',
                        'Browse the pet sitter profiles in the main app and send a request.',
                        Icons.person_search,
                      ),
                      _faqItem(
                        'How do I update my profile?',
                        'Go to Settings > Account to update your information.',
                        Icons.edit,
                      ),
                      _faqItem(
                        'How do I report a missing pet?',
                        'Use the "Report Missing" feature in your pet\'s profile.',
                        Icons.report_problem,
                      ),
                      _faqItem(
                        'How do I contact support?',
                        'Use the Help & Support section to email or call our team.',
                        Icons.support_agent,
                      ),
                    ],
                  ),
                ),
              ),
              // Enhanced Action Button
              Container(
                padding: EdgeInsets.all(20),
                child: SizedBox(
                  width: double.infinity,
                  height: 48,
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: deepRed,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      elevation: 2,
                    ),
                    onPressed: () => Navigator.pop(context),
                    child: Text(
                      'Close',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _faqItem(String question, String answer, IconData icon) {
    return Container(
      margin: EdgeInsets.only(bottom: 16),
      padding: EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: coral.withOpacity(0.2)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.05),
            blurRadius: 8,
            offset: Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: coral.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(icon, color: coral, size: 16),
              ),
              SizedBox(width: 10),
              Expanded(
                child: Text(
                  question,
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    color: deepRed,
                    fontSize: 14,
                  ),
                ),
              ),
            ],
          ),
          SizedBox(height: 8),
          Padding(
            padding: EdgeInsets.only(left: 32),
            child: Text(
              answer,
              style: TextStyle(
                color: Colors.grey[700],
                fontSize: 13,
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _reportIssue() async {
    TextEditingController issueController = TextEditingController();
    bool isLoading = false;
    
    await showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => Dialog(
          backgroundColor: lightBlush,
          child: Container(
            constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.7),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.grey.shade100,
                  lightBlush.withOpacity(0.5),
                ],
              ),
              borderRadius: BorderRadius.circular(24),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.2),
                  blurRadius: 20,
                  offset: Offset(0, 10),
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Enhanced Header
                Container(
                  padding: EdgeInsets.all(20),
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
                        child: Icon(Icons.bug_report, color: deepRed, size: 20),
                      ),
                      SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          'Report an Issue',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                            color: deepRed,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                // Enhanced Content
                Flexible(
                  child: Padding(
                    padding: EdgeInsets.all(24),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Help us improve PetTrackCare by describing the issue you\'re experiencing:',
                          style: TextStyle(
                            fontSize: 14,
                            color: Colors.grey[700],
                            height: 1.4,
                          ),
                        ),
                        SizedBox(height: 16),
                        Container(
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(color: coral.withOpacity(0.3)),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withOpacity(0.05),
                                blurRadius: 10,
                                offset: Offset(0, 2),
                              ),
                            ],
                          ),
                          child: TextField(
                            controller: issueController,
                            style: TextStyle(
                              color: Colors.black,
                              fontSize: 14,
                            ),
                            decoration: InputDecoration(
                              hintText: 'Describe the issue you\'re experiencing...\n\nPlease include:\n• What you were trying to do\n• What went wrong\n• When it happened',
                              hintStyle: TextStyle(
                                color: Colors.grey[500],
                                fontSize: 13,
                                height: 1.4,
                              ),
                              border: InputBorder.none,
                              contentPadding: EdgeInsets.all(20),
                              prefixIcon: Padding(
                                padding: EdgeInsets.all(16),
                                child: Icon(Icons.edit, color: coral, size: 20),
                              ),
                            ),
                            maxLines: 6,
                            minLines: 6,
                          ),
                        ),
                        SizedBox(height: 20),
                        // Info section
                        Container(
                          padding: EdgeInsets.all(16),
                          decoration: BoxDecoration(
                            color: lightBlush.withOpacity(0.5),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: coral.withOpacity(0.2)),
                          ),
                          child: Row(
                            children: [
                              Icon(Icons.info_outline, color: coral, size: 16),
                              SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  'Your feedback helps us make the app better for all pet owners.',
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: Colors.grey[700],
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                // Enhanced Action Buttons
                Container(
                  padding: EdgeInsets.all(20),
                  child: Row(
                    children: [
                      Expanded(
                        child: TextButton(
                          style: TextButton.styleFrom(
                            padding: EdgeInsets.symmetric(vertical: 12),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                              side: BorderSide(color: Colors.grey.shade300),
                            ),
                          ),
                          onPressed: () => Navigator.pop(context),
                          child: Text(
                            'Cancel',
                            style: TextStyle(
                              color: Colors.grey[600],
                              fontSize: 14,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                      ),
                      SizedBox(width: 12),
                      Expanded(
                        flex: 2,
                        child: ElevatedButton(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: deepRed,
                            padding: EdgeInsets.symmetric(vertical: 12),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                            elevation: 2,
                          ),
                          onPressed: isLoading ? null : () async {
                            final text = issueController.text.trim();
                            if (text.isEmpty) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Row(
                                    children: [
                                      Icon(Icons.warning, color: Colors.white),
                                      SizedBox(width: 8),
                                      Text('Please describe the issue.'),
                                    ],
                                  ),
                                  backgroundColor: Colors.orange,
                                  behavior: SnackBarBehavior.floating,
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                                ),
                              );
                              return;
                            }
                            setState(() => isLoading = true);
                            try {
                              await Supabase.instance.client
                                  .from('feedback')
                                  .insert({
                                'user_id': user?.id,
                                'message': text,
                                'created_at': DateTime.now().toIso8601String(),
                              });
                              Navigator.pop(context);
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Row(
                                    children: [
                                      Icon(Icons.check_circle, color: Colors.white),
                                      SizedBox(width: 8),
                                      Text('Issue reported successfully!'),
                                    ],
                                  ),
                                  backgroundColor: Colors.green,
                                  behavior: SnackBarBehavior.floating,
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                                ),
                              );
                            } catch (e) {
                              setState(() => isLoading = false);
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Row(
                                    children: [
                                      Icon(Icons.error, color: Colors.white),
                                      SizedBox(width: 8),
                                      Expanded(child: Text('Failed to report issue. Please try again.')),
                                    ],
                                  ),
                                  backgroundColor: Colors.red,
                                  behavior: SnackBarBehavior.floating,
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                                ),
                              );
                            }
                          },
                          child: isLoading
                              ? SizedBox(
                                  width: 20,
                                  height: 20,
                                  child: CircularProgressIndicator(
                                    color: Colors.white,
                                    strokeWidth: 2,
                                  ),
                                )
                              : Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    Icon(Icons.send, color: Colors.white, size: 16),
                                    SizedBox(width: 8),
                                    Text(
                                      'Report Issue',
                                      style: TextStyle(
                                        color: Colors.white,
                                        fontSize: 14,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ],
                                ),
                        ),
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

  // Open dialog for help & support
  void _openHelpSupport() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: lightBlush,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) {
        return Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Colors.white,
                lightBlush.withOpacity(0.2),
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
                // Enhanced Header
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
                        child: Icon(Icons.help_outline, color: deepRed, size: 20),
                      ),
                      SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          'Help & Support',
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
                          onPressed: () => Navigator.pop(ctx),
                        ),
                      ),
                    ],
                  ),
                ),
                Flexible(
                  child: SingleChildScrollView(
                    padding: EdgeInsets.all(24),
                    child: Column(
                      children: [
                        // Contact Section
                        Container(
                          padding: EdgeInsets.all(20),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(color: coral.withOpacity(0.3)),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withOpacity(0.05),
                                blurRadius: 10,
                                offset: Offset(0, 2),
                              ),
                            ],
                          ),
                          margin: EdgeInsets.only(bottom: 20),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Icon(Icons.support_agent, color: coral, size: 20),
                                  SizedBox(width: 8),
                                  Text(
                                    'Get Support',
                                    style: TextStyle(
                                      fontSize: 16,
                                      fontWeight: FontWeight.bold,
                                      color: deepRed,
                                    ),
                                  ),
                                ],
                              ),
                              SizedBox(height: 16),
                              _supportItem(
                                icon: Icons.email,
                                title: 'Email Support',
                                subtitle: 'Get help via email',
                                detail: 'test@gmail.com',
                                onTap: () => _launchEmail('test@gmail.com'),
                              ),
                              SizedBox(height: 12),
                              _supportItem(
                                icon: Icons.phone,
                                title: 'Phone Support',
                                subtitle: 'Speak with our team',
                                detail: '+1 123-456-7890',
                                onTap: () => _launchPhone('+1 123-456-7890'),
                              ),
                            ],
                          ),
                        ),
                        // Help Resources Section
                        Container(
                          padding: EdgeInsets.all(20),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(color: coral.withOpacity(0.3)),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withOpacity(0.05),
                                blurRadius: 10,
                                offset: Offset(0, 2),
                              ),
                            ],
                          ),
                          margin: EdgeInsets.only(bottom: 20),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Icon(Icons.menu_book, color: coral, size: 20),
                                  SizedBox(width: 8),
                                  Text(
                                    'Resources',
                                    style: TextStyle(
                                      fontSize: 16,
                                      fontWeight: FontWeight.bold,
                                      color: deepRed,
                                    ),
                                  ),
                                ],
                              ),
                              SizedBox(height: 16),
                              _supportItem(
                                icon: Icons.question_answer,
                                title: 'FAQs',
                                subtitle: 'Common questions and answers',
                                onTap: _showFAQs,
                              ),
                              SizedBox(height: 12),
                              _supportItem(
                                icon: Icons.bug_report,
                                title: 'Report an Issue',
                                subtitle: 'Let us know about problems',
                                onTap: _reportIssue,
                              ),
                              SizedBox(height: 12),
                              _supportItem(
                                icon: Icons.feedback,
                                title: 'Send Feedback',
                                subtitle: 'Share your thoughts with us',
                                onTap: () => _launchEmail('feedback@pettrackcare.com'),
                              ),
                            ],
                          ),
                        ),
                        // Quick Tips Section
                        Container(
                          padding: EdgeInsets.all(20),
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              colors: [lightBlush.withOpacity(0.5), peach.withOpacity(0.2)],
                            ),
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(color: coral.withOpacity(0.2)),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Icon(Icons.lightbulb_outline, color: coral, size: 20),
                                  SizedBox(width: 8),
                                  Text(
                                    'Quick Tips',
                                    style: TextStyle(
                                      fontSize: 16,
                                      fontWeight: FontWeight.bold,
                                      color: deepRed,
                                    ),
                                  ),
                                ],
                              ),
                              SizedBox(height: 12),
                              _tipItem('• Enable notifications to stay updated on your pet\'s activities'),
                              _tipItem('• Update your profile regularly for better pet care recommendations'),
                              _tipItem('• Use the search feature to quickly find specific information'),
                              _tipItem('• Check your internet connection if experiencing sync issues'),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _supportItem({
    required IconData icon,
    required String title,
    required String subtitle,
    String? detail,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: lightBlush.withOpacity(0.2),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: coral.withOpacity(0.2)),
        ),
        child: Row(
          children: [
            Container(
              padding: EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: coral.withOpacity(0.1),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(icon, color: deepRed, size: 20),
            ),
            SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: deepRed,
                    ),
                  ),
                  SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: TextStyle(
                      fontSize: 12,
                      color: Colors.grey[600],
                    ),
                  ),
                  if (detail != null) ...[
                    SizedBox(height: 4),
                    Text(
                      detail,
                      style: TextStyle(
                        fontSize: 12,
                        color: coral,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            Icon(Icons.arrow_forward_ios, color: Colors.grey[400], size: 16),
          ],
        ),
      ),
    );
  }

  Widget _tipItem(String tip) {
    return Padding(
      padding: EdgeInsets.only(bottom: 8),
      child: Text(
        tip,
        style: TextStyle(
          fontSize: 13,
          color: Colors.grey[700],
          height: 1.4,
        ),
      ),
    );
  }

  // Open dialog for about information
  void _openAbout() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: lightBlush,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) {
        return Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Colors.white,
                lightBlush.withOpacity(0.2),
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
                // Enhanced Header
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
                        child: Icon(Icons.info_outline, color: deepRed, size: 20),
                      ),
                      SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          'About PetTrackCare',
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
                          onPressed: () => Navigator.pop(ctx),
                        ),
                      ),
                    ],
                  ),
                ),
                Flexible(
                  child: SingleChildScrollView(
                    padding: EdgeInsets.all(24),
                    child: Column(
                      children: [
                        // App Info Section
                        Container(
                          padding: EdgeInsets.all(24),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(color: coral.withOpacity(0.3)),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withOpacity(0.05),
                                blurRadius: 10,
                                offset: Offset(0, 2),
                              ),
                            ],
                          ),
                          margin: EdgeInsets.only(bottom: 20),
                          child: Column(
                            children: [
                              // App Icon
                              Container(
                                width: 80,
                                height: 80,
                                decoration: BoxDecoration(
                                  gradient: LinearGradient(
                                    colors: [deepRed, coral],
                                  ),
                                  borderRadius: BorderRadius.circular(20),
                                  boxShadow: [
                                    BoxShadow(
                                      color: deepRed.withOpacity(0.2),
                                      blurRadius: 10,
                                      offset: Offset(0, 5),
                                    ),
                                  ],
                                ),
                                child: Icon(
                                  Icons.pets,
                                  color: Colors.white,
                                  size: 40,
                                ),
                              ),
                              SizedBox(height: 16),
                              Text(
                                'PetTrackCare',
                                style: TextStyle(
                                  fontSize: 24,
                                  fontWeight: FontWeight.bold,
                                  color: deepRed,
                                ),
                              ),
                              SizedBox(height: 8),
                              Container(
                                padding: EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                                decoration: BoxDecoration(
                                  color: coral.withOpacity(0.1),
                                  borderRadius: BorderRadius.circular(12),
                                  border: Border.all(color: coral.withOpacity(0.3)),
                                ),
                                child: Text(
                                  'Version 1.0.0',
                                  style: TextStyle(
                                    color: coral,
                                    fontWeight: FontWeight.w500,
                                    fontSize: 12,
                                  ),
                                ),
                              ),
                              SizedBox(height: 16),
                              Text(
                                'A comprehensive app designed to help pet owners monitor and manage their pets\' health, activities, and daily care routines with care and precision.',
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  fontSize: 14,
                                  color: Colors.grey[700],
                                  height: 1.5,
                                ),
                              ),
                            ],
                          ),
                        ),
                        // Features Section
                        Container(
                          padding: EdgeInsets.all(20),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(color: coral.withOpacity(0.3)),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withOpacity(0.05),
                                blurRadius: 10,
                                offset: Offset(0, 2),
                              ),
                            ],
                          ),
                          margin: EdgeInsets.only(bottom: 20),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Icon(Icons.star, color: coral, size: 20),
                                  SizedBox(width: 8),
                                  Text(
                                    'Key Features',
                                    style: TextStyle(
                                      fontSize: 16,
                                      fontWeight: FontWeight.bold,
                                      color: deepRed,
                                    ),
                                  ),
                                ],
                              ),
                              SizedBox(height: 16),
                              _featureItem(Icons.health_and_safety, 'Health Monitoring'),
                              _featureItem(Icons.calendar_today, 'Activity Tracking'),
                              _featureItem(Icons.notifications, 'Smart Reminders'),
                              _featureItem(Icons.people, 'Pet Sitting Services'),
                              _featureItem(Icons.analytics, 'Health Analytics'),
                            ],
                          ),
                        ),
                        // Team & Contact Section
                        Container(
                          padding: EdgeInsets.all(20),
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              colors: [lightBlush.withOpacity(0.5), peach.withOpacity(0.2)],
                            ),
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(color: coral.withOpacity(0.2)),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Icon(Icons.groups, color: coral, size: 20),
                                  SizedBox(width: 8),
                                  Text(
                                    'Our Team',
                                    style: TextStyle(
                                      fontSize: 16,
                                      fontWeight: FontWeight.bold,
                                      color: deepRed,
                                    ),
                                  ),
                                ],
                              ),
                              SizedBox(height: 12),
                              Text(
                                'Developed with ❤️ by the PetTrackCare Team',
                                style: TextStyle(
                                  fontSize: 14,
                                  color: Colors.grey[700],
                                ),
                              ),
                              SizedBox(height: 16),
                              Row(
                                children: [
                                  Icon(Icons.email, color: coral, size: 16),
                                  SizedBox(width: 8),
                                  Text(
                                    'Contact us: ',
                                    style: TextStyle(
                                      fontSize: 14,
                                      color: Colors.grey[700],
                                    ),
                                  ),
                                  InkWell(
                                    onTap: () => _launchEmail('test@gmail.com'),
                                    child: Text(
                                      'test@gmail.com',
                                      style: TextStyle(
                                        fontSize: 14,
                                        color: deepRed,
                                        fontWeight: FontWeight.w500,
                                        decoration: TextDecoration.underline,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              SizedBox(height: 12),
                              Text(
                                '© 2024 PetTrackCare. All rights reserved.',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: Colors.grey[600],
                                ),
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
          ),
        );
      },
    );
  }

  Widget _featureItem(IconData icon, String title) {
    return Padding(
      padding: EdgeInsets.only(bottom: 12),
      child: Row(
        children: [
          Container(
            padding: EdgeInsets.all(6),
            decoration: BoxDecoration(
              color: coral.withOpacity(0.1),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(icon, color: coral, size: 16),
          ),
          SizedBox(width: 12),
          Text(
            title,
            style: TextStyle(
              fontSize: 14,
              color: Colors.grey[700],
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }

  // Open dialog for saved posts
  void _openSavedPosts() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: lightBlush,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) => SavedPostsModal(userId: user?.id ?? ''),
    );
  }

  // Helper method for info cards
  Widget _buildUserInfoCard({
    required IconData icon,
    required String title,
    required String value,
    required Color color,
  }) {
    return Container(
      padding: EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.2),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withOpacity(0.3), width: 1),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: color, size: 18),
          SizedBox(height: 4),
          Text(
            title,
            style: TextStyle(
              fontSize: 11,
              color: color.withOpacity(0.8),
              fontWeight: FontWeight.w500,
            ),
            textAlign: TextAlign.center,
            overflow: TextOverflow.ellipsis,
          ),
          SizedBox(height: 2),
          Text(
            value,
            style: TextStyle(
              fontSize: 12,
              color: color,
              fontWeight: FontWeight.bold,
            ),
            textAlign: TextAlign.center,
            overflow: TextOverflow.ellipsis,
            maxLines: 1,
          ),
        ],
      ),
    );
  }
}

class _AddPetForm extends StatefulWidget {
  final VoidCallback onPetAdded;
  final Map<String, dynamic>? initialPet; // when provided, form is in "edit" mode

  _AddPetForm({required this.onPetAdded, this.initialPet});

  @override
  State<_AddPetForm> createState() => _AddPetFormState();
}

class _AddPetFormState extends State<_AddPetForm> {
  final _formKey = GlobalKey<FormState>();
  String name = '';
  String breed = '';
  int age = 0;
  String health = '';
  String gender = 'Male'; // added gender state
  double weight = 0.0;
  File? _petImage;
  bool _isLoading = false;

  final ImagePicker _picker = ImagePicker();

  String _species = 'Dog'; // default
  // Expanded breed lists including common Philippine local mixes (Askal/Aspin)
  final List<String> dogBreeds = [
    'Aspin (Askal)', // common local mixed-breed dog in the Philippines
    'Labrador Retriever',
    'Golden Retriever',
    'German Shepherd',
    'Shih Tzu',
    'Pomeranian',
    'Chihuahua',
    'Beagle',
    'Dachshund',
    'Bulldog',
    'Corgi',
    'Siberian Husky',
    'Maltese',
    'Papillon',
    'Pug',
  ];

  final List<String> catBreeds = [
    'Puspin / Domestic Shorthair', // common local cat type
    'Siamese',
    'Persian',
    'Maine Coon',
    'Ragdoll',
    'Bengal',
    'British Shorthair',
    'Sphynx',
    'American Shorthair',
    'Exotic Shorthair',
  ];

  @override
  void initState() {
    super.initState();
    // if editing, prefill fields
    final p = widget.initialPet;
    if (p != null) {
      name = p['name']?.toString() ?? '';
      breed = p['breed']?.toString() ?? '';
      age = (p['age'] is int) ? p['age'] : int.tryParse(p['age']?.toString() ?? '') ?? 0;
      health = p['health']?.toString() ?? 'Good';
      gender = p['gender']?.toString() ?? 'Male';
      weight = (p['weight'] is num) ? (p['weight'] as num).toDouble() : double.tryParse(p['weight']?.toString() ?? '') ?? 0.0;
      _species = (p['type'] ?? p['species'] ?? 'Dog').toString();
    } else {
      // default breed selection
      breed = dogBreeds.first;
      health = 'Good'; // default health for new pets
      gender = 'Male';
    }
  }

  Future<void> _pickPetImage() async {
    final pickedFile = await _picker.pickImage(source: ImageSource.gallery);
    if (pickedFile != null) {
      setState(() {
        _petImage = File(pickedFile.path);
      });
    }
  }

  Future<String?> _uploadPetImage(String userId) async {
    if (_petImage == null) return null;

    try {
      final bytes = await _petImage!.readAsBytes();
      final fileName =
          'pet_images/${userId}_${DateTime.now().millisecondsSinceEpoch}.jpg';
      final bucket = Supabase.instance.client.storage.from('pets-profile-pictures');

      await bucket.uploadBinary(
        fileName,
        bytes,
        fileOptions: const FileOptions(contentType: 'image/jpeg'),
      );

      final publicUrl = bucket.getPublicUrl(fileName);
      return publicUrl;
    } catch (e) {
      print('❌ Error uploading pet image: $e');
      return null;
    }
  }

  void _submit() async {
  if (!_formKey.currentState!.validate()) return;
  _formKey.currentState!.save();

  final userId = Supabase.instance.client.auth.currentUser?.id;
  if (userId == null) return;

  // enforce 3-pet limit server-side check
  final existing = await Supabase.instance.client
      .from('pets')
      .select('id')
      .eq('owner_id', userId);
  final currentCount = (existing as List?)?.length ?? 0;
  // if creating and already 3, block (if editing allow)
  final isEditing = widget.initialPet != null;
  if (!isEditing && currentCount >= 3) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Pet limit reached (3). Cannot add more.')),
    );
    return;
  }

  setState(() => _isLoading = true);

  try {
    final imageUrl = await _uploadPetImage(userId);

    if (isEditing) {
      // update existing pet
      final petId = widget.initialPet!['id'];
      await Supabase.instance.client.from('pets').update({
        'name': name,
        'breed': breed,
        'age': age,
        'health': health,
        'gender': gender,
        'weight': weight,
        'type': _species,
        if (imageUrl != null) 'profile_picture': imageUrl,
      }).eq('id', petId);
    } else {
      final response = await Supabase.instance.client.from('pets').insert({
        'name': name,
        'breed': breed,
        'age': age,
        'health': health,
        'gender': gender,
        'weight': weight,
        'owner_id': userId,
        'type': _species, // store species/type
        'profile_picture': imageUrl, // ✅ Must match your DB column name
      }).select();
      if (response.isEmpty) {
        throw Exception("No data returned. Check your RLS policy or table columns.");
      }
    }

    widget.onPetAdded();
    Navigator.pop(context);
  } catch (e) {
    print('❌ Error saving pet: $e');
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Failed to save pet. Please try again.')),
    );
  } finally {
    setState(() => _isLoading = false);
  }
}

  @override
  Widget build(BuildContext context) {
    return Form(
      key: _formKey,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Enhanced Header
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
                  child: Icon(Icons.pets, color: deepRed, size: 20),
                ),
                SizedBox(width: 12),
                Expanded(
                  child: Text(
                    widget.initialPet != null ? "Edit Pet" : "Add New Pet",
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
          Flexible(
            child: SingleChildScrollView(
              padding: EdgeInsets.all(24),
              child: Column(
                children: [
                  // Species selector with modern styling
                  Container(
                    padding: EdgeInsets.all(20),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: coral.withOpacity(0.3)),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withOpacity(0.05),
                          blurRadius: 10,
                          offset: Offset(0, 2),
                        ),
                      ],
                    ),
                    margin: EdgeInsets.only(bottom: 20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Icon(Icons.category, color: coral, size: 20),
                            SizedBox(width: 8),
                            Text(
                              'Pet Type',
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.bold,
                                color: deepRed,
                              ),
                            ),
                          ],
                        ),
                        SizedBox(height: 16),
                        Row(
                          children: [
                            Expanded(
                              child: _speciesChip('Dog', Icons.pets),
                            ),
                            SizedBox(width: 12),
                            Expanded(
                              child: _speciesChip('Cat', Icons.pets),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  // Enhanced Image picker section
                  Container(
                    padding: EdgeInsets.all(20),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: coral.withOpacity(0.3)),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withOpacity(0.05),
                          blurRadius: 10,
                          offset: Offset(0, 2),
                        ),
                      ],
                    ),
                    margin: EdgeInsets.only(bottom: 20),
                    child: Column(
                      children: [
                        Row(
                          children: [
                            Icon(Icons.photo_camera, color: coral, size: 20),
                            SizedBox(width: 8),
                            Text(
                              'Pet Photo',
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.bold,
                                color: deepRed,
                              ),
                            ),
                          ],
                        ),
                        SizedBox(height: 16),
                        Center(
                          child: Stack(
                            alignment: Alignment.bottomRight,
                            children: [
                              Container(
                                width: 100,
                                height: 100,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  border: Border.all(color: coral.withOpacity(0.3), width: 3),
                                  gradient: _petImage == null && (widget.initialPet == null || widget.initialPet!['profile_picture'] == null)
                                      ? LinearGradient(
                                          colors: [lightBlush.withOpacity(0.3), peach.withOpacity(0.1)],
                                        )
                                      : null,
                                ),
                                child: ClipOval(
                                  child: _petImage != null 
                                      ? Image.file(_petImage!, fit: BoxFit.cover, width: 100, height: 100)
                                      : (widget.initialPet != null && widget.initialPet!['profile_picture'] != null)
                                          ? Image.network(widget.initialPet!['profile_picture'], fit: BoxFit.cover, width: 100, height: 100)
                                          : Icon(Icons.pets, size: 40, color: coral),
                                ),
                              ),
                              Positioned(
                                bottom: 0,
                                right: 0,
                                child: GestureDetector(
                                  onTap: _pickPetImage,
                                  child: Container(
                                    padding: EdgeInsets.all(8),
                                    decoration: BoxDecoration(
                                      shape: BoxShape.circle,
                                      gradient: LinearGradient(colors: [deepRed, coral]),
                                      boxShadow: [
                                        BoxShadow(
                                          color: deepRed.withOpacity(0.3),
                                          blurRadius: 8,
                                          offset: Offset(0, 2),
                                        ),
                                      ],
                                    ),
                                    child: Icon(Icons.camera_alt, color: Colors.white, size: 16),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        SizedBox(height: 12),
                        Text(
                          'Tap the camera icon to add a photo',
                          style: TextStyle(
                            fontSize: 12,
                            color: Colors.grey[600],
                          ),
                        ),
                      ],
                    ),
                  ),

          _buildTextField(
            label: "Name", 
            initialValue: name,
            onSaved: (val) => name = val ?? '',
          ),
         // Breed dropdown moved to after Name
         Padding(
           padding: const EdgeInsets.symmetric(vertical: 8),
           child: DropdownButtonFormField<String>(
             value: (_species == 'Dog' ? (dogBreeds.contains(breed) ? breed : dogBreeds.first) : (catBreeds.contains(breed) ? breed : catBreeds.first)),
             decoration: InputDecoration(
               labelText: "Breed",
               border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
             ),
             items: (_species == 'Dog' ? dogBreeds : catBreeds).map((b) {
               return DropdownMenuItem(value: b, child: Text(b));
             }).toList(),
             onChanged: (val) => setState(() => breed = val ?? ''),
             onSaved: (val) => breed = val ?? '',
           ),
         ),
          _buildTextField(
            label: "Age (years)",
            initialValue: age > 0 ? age.toString() : '',
            keyboardType: TextInputType.number,
            onSaved: (val) => age = int.tryParse(val ?? '0') ?? 0,
          ),
          // Gender dropdown moved under Age
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: DropdownButtonFormField<String>(
              value: gender.isNotEmpty ? gender : 'Male',
              decoration: InputDecoration(
                labelText: "Gender",
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
              ),
              items: ['Male', 'Female', 'Unknown'].map((g) {
                return DropdownMenuItem(value: g, child: Text(g));
              }).toList(),
              onChanged: (val) => setState(() => gender = val ?? 'Male'),
              onSaved: (val) => gender = val ?? 'Male',
            ),
          ),
          // replace free-text health field with dropdown
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: DropdownButtonFormField<String>(
              value: (health.isNotEmpty ? health : 'Good'),
              decoration: InputDecoration(
                labelText: "Health",
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
              ),
              items: ['Good', 'Bad'].map((h) {
                return DropdownMenuItem(value: h, child: Text(h));
              }).toList(),
              onChanged: (val) => setState(() => health = val ?? 'Good'),
              onSaved: (val) => health = val ?? 'Good',
              validator: (val) => (val == null || val.isEmpty) ? 'Required' : null,
            ),
          ),
          _buildTextField(
            label: "Weight (kg)",
            initialValue: weight > 0 ? weight.toString() : '',
            keyboardType: TextInputType.number,
            onSaved: (val) => weight = double.tryParse(val ?? '0.0') ?? 0.0,
          ),

          SizedBox(height: 20),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: _isLoading ? null : _submit,
              child: _isLoading
                  ? CircularProgressIndicator(color: Colors.white)
                  : Text(widget.initialPet != null ? "Update Pet" : "Save Pet"),
              style: ElevatedButton.styleFrom(
                backgroundColor: deepRed,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
                padding: EdgeInsets.symmetric(vertical: 14),
              ),
            ),
          ),
          SizedBox(height: 16),
        ],
      ),
    )
          ),
        ]
      ),
    );
  }

  Widget _buildTextField({
    required String label,
    String? initialValue,
    TextInputType keyboardType = TextInputType.text,
    required FormFieldSetter<String> onSaved,
  }) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: coral.withOpacity(0.3)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.05),
            blurRadius: 10,
            offset: Offset(0, 2),
          ),
        ],
      ),
      margin: EdgeInsets.only(bottom: 16),
      child: TextFormField(
        initialValue: initialValue,
        keyboardType: keyboardType,
        decoration: InputDecoration(
          labelText: label,
          labelStyle: TextStyle(color: deepRed, fontWeight: FontWeight.w500),
          border: InputBorder.none,
          contentPadding: EdgeInsets.symmetric(horizontal: 20, vertical: 16),
          prefixIcon: _getFieldIcon(label),
        ),
        style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
        validator: (value) =>
            (value == null || value.isEmpty) ? 'Required' : null,
        onSaved: onSaved,
      ),
    );
  }

  Widget _speciesChip(String species, IconData icon) {
    bool isSelected = _species == species;
    return InkWell(
      onTap: () => setState(() {
        _species = species;
        // ensure breed matches selected species
        if (species == 'Dog' && !dogBreeds.contains(breed)) {
          breed = dogBreeds.first;
        } else if (species == 'Cat' && !catBreeds.contains(breed)) {
          breed = catBreeds.first;
        }
      }),
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: EdgeInsets.symmetric(vertical: 12, horizontal: 16),
        decoration: BoxDecoration(
          gradient: isSelected 
              ? LinearGradient(colors: [deepRed, coral])
              : null,
          color: isSelected ? null : lightBlush.withOpacity(0.3),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isSelected ? Colors.transparent : coral.withOpacity(0.3),
          ),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              icon,
              color: isSelected ? Colors.white : deepRed,
              size: 18,
            ),
            SizedBox(width: 8),
            Text(
              species,
              style: TextStyle(
                color: isSelected ? Colors.white : deepRed,
                fontWeight: FontWeight.w600,
                fontSize: 14,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Icon _getFieldIcon(String label) {
    switch (label.toLowerCase()) {
      case 'name':
        return Icon(Icons.pets, color: deepRed);
      case 'breed':
        return Icon(Icons.category, color: deepRed);
      case 'age':
        return Icon(Icons.cake, color: deepRed);
      case 'weight':
        return Icon(Icons.monitor_weight, color: deepRed);
      case 'health':
        return Icon(Icons.health_and_safety, color: deepRed);
      default:
        return Icon(Icons.info, color: deepRed);
    }
  }

}


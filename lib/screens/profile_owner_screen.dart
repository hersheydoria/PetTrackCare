import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:image_picker/image_picker.dart';
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
  void _openFeedbackDialog() async {
    TextEditingController feedbackController = TextEditingController();
    await showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Report or Feedback'),
        content: Container(
          decoration: BoxDecoration(
            border: Border.all(color: Colors.grey, width: 1.5),
            borderRadius: BorderRadius.circular(8),
          ),
          padding: EdgeInsets.all(4),
          child: TextField(
            controller: feedbackController,
            style: TextStyle(color: Colors.black),
            decoration: InputDecoration(
              hintText: 'Let us know your feedback or report an issue...',
              hintStyle: TextStyle(color: Colors.grey),
              border: InputBorder.none,
              contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 8),
            ),
            maxLines: 4,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () async {
              final text = feedbackController.text.trim();
              if (text.isEmpty) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('Please enter your feedback or report.')),
                );
                return;
              }
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
                  SnackBar(content: Text('Thank you for your feedback!')),
                );
              } catch (e) {
                Navigator.pop(context);
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('Failed to submit feedback. Please try again.')),
                );
              }
            },
            child: Text('Submit'),
          ),
        ],
      ),
    );
  }
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
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
    ),
    builder: (context) {
      return Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(context).viewInsets.bottom,
          top: 24,
          left: 16,
          right: 16,
        ),
        child: _AddPetForm(onPetAdded: () => setState(() {})),
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

  // Render a single pet tile used in the pets list (keeps UI consistent)
  Widget _petListTile(Map<String, dynamic> pet) {
    return Container(
      margin: EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        border: Border.all(color: Colors.grey.shade300),
        borderRadius: BorderRadius.circular(12),
        color: Colors.white,
      ),
      child: ListTile(
        onTap: () {
          // open pet profile and show this pet
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => PetProfileScreen(initialPet: pet),
            ),
          );
        },
        leading: CircleAvatar(
          radius: 25,
          backgroundColor: Colors.grey[300],
          backgroundImage: (pet['profile_picture'] != null &&
                  pet['profile_picture'].toString().isNotEmpty)
              ? NetworkImage(pet['profile_picture'])
              : const AssetImage('assets/pets-profile-pictures.png')
                  as ImageProvider,
        ),
        title: Text(pet['name'] ?? 'Unnamed'),
        subtitle: Text(
          'Breed: ${pet['breed'] ?? 'Unknown'} | Age: ${pet['age'] ?? 0}',
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              icon: Icon(Icons.edit, color: deepRed),
              onPressed: () {
                // open edit modal with initial pet data
                showModalBottomSheet(
                  context: context,
                  isScrollControlled: true,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
                  ),
                  builder: (context) {
                    return Padding(
                      padding: EdgeInsets.only(
                        bottom: MediaQuery.of(context).viewInsets.bottom,
                        top: 24,
                        left: 16,
                        right: 16,
                      ),
                      child: _AddPetForm(
                        onPetAdded: () => setState(() {}),
                        initialPet: pet,
                      ),
                    );
                  },
                );
              },
            ),
            IconButton(
              icon: Icon(Icons.delete, color: Colors.grey[700]),
              onPressed: () => _deletePet(pet['id']?.toString() ?? ''),
            ),
          ],
        ),
      ),
    );
  }

  // Delete pet with confirmation dialog, refresh UI (FutureBuilder will refetch)
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
        title: Text('Owner Profile', style: TextStyle(fontWeight: FontWeight.bold)),
        backgroundColor: Color(0xFFCB4154),
        elevation: 0,
        actions: [
          IconButton(
            icon: Icon(Icons.logout, color: Colors.white),
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
        ],
      ),
      body: Column(
        children: [
          // Profile Info
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
              : (userData['profile_picture'] != null
                  ? NetworkImage(userData['profile_picture'])
                  : (metadata['profile_picture'] != null
                      ? NetworkImage(metadata['profile_picture'])
                      : AssetImage('assets/default_profile.png'))) as ImageProvider,
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

// 👇 Add this
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
                      Tab(icon: Icon(Icons.pets), text: 'Owned Pets'),
                      Tab(icon: Icon(Icons.settings), text: 'Settings'),
                    ],
                  ),
                  Divider(height: 1, color: Colors.grey.shade300),

                  // Tab content
                  Expanded(
                    child: TabBarView(
                      controller: _tabController,
                      children: [
                        // 🐾 Owned Pets
                        FutureBuilder<List<Map<String, dynamic>>>(
                          future: _fetchPets(),
                          builder: (context, snapshot) {
                            if (snapshot.connectionState ==
                                ConnectionState.waiting) {
                              return Center(
                                  child:
                                      CircularProgressIndicator(color: deepRed));
                            }
                            final pets = snapshot.data ?? [];
                            // group by type (try 'type' then 'species' then fallback)
                            final dogPets = pets.where((p) {
                              final t = (p['type'] ?? p['species'] ?? '')
                                  .toString()
                                  .toLowerCase();
                              return t == 'dog';
                            }).toList();
                            final catPets = pets.where((p) {
                              final t = (p['type'] ?? p['species'] ?? '')
                                  .toString()
                                  .toLowerCase();
                              return t == 'cat';
                            }).toList();
                            final otherPets = pets
                                .where((p) =>
                                    !dogPets.contains(p) && !catPets.contains(p))
                                .toList();

                            if (pets.isEmpty) {
                              return Column(
                                children: [
                                  Expanded(
                                    child: Center(
                                      child: Text('No pets found.',
                                          style: TextStyle(color: Colors.grey)),
                                    ),
                                  ),
                                  Padding(
                                    padding: const EdgeInsets.all(16.0),
                                    child: ElevatedButton.icon(
                                      onPressed: _addPet,
                                      icon: Icon(Icons.add),
                                      label: Text('Add Pet'),
                                      style: ElevatedButton.styleFrom(
                                        backgroundColor: deepRed,
                                        foregroundColor: Colors.white,
                                        minimumSize: Size(double.infinity, 48),
                                        shape: RoundedRectangleBorder(
                                            borderRadius:
                                                BorderRadius.circular(12)),
                                      ),
                                    ),
                                  ),
                                ],
                              );
                            }

                            // disable add if already 3 pets
                            final canAdd = pets.length < 3;

                            return Column(
                              children: [
                                Expanded(
                                  child: ListView(
                                    padding: EdgeInsets.symmetric(vertical: 8),
                                    children: [
                                      if (dogPets.isNotEmpty) ...[
                                        Padding(
                                          padding: const EdgeInsets.symmetric(
                                              horizontal: 16, vertical: 8),
                                          child: Text("Dogs",
                                              style: TextStyle(
                                                  fontWeight: FontWeight.bold)),
                                        ),
                                        ...dogPets.map((pet) => _petListTile(pet))
                                      ],
                                      if (catPets.isNotEmpty) ...[
                                        Padding(
                                          padding: const EdgeInsets.symmetric(
                                              horizontal: 16, vertical: 8),
                                          child: Text("Cats",
                                              style: TextStyle(
                                                  fontWeight: FontWeight.bold)),
                                        ),
                                        ...catPets.map((pet) => _petListTile(pet))
                                      ],
                                      if (otherPets.isNotEmpty) ...[
                                        Padding(
                                          padding: const EdgeInsets.symmetric(
                                              horizontal: 16, vertical: 8),
                                          child: Text("Other",
                                              style: TextStyle(
                                                  fontWeight: FontWeight.bold)),
                                        ),
                                        ...otherPets.map((pet) => _petListTile(pet))
                                      ],
                                    ],
                                  ),
                                ),
                                Padding(
                                  padding: const EdgeInsets.all(16.0),
                                  child: ElevatedButton.icon(
                                    onPressed: canAdd
                                        ? _addPet
                                        : () {
                                            ScaffoldMessenger.of(context)
                                                .showSnackBar(SnackBar(
                                                    content: Text(
                                                        "You can add up to 3 pets only.")));
                                          },
                                    icon: Icon(Icons.add),
                                    label: Text(canAdd
                                        ? 'Add Pet'
                                        : 'Limit reached (3 pets)'),
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor:
                                          canAdd ? deepRed : Colors.grey,
                                      foregroundColor: Colors.white,
                                      minimumSize: Size(double.infinity, 48),
                                      shape: RoundedRectangleBorder(
                                          borderRadius:
                                              BorderRadius.circular(12)),
                                      elevation: 4,
                                    ),
                                  ),
                                ),
                              ],
                            );
                          },
                        ),

                        // ⚙️ Settings
                        ListView(
                          padding: EdgeInsets.all(16),
                          children: [
                            _settingsTile(Icons.person, 'Account', onTap: _openAccountSettings),
                            _settingsTile(Icons.feedback, 'Report or Feedback', onTap: _openFeedbackDialog),
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

  // Open dialog for account settings
  void _openAccountSettings() async {
    String newName = name;
    String newAddress = address == 'No address provided' ? '' : address;
    bool isLoading = false;

    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setSt) {
            return SafeArea(
              child: Container(
                color: lightBlush,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        IconButton(
                          icon: const Icon(Icons.arrow_back, color: deepRed),
                          onPressed: () => Navigator.pop(ctx),
                        ),
                        Expanded(
                          child: Center(
                            child: Text(
                              'Account',
                              style: TextStyle(
                                fontSize: 24,
                                fontWeight: FontWeight.bold,
                                color: deepRed,
                                letterSpacing: 0.5,
                              ),
                            ),
                          ),
                        ),
                        SizedBox(width: 48),
                      ],
                    ),
                    SingleChildScrollView(
                      padding: EdgeInsets.all(16),
                      child: Column(
                        children: [
                          Container(
                            decoration: BoxDecoration(
                              border: Border.all(color: Colors.grey.shade400),
                              borderRadius: BorderRadius.circular(12),
                              color: Colors.white,
                            ),
                            margin: EdgeInsets.only(bottom: 16),
                            child: TextFormField(
                              enabled: false,
                              initialValue: email,
                              decoration: InputDecoration(
                                labelText: 'Email',
                                border: InputBorder.none,
                                contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                              ),
                            ),
                          ),
                          Container(
                            decoration: BoxDecoration(
                              border: Border.all(color: Colors.grey.shade400),
                              borderRadius: BorderRadius.circular(12),
                              color: Colors.white,
                            ),
                            margin: EdgeInsets.only(bottom: 16),
                            child: TextFormField(
                              initialValue: newName,
                              decoration: InputDecoration(
                                labelText: 'Name',
                                border: InputBorder.none,
                                contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                              ),
                              onChanged: (v) => setSt(() => newName = v),
                            ),
                          ),
                          Container(
                            decoration: BoxDecoration(
                              border: Border.all(color: Colors.grey.shade400),
                              borderRadius: BorderRadius.circular(12),
                              color: Colors.white,
                            ),
                            margin: EdgeInsets.only(bottom: 16),
                            child: TextFormField(
                              initialValue: newAddress,
                              decoration: InputDecoration(
                                labelText: 'Address',
                                border: InputBorder.none,
                                contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                              ),
                              onChanged: (v) => setSt(() => newAddress = v),
                            ),
                          ),
                          SizedBox(height: 16),
                          Container(
                            width: double.infinity,
                            child: ElevatedButton(
                              style: ElevatedButton.styleFrom(
                                backgroundColor: deepRed,
                                padding: EdgeInsets.symmetric(vertical: 12),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(12),
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
                                    SnackBar(content: Text('Account updated')),
                                  );
                                  Navigator.pop(ctx);
                                } catch (e) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(content: Text('Failed to update account: ${e.toString()}')),
                                  );
                                }
                                setSt(() => isLoading = false);
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
                                  : Text(
                                      'Save Changes',
                                      style: TextStyle(
                                        fontSize: 16,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                            ),
                          ),
                          SizedBox(height: 16),
                          Container(
                            width: double.infinity,
                            child: TextButton(
                              style: TextButton.styleFrom(
                                foregroundColor: Colors.red,
                              ),
                              onPressed: () async {
                                final confirm = await showDialog<bool>(
                                  context: context,
                                  builder: (context) => AlertDialog(
                                    title: Text('Delete Account'),
                                    content: Text('Are you sure you want to delete your account? This action cannot be undone.'),
                                    actions: [
                                      TextButton(
                                        onPressed: () => Navigator.pop(context, false),
                                        child: Text('Cancel'),
                                      ),
                                      TextButton(
                                        onPressed: () => Navigator.pop(context, true),
                                        child: Text('Delete', style: TextStyle(color: Colors.red)),
                                      ),
                                    ],
                                  ),
                                );
                                
                                if (confirm == true) {
                                  try {
                                    await Supabase.instance.client.auth.signOut();
                                    await Supabase.instance.client.from('users').delete().eq('id', user!.id);
                                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Account deleted.')));
                                    Navigator.pushNamedAndRemoveUntil(context, '/login', (r) => false);
                                  } catch (e) {
                                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error deleting account: $e')));
                                  }
                                }
                              },
                              child: Text('Delete Account'),
                            ),
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
      },
    );
  }

  // Open dialog for notification preferences
  void _openNotificationPreferences() async {
    final currentPrefs = metadata['notification_preferences'] ?? {'enabled': true};

    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        bool enabled = currentPrefs['enabled'] ?? true;
        return StatefulBuilder(
          builder: (ctx, setSt) {
            return SafeArea(
              child: Padding(
                padding: EdgeInsets.only(
                  bottom: MediaQuery.of(ctx).viewInsets.bottom,
                ),
                child: Container(
                  color: lightBlush,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        children: [
                          IconButton(
                            icon: Icon(Icons.arrow_back, color: deepRed),
                            onPressed: () => Navigator.pop(ctx),
                          ),
                          Expanded(
                            child: Center(
                              child: Text(
                                'Notifications',
                                style: TextStyle(
                                  fontSize: 24,
                                  fontWeight: FontWeight.bold,
                                  color: deepRed,
                                  letterSpacing: 0.5,
                                ),
                              ),
                            ),
                          ),
                          SizedBox(width: 48),
                        ],
                      ),
                      SingleChildScrollView(
                        padding: EdgeInsets.all(16),
                        child: Column(
                          children: [
                            Container(
                              decoration: BoxDecoration(
                                border: Border.all(color: Colors.grey.shade400),
                                borderRadius: BorderRadius.circular(12),
                                color: Colors.white,
                              ),
                              margin: EdgeInsets.only(bottom: 16),
                              child: SwitchListTile(
                                title: Text('Enable Notifications'),
                                value: enabled,
                                onChanged: (v) => setSt(() => enabled = v),
                              ),
                            ),
                            SizedBox(height: 8),
                            SizedBox(
                              width: double.infinity,
                              child: ElevatedButton(
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: deepRed,
                                  padding: EdgeInsets.symmetric(vertical: 12),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                ),
                                onPressed: () async {
                                  try {
                                    await Supabase.instance.client.auth.updateUser(
                                      UserAttributes(data: {
                                        'notification_preferences': {'enabled': enabled}
                                      })
                                    );
                                    Navigator.pop(ctx);
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      SnackBar(content: Text('Notification preferences updated')),
                                    );
                                  } catch (e) {
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      SnackBar(content: Text('Failed to update preferences: ${e.toString()}')),
                                    );
                                  }
                                },
                                child: Text(
                                  'Save',
                                  style: TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.bold,
                                  ),
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
            );
          },
        );
      },
    );
  }

  // Open dialog for privacy settings
  void _openPrivacySettings() async {
    final currentPrivacy = metadata['privacy'] ?? {'profile_visible': true};

    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        bool profileVisible = currentPrivacy['profile_visible'] ?? true;
        return StatefulBuilder(
          builder: (ctx, setSt) {
            return SafeArea(
              child: Padding(
                padding: EdgeInsets.only(
                  bottom: MediaQuery.of(ctx).viewInsets.bottom,
                ),
                child: Container(
                  color: lightBlush,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        children: [
                          IconButton(
                            icon: Icon(Icons.arrow_back, color: deepRed),
                            onPressed: () => Navigator.pop(ctx),
                          ),
                          Expanded(
                            child: Center(
                              child: Text(
                                'Privacy',
                                style: TextStyle(
                                  fontSize: 24,
                                  fontWeight: FontWeight.bold,
                                  color: deepRed,
                                  letterSpacing: 0.5,
                                ),
                              ),
                            ),
                          ),
                          SizedBox(width: 48),
                        ],
                      ),
                      SingleChildScrollView(
                        padding: EdgeInsets.all(16),
                        child: Column(
                          children: [
                            Container(
                              decoration: BoxDecoration(
                                border: Border.all(color: Colors.grey.shade400),
                                borderRadius: BorderRadius.circular(12),
                                color: Colors.white,
                              ),
                              margin: EdgeInsets.only(bottom: 16),
                              child: SwitchListTile(
                                title: Text('Profile Visible to Others'),
                                value: profileVisible,
                                onChanged: (v) => setSt(() => profileVisible = v),
                              ),
                            ),
                            SizedBox(height: 8),
                            SizedBox(
                              width: double.infinity,
                              child: ElevatedButton(
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: deepRed,
                                  padding: EdgeInsets.symmetric(vertical: 12),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                ),
                                onPressed: () async {
                                  try {
                                    await Supabase.instance.client.auth.updateUser(
                                      UserAttributes(data: {
                                        'privacy': {'profile_visible': profileVisible}
                                      })
                                    );
                                    Navigator.pop(ctx);
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      SnackBar(content: Text('Privacy settings updated')),
                                    );
                                  } catch (e) {
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      SnackBar(content: Text('Failed to update privacy settings: ${e.toString()}')),
                                    );
                                  }
                                },
                                child: Text(
                                  'Save',
                                  style: TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.bold,
                                  ),
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
            );
          },
        );
      },
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
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setSt) {
            return SafeArea(
              child: Padding(
                padding: EdgeInsets.only(
                  bottom: MediaQuery.of(ctx).viewInsets.bottom,
                ),
                child: Container(
                  color: lightBlush,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        children: [
                          IconButton(
                            icon: Icon(Icons.arrow_back, color: deepRed),
                            onPressed: () => Navigator.pop(ctx),
                          ),
                          Expanded(
                            child: Center(
                              child: Text(
                                'Change Password',
                                style: TextStyle(
                                  fontSize: 24,
                                  fontWeight: FontWeight.bold,
                                  color: deepRed,
                                  letterSpacing: 0.5,
                                ),
                              ),
                            ),
                          ),
                          SizedBox(width: 48),
                        ],
                      ),
                      Flexible(
                        child: SingleChildScrollView(
                          padding: EdgeInsets.all(16),
                          child: Column(
                            children: [
                              Container(
                                decoration: BoxDecoration(
                                  border: Border.all(color: Colors.grey.shade400),
                                  borderRadius: BorderRadius.circular(12),
                                  color: Colors.white,
                                ),
                                margin: EdgeInsets.only(bottom: 16),
                                child: TextFormField(
                                  controller: _currentPasswordController,
                                  obscureText: !_showCurrentPassword,
                                  decoration: InputDecoration(
                                    labelText: 'Current Password',
                                    border: InputBorder.none,
                                    contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                    suffixIcon: IconButton(
                                      icon: Icon(_showCurrentPassword ? Icons.visibility_off : Icons.visibility),
                                      onPressed: () => setSt(() => _showCurrentPassword = !_showCurrentPassword),
                                    ),
                                  ),
                                ),
                              ),
                              Container(
                                decoration: BoxDecoration(
                                  border: Border.all(color: Colors.grey.shade400),
                                  borderRadius: BorderRadius.circular(12),
                                  color: Colors.white,
                                ),
                                margin: EdgeInsets.only(bottom: 16),
                                child: TextFormField(
                                  controller: _newPasswordController,
                                  obscureText: !_showNewPassword,
                                  decoration: InputDecoration(
                                    labelText: 'New Password',
                                    border: InputBorder.none,
                                    contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                    suffixIcon: IconButton(
                                      icon: Icon(_showNewPassword ? Icons.visibility_off : Icons.visibility),
                                      onPressed: () => setSt(() => _showNewPassword = !_showNewPassword),
                                    ),
                                  ),
                                ),
                              ),
                              Container(
                                decoration: BoxDecoration(
                                  border: Border.all(color: Colors.grey.shade400),
                                  borderRadius: BorderRadius.circular(12),
                                  color: Colors.white,
                                ),
                                margin: EdgeInsets.only(bottom: 16),
                                child: TextFormField(
                                  controller: _confirmPasswordController,
                                  obscureText: !_showConfirmPassword,
                                  decoration: InputDecoration(
                                    labelText: 'Confirm New Password',
                                    border: InputBorder.none,
                                    contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                    suffixIcon: IconButton(
                                      icon: Icon(_showConfirmPassword ? Icons.visibility_off : Icons.visibility),
                                      onPressed: () => setSt(() => _showConfirmPassword = !_showConfirmPassword),
                                    ),
                                  ),
                                ),
                              ),
                              // Password requirements text
                              Align(
                                alignment: Alignment.centerLeft,
                                child: Padding(
                                  padding: const EdgeInsets.only(bottom: 16, left: 4),
                                  child: Text(
                                    'Password must contain:\n• At least 8 characters\n• One uppercase letter\n• One lowercase letter\n• One number\n• One special character',
                                    style: TextStyle(
                                      color: Colors.grey[600],
                                      fontSize: 12,
                                    ),
                                    textAlign: TextAlign.left,
                                  ),
                                ),
                              ),
                              SizedBox(
                                width: double.infinity,
                                child: ElevatedButton(
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: deepRed,
                                    padding: EdgeInsets.symmetric(vertical: 12),
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(12),
                                    ),
                                  ),
                                  onPressed: _isLoading ? null : () async {
                                    if (_newPasswordController.text.isEmpty ||
                                        _currentPasswordController.text.isEmpty ||
                                        _confirmPasswordController.text.isEmpty) {
                                      ScaffoldMessenger.of(context).showSnackBar(
                                        SnackBar(content: Text('Please fill in all fields')),
                                      );
                                      return;
                                    }

                                    if (_newPasswordController.text != _confirmPasswordController.text) {
                                      ScaffoldMessenger.of(context).showSnackBar(
                                        SnackBar(content: Text('New passwords do not match')),
                                      );
                                      return;
                                    }

                                    final password = _newPasswordController.text;
                                    if (password.length < 8 ||
                                        !RegExp(r'[A-Z]').hasMatch(password) ||
                                        !RegExp(r'[a-z]').hasMatch(password) ||
                                        !RegExp(r'[0-9]').hasMatch(password) ||
                                        !RegExp(r'[!@#\$&*~_.,%^()\-\+=]').hasMatch(password)) {
                                      ScaffoldMessenger.of(context).showSnackBar(
                                        SnackBar(content: Text('Password does not meet requirements')),
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
                                        SnackBar(content: Text('Password updated successfully')),
                                      );
                                    } catch (e) {
                                      ScaffoldMessenger.of(context).showSnackBar(
                                        SnackBar(content: Text('Failed to update password: ${e.toString()}')),
                                      );
                                    }
                                    setSt(() => _isLoading = false);
                                  },
                                  child: _isLoading
                                      ? SizedBox(
                                          width: 20,
                                          height: 20,
                                          child: CircularProgressIndicator(
                                            color: Colors.white,
                                            strokeWidth: 2,
                                          ),
                                        )
                                      : Text(
                                          'Update Password',
                                          style: TextStyle(
                                            fontSize: 16,
                                            fontWeight: FontWeight.bold,
                                          ),
                                        ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  // Open dialog for theme settings
  // Open dialog for help & support
  void _openHelpSupport() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        return SafeArea(
          child: Container(
            color: lightBlush,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    IconButton(
                      icon: const Icon(Icons.arrow_back, color: deepRed),
                      onPressed: () => Navigator.pop(ctx),
                    ),
                    Expanded(
                      child: Center(
                        child: Text(
                          'Help & Support',
                          style: TextStyle(
                            fontSize: 24,
                            fontWeight: FontWeight.bold,
                            color: deepRed,
                            letterSpacing: 0.5,
                          ),
                        ),
                      ),
                    ),
                    SizedBox(width: 48),
                  ],
                ),
                SingleChildScrollView(
                  padding: EdgeInsets.all(16),
                  child: Column(
                    children: [
                      Container(
                        decoration: BoxDecoration(
                          border: Border.all(color: Colors.grey.shade400),
                          borderRadius: BorderRadius.circular(12),
                          color: Colors.white,
                        ),
                        margin: EdgeInsets.only(bottom: 16),
                        child: Column(
                          children: [
                            ListTile(
                              title: Text('Contact Support'),
                              subtitle: Text('Reach out to our support team'),
                              leading: Icon(Icons.support_agent, color: deepRed),
                              trailing: Icon(Icons.arrow_forward_ios, size: 16),
                              onTap: () {
                                // Add contact support action
                              },
                            ),
                            Divider(height: 1),
                            ListTile(
                              title: Text('FAQs'),
                              subtitle: Text('Find answers to common questions'),
                              leading: Icon(Icons.question_answer, color: deepRed),
                              trailing: Icon(Icons.arrow_forward_ios, size: 16),
                              onTap: () {
                                // Add FAQs action
                              },
                            ),
                            Divider(height: 1),
                            ListTile(
                              title: Text('Report an Issue'),
                              subtitle: Text('Let us know if something\'s not working'),
                              leading: Icon(Icons.bug_report, color: deepRed),
                              trailing: Icon(Icons.arrow_forward_ios, size: 16),
                              onTap: () {
                                // Add report issue action
                              },
                            ),
                          ],
                        ),
                      ),
                      Container(
                        decoration: BoxDecoration(
                          border: Border.all(color: Colors.grey.shade400),
                          borderRadius: BorderRadius.circular(12),
                          color: Colors.white,
                        ),
                        margin: EdgeInsets.only(bottom: 16),
                        child: Column(
                          children: [
                            ListTile(
                              leading: Icon(Icons.email, color: deepRed),
                              title: Text('Email Support'),
                              subtitle: Text('support@pettrackcare.com'),
                              onTap: () {
                                // Add email support action
                              },
                            ),
                            Divider(height: 1),
                            ListTile(
                              leading: Icon(Icons.phone, color: deepRed),
                              title: Text('Phone Support'),
                              subtitle: Text('+1 123-456-7890'),
                              onTap: () {
                                // Add phone support action
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
        );
      },
    );
  }

  // Open dialog for about information
  void _openAbout() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Padding(
            padding: EdgeInsets.only(
              bottom: MediaQuery.of(ctx).viewInsets.bottom,
            ),
            child: Container(
              color: lightBlush,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      IconButton(
                        icon: Icon(Icons.arrow_back, color: deepRed),
                        onPressed: () => Navigator.pop(ctx),
                      ),
                      Expanded(
                        child: Center(
                          child: Text(
                            'About',
                            style: TextStyle(
                              fontSize: 24,
                              fontWeight: FontWeight.bold,
                              color: deepRed,
                              letterSpacing: 0.5,
                            ),
                          ),
                        ),
                      ),
                      SizedBox(width: 48),
                    ],
                  ),
                  SingleChildScrollView(
                    padding: EdgeInsets.all(16),
                    child: Column(
                      children: [
                        Container(
                          decoration: BoxDecoration(
                            border: Border.all(color: Colors.grey.shade400),
                            borderRadius: BorderRadius.circular(12),
                            color: Colors.white,
                          ),
                          margin: EdgeInsets.only(bottom: 16),
                          padding: EdgeInsets.symmetric(vertical: 16, horizontal: 16),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'PetTrackCare',
                                style: TextStyle(
                                  fontSize: 20,
                                  fontWeight: FontWeight.bold,
                                  color: deepRed,
                                ),
                              ),
                              SizedBox(height: 8),
                              Text(
                                'Version 1.0.0',
                                style: TextStyle(
                                  color: Colors.grey[700],
                                ),
                              ),
                              SizedBox(height: 16),
                              Text(
                                'PetTrackCare is a comprehensive app designed to help pet owners monitor and manage their pets\' health, activities, and daily care routines.',
                                style: TextStyle(
                                  fontSize: 15,
                                  color: Colors.grey[800],
                                ),
                              ),
                              SizedBox(height: 16),
                              Divider(),
                              SizedBox(height: 16),
                              Text(
                                'Developed by:',
                                style: TextStyle(
                                  fontWeight: FontWeight.bold,
                                  color: Colors.grey[800],
                                ),
                              ),
                              SizedBox(height: 4),
                              Text(
                                'PetTrackCare Team',
                                style: TextStyle(
                                  color: Colors.grey[700],
                                ),
                              ),
                              SizedBox(height: 8),
                              Text(
                                'Contact:',
                                style: TextStyle(
                                  fontWeight: FontWeight.bold,
                                  color: Colors.grey[800],
                                ),
                              ),
                              SizedBox(height: 4),
                              Text(
                                'support@pettrackcare.com',
                                style: TextStyle(
                                  color: deepRed,
                                ),
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
          ),
        );
      },
    );
  }

  // Open dialog for saved posts
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
      child: Wrap(
        children: [
          Text(widget.initialPet != null ? "Edit Pet" : "Add New Pet",
              style: TextStyle(
                  fontSize: 20, fontWeight: FontWeight.bold, color: deepRed)),
          SizedBox(height: 16),

           // species selector
           Row(
             mainAxisAlignment: MainAxisAlignment.center,
             children: [
               ChoiceChip(
                 label: Text(
                   'Dog',
                   style: TextStyle(
                     color: _species == 'Dog' ? Colors.white : deepRed,
                     fontWeight: FontWeight.w600,
                   ),
                 ),
                 selected: _species == 'Dog',
                 selectedColor: deepRed,
                 backgroundColor: Colors.grey.shade200,
                 onSelected: (_) => setState(() {
                   _species = 'Dog';
                   // ensure breed matches selected species
                   if (!dogBreeds.contains(breed)) breed = dogBreeds.first;
                 }),
               ),
               SizedBox(width: 8),
               ChoiceChip(
                 label: Text(
                   'Cat',
                   style: TextStyle(
                     color: _species == 'Cat' ? Colors.white : deepRed,
                     fontWeight: FontWeight.w600,
                   ),
                 ),
                 selected: _species == 'Cat',
                 selectedColor: deepRed,
                 backgroundColor: Colors.grey.shade200,
                 onSelected: (_) => setState(() {
                   _species = 'Cat';
                   // ensure breed matches selected species
                   if (!catBreeds.contains(breed)) breed = catBreeds.first;
                 }),
               ),
             ],
           ),
           SizedBox(height: 12),

          // Image picker section
          Center(
            child: Stack(
              alignment: Alignment.bottomRight,
              children: [
                CircleAvatar(
                  radius: 50,
                  backgroundColor: Colors.grey[300],
                  backgroundImage: _petImage != null 
                      ? FileImage(_petImage!) 
                      : (widget.initialPet != null && widget.initialPet!['profile_picture'] != null)
                          ? NetworkImage(widget.initialPet!['profile_picture'])
                          : null,
                  child: (_petImage == null && (widget.initialPet == null || widget.initialPet!['profile_picture'] == null))
                      ? Icon(Icons.pets, size: 50, color: Colors.white)
                      : null,
                ),
                Positioned(
                  bottom: 0,
                  right: 0,
                  child: GestureDetector(
                    onTap: _pickPetImage,
                    child: Container(
                      padding: EdgeInsets.all(6),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: deepRed,
                      ),
                      child: Icon(Icons.camera_alt, color: Colors.white, size: 18),
                    ),
                  ),
                ),
              ],
            ),
          ),
          SizedBox(height: 16),

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
    );
  }

  Widget _buildTextField({
    required String label,
    String? initialValue,
    TextInputType keyboardType = TextInputType.text,
    required FormFieldSetter<String> onSaved,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: TextFormField(
        initialValue: initialValue,
        keyboardType: keyboardType,
        decoration: InputDecoration(
          labelText: label,
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
        ),
        validator: (value) =>
            (value == null || value.isEmpty) ? 'Required' : null,
        onSaved: onSaved,
      ),
    );
  }
}


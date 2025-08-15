import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:image_picker/image_picker.dart';
import 'dart:io';
import 'pets_screen.dart';

// Color palette
const deepRed = Color(0xFFB82132);
const coral = Color(0xFFD2665A);
const peach = Color(0xFFF2B28C);
const lightBlush = Color(0xFFF6DED8);

class OwnerProfileScreen extends StatefulWidget {
  @override
  State<OwnerProfileScreen> createState() => _OwnerProfileScreenState();
}

class _OwnerProfileScreenState extends State<OwnerProfileScreen>
    with SingleTickerProviderStateMixin {
  final user = Supabase.instance.client.auth.currentUser;
  final metadata =
      Supabase.instance.client.auth.currentUser?.userMetadata ?? {};

  late TabController _tabController;

  String get name => metadata['name'] ?? 'Pet Owner';
  String get email => user?.email ?? 'No email';
  String get address =>
      metadata['address'] ?? metadata['location'] ?? 'No address provided';

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
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


File? _profileImage;
final ImagePicker _picker = ImagePicker();

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

    await supabase.auth.updateUser(UserAttributes(
      data: {'profile_picture': publicUrl},
    ));

    setState(() {
      _profileImage = file;
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

    final response = await supabase.storage
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
      final resp = await Supabase.instance.client.from('pets').delete().eq('id', petId);
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
            icon: Icon(Icons.more_vert),
            onPressed: () {
              showModalBottomSheet(
                context: context,
                builder: (_) => Wrap(
                  children: [
                    ListTile(
                      leading: Icon(Icons.logout, color: Colors.red),
                      title:
                          Text('Logout', style: TextStyle(color: Colors.red)),
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
              : (metadata['profile_picture'] != null
                  ? NetworkImage(metadata['profile_picture'])
                  : AssetImage('assets/default_profile.png')) as ImageProvider,
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
                            // Account entry now contains name, address, password and delete actions
                            _settingsTile(Icons.person, 'Account (Name / Address / Security)', onTap: _openAccountSettings),
                            _settingsTile(Icons.notifications, 'Notification Preferences', onTap: _openNotificationPreferences),
                            _settingsTile(Icons.privacy_tip, 'Privacy Settings', onTap: _openPrivacySettings),
                            _settingsTile(Icons.palette, 'App Theme', onTap: _openThemeSettings),
                            _settingsTile(Icons.language, 'Language', onTap: _openLanguageSettings),
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

  // Open dialog for account settings (name / address / optional password / inline delete)
  void _openAccountSettings() async {
    String newName = name;
    String newAddress = address == 'No address provided' ? '' : address;
    String newPassword = '';

    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        return StatefulBuilder(builder: (ctx, setSt) {
          return SafeArea(
            child: Padding(
              padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
              child: SizedBox(
                height: MediaQuery.of(ctx).size.height * 0.9,
                child: Column(
                  children: [
                    Container(width: 40, height: 4, margin: EdgeInsets.only(top: 8), decoration: BoxDecoration(color: Colors.grey[300], borderRadius: BorderRadius.circular(2))),
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Text('Account', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: deepRed)),
                      ),
                    ),
                    Expanded(
                      child: SingleChildScrollView(
                        padding: EdgeInsets.symmetric(horizontal: 16),
                        child: Column(
                          children: [
                            TextFormField(
                              initialValue: newName,
                              decoration: InputDecoration(labelText: 'Name', border: OutlineInputBorder(borderRadius: BorderRadius.circular(12))),
                              onChanged: (v) => setSt(() => newName = v),
                            ),
                            SizedBox(height: 12),
                            TextFormField(
                              initialValue: newAddress,
                              decoration: InputDecoration(labelText: 'Address', border: OutlineInputBorder(borderRadius: BorderRadius.circular(12))),
                              onChanged: (v) => setSt(() => newAddress = v),
                            ),
                            SizedBox(height: 12),
                            TextFormField(
                              obscureText: true,
                              decoration: InputDecoration(labelText: 'New password (optional)', border: OutlineInputBorder(borderRadius: BorderRadius.circular(12))),
                              onChanged: (v) => setSt(() => newPassword = v),
                            ),
                            SizedBox(height: 16),
                            Divider(),
                            SizedBox(height: 8),
                            Align(
                              alignment: Alignment.centerLeft,
                              child: ElevatedButton(
                                style: ElevatedButton.styleFrom(backgroundColor: Colors.red.shade700),
                                child: Text('Delete Account', style: TextStyle(color: Colors.white)),
                                onPressed: () async {
                                  final confirmed = await showModalBottomSheet<bool>(
                                    context: ctx,
                                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
                                    isScrollControlled: true,
                                    builder: (c) {
                                      return SafeArea(
                                        child: SizedBox(
                                          height: MediaQuery.of(c).size.height * 0.4,
                                          child: Column(
                                            children: [
                                              Container(width: 40, height: 4, margin: EdgeInsets.only(top: 8), decoration: BoxDecoration(color: Colors.grey[300], borderRadius: BorderRadius.circular(2))),
                                              Padding(
                                                padding: const EdgeInsets.all(16),
                                                child: Align(
                                                  alignment: Alignment.centerLeft,
                                                  child: Text('Confirm delete', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: deepRed)),
                                                ),
                                              ),
                                              Padding(
                                                padding: const EdgeInsets.symmetric(horizontal: 16),
                                                child: Text('Deleting your account is permanent. Continue?'),
                                              ),
                                              Spacer(),
                                              Padding(
                                                padding: const EdgeInsets.all(16),
                                                child: Row(
                                                  children: [
                                                    Expanded(
                                                      child: OutlinedButton(
                                                        onPressed: () => Navigator.pop(c, false),
                                                        child: Text('Cancel'),
                                                      ),
                                                    ),
                                                    SizedBox(width: 12),
                                                    Expanded(
                                                      child: ElevatedButton(
                                                        style: ElevatedButton.styleFrom(backgroundColor: deepRed),
                                                        onPressed: () => Navigator.pop(c, true),
                                                        child: Text('Delete'),
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
                                  if (confirmed == true) {
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
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: Row(
                        children: [
                          Expanded(child: OutlinedButton(onPressed: () => Navigator.pop(ctx), child: Text('Cancel'))),
                          SizedBox(width: 12),
                          Expanded(
                            child: ElevatedButton(
                              style: ElevatedButton.styleFrom(backgroundColor: deepRed),
                              onPressed: () async {
                                Navigator.pop(ctx);
                                try {
                                  final supabase = Supabase.instance.client;
                                  if (newPassword.isNotEmpty) {
                                    await supabase.auth.updateUser(UserAttributes(password: newPassword, data: {
                                      'name': newName,
                                      'address': newAddress,
                                    }));
                                  } else {
                                    await supabase.auth.updateUser(UserAttributes(data: {
                                      'name': newName,
                                      'address': newAddress,
                                    }));
                                  }
                                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Account updated.')));
                                  setState(() {}); // refresh metadata display
                                } catch (e) {
                                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error updating account: $e')));
                                }
                              },
                              child: Text('Save'),
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
        });
      },
    );
  }

  // Open dialog for notification preferences
  void _openNotificationPreferences() async {
    final currentPrefs = metadata['notification_preferences'] ?? {'enabled': true};

    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (ctx) {
        bool enabled = currentPrefs['enabled'] ?? true;
        return StatefulBuilder(builder: (ctx, setSt) {
          return SafeArea(
            child: SizedBox(
              height: MediaQuery.of(ctx).size.height * 0.9,
              child: Column(
                children: [
                  Container(width: 40, height: 4, margin: EdgeInsets.only(top: 8), decoration: BoxDecoration(color: Colors.grey[300], borderRadius: BorderRadius.circular(2))),
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text('Notification Preferences', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: deepRed)),
                    ),
                  ),
                  Expanded(
                    child: SingleChildScrollView(
                      padding: EdgeInsets.symmetric(horizontal: 16),
                      child: Column(
                        children: [
                          SwitchListTile(
                            title: Text('Enable Notifications'),
                            value: enabled,
                            onChanged: (v) => setSt(() => enabled = v),
                          ),
                          // ...add other notification settings here...
                        ],
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Row(
                      children: [
                        Expanded(child: OutlinedButton(onPressed: () => Navigator.pop(ctx), child: Text('Cancel'))),
                        SizedBox(width: 12),
                        Expanded(
                          child: ElevatedButton(
                            style: ElevatedButton.styleFrom(backgroundColor: deepRed),
                            onPressed: () async {
                              Navigator.pop(ctx);
                              try {
                                await Supabase.instance.client.auth.updateUser(UserAttributes(data: {'notification_preferences': {'enabled': enabled}}));
                                ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Notification preferences updated.')));
                              } catch (e) {
                                ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error updating preferences: $e')));
                              }
                            },
                            child: Text('Save'),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          );
        });
      },
    );
  }

  // Open dialog for privacy settings
  void _openPrivacySettings() async {
    final currentPrivacy = metadata['privacy'] ?? {'profile_visible': true};

    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (ctx) {
        bool profileVisible = currentPrivacy['profile_visible'] ?? true;
        return StatefulBuilder(builder: (ctx, setSt) {
          return SafeArea(
            child: SizedBox(
              height: MediaQuery.of(ctx).size.height * 0.9,
              child: Column(
                children: [
                  Container(width: 40, height: 4, margin: EdgeInsets.only(top: 8), decoration: BoxDecoration(color: Colors.grey[300], borderRadius: BorderRadius.circular(2))),
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text('Privacy Settings', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: deepRed)),
                    ),
                  ),
                  Expanded(
                    child: SingleChildScrollView(
                      padding: EdgeInsets.symmetric(horizontal: 16),
                      child: Column(
                        children: [
                          SwitchListTile(
                            title: Text('Profile Visible'),
                            value: profileVisible,
                            onChanged: (v) => setSt(() => profileVisible = v),
                          ),
                          // ...add other privacy options...
                        ],
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Row(
                      children: [
                        Expanded(child: OutlinedButton(onPressed: () => Navigator.pop(ctx), child: Text('Cancel'))),
                        SizedBox(width: 12),
                        Expanded(
                          child: ElevatedButton(
                            style: ElevatedButton.styleFrom(backgroundColor: deepRed),
                            onPressed: () async {
                              Navigator.pop(ctx);
                              try {
                                await Supabase.instance.client.auth.updateUser(UserAttributes(data: {'privacy': {'profile_visible': profileVisible}}));
                                ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Privacy settings updated.')));
                              } catch (e) {
                                ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error updating privacy: $e')));
                              }
                            },
                            child: Text('Save'),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          );
        });
      },
    );
  }

  // Open dialog for theme settings
  void _openThemeSettings() async {
    final currentTheme = metadata['theme'] ?? 'System Default';

    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (ctx) {
        String selectedTheme = currentTheme;
        return StatefulBuilder(builder: (ctx, setSt) {
          return SafeArea(
            child: SizedBox(
              height: MediaQuery.of(ctx).size.height * 0.9,
              child: Column(
                children: [
                  Container(width: 40, height: 4, margin: EdgeInsets.only(top: 8), decoration: BoxDecoration(color: Colors.grey[300], borderRadius: BorderRadius.circular(2))),
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text('App Theme', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: deepRed)),
                    ),
                  ),
                  Expanded(
                    child: SingleChildScrollView(
                      padding: EdgeInsets.symmetric(horizontal: 16),
                      child: Column(
                        children: [
                          RadioListTile(value: 'Light', groupValue: selectedTheme, title: Text('Light'), onChanged: (v) => setSt(() => selectedTheme = v as String)),
                          RadioListTile(value: 'Dark', groupValue: selectedTheme, title: Text('Dark'), onChanged: (v) => setSt(() => selectedTheme = v as String)),
                          RadioListTile(value: 'System Default', groupValue: selectedTheme, title: Text('System Default'), onChanged: (v) => setSt(() => selectedTheme = v as String)),
                        ],
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Row(
                      children: [
                        Expanded(child: OutlinedButton(onPressed: () => Navigator.pop(ctx), child: Text('Cancel'))),
                        SizedBox(width: 12),
                        Expanded(
                          child: ElevatedButton(
                            style: ElevatedButton.styleFrom(backgroundColor: deepRed),
                            onPressed: () async {
                              Navigator.pop(ctx);
                              try {
                                await Supabase.instance.client.auth.updateUser(UserAttributes(data: {'theme': selectedTheme}));
                                ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Theme updated. Restart the app to see changes.')));
                              } catch (e) {
                                ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error updating theme: $e')));
                              }
                            },
                            child: Text('Save'),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          );
        });
      },
    );
  }

  // Open dialog for language settings
  void _openLanguageSettings() async {
    final currentLanguage = metadata['language'] ?? 'English';

    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (ctx) {
        String selectedLanguage = currentLanguage;
        return StatefulBuilder(builder: (ctx, setSt) {
          return SafeArea(
            child: SizedBox(
              height: MediaQuery.of(ctx).size.height * 0.9,
              child: Column(
                children: [
                  Container(width: 40, height: 4, margin: EdgeInsets.only(top: 8), decoration: BoxDecoration(color: Colors.grey[300], borderRadius: BorderRadius.circular(2))),
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text('Language Settings', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: deepRed)),
                    ),
                  ),
                  Expanded(
                    child: SingleChildScrollView(
                      padding: EdgeInsets.symmetric(horizontal: 16),
                      child: Column(
                        children: [
                          RadioListTile(value: 'English', groupValue: selectedLanguage, title: Text('English'), onChanged: (v) => setSt(() => selectedLanguage = v as String)),
                          RadioListTile(value: 'Filipino', groupValue: selectedLanguage, title: Text('Filipino'), onChanged: (v) => setSt(() => selectedLanguage = v as String)),
                          // ...add more languages...
                        ],
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Row(
                      children: [
                        Expanded(child: OutlinedButton(onPressed: () => Navigator.pop(ctx), child: Text('Cancel'))),
                        SizedBox(width: 12),
                        Expanded(
                          child: ElevatedButton(
                            style: ElevatedButton.styleFrom(backgroundColor: deepRed),
                            onPressed: () async {
                              Navigator.pop(ctx);
                              try {
                                await Supabase.instance.client.auth.updateUser(UserAttributes(data: {'language': selectedLanguage}));
                                ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Language updated. Restart the app to see changes.')));
                              } catch (e) {
                                ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error updating language: $e')));
                              }
                            },
                            child: Text('Save'),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          );
        });
      },
    );
  }

  // Open dialog for help & support
  void _openHelpSupport() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (ctx) {
        return SafeArea(
          child: SizedBox(
            height: MediaQuery.of(ctx).size.height * 0.9,
            child: Column(
              children: [
                Container(width: 40, height: 4, margin: EdgeInsets.only(top: 8), decoration: BoxDecoration(color: Colors.grey[300], borderRadius: BorderRadius.circular(2))),
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text('Help & Support', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: deepRed)),
                  ),
                ),
                Expanded(
                  child: SingleChildScrollView(
                    padding: EdgeInsets.symmetric(horizontal: 16),
                    child: ListBody(
                      children: [
                        Text('For assistance, please contact support@pettrackcare.com'),
                        SizedBox(height: 8),
                        Text('Visit our Help Center for FAQs and guides.'),
                      ],
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: SizedBox(
                    width: double.infinity,
                    child: OutlinedButton(onPressed: () => Navigator.pop(ctx), child: Text('Close')),
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
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (ctx) {
        return SafeArea(
          child: SizedBox(
            height: MediaQuery.of(ctx).size.height * 0.9,
            child: Column(
              children: [
                Container(width: 40, height: 4, margin: EdgeInsets.only(top: 8), decoration: BoxDecoration(color: Colors.grey[300], borderRadius: BorderRadius.circular(2))),
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text('About PetTrackCare', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: deepRed)),
                  ),
                ),
                Expanded(
                  child: SingleChildScrollView(
                    padding: EdgeInsets.symmetric(horizontal: 16),
                    child: ListBody(
                      children: [
                        Text('Version 1.0.0'),
                        Text('PetTrackCare is a comprehensive app for pet owners.'),
                        SizedBox(height: 8),
                        Text('Developed by: Your Company Name'),
                        Text('Contact: support@pettrackcare.com'),
                      ],
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: SizedBox(
                    width: double.infinity,
                    child: OutlinedButton(onPressed: () => Navigator.pop(ctx), child: Text('Close')),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<String?> _showTextInputDialog({
    required String title,
    required String hint,
    String? initialValue,
    bool isObscure = false,
  }) async {
    String value = initialValue ?? '';
    return showDialog<String>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text(title),
          content: TextField(
            obscureText: isObscure,
            decoration: InputDecoration(
              hintText: hint,
              border: OutlineInputBorder(),
            ),
            onChanged: (val) => value = val,
          ),
          actions: [
            TextButton(
              child: Text('Cancel'),
              onPressed: () => Navigator.of(context).pop(),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: deepRed),
              child: Text('Save'),
              onPressed: () => Navigator.of(context).pop(value),
            ),
          ],
        );
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
          Text("Add New Pet",
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
                  backgroundImage:
                      _petImage != null ? FileImage(_petImage!) : null,
                  child: _petImage == null
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

          _buildTextField(label: "Name", onSaved: (val) => name = val ?? ''),
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
                  : Text("Save Pet"),
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
    TextInputType keyboardType = TextInputType.text,
    required FormFieldSetter<String> onSaved,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: TextFormField(
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


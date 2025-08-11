import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:image_picker/image_picker.dart';
import 'dart:io';


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
    final response = await Supabase.instance.client
        .from('pets')
        .select()
        .eq('owner_id', user?.id);
    return List<Map<String, dynamic>>.from(response);
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
                        Column(
                          children: [
                            Expanded(
                              child: FutureBuilder<List<Map<String, dynamic>>>(
                                future: _fetchPets(),
                                builder: (context, snapshot) {
                                  if (snapshot.connectionState ==
                                      ConnectionState.waiting) {
                                    return Center(
                                        child: CircularProgressIndicator(
                                            color: deepRed));
                                  }
                                  final pets = snapshot.data ?? [];
                                  if (pets.isEmpty) {
                                    return Center(
                                        child: Text('No pets found.',
                                            style:
                                                TextStyle(color: Colors.grey)));
                                  }
                                  return ListView.builder(
  itemCount: pets.length,
  itemBuilder: (context, index) {
    final pet = pets[index];
    return Container(
      margin: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        border: Border.all(color: Colors.grey.shade300),
        borderRadius: BorderRadius.circular(12),
        color: Colors.white,
      ),
      child: ListTile(
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
      ),
    );
  },
);

                                },
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
                                      borderRadius: BorderRadius.circular(12)),
                                  elevation: 4,
                                ),
                              ),
                            ),
                          ],
                        ),

                        // ⚙️ Settings
                        // ⚙️ Settings
ListView(
  padding: EdgeInsets.all(16),
  children: [
    _settingsTile(Icons.lock, 'Change Password'),
    _settingsTile(Icons.notifications, 'Notification Preferences'),
    _settingsTile(Icons.privacy_tip, 'Privacy Settings'),
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

class _AddPetForm extends StatefulWidget {
  final VoidCallback onPetAdded;

  _AddPetForm({required this.onPetAdded});

  @override
  State<_AddPetForm> createState() => _AddPetFormState();
}

class _AddPetFormState extends State<_AddPetForm> {
  final _formKey = GlobalKey<FormState>();
  String name = '';
  String breed = '';
  int age = 0;
  String health = '';
  double weight = 0.0;
  File? _petImage;
  bool _isLoading = false;

  final ImagePicker _picker = ImagePicker();

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

  setState(() => _isLoading = true);

  try {
    final imageUrl = await _uploadPetImage(userId);

    final response = await Supabase.instance.client.from('pets').insert({
      'name': name,
      'breed': breed,
      'age': age,
      'health': health,
      'weight': weight,
      'owner_id': userId,
      'profile_picture': imageUrl, // ✅ Must match your DB column name
    }).select();

    if (response.isEmpty) {
      throw Exception("No data returned. Check your RLS policy or table columns.");
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
          _buildTextField(label: "Breed", onSaved: (val) => breed = val ?? ''),
          _buildTextField(
            label: "Age (years)",
            keyboardType: TextInputType.number,
            onSaved: (val) => age = int.tryParse(val ?? '0') ?? 0,
          ),
          _buildTextField(
              label: "Health", onSaved: (val) => health = val ?? 'Healthy'),
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


import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

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
          Padding(
            padding: EdgeInsets.symmetric(vertical: 16),
            child: Column(
              children: [
                CircleAvatar(
                  radius: 60,
                  backgroundImage: AssetImage('assets/default_profile.png'),
                ),
                SizedBox(height: 12),
                Text(name,
                    style: TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.bold,
                        color: deepRed)),
                Text(email, style: TextStyle(fontSize: 16)),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.location_on, color: Colors.grey[600], size: 16),
                    SizedBox(width: 4),
                    Text(address,
                        style:
                            TextStyle(fontSize: 14, color: Colors.grey[700]))
                  ],
                ),
              ],
            ),
          ),

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
                                        margin: EdgeInsets.symmetric(
                                            horizontal: 12, vertical: 8),
                                        decoration: BoxDecoration(
                                          border: Border.all(
                                              color: Colors.grey.shade300),
                                          borderRadius:
                                              BorderRadius.circular(12),
                                          color: Colors.white,
                                        ),
                                        child: ListTile(
                                          leading: Icon(Icons.pets,
                                              color: deepRed),
                                          title:
                                              Text(pet['name'] ?? 'Unnamed'),
                                          subtitle: Text(
                                              'Breed: ${pet['breed'] ?? 'Unknown'} | Age: ${pet['age'] ?? 0}'),
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
                        ListView(
                          padding: EdgeInsets.all(16),
                          children: [
                            _settingsTile(Icons.lock, 'Change Password'),
                            _settingsTile(Icons.notifications,
                                'Notification Preferences'),
                            _settingsTile(
                                Icons.privacy_tip, 'Privacy Settings'),
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

  bool _isLoading = false;

  void _submit() async {
    if (!_formKey.currentState!.validate()) return;
    _formKey.currentState!.save();

    final userId = Supabase.instance.client.auth.currentUser?.id;
    if (userId == null) return;

    setState(() => _isLoading = true);

    await Supabase.instance.client.from('pets').insert({
      'name': name,
      'breed': breed,
      'age': age,
      'health': health,
      'weight': weight,
      'owner_id': userId,
    });

    setState(() => _isLoading = false);
    widget.onPetAdded();
    Navigator.pop(context);
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
          _buildTextField(label: "Name", onSaved: (val) => name = val ?? ''),
          _buildTextField(label: "Breed", onSaved: (val) => breed = val ?? ''),
          _buildTextField(
            label: "Age (years)",
            keyboardType: TextInputType.number,
            onSaved: (val) => age = int.tryParse(val ?? '0') ?? 0,
          ),
          _buildTextField(
              label: "Health",
              onSaved: (val) => health = val ?? 'Healthy'),
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

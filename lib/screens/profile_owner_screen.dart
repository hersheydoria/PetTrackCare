import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class OwnerProfileScreen extends StatefulWidget {
  @override
  State<OwnerProfileScreen> createState() => _OwnerProfileScreenState();
}

class _OwnerProfileScreenState extends State<OwnerProfileScreen> with TickerProviderStateMixin {
  final user = Supabase.instance.client.auth.currentUser;
  final metadata = Supabase.instance.client.auth.currentUser?.userMetadata ?? {};

  late TabController _tabController;

  String get name => metadata['name'] ?? 'Pet Owner';
  String get role => metadata['role'] ?? 'Pet Owner';
  String get email => user?.email ?? 'No email';
  String get address => metadata['address'] ?? metadata['location'] ?? 'No address provided';

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
  }

  void _logout(BuildContext context) async {
    await Supabase.instance.client.auth.signOut();
    Navigator.pushNamedAndRemoveUntil(context, '/login', (route) => false);
  }

  void _addPet() async {
    final userId = user?.id;
    if (userId == null) return;

    await Supabase.instance.client.from('pets').insert({
      'name': 'New Pet',
      'breed': 'Unknown',
      'age': 0,
      'gender': 'Unknown',
      'owner_id': userId,
    });

    setState(() {}); // Refresh pet list
  }

  void _deletePet(String petId) async {
    await Supabase.instance.client.from('pets').delete().eq('id', petId);
    setState(() {});
  }

  void _editPet(String petId) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Edit $petId')));
  }

  Future<List<Map<String, dynamic>>> _fetchPets() async {
    final response = await Supabase.instance.client
        .from('pets')
        .select()
        .eq('owner_id', user?.id);
    return List<Map<String, dynamic>>.from(response);
  }

  Widget _buildProfileHeader() {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 16),
      child: Column(
        children: [
          CircleAvatar(
            radius: 40,
            backgroundImage: AssetImage('assets/default_profile.png'),
          ),
          SizedBox(height: 8),
          Text(name, style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
          Text(role, style: TextStyle(color: Colors.grey[600])),
          Text(email, style: TextStyle(color: Colors.grey[700])),
          Text(address, style: TextStyle(color: Colors.grey[700])),
          SizedBox(height: 12),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Owner Profile'),
        backgroundColor: Color(0xFFCB4154),
        bottom: TabBar(
          controller: _tabController,
          tabs: [
            Tab(text: 'Owned Pets'),
            Tab(text: 'Settings'),
          ],
        ),
      ),
      body: Column(
        children: [
          _buildProfileHeader(),
          Expanded(
            child: TabBarView(
              controller: _tabController,
              children: [
                // Pets Tab
                Column(
                  children: [
                    ElevatedButton(
                      onPressed: _addPet,
                      child: Text("Add Pet"),
                      style: ElevatedButton.styleFrom(backgroundColor: Color(0xFFCB4154)),
                    ),
                    Expanded(
                      child: FutureBuilder<List<Map<String, dynamic>>>(
                        future: _fetchPets(),
                        builder: (context, snapshot) {
                          if (!snapshot.hasData) {
                            return Center(child: CircularProgressIndicator());
                          }
                          final pets = snapshot.data!;
                          return ListView.builder(
                            itemCount: pets.length,
                            itemBuilder: (context, index) {
                              final pet = pets[index];
                              return Card(
                                child: ListTile(
                                  title: Text(pet['name']),
                                  subtitle: Text('${pet['breed'] ?? 'Unknown'}, Age: ${pet['age'] ?? 0}'),
                                  trailing: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      IconButton(
                                        icon: Icon(Icons.edit),
                                        onPressed: () => _editPet(pet['id']),
                                      ),
                                      IconButton(
                                        icon: Icon(Icons.delete),
                                        onPressed: () => _deletePet(pet['id']),
                                      ),
                                    ],
                                  ),
                                ),
                              );
                            },
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
                    ListTile(
                      leading: Icon(Icons.person),
                      title: Text('Account Info'),
                      onTap: () {},
                    ),
                    ListTile(
                      leading: Icon(Icons.settings),
                      title: Text('App Preferences'),
                      onTap: () {},
                    ),
                    ListTile(
                      leading: Icon(Icons.help),
                      title: Text('Help & Support'),
                      onTap: () {},
                    ),
                    ListTile(
                      leading: Icon(Icons.logout, color: Colors.red),
                      title: Text('Logout', style: TextStyle(color: Colors.red)),
                      onTap: () => _logout(context),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

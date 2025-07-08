import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class SitterProfileScreen extends StatefulWidget {
  @override
  State<SitterProfileScreen> createState() => _SitterProfileScreenState();
}

class _SitterProfileScreenState extends State<SitterProfileScreen> with TickerProviderStateMixin {
  final user = Supabase.instance.client.auth.currentUser;
  final metadata = Supabase.instance.client.auth.currentUser?.userMetadata ?? {};
  late TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
  }

  String get name => metadata['name'] ?? 'Pet Sitter';
  String get role => metadata['role'] ?? 'Pet Sitter';
  String get email => user?.email ?? 'No email';
  String get address => metadata['address'] ?? metadata['location'] ?? 'No address provided';

  void _logout(BuildContext context) async {
    await Supabase.instance.client.auth.signOut();
    Navigator.pushNamedAndRemoveUntil(context, '/login', (route) => false);
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
        title: Text('Pet Sitter Profile'),
        backgroundColor: Color(0xFFCB4154),
        bottom: TabBar(
          controller: _tabController,
          tabs: [
            Tab(text: 'Assigned Pets'),
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
                AssignedPetsTab(),
                SettingsTab(onLogout: () => _logout(context)),
              ],
            ),
          ),
        ],
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
          .in_('status', ['Accepted', 'Active']);

      setState(() {
        assignedPets = List<Map<String, dynamic>>.from(response);
        isLoading = false;
      });
    } catch (e) {
      print('Error fetching assigned pets: $e');
      setState(() => isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (isLoading) {
      return Center(child: CircularProgressIndicator());
    }

    if (assignedPets.isEmpty) {
      return Center(child: Text('No assigned pets yet.'));
    }

    return ListView.builder(
      itemCount: assignedPets.length,
      itemBuilder: (context, index) {
        final pet = assignedPets[index]['pets'];
        final owner = pet['users'];

        return Card(
          margin: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: ListTile(
            leading: Icon(Icons.pets, color: Color(0xFFCB4154)),
            title: Text(pet['name'] ?? 'Unknown Pet'),
            subtitle: Text(
              'Breed: ${pet['breed'] ?? 'N/A'}\n'
              'Age: ${pet['age'] ?? 'N/A'}\n'
              'Owner: ${owner?['name'] ?? 'Unknown'}',
            ),
          ),
        );
      },
    );
  }
}

class SettingsTab extends StatelessWidget {
  final VoidCallback onLogout;

  SettingsTab({required this.onLogout});

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: EdgeInsets.all(16),
      children: [
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
          onTap: onLogout,
        ),
      ],
    );
  }
}

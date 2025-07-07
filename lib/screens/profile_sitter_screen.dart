import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class SitterProfileScreen extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          backgroundColor: Color(0xFFCB4154),
          title: Text('Pet Sitter Profile'),
          bottom: TabBar(
            tabs: [
              Tab(text: 'Assigned Pets'),
              Tab(text: 'Settings'),
            ],
          ),
        ),
        body: TabBarView(
          children: [
            AssignedPetsTab(),
            SettingsTab(),
          ],
        ),
      ),
    );
  }
}

class AssignedPetsTab extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Center(
      child: Text('List of assigned pets will be shown here.'),
    );
  }
}

class SettingsTab extends StatelessWidget {
  final user = Supabase.instance.client.auth.currentUser;
  final metadata = Supabase.instance.client.auth.currentUser?.userMetadata ?? {};

  void _logout(BuildContext context) async {
    await Supabase.instance.client.auth.signOut();
    Navigator.pushNamedAndRemoveUntil(context, '/login', (route) => false);
  }

  @override
  Widget build(BuildContext context) {
    final name = metadata['name'] ?? 'Pet Sitter';
    final role = metadata['role'] ?? 'sitter';
    final email = user?.email ?? 'No email';

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          CircleAvatar(
            radius: 50,
            backgroundImage: AssetImage('assets/default_profile.png'), // Replace with user image if available
          ),
          SizedBox(height: 12),
          Text(name, style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
          Text(role == 'sitter' ? 'Pet Sitter' : role, style: TextStyle(color: Colors.grey[600])),
          Text(email, style: TextStyle(color: Colors.grey[700])),
          SizedBox(height: 20),

          ListTile(
            leading: Icon(Icons.edit, color: Colors.black87),
            title: Text('Edit Profile'),
            onTap: () {
              // Navigate to edit screen if implemented
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('Edit Profile tapped')),
              );
            },
          ),
          Divider(),
          ListTile(
            leading: Icon(Icons.logout, color: Colors.red),
            title: Text('Logout', style: TextStyle(color: Colors.red)),
            onTap: () => _logout(context),
          ),
        ],
      ),
    );
  }
}

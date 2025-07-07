import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class OwnerProfileScreen extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          backgroundColor: Color(0xFFCB4154),
          title: Text('Owner Profile'),
          bottom: TabBar(
            tabs: [
              Tab(text: 'Owned Pets'),
              Tab(text: 'Settings'),
            ],
          ),
        ),
        body: TabBarView(
          children: [
            OwnedPetsTab(),
            SettingsTab(),
          ],
        ),
      ),
    );
  }
}

class OwnedPetsTab extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Center(
      child: Text('List of owned pets will be shown here.'),
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
    final name = metadata['name'] ?? 'Pet Owner';
    final role = metadata['role'] ?? 'owner';
    final email = user?.email ?? 'No email';

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          CircleAvatar(
            radius: 50,
            backgroundImage: AssetImage('assets/default_profile.png'),
          ),
          SizedBox(height: 12),
          Text(name, style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
          Text(role == 'owner' ? 'Pet Owner' : role, style: TextStyle(color: Colors.grey[600])),
          Text(email, style: TextStyle(color: Colors.grey[700])),
          SizedBox(height: 20),

          ListTile(
            leading: Icon(Icons.edit, color: Colors.black87),
            title: Text('Edit Profile'),
            onTap: () {
              // Navigate to edit profile screen if needed
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

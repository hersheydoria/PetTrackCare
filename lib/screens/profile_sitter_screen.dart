import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

// Reuse owner's color palette
const deepRed = Color(0xFFB82132);
const coral = Color(0xFFD2665A);
const peach = Color(0xFFF2B28C);
const lightBlush = Color(0xFFF6DED8);

class SitterProfileScreen extends StatefulWidget {
  @override
  State<SitterProfileScreen> createState() => _SitterProfileScreenState();
}

class _SitterProfileScreenState extends State<SitterProfileScreen>
    with SingleTickerProviderStateMixin {
  final user = Supabase.instance.client.auth.currentUser;
  final metadata = Supabase.instance.client.auth.currentUser?.userMetadata ?? {};

  late TabController _tabController;

  String get name => metadata['name'] ?? 'Pet Sitter';
  String get role => metadata['role'] ?? 'Pet Sitter';
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: lightBlush,
      appBar: AppBar(
        title: Text(
          'Sitter Profile',
          style: TextStyle(color: deepRed, fontWeight: FontWeight.bold),
        ),
        centerTitle: true,
        backgroundColor: lightBlush,
        elevation: 0,
        actions: [
          IconButton(
            icon: Icon(Icons.more_vert, color: deepRed),
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
          Padding(
            padding: EdgeInsets.symmetric(vertical: 16),
            child: Column(
              children: [
                CircleAvatar(
                  radius: 60,
                  backgroundImage: AssetImage('assets/default_profile.png'),
                ),
                SizedBox(height: 12),
                Text(
                  name,
                  style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: deepRed),
                ),
                Text(email, style: TextStyle(fontSize: 16)),
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
              ],
            ),
          ),
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
                        SettingsTab(), // No logout here anymore
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

class SettingsTab extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: EdgeInsets.all(16),
      children: [
        _settingsTile(Icons.lock, 'Change Password'),
        _settingsTile(Icons.notifications, 'Notification Preferences'),
        _settingsTile(Icons.privacy_tip, 'Privacy Settings'),
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

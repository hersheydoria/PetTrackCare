import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'notification_screen.dart';

// Color palette
const deepRed = Color(0xFFB82132);
const coral = Color(0xFFD2665A);
const peach = Color(0xFFF2B28C);
const lightBlush = Color(0xFFF6DED8);

class PetProfileScreen extends StatefulWidget {
  @override
  _PetProfileScreenState createState() => _PetProfileScreenState();
}

class _PetProfileScreenState extends State<PetProfileScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  final user = Supabase.instance.client.auth.currentUser;

  Future<Map<String, dynamic>?> _fetchLatestPet() async {
    final response = await Supabase.instance.client
        .from('pets')
        .select()
        .eq('owner_id', user?.id)
        .order('id', ascending: false)
        .limit(1);

    if (response.isEmpty) return null;
    return response.first;
  }

List<Map<String, dynamic>> _pets = [];
Map<String, dynamic>? _selectedPet;

Future<void> _fetchPets() async {
  final response = await Supabase.instance.client
      .from('pets')
      .select()
      .eq('owner_id', user?.id)
      .order('id', ascending: false);

  if (response.isNotEmpty) {
    setState(() {
      _pets = List<Map<String, dynamic>>.from(response);
      _selectedPet = _pets.first; // Default to latest pet
    });
  }
}

@override
void initState() {
  super.initState();
  _tabController = TabController(length: 3, vsync: this);
  _fetchPets();
}


  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: lightBlush,
      appBar: AppBar(
        backgroundColor: const Color(0xFFCB4154),
        elevation: 0,
        title:
            Text('Pet Profile', style: TextStyle(fontWeight: FontWeight.bold)),
        actions: [
  IconButton(
    icon: Icon(Icons.notifications),
    onPressed: () {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (context) => const NotificationScreen(),
        ),
      );
    },
  ),
  PopupMenuButton<Map<String, dynamic>>(
    icon: Icon(Icons.more_vert),
    onSelected: (pet) {
      setState(() {
        _selectedPet = pet;
      });
    },
    itemBuilder: (context) {
      return _pets.map((pet) {
        return PopupMenuItem(
          value: pet,
          child: Text(
            pet['name'] ?? 'Unnamed',
            style: TextStyle(
              fontWeight: pet == _selectedPet
                  ? FontWeight.bold
                  : FontWeight.normal,
              color: pet == _selectedPet ? deepRed : Colors.black,
            ),
          ),
        );
      }).toList();
    },
  ),
],
      ),
      body: _selectedPet == null
    ? Center(child: CircularProgressIndicator(color: deepRed))
    : SingleChildScrollView(
        padding: EdgeInsets.only(bottom: 16),
        child: Column(
          children: [
            Padding(
              padding: EdgeInsets.symmetric(vertical: 16),
              child: Column(
                children: [
                  CircleAvatar(
                    radius: 60,
                    backgroundImage: _selectedPet!['profile_picture'] != null &&
                            _selectedPet!['profile_picture'].toString().isNotEmpty
                        ? NetworkImage(_selectedPet!['profile_picture'])
                        : const AssetImage('assets/pets-profile-pictures.png')
                            as ImageProvider,
                  ),
                  SizedBox(height: 12),
                  Text(_selectedPet!['name'] ?? 'Unnamed',
                      style: TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.bold,
                          color: deepRed)),
                  Text(_selectedPet!['breed'] ?? 'Unknown',
                      style: TextStyle(fontSize: 16)),
                  Text('${_selectedPet!['age']} years old',
                      style:
                          TextStyle(fontSize: 14, color: Colors.grey[700])),
                ],
              ),
            ),
          
             // ❤️ Health & ⚖️ Weight Card
Container(
  margin: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
  padding: EdgeInsets.all(16),
  decoration: BoxDecoration(
    color: peach,
    borderRadius: BorderRadius.circular(12),
    boxShadow: [BoxShadow(color: Colors.black12, blurRadius: 6)],
  ),
  child: Row(
    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
    children: [
      Column(
        children: [
          Icon(Icons.favorite, color: Colors.green),
          SizedBox(height: 4),
          Text('Health', style: TextStyle(fontWeight: FontWeight.bold)),
          Text(_selectedPet!['health'] ?? 'Unknown'),
        ],
      ),
      Column(
        children: [
          Icon(Icons.monitor_weight, color: deepRed),
          SizedBox(height: 4),
          Text('Weight', style: TextStyle(fontWeight: FontWeight.bold)),
          Text('${_selectedPet!['weight']} kg'),
        ],
      ),
    ],
  ),
),


                // 🧭 Tab Bar
                Container(
                  margin: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    border: Border.all(color: Colors.grey.shade300),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Column(
                    children: [
                      TabBar(
                        controller: _tabController,
                        indicatorColor: deepRed,
                        labelColor: deepRed,
                        unselectedLabelColor: Colors.grey,
                        tabs: [
                          Tab(icon: Icon(Icons.qr_code), text: 'QR Code'),
                          Tab(icon: Icon(Icons.location_on), text: 'Location'),
                          Tab(icon: Icon(Icons.bar_chart), text: 'Behavior'),
                        ],
                      ),
                      Divider(height: 1, color: Colors.grey.shade300),
                      Container(
                        height: 180,
                        padding: EdgeInsets.all(12),
                        child: TabBarView(
                          controller: _tabController,
                          children: [
                            _buildTabContent('QR Code Content Here'),
                            _buildTabContent('Location Content Here'),
                            _buildTabContent('Behavior Content Here'),
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
  }

  Widget _buildTabContent(String text) {
    return Center(
      child: Text(
        text,
        style:
            TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: deepRed),
      ),
    );
  }
}

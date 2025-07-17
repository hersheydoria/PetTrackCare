import 'package:flutter/material.dart';

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

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this); // QR, Location, Behavior
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
        backgroundColor: lightBlush,
        elevation: 0,
        title: Text('Pet Profile', style: TextStyle(color: deepRed, fontWeight: FontWeight.bold)),
        centerTitle: true,
        actions: [
          IconButton(
            icon: Icon(Icons.more_vert, color: deepRed),
            onPressed: () {
              // TODO: Show popup menu
            },
          )
        ],
      ),
      body: Column(
        children: [
          // 🐶 Pet Info
          Padding(
            padding: EdgeInsets.symmetric(vertical: 16),
            child: Column(
              children: [
                CircleAvatar(
                  radius: 60,
                  backgroundImage: AssetImage('assets/pet_profile.png'),
                ),
                SizedBox(height: 12),
                Text('Buddy', style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: deepRed)),
                Text('Golden Retriever', style: TextStyle(fontSize: 16)),
                Text('3 years old', style: TextStyle(fontSize: 14, color: Colors.grey[700])),
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
                    Text('Good'),
                  ],
                ),
                Column(
                  children: [
                    Icon(Icons.monitor_weight, color: deepRed),
                    SizedBox(height: 4),
                    Text('Weight', style: TextStyle(fontWeight: FontWeight.bold)),
                    Text('5.2 kg'),
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
                  height: 180, // Fixed height to match style
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
    );
  }

  Widget _buildTabContent(String text) {
    return Center(
      child: Text(
        text,
        style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: deepRed),
      ),
    );
  }
}

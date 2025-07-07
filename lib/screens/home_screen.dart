import 'package:flutter/material.dart';

class HomeScreen extends StatelessWidget {
  final String userName;
  final String userRole; // 'owner' or 'sitter'

  HomeScreen({required this.userName, required this.userRole});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Color(0xFFCB4154),
      ),
      body: SingleChildScrollView(
        padding: EdgeInsets.all(16),
        child: userRole == 'Pet Owner' ? _buildOwnerHome() : _buildSitterHome(),
      ),
    );
  }

  // Home screen for Pet Owners
  Widget _buildOwnerHome() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Hi, $userName!',
          style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
        ),
        SizedBox(height: 8),
        Text(
          "What would you like to do today?",
          style: TextStyle(fontSize: 16),
        ),
        SizedBox(height: 24),

        // Owner Quick Actions
        GridView.count(
          crossAxisCount: 2,
          shrinkWrap: true,
          physics: NeverScrollableScrollPhysics(),
          crossAxisSpacing: 12,
          mainAxisSpacing: 12,
          children: [
            _buildHomeCard(icon: Icons.pets, label: 'Track Pet', onTap: () {}),
            _buildHomeCard(icon: Icons.warning, label: 'Alerts', onTap: () {}),
            _buildHomeCard(icon: Icons.person_search, label: 'Hire Sitter', onTap: () {}),
            _buildHomeCard(icon: Icons.history, label: 'Pet History', onTap: () {}),
          ],
        ),

        SizedBox(height: 32),

        Text(
          "Daily Activity Summary",
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
        ),
        SizedBox(height: 12),
        Container(
          padding: EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(12),
            boxShadow: [BoxShadow(color: Colors.black12, blurRadius: 6)],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text("Pet: Luna 🐾"),
              SizedBox(height: 8),
              Text("Steps: 5,200"),
              Text("Mood: Happy 😊"),
              Text("Sleep: 8 hrs"),
            ],
          ),
        ),
      ],
    );
  }

  // Home screen for Pet Sitters
  Widget _buildSitterHome() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Hi, $userName!',
          style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
        ),
        SizedBox(height: 8),
        Text(
          "Here’s your dashboard for today:",
          style: TextStyle(fontSize: 16),
        ),
        SizedBox(height: 24),

        GridView.count(
          crossAxisCount: 2,
          shrinkWrap: true,
          physics: NeverScrollableScrollPhysics(),
          crossAxisSpacing: 12,
          mainAxisSpacing: 12,
          children: [
            _buildHomeCard(icon: Icons.schedule, label: 'Upcoming Bookings', onTap: () {}),
            _buildHomeCard(icon: Icons.message, label: 'Messages', onTap: () {}),
            _buildHomeCard(icon: Icons.reviews, label: 'Reviews', onTap: () {}),
            _buildHomeCard(icon: Icons.account_circle, label: 'Profile', onTap: () {}),
          ],
        ),

        SizedBox(height: 32),
        Text(
          "Earnings Summary",
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
        ),
        SizedBox(height: 12),
        Container(
          padding: EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(12),
            boxShadow: [BoxShadow(color: Colors.black12, blurRadius: 6)],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text("Today: ₱750.00"),
              Text("This Week: ₱4,500.00"),
              Text("Pending Payouts: ₱2,000.00"),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildHomeCard({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        decoration: BoxDecoration(
          color: Color(0xFFFFE5E5),
          borderRadius: BorderRadius.circular(16),
          boxShadow: [BoxShadow(color: Colors.black12, blurRadius: 4)],
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 40, color: Color(0xFFCB4154)),
            SizedBox(height: 12),
            Text(label, style: TextStyle(fontWeight: FontWeight.w600)),
          ],
        ),
      ),
    );
  }
}

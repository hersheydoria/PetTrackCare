import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

// Define the palette for reuse
const deepRed = Color(0xFFB82132);
const coral = Color(0xFFD2665A);
const peach = Color(0xFFF2B28C);
const lightBlush = Color(0xFFF6DED8);

class HomeScreen extends StatefulWidget {
  final String userId;

  HomeScreen({required this.userId});

  @override
  _HomeScreenState createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final supabase = Supabase.instance.client;

  String userName = '';
  String userRole = '';
  List<dynamic> pets = [];
  List<dynamic> sittingJobs = [];
  Map<String, dynamic> summary = {};

  bool isLoading = true;

  @override
  void initState() {
    super.initState();
    fetchUserData();
  }

  Future<void> fetchUserData() async {
    try {
      final userRes = await supabase
          .from('users')
          .select()
          .eq('id', widget.userId)
          .maybeSingle();

      if (userRes == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('User profile not found. Please contact support.')),
        );
        setState(() => isLoading = false);
        return;
      }

      final role = userRes['role'];
      final name = userRes['name'];

      setState(() {
        userRole = role;
        userName = name;
      });

      await Future.wait([
        if (role == 'Pet Owner') fetchOwnedPets(),
        if (role == 'Pet Sitter') fetchSittingJobs(),
        fetchDailySummary()
      ]);

      setState(() => isLoading = false);
    } catch (e) {
      print('❌ fetchUserData ERROR: $e');
      setState(() => isLoading = false);
    }
  }

  Future<void> fetchOwnedPets() async {
    final petRes = await supabase
        .from('pets')
        .select()
        .eq('owner_id', widget.userId);
    setState(() => pets = petRes);
  }

  Future<void> fetchSittingJobs() async {
    final jobsRes = await supabase
        .from('sitting_jobs')
        .select('*, pets(name)')
        .eq('sitter_id', widget.userId)
        .order('start_date', ascending: false);
    setState(() => sittingJobs = jobsRes);
  }

  Future<void> fetchDailySummary() async {
    try {
      final summaryRes = await supabase
          .from('behavior_logs')
          .select()
          .eq('user_id', widget.userId)
          .order('log_date', ascending: false)
          .limit(1)
          .maybeSingle();
      if (summaryRes != null) {
        setState(() => summary = summaryRes);
      }
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: lightBlush,
      body: isLoading
          ? Center(child: CircularProgressIndicator(color: deepRed))
          : SingleChildScrollView(
              padding: EdgeInsets.all(16),
              child: userRole == 'Pet Owner' ? _buildOwnerHome() : _buildSitterHome(),
            ),
    );
  }

  Widget _buildOwnerHome() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Hi, $userName!',
          style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: deepRed),
        ),
        SizedBox(height: 8),
        Text("What would you like to do today?", style: TextStyle(color: deepRed)),
        SizedBox(height: 24),
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
        Text("Daily Activity Summary", style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: coral)),
        SizedBox(height: 12),
        Container(
          padding: EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: peach,
            borderRadius: BorderRadius.circular(12),
            boxShadow: [BoxShadow(color: Colors.black12, blurRadius: 6)],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text("Pet: ${pets.isNotEmpty ? pets.first['name'] : 'No pets'} 🐾"),
              Text("Mood: ${summary['mood'] ?? 'Unknown'}"),
              Text("Sleep: ${summary['sleep_hours']?.toString() ?? '--'} hrs"),
              Text("Activity: ${summary['activity_level'] ?? 'Unknown'}"),
            ],
          ),
        )
      ],
    );
  }

  Widget _buildSitterHome() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Hi, $userName!',
          style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: deepRed),
        ),
        SizedBox(height: 8),
        Text("Here’s your dashboard for today:", style: TextStyle(color: deepRed)),
        SizedBox(height: 24),
        GridView.count(
          crossAxisCount: 2,
          shrinkWrap: true,
          physics: NeverScrollableScrollPhysics(),
          crossAxisSpacing: 12,
          mainAxisSpacing: 12,
          children: [
            _buildHomeCard(icon: Icons.schedule, label: 'Bookings', onTap: () {}),
            _buildHomeCard(icon: Icons.message, label: 'Messages', onTap: () {}),
            _buildHomeCard(icon: Icons.reviews, label: 'Reviews', onTap: () {}),
            _buildHomeCard(icon: Icons.account_circle, label: 'Profile', onTap: () {}),
          ],
        ),
        SizedBox(height: 32),
        Text("Your Assigned Jobs", style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: coral)),
        SizedBox(height: 12),
        ...sittingJobs.map((job) => Padding(
              padding: const EdgeInsets.only(bottom: 8.0),
              child: Text("Pet: ${job['pets']['name']} (${job['status']})"),
            )),
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
          color: peach,
          borderRadius: BorderRadius.circular(16),
          boxShadow: [BoxShadow(color: Colors.black12, blurRadius: 4)],
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 40, color: deepRed),
            SizedBox(height: 12),
            Text(label, style: TextStyle(fontWeight: FontWeight.w600, color: deepRed)),
          ],
        ),
      ),
    );
  }
}

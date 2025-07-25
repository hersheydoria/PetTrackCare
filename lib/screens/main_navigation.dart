import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'chat_list_screen.dart';
import 'community_screen.dart';
import 'home_screen.dart';
import 'pets_screen.dart';
import 'profile_owner_screen.dart';
import 'profile_sitter_screen.dart';
import 'notification_screen.dart';

class MainNavigation extends StatefulWidget {
  final String userId;

  const MainNavigation({Key? key, required this.userId}) : super(key: key);

  @override
  State<MainNavigation> createState() => _MainNavigationState();
}


class _MainNavigationState extends State<MainNavigation> {
  int _selectedIndex = 0;
  bool _isLoading = true;
  String userName = '';
  String userRole = '';

  @override
  void initState() {
    super.initState();
    _loadUserInfo();
  }

  Future<void> _loadUserInfo() async {
    final userId = Supabase.instance.client.auth.currentUser?.id;
    if (userId == null) return;

    final response = await Supabase.instance.client
        .from('users')
        .select('name, role')
        .eq('id', userId)
        .single();

    setState(() {
      userName = response['name'] ?? 'User';
      userRole = response['role'] ?? 'Pet Owner';
      _isLoading = false;
    });
  }

  void _onItemTapped(int index) {
    setState(() {
      _selectedIndex = index;
    });
  }

  List<Widget> getScreens() {
    return [
      HomeScreen(userId: Supabase.instance.client.auth.currentUser!.id),
      PetProfileScreen(), 
      CommunityScreen(userId: widget.userId),
      ChatListScreen(),
      userRole == 'Pet Owner' ? OwnerProfileScreen() : SitterProfileScreen(),
    ];
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    final screens = getScreens();

    return Scaffold(
      appBar: _selectedIndex == 0
        ? AppBar(
            title: const Text('PetTrackCare', style: TextStyle(fontWeight: FontWeight.bold)),
            backgroundColor: const Color(0xFFCB4154),
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
            ],
          )
        : null,
      body: screens[_selectedIndex],
      bottomNavigationBar: BottomNavigationBar(
        type: BottomNavigationBarType.fixed,
        currentIndex: _selectedIndex,
        onTap: _onItemTapped,
        selectedItemColor: const Color(0xFFCB4154),
        unselectedItemColor: Colors.grey[600],
        backgroundColor: Colors.white,
        items: const [
          BottomNavigationBarItem(icon: Icon(Icons.home), label: 'Home'),
          BottomNavigationBarItem(icon: Icon(Icons.pets), label: 'Pets'),
          BottomNavigationBarItem(icon: Icon(Icons.people), label: 'Community'),
          BottomNavigationBarItem(icon: Icon(Icons.chat_bubble), label: 'Messages'),
          BottomNavigationBarItem(icon: Icon(Icons.person), label: 'Profile'),
        ],
      ),
    );
  }
}

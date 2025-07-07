import 'package:flutter/material.dart';
import 'chat_list_screen.dart';
import 'home_screen.dart';
import 'profile_owner_screen.dart';
import 'profile_sitter_screen.dart';

class MainNavigation extends StatefulWidget {
  final String userName;
  final String userRole;

  const MainNavigation({required this.userName, required this.userRole});

  @override
  _MainNavigationState createState() => _MainNavigationState();
}

class _MainNavigationState extends State<MainNavigation> {
  int _selectedIndex = 0;

  List<Widget> getScreens() {
    return [
      HomeScreen(userName: widget.userName, userRole: widget.userRole),
      Center(child: Text('Pets Page')),
      Center(child: Text('Community Page')),
      ChatListScreen(),
      widget.userRole == 'Pet Owner' ? OwnerProfileScreen() : SitterProfileScreen(),
    ];
  }

  void _onItemTapped(int index) {
    setState(() {
      _selectedIndex = index;
    });
  }

  @override
  Widget build(BuildContext context) {
    final screens = getScreens();

    return Scaffold(
      appBar: AppBar(
        title: const Text('PetTrackCare'),
        backgroundColor: const Color(0xFFCB4154),
      ),
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

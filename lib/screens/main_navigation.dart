import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'chat_list_screen.dart';
import 'community_screen.dart';
import 'home_screen.dart';
import 'pets_screen.dart';
import 'profile_owner_screen.dart';
import 'profile_sitter_screen.dart';
import 'notification_screen.dart';
import '../widgets/missing_pet_alert_wrapper.dart';

// Color constants for consistent theming
const deepRed = Color(0xFFB82132);
const coral = Color(0xFFD2665A);
const peach = Color(0xFFF2B28C);
const lightBlush = Color(0xFFF6DED8);

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
    print('🚀 MainNavigation: getScreens called, creating PetProfileScreen');
    return [
      HomeScreen(userId: Supabase.instance.client.auth.currentUser!.id),
      PetProfileScreen(), 
      CommunityScreen(userId: widget.userId),
      ChatListScreen(),
      userRole == 'Pet Owner' ? OwnerProfileScreen(openSavedPosts: false) : SitterProfileScreen(openSavedPosts: false),
    ];
  }

  @override
  Widget build(BuildContext context) {
    print('🚀 MainNavigation: build called');
    if (_isLoading) {
      return Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    final screens = getScreens();

    return MissingPetAlertWrapper(
      child: Scaffold(
        appBar: _selectedIndex == 0
          ? AppBar(
              backgroundColor: deepRed,
              elevation: 0,
              title: Row(
                children: [
                  SizedBox(width: 12),
                  Text(
                    'PetTrackCare',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                      fontSize: 20,
                      letterSpacing: 0.5,
                    ),
                  ),
                ],
              ),
              actions: [
                Container(
                  margin: EdgeInsets.only(right: 8),
                  child: IconButton(
                    icon: Container(
                      padding: EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: Colors.white.withOpacity(0.2),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: Colors.white.withOpacity(0.3),
                          width: 1,
                        ),
                      ),
                      child: Icon(
                        Icons.notifications_outlined,
                        color: Colors.white,
                        size: 20,
                      ),
                    ),
                    onPressed: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (context) => const NotificationScreen(),
                        ),
                      );
                    },
                  ),
                ),
              ],
            )
          : null,
        body: screens[_selectedIndex],
        bottomNavigationBar: Container(
          decoration: BoxDecoration(
            color: Colors.white,
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.1),
                blurRadius: 20,
                offset: Offset(0, -5),
              ),
            ],
          ),
          child: BottomNavigationBar(
            type: BottomNavigationBarType.fixed,
            currentIndex: _selectedIndex,
            onTap: _onItemTapped,
            selectedItemColor: deepRed,
            unselectedItemColor: Colors.grey[600],
            backgroundColor: Colors.transparent,
            elevation: 0,
            selectedLabelStyle: TextStyle(
              fontWeight: FontWeight.w600,
              fontSize: 12,
            ),
            unselectedLabelStyle: TextStyle(
              fontWeight: FontWeight.w500,
              fontSize: 11,
            ),
            items: [
              BottomNavigationBarItem(
                icon: Container(
                  padding: EdgeInsets.all(8),
                  decoration: _selectedIndex == 0
                      ? BoxDecoration(
                          color: deepRed.withOpacity(0.1),
                          borderRadius: BorderRadius.circular(12),
                        )
                      : null,
                  child: Icon(Icons.home_outlined),
                ),
                activeIcon: Container(
                  padding: EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: deepRed.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(Icons.home, color: deepRed),
                ),
                label: 'Home',
              ),
              BottomNavigationBarItem(
                icon: Container(
                  padding: EdgeInsets.all(8),
                  decoration: _selectedIndex == 1
                      ? BoxDecoration(
                          color: deepRed.withOpacity(0.1),
                          borderRadius: BorderRadius.circular(12),
                        )
                      : null,
                  child: Icon(Icons.pets_outlined),
                ),
                activeIcon: Container(
                  padding: EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: deepRed.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(Icons.pets, color: deepRed),
                ),
                label: 'Pets',
              ),
              BottomNavigationBarItem(
                icon: Container(
                  padding: EdgeInsets.all(8),
                  decoration: _selectedIndex == 2
                      ? BoxDecoration(
                          color: deepRed.withOpacity(0.1),
                          borderRadius: BorderRadius.circular(12),
                        )
                      : null,
                  child: Icon(Icons.people_outline),
                ),
                activeIcon: Container(
                  padding: EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: deepRed.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(Icons.people, color: deepRed),
                ),
                label: 'Community',
              ),
              BottomNavigationBarItem(
                icon: Container(
                  padding: EdgeInsets.all(8),
                  decoration: _selectedIndex == 3
                      ? BoxDecoration(
                          color: deepRed.withOpacity(0.1),
                          borderRadius: BorderRadius.circular(12),
                        )
                      : null,
                  child: Icon(Icons.chat_bubble_outline),
                ),
                activeIcon: Container(
                  padding: EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: deepRed.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(Icons.chat_bubble, color: deepRed),
                ),
                label: 'Messages',
              ),
              BottomNavigationBarItem(
                icon: Container(
                  padding: EdgeInsets.all(8),
                  decoration: _selectedIndex == 4
                      ? BoxDecoration(
                          color: deepRed.withOpacity(0.1),
                          borderRadius: BorderRadius.circular(12),
                        )
                      : null,
                  child: Icon(Icons.person_outline),
                ),
                activeIcon: Container(
                  padding: EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: deepRed.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(Icons.person, color: deepRed),
                ),
                label: 'Profile',
              ),
            ],
          ),
        ),
      ),
    );
  }
}

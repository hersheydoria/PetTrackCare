import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'chat_list_screen.dart';
import 'community_screen.dart';
import 'home_screen.dart';
import 'pets_screen.dart';
import 'profile_owner_screen.dart';
import 'profile_sitter_screen.dart';
import 'notification_screen.dart';
import '../services/fastapi_service.dart';
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

  final FastApiService _fastApi = FastApiService.instance;

  @override
  void initState() {
    super.initState();
    _loadUserInfo();
  }

  Future<void> _loadUserInfo() async {
    try {
      final user = await _fastApi.fetchUserById(widget.userId);
      setState(() {
        userName = (user['name'] as String?) ?? user['email'] ?? 'User';
        userRole = (user['role'] as String?) ?? 'Pet Owner';
        _isLoading = false;
      });
      return;
    } catch (fastApiError) {
      print('⚠️ FastAPI user fetch failed: $fastApiError');
    }

    try {
      final response = await Supabase.instance.client
          .from('users')
          .select('name, role')
          .eq('id', widget.userId)
          .single();

      setState(() {
        userName = response['name'] ?? 'User';
        userRole = response['role'] ?? 'Pet Owner';
        _isLoading = false;
      });
    } catch (supabaseError) {
      print('⚠️ Supabase fallback user fetch failed: $supabaseError');
      setState(() {
        userName = 'User';
        userRole = 'Pet Owner';
        _isLoading = false;
      });
    }
  }

  void _onItemTapped(int index) {
    setState(() {
      _selectedIndex = index;
    });
  }

  List<Widget> getScreens() {
    print('🚀 MainNavigation: getScreens called, creating PetProfileScreen');
    return [
      HomeScreen(userId: widget.userId),
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
                      fontWeight: FontWeight.w900,
                      color: Colors.white,
                      fontSize: 22,
                      letterSpacing: 0.8,
                    ),
                  ),
                ],
              ),
              actions: [
                Container(
                  margin: EdgeInsets.only(right: 16),
                  child: IconButton(
                    icon: Container(
                      padding: EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: Colors.white.withOpacity(0.2),
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(
                          color: Colors.white.withOpacity(0.4),
                          width: 1.2,
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withOpacity(0.15),
                            blurRadius: 8,
                            offset: Offset(0, 2),
                          ),
                        ],
                      ),
                      child: Icon(
                        Icons.notifications_outlined,
                        color: Colors.white,
                        size: 22,
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
                color: Colors.black.withOpacity(0.15),
                blurRadius: 28,
                offset: Offset(0, -8),
                spreadRadius: 2,
              ),
            ],
          ),
          child: BottomNavigationBar(
            type: BottomNavigationBarType.fixed,
            currentIndex: _selectedIndex,
            onTap: _onItemTapped,
            selectedItemColor: deepRed,
            unselectedItemColor: Colors.grey[400],
            backgroundColor: Colors.transparent,
            elevation: 0,
            selectedLabelStyle: TextStyle(
              fontWeight: FontWeight.w800,
              fontSize: 12,
              letterSpacing: 0.3,
            ),
            unselectedLabelStyle: TextStyle(
              fontWeight: FontWeight.w600,
              fontSize: 11,
              letterSpacing: 0.1,
            ),
            items: [
              BottomNavigationBarItem(
                icon: Container(
                  padding: EdgeInsets.all(10),
                  child: Icon(Icons.home_outlined, size: 26),
                ),
                activeIcon: Container(
                  padding: EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [deepRed.withOpacity(0.15), deepRed.withOpacity(0.08)],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: deepRed.withOpacity(0.3), width: 1.2),
                    boxShadow: [
                      BoxShadow(
                        color: deepRed.withOpacity(0.1),
                        blurRadius: 8,
                        offset: Offset(0, 2),
                      ),
                    ],
                  ),
                  child: Icon(Icons.home, color: deepRed, size: 26),
                ),
                label: 'Home',
              ),
              BottomNavigationBarItem(
                icon: Container(
                  padding: EdgeInsets.all(10),
                  child: Icon(Icons.pets, size: 26),
                ),
                activeIcon: Container(
                  padding: EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [deepRed.withOpacity(0.15), deepRed.withOpacity(0.08)],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: deepRed.withOpacity(0.3), width: 1.2),
                    boxShadow: [
                      BoxShadow(
                        color: deepRed.withOpacity(0.1),
                        blurRadius: 8,
                        offset: Offset(0, 2),
                      ),
                    ],
                  ),
                  child: Icon(Icons.pets, color: deepRed, size: 26),
                ),
                label: 'Pets',
              ),
              BottomNavigationBarItem(
                icon: Container(
                  padding: EdgeInsets.all(10),
                  child: Icon(Icons.people_outline, size: 26),
                ),
                activeIcon: Container(
                  padding: EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [deepRed.withOpacity(0.15), deepRed.withOpacity(0.08)],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: deepRed.withOpacity(0.3), width: 1.2),
                    boxShadow: [
                      BoxShadow(
                        color: deepRed.withOpacity(0.1),
                        blurRadius: 8,
                        offset: Offset(0, 2),
                      ),
                    ],
                  ),
                  child: Icon(Icons.people, color: deepRed, size: 26),
                ),
                label: 'Community',
              ),
              BottomNavigationBarItem(
                icon: Container(
                  padding: EdgeInsets.all(10),
                  child: Icon(Icons.chat_bubble_outline, size: 26),
                ),
                activeIcon: Container(
                  padding: EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [deepRed.withOpacity(0.15), deepRed.withOpacity(0.08)],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: deepRed.withOpacity(0.3), width: 1.2),
                    boxShadow: [
                      BoxShadow(
                        color: deepRed.withOpacity(0.1),
                        blurRadius: 8,
                        offset: Offset(0, 2),
                      ),
                    ],
                  ),
                  child: Icon(Icons.chat_bubble, color: deepRed, size: 26),
                ),
                label: 'Messages',
              ),
              BottomNavigationBarItem(
                icon: Container(
                  padding: EdgeInsets.all(10),
                  child: Icon(Icons.person_outline, size: 26),
                ),
                activeIcon: Container(
                  padding: EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [deepRed.withOpacity(0.15), deepRed.withOpacity(0.08)],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: deepRed.withOpacity(0.3), width: 1.2),
                    boxShadow: [
                      BoxShadow(
                        color: deepRed.withOpacity(0.1),
                        blurRadius: 8,
                        offset: Offset(0, 2),
                      ),
                    ],
                  ),
                  child: Icon(Icons.person, color: deepRed, size: 26),
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

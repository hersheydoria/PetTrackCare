import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/fastapi_service.dart';
import 'main_navigation.dart';

const deepRed = Color(0xFFB82132);
const coral = Color(0xFFD2665A);
const peach = Color(0xFFF2B28C);
const lightBlush = Color(0xFFF6DED8);

class OnboardingScreen extends StatefulWidget {
  final String userId;
  const OnboardingScreen({Key? key, required this.userId}) : super(key: key);
  @override
  _OnboardingScreenState createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  PageController _pageController = PageController();
  int _currentIndex = 0;
  String? _userRole;
  bool _isLoading = true;
  List<Map<String, dynamic>> _pages = [];
  final FastApiService _fastApi = FastApiService.instance;

  // Pet Owner specific pages
  final List<Map<String, dynamic>> _petOwnerPages = [
    {
      'title': 'Welcome to PetTrackCare',
      'subtitle': 'Your Complete Pet Care Companion',
      'description': 'Track, monitor, and care for your beloved pets with comprehensive health and location tracking features.',
      'icon': Icons.pets,
      'color': deepRed,
    },
    {
      'title': 'Pet Health Monitoring',
      'subtitle': 'Track Your Pet\'s Wellbeing',
      'description': 'Log daily food and water intake, bathroom habits, activity level, and clinical signs. The system analyzes your pet\'s behavior logs and generates actionable health insights.',
      'icon': Icons.favorite,
      'color': coral,
    },
    {
      'title': 'GPS Location Tracking',
      'subtitle': 'Never Lose Your Pet Again',
      'description': 'Real-time GPS tracking with location history, community alerts, and instant notifications.',
      'icon': Icons.location_on,
      'color': peach,
    },
    {
      'title': 'Pet Community',
      'subtitle': 'Connect & Share with Pet Lovers',
      'description': 'Join a vibrant community of pet owners and share your pet\'s adventures.',
      'icon': Icons.group,
      'color': coral,
    },
  ];

  // Pet Sitter specific pages
  final List<Map<String, dynamic>> _petSitterPages = [
    {
      'title': 'Welcome to PetTrackCare',
      'subtitle': 'Professional Pet Care Platform',
      'description': 'Connect with pet owners and provide trusted pet sitting services in your community.',
      'icon': Icons.pets,
      'color': deepRed,
    },
    {
      'title': 'Pet Sitting Services',
      'subtitle': 'Build Your Pet Care Business',
      'description': 'Create your sitter profile, set your rates, and manage bookings with pet owners.',
      'icon': Icons.pets_outlined,
      'color': peach,
    },
    {
      'title': 'Client Pet Monitoring',
      'subtitle': 'Track Pets Under Your Care',
      'description': 'Monitor the health and location of pets you\'re caring for and provide updates to owners.',
      'icon': Icons.favorite,
      'color': coral,
    },
    {
      'title': 'Pet Community',
      'subtitle': 'Network with Pet Owners',
      'description': 'Build relationships with pet owners and grow your reputation in the community.',
      'icon': Icons.group,
      'color': coral,
    },
  ];

  @override
  void initState() {
    super.initState();
    _getUserRole();
  }

  Future<void> _getUserRole() async {
    try {
      final user = await _fastApi.fetchUserById(widget.userId);
      final roleValue = user['role'];
      final role = roleValue is String && roleValue.isNotEmpty ? roleValue : 'Pet Owner';
      setState(() {
        _userRole = role;
        _pages = _userRole == 'Pet Sitter' ? _petSitterPages : _petOwnerPages;
        _isLoading = false;
      });
    } catch (e) {
      // Default to pet owner if role not found
      setState(() {
        _userRole = 'Pet Owner';
        _pages = _petOwnerPages;
        _isLoading = false;
      });
    }
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  void _completeOnboarding() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('onboarding_completed', true);
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(builder: (context) => MainNavigation(userId: widget.userId)),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return Scaffold(
        body: Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              stops: [0.0, 0.3, 0.6, 1.0],
              colors: [
                Color(0xFFF6DED8),
                Color(0xFFFFE5E5),
                Color(0xFFE8C5C8),
                Color(0xFFF2B28C),
              ],
            ),
          ),
          child: Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Container(
                  padding: EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.9),
                    borderRadius: BorderRadius.circular(20),
                    boxShadow: [
                      BoxShadow(
                        color: deepRed.withOpacity(0.1),
                        blurRadius: 20,
                        offset: Offset(0, 10),
                      ),
                    ],
                  ),
                  child: CircularProgressIndicator(color: deepRed, strokeWidth: 3),
                ),
                SizedBox(height: 30),
                Container(
                  padding: EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.9),
                    borderRadius: BorderRadius.circular(15),
                    boxShadow: [
                      BoxShadow(
                        color: coral.withOpacity(0.1),
                        blurRadius: 15,
                        offset: Offset(0, 5),
                      ),
                    ],
                  ),
                  child: Text(
                    'Preparing your experience...',
                    style: TextStyle(
                      color: deepRed,
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            stops: [0.0, 0.3, 0.6, 1.0],
            colors: [
              Color(0xFFF6DED8),
              Color(0xFFFFE5E5),
              Color(0xFFE8C5C8),
              Color(0xFFF2B28C),
            ],
          ),
        ),
        child: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: EdgeInsets.all(20),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text('PetTrackCare', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: deepRed)),
                  if (_currentIndex < _pages.length - 1)
                    TextButton(onPressed: _completeOnboarding, child: Text('Skip')),
                ],
              ),
            ),
            // Role indicator
            Container(
              margin: EdgeInsets.symmetric(horizontal: 20, vertical: 10),
              padding: EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: _userRole == 'Pet Sitter' ? peach.withOpacity(0.2) : coral.withOpacity(0.2),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: _userRole == 'Pet Sitter' ? peach : coral, width: 1),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    _userRole == 'Pet Sitter' ? Icons.work : Icons.pets,
                    color: _userRole == 'Pet Sitter' ? peach : coral,
                    size: 16,
                  ),
                  SizedBox(width: 8),
                  Text(
                    _userRole == 'Pet Sitter' ? 'Pet Sitter Experience' : 'Pet Owner Experience',
                    style: TextStyle(
                      color: _userRole == 'Pet Sitter' ? peach : coral,
                      fontWeight: FontWeight.w600,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: PageView.builder(
                controller: _pageController,
                onPageChanged: (index) => setState(() => _currentIndex = index),
                itemCount: _pages.length,
                itemBuilder: (context, index) {
                  final page = _pages[index];
                  return Padding(
                    padding: EdgeInsets.all(20),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(page['icon'], size: 80, color: page['color']),
                        SizedBox(height: 40),
                        Text(page['title'], style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: deepRed), textAlign: TextAlign.center),
                        SizedBox(height: 10),
                        Text(page['subtitle'], style: TextStyle(fontSize: 16, color: coral), textAlign: TextAlign.center),
                        SizedBox(height: 20),
                        Text(page['description'], style: TextStyle(fontSize: 14, color: Colors.grey[600]), textAlign: TextAlign.center),
                      ],
                    ),
                  );
                },
              ),
            ),
            Padding(
              padding: EdgeInsets.all(20),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  if (_currentIndex > 0)
                    TextButton(
                      onPressed: () => _pageController.previousPage(duration: Duration(milliseconds: 300), curve: Curves.ease),
                      child: Text('Previous'),
                    )
                  else
                    SizedBox(width: 80),
                  Text('${_currentIndex + 1} of ${_pages.length}'),
                  ElevatedButton(
                    onPressed: () {
                      if (_currentIndex < _pages.length - 1) {
                        _pageController.nextPage(duration: Duration(milliseconds: 300), curve: Curves.ease);
                      } else {
                        _completeOnboarding();
                      }
                    },
                    style: ElevatedButton.styleFrom(backgroundColor: deepRed, foregroundColor: Colors.white),
                    child: Text(_currentIndex == _pages.length - 1 ? 'Get Started' : 'Next'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    ),
    );
  }
}

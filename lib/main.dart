import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart'; // + add
import 'screens/login_screen.dart';
import 'screens/registration_screen.dart';
import 'screens/main_navigation.dart';
import 'screens/location_picker.dart';
import 'screens/reset_password_screen.dart';
import 'screens/notification_screen.dart';
import 'screens/post_detail_screen.dart';
import 'screens/pet_alert_screen.dart';
import 'screens/profile_owner_screen.dart';
import 'screens/profile_sitter_screen.dart';
import 'widgets/missing_pet_alert_wrapper.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await dotenv.load(fileName: ".env");
  await Supabase.initialize(
    url: dotenv.env['SUPABASE_URL'] ?? '',
    anonKey: dotenv.env['SUPABASE_ANON_KEY'] ?? '',
  );
  runApp(PetTrackCareApp());
}

class PetTrackCareApp extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final uri = Uri.base;
    String initialRoute = '/login';

    // Handle reset password redirect
    if (uri.path == '/reset-password') {
      initialRoute = '/reset-password';
    }
    
    print('🚀 PetTrackCareApp: Starting with initial route: $initialRoute');
    
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'PetTrackCare',
      theme: ThemeData(
        primaryColor: Color(0xFFB82132), // Main red color
        scaffoldBackgroundColor: Color(0xFFF6DED8), // Light blush background
        fontFamily: 'Roboto',
        colorScheme: ColorScheme.fromSwatch().copyWith(
          primary: Color(0xFFB82132), // AppBar, buttons
          secondary: Color(0xFFD2665A), // Accent color
          background: Color(0xFFF6DED8), // Background color
          surface: Color(0xFFF2B28C), // Cards, surfaces
          onPrimary: Colors.white, // Text on primary
          onSecondary: Colors.white, // Text on secondary
          onBackground: Colors.black, // Text on background
          onSurface: Colors.black, // Text on surfaces
        ),
        textTheme: Theme.of(context).textTheme.apply(
          bodyColor: Colors.black,
          displayColor: Colors.black,
        ),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            backgroundColor: Color(0xFFB82132),
            foregroundColor: Colors.white,
          ),
        ),
        appBarTheme: AppBarTheme(
          backgroundColor: Color(0xFFB82132),
          foregroundColor: Colors.white,
        ),
      ),
      initialRoute: initialRoute,
      routes: {
        '/login': (_) {
          print('🚀 Route: /login accessed');
          return LoginScreen();
        },
        '/register': (_) {
          print('🚀 Route: /register accessed');
          return RegistrationScreen();
        },
        '/home': (_) {
            print('🚀 Route: /home accessed - initializing MissingPetAlertWrapper');
            final user = Supabase.instance.client.auth.currentUser;
            return MissingPetAlertWrapper(
              child: MainNavigation(userId: user!.id),
            );
          },
        '/location_picker': (_) {
          print('🚀 Route: /location_picker accessed - initializing MissingPetAlertWrapper');
          return MissingPetAlertWrapper(
            child: LocationPicker(),
          );
        },
        '/reset-password': (_) {
          print('🚀 Route: /reset-password accessed');
          return ResetPasswordScreen();
        },
        '/notification' : (_) {
          print('🚀 Route: /notification accessed - initializing MissingPetAlertWrapper');
          return MissingPetAlertWrapper(
            child: NotificationScreen(),
          );
        },
         '/postDetail': (context) {
          print('🚀 Route: /postDetail accessed - initializing MissingPetAlertWrapper');
          return MissingPetAlertWrapper(
            child: PostDetailScreen.fromRoute(context),
          );
        },
          '/petAlert': (context) {
          print('🚀 Route: /petAlert accessed - initializing MissingPetAlertWrapper');
          return MissingPetAlertWrapper(
            child: PetAlertScreen.fromRoute(context),
          );
        },
        '/profile_owner': (_) {
          print('🚀 Route: /profile_owner accessed - initializing MissingPetAlertWrapper');
          return MissingPetAlertWrapper(
            child: OwnerProfileScreen(openSavedPosts: false),
          );
        },
        '/profile_sitter': (_) {
          print('🚀 Route: /profile_sitter accessed - initializing MissingPetAlertWrapper');
          return MissingPetAlertWrapper(
            child: SitterProfileScreen(openSavedPosts: false),
          );
        },
      },
    );
  }
}

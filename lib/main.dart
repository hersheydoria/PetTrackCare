import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart'; // + add
import 'screens/login_screen.dart';
import 'screens/registration_screen.dart';
import 'screens/main_navigation.dart';
import 'screens/location_picker.dart';
import 'screens/reset_password_screen.dart';
import 'screens/notification_screen.dart';

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
        '/login': (_) => LoginScreen(),
        '/register': (_) => RegistrationScreen(),
        '/home': (_) {
            final user = Supabase.instance.client.auth.currentUser;
            return MainNavigation(userId: user!.id);
          },
        '/location_picker': (_) => LocationPicker(),
        '/reset-password': (_) => ResetPasswordScreen(),
        '/notification' : (_) => NotificationScreen(),
      },
    );
  }
}

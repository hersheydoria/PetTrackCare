import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'screens/login_screen.dart';
import 'screens/registration_screen.dart';
import 'screens/main_navigation.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Supabase.initialize(
    url: 'https://gcqmkaoyoruajayvubei.supabase.co',
    anonKey: 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImdjcW1rYW95b3J1YWpheXZ1YmVpIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NTE4OTA1MjAsImV4cCI6MjA2NzQ2NjUyMH0.Rmp3OH4MjgUwN5UXI7mGD5b4loZ5dQFr4NHV-wP5tGc',
  );
  runApp(PetTrackCareApp());
}

class PetTrackCareApp extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'PetTrackCare',
      theme: ThemeData(
        primaryColor: Color(0xFFCB4154),
        scaffoldBackgroundColor: Color(0xFFFFCCCB),
        fontFamily: 'Roboto',
        textTheme: Theme.of(context).textTheme.apply(bodyColor: Colors.black),
      ),
      initialRoute: '/login',
      routes: {
        '/login': (_) => LoginScreen(),
        '/register': (_) => RegistrationScreen(),
        '/home': (context) {
        final args = ModalRoute.of(context)!.settings.arguments as Map<String, dynamic>;
        return MainNavigation(
          userName: args['userName'],
          userRole: args['userRole'],
        );
      },
      },
    );
  }
}

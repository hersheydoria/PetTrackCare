import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'main_navigation.dart';

class LoginScreen extends StatefulWidget {
  @override
  _LoginScreenState createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _formKey = GlobalKey<FormState>();
  final emailController = TextEditingController();
  final passwordController = TextEditingController();

  bool isLoading = false;
  bool showPassword = false;
  bool isCheckingSession = true; // New: flag to gate UI while checking existing session

  @override
  void initState() {
    super.initState();
    _checkExistingSession();
  }

  // New: check persisted Supabase session and skip login if present
  Future<void> _checkExistingSession() async {
    final session = Supabase.instance.client.auth.currentSession;
    final user = session?.user;
    if (user != null) {
      // Check user status in public.users table
      try {
        final userData = await Supabase.instance.client
            .from('users')
            .select('status')
            .eq('id', user.id)
            .single();
        
        final userStatus = userData['status']?.toString().toLowerCase();
        
        if (userStatus == 'inactive') {
          // Sign out the user immediately if inactive
          await Supabase.instance.client.auth.signOut();
          if (mounted) {
            setState(() => isCheckingSession = false);
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('Your account has been deactivated. Please contact support.'),
                backgroundColor: Colors.red,
              ),
            );
          }
          return;
        }
      } catch (e) {
        print('Error checking user status: $e');
        // If we can't check status, allow the session to continue but log the error
      }

      WidgetsBinding.instance.addPostFrameCallback((_) {
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(
            builder: (_) => MainNavigation(userId: user.id),
          ),
        );
      });
    } else {
      if (mounted) setState(() => isCheckingSession = false);
    }
  }

  void _login() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() => isLoading = true);

    try {
      final response = await Supabase.instance.client.auth.signInWithPassword(
        email: emailController.text.trim(),
        password: passwordController.text.trim(),
      );

      final user = response.user;

      if (user != null) {
        // Check user status in public.users table
        try {
          final userData = await Supabase.instance.client
              .from('users')
              .select('status')
              .eq('id', user.id)
              .single();
          
          final userStatus = userData['status']?.toString().toLowerCase();
          
          if (userStatus == 'inactive') {
            // Sign out the user immediately
            await Supabase.instance.client.auth.signOut();
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('Your account has been deactivated. Please contact support.'),
                backgroundColor: Colors.red,
              ),
            );
            setState(() => isLoading = false);
            return;
          }
        } catch (e) {
          print('Error checking user status: $e');
          // If we can't check status, allow login but log the error
        }

        Navigator.pushReplacement(
          context,
          MaterialPageRoute(
            builder: (_) => MainNavigation(userId: user.id), // ✅ userId passed
          ),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Login failed: No user found.')),
        );
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Login failed: ${e.toString()}')),
      );
    }

    setState(() => isLoading = false);
  }

  void _resetPassword() async {
    final email = emailController.text.trim();

    if (email.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Please enter your email to reset your password')),
      );
      return;
    }

    try {
      await Supabase.instance.client.auth.resetPasswordForEmail(email);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Password reset email sent')),
      );
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Reset failed: ${e.toString()}')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    // New: show a loader while verifying existing session
    if (isCheckingSession) {
      return Scaffold(
        backgroundColor: Color(0xFFF6DED8),
        body: Center(child: CircularProgressIndicator()),
      );
    }

    return Scaffold(
      backgroundColor: Color(0xFFF6DED8),
      body: Center(
        child: SingleChildScrollView(
          padding: EdgeInsets.all(24),
          child: Container(
            padding: EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(20),
              boxShadow: [
                BoxShadow(color: Colors.black12, blurRadius: 12, offset: Offset(0, 6)),
              ],
            ),
            child: Form(
              key: _formKey,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Image.asset('assets/logo.png', height: 120),
                  SizedBox(height: 16),
                  Text(
                    "Welcome to PetTrackCare",
                    style: TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.bold,
                      color: Color(0xFFB82132),
                    ),
                  ),
                  SizedBox(height: 24),
                  TextFormField(
                    controller: emailController,
                    keyboardType: TextInputType.emailAddress,
                    decoration: InputDecoration(
                      labelText: 'Email',
                      prefixIcon: Icon(Icons.email),
                      filled: true,
                      fillColor: Color(0xFFFFE5E5),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                    validator: (value) {
                      if (value == null || value.trim().isEmpty) {
                        return 'Email is required';
                      } else if (!RegExp(r'^[\w-\.]+@([\w-]+\.)+[\w]{2,4}$').hasMatch(value.trim())) {
                        return 'Enter a valid email address';
                      }
                      return null;
                    },
                  ),
                  SizedBox(height: 16),
                  TextFormField(
                    controller: passwordController,
                    obscureText: !showPassword,
                    decoration: InputDecoration(
                      labelText: 'Password',
                      prefixIcon: Icon(Icons.lock),
                      suffixIcon: IconButton(
                        icon: Icon(showPassword ? Icons.visibility : Icons.visibility_off),
                        onPressed: () => setState(() => showPassword = !showPassword),
                      ),
                      filled: true,
                      fillColor: Color(0xFFFFE5E5),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                    validator: (value) {
                      if (value == null || value.trim().isEmpty) {
                        return 'Password is required';
                      } else if (value.trim().length < 6) {
                        return 'Password must be at least 6 characters';
                      }
                      return null;
                    },
                  ),
                  SizedBox(height: 20),
                  ElevatedButton(
                    onPressed: isLoading ? null : _login,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Color(0xFFB82132),
                      padding: EdgeInsets.symmetric(horizontal: 60, vertical: 14),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                    child: isLoading
                        ? CircularProgressIndicator(color: Colors.white)
                        : Text('Login', style: TextStyle(fontSize: 16)),
                  ),
                  SizedBox(height: 8),
                  TextButton(
                    onPressed: _resetPassword,
                    child: Text('Forgot Password?', style: TextStyle(color: Color(0xFFB82132))),
                  ),
                  TextButton(
                    onPressed: () => Navigator.pushNamed(context, '/register'),
                    child: Text("Don't have an account? Register", style: TextStyle(color: Color(0xFFB82132))),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

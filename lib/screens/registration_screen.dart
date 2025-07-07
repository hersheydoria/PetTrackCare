import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class RegistrationScreen extends StatefulWidget {
  @override
  _RegistrationScreenState createState() => _RegistrationScreenState();
}

class _RegistrationScreenState extends State<RegistrationScreen> {
  final nameController = TextEditingController();
  final emailController = TextEditingController();
  final passwordController = TextEditingController();
  final confirmController = TextEditingController();
  final locationController = TextEditingController();
  String selectedRole = 'Pet Owner';
  bool isLoading = false;

  void _register() async {
    if (passwordController.text != confirmController.text) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Passwords do not match.'),
      ));
      return;
    }

    setState(() => isLoading = true);

    try {
      final response = await Supabase.instance.client.auth.signUp(
        email: emailController.text.trim(),
        password: passwordController.text.trim(),
        data: {
          'name': nameController.text.trim(),
          'role': selectedRole,
          'location': locationController.text.trim(),
        },
      );

      if (response.user != null) {
        Navigator.pushReplacementNamed(context, '/home');
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Registration failed: ${e.toString()}'),
      ));
    }

    setState(() => isLoading = false);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Color(0xFFFFCCCB),
      appBar: AppBar(
        title: Text('Register'),
        backgroundColor: Color(0xFFCB4154),
      ),
      body: SingleChildScrollView(
        padding: EdgeInsets.all(24),
        child: Column(
          children: [
            DropdownButtonFormField<String>(
              value: selectedRole,
              items: ['Pet Owner', 'Pet Sitter']
                  .map((role) => DropdownMenuItem(value: role, child: Text(role)))
                  .toList(),
              onChanged: (val) => setState(() => selectedRole = val!),
              decoration: InputDecoration(labelText: 'Role'),
            ),
            TextField(controller: nameController, decoration: InputDecoration(labelText: 'Name')),
            TextField(controller: emailController, decoration: InputDecoration(labelText: 'Email')),
            TextField(
              controller: passwordController,
              obscureText: true,
              decoration: InputDecoration(labelText: 'Password'),
            ),
            TextField(
              controller: confirmController,
              obscureText: true,
              decoration: InputDecoration(labelText: 'Confirm Password'),
            ),
            TextField(controller: locationController, decoration: InputDecoration(labelText: 'Location')),
            SizedBox(height: 20),
            ElevatedButton(
              onPressed: isLoading ? null : _register,
              style: ElevatedButton.styleFrom(
                backgroundColor: Color(0xFFCB4154),
                padding: EdgeInsets.symmetric(horizontal: 80, vertical: 12),
              ),
              child: isLoading
                  ? CircularProgressIndicator(color: Colors.white)
                  : Text('Register'),
            ),
          ],
        ),
      ),
    );
  }
}

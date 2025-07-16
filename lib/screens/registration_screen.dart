import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class RegistrationScreen extends StatefulWidget {
  @override
  _RegistrationScreenState createState() => _RegistrationScreenState();
}

class _RegistrationScreenState extends State<RegistrationScreen> {
  final _formKey = GlobalKey<FormState>();

  final nameController = TextEditingController();
  final emailController = TextEditingController();
  final passwordController = TextEditingController();
  final confirmController = TextEditingController();
  final locationController = TextEditingController();

  String selectedRole = 'Pet Owner';
  bool isLoading = false;
  bool showPassword = false;
  bool showConfirm = false;

  double? latitude;
  double? longitude;

  void _register() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() => isLoading = true);

    try {
      final response = await Supabase.instance.client.auth.signUp(
        email: emailController.text.trim(),
        password: passwordController.text.trim(),
        data: {
          'name': nameController.text.trim(),
          'role': selectedRole,
          'location': locationController.text.trim(),
          'latitude': latitude,
          'longitude': longitude,
        },
      );

      if (response.user != null) {
        Navigator.pushReplacementNamed(context, '/home');
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Registration failed: Check password strength or email format.')),
      );
    }

    setState(() => isLoading = false);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF6DED8),
      appBar: AppBar(
        title: const Text('Register'),
        backgroundColor: const Color(0xFFB82132),
      ),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Container(
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(20),
              boxShadow: const [
                BoxShadow(color: Colors.black12, blurRadius: 12, offset: Offset(0, 6)),
              ],
            ),
            child: Form(
              key: _formKey,
              child: Column(
                children: [
                  Image.asset('assets/logo.png', height: 100),
                  const SizedBox(height: 16),
                  const Text(
                    "Welcome to PetTrackCare",
                    style: TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.bold,
                      color: Color(0xFFB82132),
                    ),
                  ),
                  const SizedBox(height: 24),
                  DropdownButtonFormField<String>(
                    value: selectedRole,
                    items: ['Pet Owner', 'Pet Sitter']
                        .map((role) => DropdownMenuItem(value: role, child: Text(role)))
                        .toList(),
                    onChanged: (val) => setState(() => selectedRole = val!),
                    decoration: _inputDecoration('Role'),
                  ),
                  const SizedBox(height: 16),
                  TextFormField(
                    controller: nameController,
                    decoration: _inputDecoration('Name'),
                    validator: (value) => value!.trim().isEmpty ? 'Name is required' : null,
                  ),
                  const SizedBox(height: 16),
                  TextFormField(
                    controller: emailController,
                    keyboardType: TextInputType.emailAddress,
                    decoration: _inputDecoration('Email'),
                    validator: (value) {
                      if (value!.trim().isEmpty) return 'Email is required';
                      if (!RegExp(r'^[\w-\.]+@([\w-]+\.)+[\w]{2,4}$').hasMatch(value.trim())) {
                        return 'Enter a valid email';
                      }
                      return null;
                    },
                  ),
                  const SizedBox(height: 16),
                  TextFormField(
                    controller: passwordController,
                    obscureText: !showPassword,
                    decoration: _inputDecoration(
                      'Password',
                      suffixIcon: IconButton(
                        icon: Icon(showPassword ? Icons.visibility : Icons.visibility_off),
                        onPressed: () => setState(() => showPassword = !showPassword),
                      ),
                    ),
                    validator: (value) {
                      if (value == null || value.isEmpty) {
                        return 'Password is required';
                      }

                      final password = value.trim();
                      if (password.length < 8) return 'Must be at least 8 characters';
                      if (!RegExp(r'[a-z]').hasMatch(password)) return 'Must contain a lowercase letter';
                      if (!RegExp(r'[A-Z]').hasMatch(password)) return 'Must contain an uppercase letter';
                      if (!RegExp(r'\d').hasMatch(password)) return 'Must contain a digit';
                      if (!RegExp(r'[!@#\$&*~_.,%^()\-\+=]').hasMatch(password)) return 'Must contain a symbol';

                      return null;
                    }
                  ),
                  const SizedBox(height: 16),
                  TextFormField(
                    controller: confirmController,
                    obscureText: !showConfirm,
                    decoration: _inputDecoration(
                      'Confirm Password',
                      suffixIcon: IconButton(
                        icon: Icon(showConfirm ? Icons.visibility : Icons.visibility_off),
                        onPressed: () => setState(() => showConfirm = !showConfirm),
                      ),
                    ),
                    validator: (value) =>
                        value != passwordController.text ? 'Passwords do not match' : null,
                  ),
                  const SizedBox(height: 16),
                  TextFormField(
                    controller: locationController,
                    readOnly: true,
                    decoration: _inputDecoration(
                      'Tap to select your location',
                      suffixIcon: const Icon(Icons.location_on),
                    ),
                    onTap: () async {
                      final result = await Navigator.pushNamed(context, '/location_picker');

                      if (result != null && result is Map<String, dynamic>) {
                        setState(() {
                          locationController.text = result['address'];
                          latitude = result['latitude'];
                          longitude = result['longitude'];
                        });
                      }
                    },
                    validator: (value) =>
                        value!.trim().isEmpty ? 'Location is required' : null,
                  ),
                  const SizedBox(height: 24),
                  ElevatedButton(
                    onPressed: isLoading ? null : _register,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFFB82132),
                      padding: const EdgeInsets.symmetric(horizontal: 60, vertical: 14),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    child: isLoading
                        ? const CircularProgressIndicator(color: Colors.white)
                        : const Text('Register', style: TextStyle(fontSize: 16)),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  InputDecoration _inputDecoration(String label, {Widget? suffixIcon}) {
    return InputDecoration(
      labelText: label,
      filled: true,
      fillColor: const Color(0xFFFFE5E5),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
      suffixIcon: suffixIcon,
    );
  }
}

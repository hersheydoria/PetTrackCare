import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:flutter/foundation.dart'; // kDebugMode

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
  // removed latitudeController and longitudeController

  String selectedRole = 'Pet Owner';
  bool isLoading = false;
  bool showPassword = false;
  bool showConfirm = false;

  // removed double? latitude; double? longitude;

  void _register() async {
    if (!_formKey.currentState!.validate()) return;

    // removed parsing/guard for latitude/longitude; address is validated by the form

    setState(() => isLoading = true);

    try {
      // sanitize address to avoid DB constraint issues
      final rawAddress = locationController.text.trim();
      final safeAddress = rawAddress.isEmpty
          ? '-'
          : (rawAddress.length > 255 ? rawAddress.substring(0, 255) : rawAddress);

      final response = await Supabase.instance.client.auth.signUp(
        email: emailController.text.trim(),
        password: passwordController.text.trim(),
        data: {
          // keep user details in auth.users metadata; exclude role and email to reduce conflicts
          'name': nameController.text.trim(),
          'full_name': nameController.text.trim(),
          'address': safeAddress,
        },
      );

      if (response.user != null) {
        if (response.session == null) {
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Verification email sent. Please confirm to finish registration.')),
          );
          setState(() => isLoading = false);
          return;
        }

        // profiles upsert (only id + role)
        try {
          if (kDebugMode) {
            print('Upserting role $selectedRole for user ${response.user!.id}');
          }
          // add created_at timestamp (UTC ISO8601)
          final createdAt = DateTime.now().toUtc().toIso8601String();

          await Supabase.instance.client.from('users').upsert(
            {
              'id': response.user!.id,
              'role': selectedRole, // only id and role in profiles
              'created_at': createdAt,
            },
            onConflict: 'id',
          );
        } on PostgrestException catch (e) {
          if (kDebugMode) {
            print('profiles upsert PostgrestException ${e.code}: ${e.message} ${e.details}');
          }
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('Could not save your role due to a server constraint. You can continue and set it later.')),
            );
          }
        } catch (e) {
          if (kDebugMode) {
            print('profiles upsert error: $e');
          }
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('Profile role save encountered an issue. You can continue and set it later.')),
            );
          }
        }

        if (!mounted) return;
        Navigator.pushReplacementNamed(context, '/home');
      } else {
        // No user returned and no exception thrown: treat as unknown error
        throw Exception('Signup failed. Please try again later.');
      }
    } on AuthException catch (e) {
      if (kDebugMode) {
        print('AuthException on signUp: ${e.message}');
      }
      final msg = e.message.toLowerCase();
      String friendly = e.message;
      if (msg.contains('already registered') || msg.contains('duplicate key')) {
        friendly = 'Email already registered. Try logging in instead.';
      } else if (
        msg.contains('database error saving new user') ||
        msg.contains('unexpected_failure') ||
        msg.contains('constraint') ||
        msg.contains('violates')
      ) {
        friendly = 'Signup failed due to a server constraint. Please try again later or contact support.';
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(friendly)));
      }
    } catch (e) {
      if (kDebugMode) {
        print('Unhandled signup error: $e');
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString())));
      }
    } finally {
      if (mounted) setState(() => isLoading = false);
    }
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
                  // single full location input
                  TextFormField(
                    controller: locationController,
                    decoration: _inputDecoration('Address'),
                    validator: (value) =>
                        value!.trim().isEmpty ? 'Address is required' : null,
                  ),
                  // removed latitude and longitude input fields
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

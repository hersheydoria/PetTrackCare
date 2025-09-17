import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:flutter/foundation.dart'; // kDebugMode
import 'dart:convert';
import 'package:http/http.dart' as http;

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

  String selectedRole = 'Pet Owner';
  bool isLoading = false;
  bool showPassword = false;
  bool showConfirm = false;

  // Address dropdown state
  List<Map<String, dynamic>> provinces = [];
  List<Map<String, dynamic>> municipalities = [];
  List<Map<String, dynamic>> barangays = [];

  List<String> districts = [
    'Purok 1',
    'Purok 2',
    'Purok 3',
    'Purok 4',
    'Purok 5',
    'District 1',
    'District 2',
    'District 3',
  ]; // Static list for districts/puroks

  String? selectedProvince;
  String? selectedMunicipality;
  String? selectedBarangay;
  String? selectedDistrict;

  String? selectedProvinceCode;
  String? selectedMunicipalityCode;
  String? selectedBarangayCode;

  void _register() async {
    if (!_formKey.currentState!.validate()) return;

    // Validate address dropdowns
    if (selectedProvince == null ||
        selectedMunicipality == null ||
        selectedBarangay == null ||
        selectedDistrict == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Please select your complete address.')),
      );
      return;
    }

    setState(() => isLoading = true);

    try {
      final safeAddress =
          '${selectedDistrict!}, ${selectedBarangay!}, ${selectedMunicipality!}, ${selectedProvince!}';

      final response = await Supabase.instance.client.auth.signUp(
        email: emailController.text.trim(),
        password: passwordController.text.trim(),
        data: {
          // Store basic info and address components in auth.users metadata
          'name': nameController.text.trim(),
          'full_name': nameController.text.trim(),
          'role': selectedRole,
          'province': selectedProvince,
          'municipality': selectedMunicipality,
          'barangay': selectedBarangay,
          'district': selectedDistrict,
        },
      );

      if (response.user != null) {
        // Insert user data regardless of session status
        // This ensures data is saved even with email verification required
        try {
          if (kDebugMode) {
            print('Inserting user data for user ${response.user!.id}');
            print('Address: $safeAddress');
            print('Status: Active');
          }

          final userPayload = {
            'id': response.user!.id,
            'name': nameController.text.trim(),
            'role': selectedRole,
            'address': safeAddress,
            'status': 'Active',
            'created_at': DateTime.now().toUtc().toIso8601String(),
          };

          if (kDebugMode) {
            print('User payload: $userPayload');
          }

          // Try direct insert first
          try {
            final insertResult = await Supabase.instance.client
                .from('users')
                .insert(userPayload)
                .select();
            if (kDebugMode) {
              print('Insert result: $insertResult');
            }
          } catch (insertError) {
            if (kDebugMode) {
              print('Insert failed, trying upsert: $insertError');
            }
            // If insert fails (maybe user already exists), try upsert
            final upsertResult = await Supabase.instance.client
                .from('users')
                .upsert(userPayload, onConflict: 'id')
                .select();
            if (kDebugMode) {
              print('Upsert result: $upsertResult');
            }
          }

          // If user registered as Pet Sitter, create sitter profile
          if (selectedRole == 'Pet Sitter') {
            try {
              final sitterPayload = {
                'user_id': response.user!.id,
                'bio': null, // User can fill this later
                'experience': 0, // Default to 0, user can update later
                'is_available': true,
                'hourly_rate': null, // User can set this later
              };

              final sitterResult = await Supabase.instance.client
                  .from('sitters')
                  .insert(sitterPayload)
                  .select();
              
              if (kDebugMode) {
                print('Sitter profile created: $sitterResult');
              }
            } catch (sitterError) {
              if (kDebugMode) {
                print('Failed to create sitter profile: $sitterError');
              }
              // Don't fail the entire registration if sitter profile creation fails
              // User can complete their sitter profile later
            }
          }

          // Verify the data was actually stored
          final verifyResult = await Supabase.instance.client
              .from('users')
              .select('id, name, role, address, status')
              .eq('id', response.user!.id)
              .maybeSingle();

          if (kDebugMode) {
            print('Verification query result: $verifyResult');
          }

          if (verifyResult == null) {
            if (kDebugMode) {
              print('❌ User data was not found after insert/upsert!');
            }
          } else {
            if (kDebugMode) {
              print('✅ User data verified: $verifyResult');
            }
          }
        } on PostgrestException catch (e) {
          if (kDebugMode) {
            print('Database insert PostgrestException ${e.code}: ${e.message} ${e.details}');
          }
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('Could not save user data: ${e.message}')),
            );
          }
        } catch (e) {
          if (kDebugMode) {
            print('Database insert error: $e');
          }
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('Could not save user data. Please try again.')),
            );
          }
        }

        // Handle different registration scenarios
        if (response.session == null) {
          // Email verification required
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Verification email sent. Please confirm to finish registration.')),
          );
        } else {
          // Immediate login (if email verification is disabled)
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Registration successful!')),
          );
        }

        // Always redirect to login after registration
        if (mounted) {
          Navigator.pushReplacementNamed(context, '/login');
        }
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
      } else if (msg.contains('database error saving new user') ||
          msg.contains('unexpected_failure') ||
          msg.contains('constraint') ||
          msg.contains('violates')) {
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
  void initState() {
    super.initState();
    _fetchProvinces();
  }

  Future<void> _fetchProvinces() async {
    final res = await http.get(Uri.parse('https://psgc.gitlab.io/api/provinces/'));
    if (res.statusCode == 200) {
      final data = jsonDecode(res.body) as List;
      final provinceList = data.cast<Map<String, dynamic>>();
      provinceList.sort((a, b) => (a['name'] as String).compareTo(b['name'] as String));
      setState(() {
        provinces = provinceList;
      });
    }
  }

  Future<void> _fetchMunicipalities(String provinceCode) async {
    final res = await http.get(Uri.parse('https://psgc.gitlab.io/api/provinces/$provinceCode/cities-municipalities/'));
    if (res.statusCode == 200) {
      final data = jsonDecode(res.body) as List;
      final municipalityList = data.cast<Map<String, dynamic>>();
      municipalityList.sort((a, b) => (a['name'] as String).compareTo(b['name'] as String));
      setState(() {
        municipalities = municipalityList;
        selectedMunicipality = null;
        selectedMunicipalityCode = null;
        barangays = [];
        selectedBarangay = null;
        selectedBarangayCode = null;
        selectedDistrict = null;
      });
    }
  }

  Future<void> _fetchBarangays(String cityMunCode) async {
    final res = await http.get(Uri.parse('https://psgc.gitlab.io/api/cities-municipalities/$cityMunCode/barangays/'));
    if (res.statusCode == 200) {
      final data = jsonDecode(res.body) as List;
      final barangayList = data.cast<Map<String, dynamic>>();
      barangayList.sort((a, b) => (a['name'] as String).compareTo(b['name'] as String));
      setState(() {
        barangays = barangayList;
        selectedBarangay = null;
        selectedBarangayCode = null;
        selectedDistrict = null;
      });
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
                  // Add divider and address label here
                  Divider(thickness: 1, color: Colors.grey[400]),
                  const SizedBox(height: 8),
                  const Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      'Address Information',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 16,
                        color: Color(0xFFB82132),
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  // Address dropdowns
                  DropdownButtonFormField<String>(
                    value: selectedProvince,
                    items: provinces
                        .map<DropdownMenuItem<String>>((prov) => DropdownMenuItem<String>(
                              value: prov['name'] as String,
                              child: Text(prov['name'] as String),
                            ))
                        .toList(),
                    onChanged: (val) {
                      final code = provinces.firstWhere((p) => p['name'] == val)['code'];
                      setState(() {
                        selectedProvince = val;
                        selectedProvinceCode = code;
                      });
                      if (code != null) _fetchMunicipalities(code);
                    },
                    decoration: _inputDecoration('Province'),
                    validator: (value) => value == null ? 'Select province' : null,
                  ),
                  const SizedBox(height: 16),
                  DropdownButtonFormField<String>(
                    value: selectedMunicipality,
                    items: municipalities
                        .map<DropdownMenuItem<String>>((mun) => DropdownMenuItem<String>(
                              value: mun['name'] as String,
                              child: Text(mun['name'] as String),
                            ))
                        .toList(),
                    onChanged: (val) {
                      final code = municipalities.firstWhere((m) => m['name'] == val)['code'];
                      setState(() {
                        selectedMunicipality = val;
                        selectedMunicipalityCode = code;
                      });
                      if (code != null) _fetchBarangays(code);
                    },
                    decoration: _inputDecoration('Municipality'),
                    validator: (value) => value == null ? 'Select municipality' : null,
                  ),
                  const SizedBox(height: 16),
                  DropdownButtonFormField<String>(
                    value: selectedBarangay,
                    items: barangays
                        .map<DropdownMenuItem<String>>((brgy) => DropdownMenuItem<String>(
                              value: brgy['name'] as String,
                              child: Text(brgy['name'] as String),
                            ))
                        .toList(),
                    onChanged: (val) {
                      final code = barangays.firstWhere((b) => b['name'] == val)['code'];
                      setState(() {
                        selectedBarangay = val;
                        selectedBarangayCode = code;
                      });
                    },
                    decoration: _inputDecoration('Barangay'),
                    validator: (value) => value == null ? 'Select barangay' : null,
                  ),
                  const SizedBox(height: 16),
                  // Add District/Purok dropdown
                  DropdownButtonFormField<String>(
                    value: selectedDistrict,
                    items: districts
                        .map<DropdownMenuItem<String>>((dist) => DropdownMenuItem<String>(
                              value: dist,
                              child: Text(dist),
                            ))
                        .toList(),
                    onChanged: (val) {
                      setState(() {
                        selectedDistrict = val;
                      });
                    },
                    decoration: _inputDecoration('District/Purok'),
                    validator: (value) => value == null ? 'Select district/purok' : null,
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
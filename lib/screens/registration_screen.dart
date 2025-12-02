import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart'; // kDebugMode
import 'dart:convert';
import 'package:http/http.dart' as http;
import '../services/fastapi_service.dart';

class RegistrationScreen extends StatefulWidget {
  @override
  _RegistrationScreenState createState() => _RegistrationScreenState();
}

class _RegistrationScreenState extends State<RegistrationScreen>
    with TickerProviderStateMixin {
  final _formKey = GlobalKey<FormState>();

  final nameController = TextEditingController();
  final emailController = TextEditingController();
  final passwordController = TextEditingController();
  final confirmController = TextEditingController();

  String selectedRole = 'Pet Owner';
  bool isLoading = false;
  bool showPassword = false;
  bool showConfirm = false;

  late AnimationController _animationController;
  late Animation<double> _fadeAnimation;
  late Animation<Offset> _slideAnimation;

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

    if (selectedProvince == null ||
        selectedMunicipality == null ||
        selectedBarangay == null ||
        selectedDistrict == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please select your complete address.')),
      );
      return;
    }

    setState(() => isLoading = true);

    try {
      final safeAddress =
          '${selectedDistrict!}, ${selectedBarangay!}, ${selectedMunicipality!}, ${selectedProvince!}';

      await FastApiService.instance.signUp(
        email: emailController.text.trim(),
        password: passwordController.text.trim(),
        name: nameController.text.trim(),
        role: selectedRole,
        address: safeAddress,
      );

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Registration submitted! Please log in once your account is active.')),
        );
        Navigator.pushReplacementNamed(context, '/login');
      }
    } catch (e) {
      if (kDebugMode) {
        print('FastAPI signup error: $e');
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.toString())),
        );
      }
    } finally {
      if (mounted) setState(() => isLoading = false);
    }
  }

  @override
  void initState() {
    super.initState();
    _fetchProvinces();
    
    _animationController = AnimationController(
      duration: const Duration(milliseconds: 1200),
      vsync: this,
    );
    
    _fadeAnimation = Tween<double>(
      begin: 0.0,
      end: 1.0,
    ).animate(CurvedAnimation(
      parent: _animationController,
      curve: Curves.easeInOut,
    ));
    
    _slideAnimation = Tween<Offset>(
      begin: const Offset(0, 0.3),
      end: Offset.zero,
    ).animate(CurvedAnimation(
      parent: _animationController,
      curve: Curves.easeOutQuart,
    ));
    
    _animationController.forward();
  }

  @override
  void dispose() {
    _animationController.dispose();
    super.dispose();
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
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            stops: [0.0, 0.5, 1.0],
            colors: [
              Color(0xFFF6DED8),
              Color(0xFFFFE5E5),
              Color(0xFFE8C5C8),
            ],
          ),
        ),
        child: SafeArea(
          child: AnimatedBuilder(
            animation: _animationController,
            builder: (context, child) {
              return FadeTransition(
                opacity: _fadeAnimation,
                child: SlideTransition(
                  position: _slideAnimation,
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      children: [
                        // Enhanced Back button
                        Row(
                          children: [
                            Container(
                              decoration: BoxDecoration(
                                color: Colors.white.withOpacity(0.95),
                                borderRadius: BorderRadius.circular(16),
                                boxShadow: [
                                  BoxShadow(
                                    color: const Color(0xFFB82132).withOpacity(0.2),
                                    blurRadius: 12,
                                    offset: const Offset(0, 4),
                                  ),
                                ],
                              ),
                              child: IconButton(
                                icon: const Icon(
                                  Icons.arrow_back_ios_new,
                                  color: Color(0xFFB82132),
                                  size: 20,
                                ),
                                onPressed: () => Navigator.pop(context),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 24),
                        
                        // Enhanced Form Container
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(32),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(28),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withOpacity(0.08),
                                blurRadius: 30,
                                offset: const Offset(0, 15),
                                spreadRadius: 0,
                              ),
                              BoxShadow(
                                color: const Color(0xFFB82132).withOpacity(0.1),
                                blurRadius: 20,
                                offset: const Offset(0, 10),
                                spreadRadius: 0,
                              ),
                            ],
                          ),
                          child: Form(
                            key: _formKey,
                            child: Column(
                              children: [
                                // Enhanced Logo and Title
                                Container(
                                  padding: const EdgeInsets.only(top: 20, left: 20, right: 20, bottom: 8),
                                  child: Image.asset('assets/logo.png', height: 120),
                                ),
                                const SizedBox(height: 10),
                                
                                Container(
                                  margin: const EdgeInsets.symmetric(horizontal: 10),
                                  child: Column(
                                    children: [
                                      const Text(
                                        "Welcome to",
                                        style: TextStyle(
                                          fontSize: 20,
                                          fontWeight: FontWeight.w600,
                                          fontFamily: 'SF Pro Display',
                                          color: Color(0xFFB82132),
                                          letterSpacing: 0.5,
                                          height: 1.2,
                                        ),
                                        textAlign: TextAlign.center,
                                      ),
                                      const SizedBox(height: 4),
                                      const Text(
                                        "PetTrackCare",
                                        style: TextStyle(
                                          fontSize: 36,
                                          fontWeight: FontWeight.w900,
                                          fontFamily: 'SF Pro Display',
                                          color: Color(0xFFB82132),
                                          letterSpacing: -0.5,
                                          height: 0.95,
                                          fontFeatures: [
                                            FontFeature.enable('kern'),
                                          ],
                                        ),
                                        textAlign: TextAlign.center,
                                      ),
                                    ],
                                  ),
                                ),
                                
                                const SizedBox(height: 8),
                                Text(
                                  "Create your account to get started",
                                  style: TextStyle(
                                    fontSize: 16,
                                    color: Colors.grey[600],
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                                const SizedBox(height: 32),
                                
                                // Enhanced Role Selection
                                _buildRoleSelector(),
                                const SizedBox(height: 20),
                                
                                // Enhanced Form Fields
                                _buildEnhancedTextField(
                                  controller: nameController,
                                  label: 'Full Name',
                                  icon: Icons.person_outline,
                                  validator: (value) => value!.trim().isEmpty ? 'Name is required' : null,
                                ),
                                const SizedBox(height: 16),
                                
                                _buildEnhancedTextField(
                                  controller: emailController,
                                  label: 'Email Address',
                                  icon: Icons.email_outlined,
                                  keyboardType: TextInputType.emailAddress,
                                  validator: (value) {
                                    if (value!.trim().isEmpty) return 'Email is required';
                                    if (!RegExp(r'^[\w-\.]+@([\w-]+\.)+[\w]{2,4}$').hasMatch(value.trim())) {
                                      return 'Enter a valid email';
                                    }
                                    return null;
                                  },
                                ),
                                const SizedBox(height: 16),
                                
                                _buildEnhancedTextField(
                                  controller: passwordController,
                                  label: 'Password',
                                  icon: Icons.lock_outline,
                                  obscureText: !showPassword,
                                  suffixIcon: IconButton(
                                    icon: Icon(
                                      showPassword ? Icons.visibility : Icons.visibility_off,
                                      color: const Color(0xFFB82132),
                                    ),
                                    onPressed: () => setState(() => showPassword = !showPassword),
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
                                
                                _buildEnhancedTextField(
                                  controller: confirmController,
                                  label: 'Confirm Password',
                                  icon: Icons.lock_outline,
                                  obscureText: !showConfirm,
                                  suffixIcon: IconButton(
                                    icon: Icon(
                                      showConfirm ? Icons.visibility : Icons.visibility_off,
                                      color: const Color(0xFFB82132),
                                    ),
                                    onPressed: () => setState(() => showConfirm = !showConfirm),
                                  ),
                                  validator: (value) =>
                                      value != passwordController.text ? 'Passwords do not match' : null,
                                ),
                                const SizedBox(height: 24),
                                
                                // Address Section
                                _buildSectionHeader('Address Information'),
                                const SizedBox(height: 16),
                                
                                _buildEnhancedDropdown(
                                  value: selectedProvince,
                                  items: provinces.map((prov) => prov['name'] as String).toList(),
                                  label: 'Province',
                                  icon: Icons.location_on_outlined,
                                  onChanged: (val) {
                                    final code = provinces.firstWhere((p) => p['name'] == val)['code'];
                                    setState(() {
                                      selectedProvince = val;
                                      selectedProvinceCode = code;
                                    });
                                    if (code != null) _fetchMunicipalities(code);
                                  },
                                ),
                                const SizedBox(height: 16),
                                
                                _buildEnhancedDropdown(
                                  value: selectedMunicipality,
                                  items: municipalities.map((mun) => mun['name'] as String).toList(),
                                  label: 'Municipality',
                                  icon: Icons.location_city_outlined,
                                  onChanged: (val) {
                                    final code = municipalities.firstWhere((m) => m['name'] == val)['code'];
                                    setState(() {
                                      selectedMunicipality = val;
                                      selectedMunicipalityCode = code;
                                    });
                                    if (code != null) _fetchBarangays(code);
                                  },
                                ),
                                const SizedBox(height: 16),
                                
                                _buildEnhancedDropdown(
                                  value: selectedBarangay,
                                  items: barangays.map((brgy) => brgy['name'] as String).toList(),
                                  label: 'Barangay',
                                  icon: Icons.home_outlined,
                                  onChanged: (val) {
                                    final code = barangays.firstWhere((b) => b['name'] == val)['code'];
                                    setState(() {
                                      selectedBarangay = val;
                                      selectedBarangayCode = code;
                                    });
                                  },
                                ),
                                const SizedBox(height: 16),
                                
                                _buildEnhancedDropdown(
                                  value: selectedDistrict,
                                  items: districts,
                                  label: 'District/Purok',
                                  icon: Icons.maps_home_work_outlined,
                                  onChanged: (val) {
                                    setState(() {
                                      selectedDistrict = val;
                                    });
                                  },
                                ),
                                const SizedBox(height: 32),
                                
                                // Enhanced Register Button
                                _buildEnhancedButton(),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _buildRoleSelector() {
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: const Color(0xFFF6DED8).withOpacity(0.3),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFB82132).withOpacity(0.2)),
      ),
      child: Row(
        children: [
          Expanded(
            child: GestureDetector(
              onTap: () => setState(() => selectedRole = 'Pet Owner'),
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 16),
                decoration: BoxDecoration(
                  color: selectedRole == 'Pet Owner' 
                      ? const Color(0xFFB82132) 
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  'Pet Owner',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: selectedRole == 'Pet Owner' 
                        ? Colors.white 
                        : const Color(0xFFB82132),
                    fontWeight: FontWeight.w600,
                    fontSize: 16,
                  ),
                ),
              ),
            ),
          ),
          Expanded(
            child: GestureDetector(
              onTap: () => setState(() => selectedRole = 'Pet Sitter'),
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 16),
                decoration: BoxDecoration(
                  color: selectedRole == 'Pet Sitter' 
                      ? const Color(0xFFB82132) 
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  'Pet Sitter',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: selectedRole == 'Pet Sitter' 
                        ? Colors.white 
                        : const Color(0xFFB82132),
                    fontWeight: FontWeight.w600,
                    fontSize: 16,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEnhancedTextField({
    required TextEditingController controller,
    required String label,
    required IconData icon,
    TextInputType? keyboardType,
    bool obscureText = false,
    Widget? suffixIcon,
    String? Function(String?)? validator,
  }) {
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.04),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: TextFormField(
        controller: controller,
        keyboardType: keyboardType,
        obscureText: obscureText,
        validator: validator,
        style: const TextStyle(
          fontSize: 16,
          fontWeight: FontWeight.w500,
        ),
        decoration: InputDecoration(
          labelText: label,
          prefixIcon: Icon(icon, color: const Color(0xFFB82132)),
          suffixIcon: suffixIcon,
          filled: true,
          fillColor: const Color(0xFFF8F9FA),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(16),
            borderSide: BorderSide.none,
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(16),
            borderSide: const BorderSide(color: Color(0xFFB82132), width: 2),
          ),
          errorBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(16),
            borderSide: const BorderSide(color: Colors.red, width: 1),
          ),
          focusedErrorBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(16),
            borderSide: const BorderSide(color: Colors.red, width: 2),
          ),
          labelStyle: TextStyle(
            color: Colors.grey[600],
            fontWeight: FontWeight.w500,
          ),
          contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 20),
        ),
      ),
    );
  }

  Widget _buildEnhancedDropdown({
    required String? value,
    required List<String> items,
    required String label,
    required IconData icon,
    required Function(String?) onChanged,
  }) {
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.04),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: DropdownButtonFormField<String>(
        value: value,
        items: items.map((item) => DropdownMenuItem(
          value: item,
          child: Text(item),
        )).toList(),
        onChanged: onChanged,
        validator: (value) => value == null ? 'Please select $label' : null,
        decoration: InputDecoration(
          labelText: label,
          prefixIcon: Icon(icon, color: const Color(0xFFB82132)),
          filled: true,
          fillColor: const Color(0xFFF8F9FA),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(16),
            borderSide: BorderSide.none,
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(16),
            borderSide: const BorderSide(color: Color(0xFFB82132), width: 2),
          ),
          labelStyle: TextStyle(
            color: Colors.grey[600],
            fontWeight: FontWeight.w500,
          ),
          contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 20),
        ),
        style: const TextStyle(
          fontSize: 16,
          fontWeight: FontWeight.w500,
          color: Colors.black87,
        ),
      ),
    );
  }

  Widget _buildSectionHeader(String title) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            const Color(0xFFB82132).withOpacity(0.1),
            const Color(0xFFE91E63).withOpacity(0.1),
          ],
        ),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFB82132).withOpacity(0.2)),
      ),
      child: Row(
        children: [
          Icon(
            Icons.location_on,
            color: const Color(0xFFB82132),
            size: 20,
          ),
          const SizedBox(width: 8),
          Text(
            title,
            style: const TextStyle(
              fontWeight: FontWeight.bold,
              fontSize: 16,
              color: Color(0xFFB82132),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEnhancedButton() {
    return Container(
      width: double.infinity,
      height: 56,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        gradient: const LinearGradient(
          colors: [Color(0xFFB82132), Color(0xFFE91E63)],
          begin: Alignment.centerLeft,
          end: Alignment.centerRight,
        ),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFFB82132).withOpacity(0.4),
            blurRadius: 15,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: ElevatedButton(
        onPressed: isLoading ? null : _register,
        style: ElevatedButton.styleFrom(
          backgroundColor: Colors.transparent,
          shadowColor: Colors.transparent,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
        ),
        child: isLoading
            ? const SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(
                  color: Colors.white,
                  strokeWidth: 2,
                ),
              )
            : const Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.app_registration, color: Colors.white),
                  SizedBox(width: 8),
                  Text(
                    'Create Account',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:image_picker/image_picker.dart';
import 'package:url_launcher/url_launcher.dart';
import 'dart:io';
import '../widgets/saved_posts_modal.dart';
import 'pets_screen.dart';

// Reuse owner's color palette
const deepRed = Color(0xFFB82132);
const coral = Color(0xFFD2665A);
const peach = Color(0xFFF2B28C);
const lightBlush = Color(0xFFF6DED8);

class SitterProfileScreen extends StatefulWidget {
  final bool openSavedPosts;
  
  const SitterProfileScreen({Key? key, this.openSavedPosts = false}) : super(key: key);
  
  @override
  State<SitterProfileScreen> createState() => _SitterProfileScreenState();
}

class _SitterProfileScreenState extends State<SitterProfileScreen> with SingleTickerProviderStateMixin {
  final user = Supabase.instance.client.auth.currentUser;
  final metadata = Supabase.instance.client.auth.currentUser?.userMetadata ?? {};
  Map<String, dynamic> userData = {}; // Store user data from public.users table

  late TabController _tabController;

  String get name => userData['name'] ?? metadata['name'] ?? 'Pet Sitter';
  String get role => metadata['role'] ?? 'Pet Sitter';
  String get email => user?.email ?? 'No email';
  String get address => userData['address'] ?? metadata['address'] ?? metadata['location'] ?? 'No address provided';

  File? _profileImage;
  final ImagePicker _picker = ImagePicker();
  
  // Helper to refresh user and metadata after update
  Future<void> _refreshUserMetadata() async {
    // Load user data from public.users table (name, profile_picture, and address)
    try {
      final response = await Supabase.instance.client
          .from('users')
          .select('name, profile_picture, address')
          .eq('id', user?.id ?? '')
          .single();
      
      setState(() {
        userData = response;
      });
    } catch (e) {
      print('Error loading user data: $e');
    }
  }

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _refreshUserMetadata(); // Load user data from database
    
    // If openSavedPosts is true, switch to settings tab and open saved posts
    if (widget.openSavedPosts) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _tabController.animateTo(1); // Switch to settings tab (index 1)
        Future.delayed(Duration(milliseconds: 300), () {
          _openSavedPosts(); // Open saved posts modal
        });
      });
    }
  }

  void _logout(BuildContext context) async {
    await Supabase.instance.client.auth.signOut();
    Navigator.pushNamedAndRemoveUntil(context, '/login', (route) => false);
  }

  // Add settings dialog handlers (copied from profile_owner_screen.dart)
  void _openAccountSettings() async {
    String newName = name;
    String newAddress = address == 'No address provided' ? '' : address;
    bool isLoading = false;

    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: lightBlush,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setSt) {
            return Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.white,
                    lightBlush.withOpacity(0.3),
                  ],
                ),
                borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.2),
                    blurRadius: 20,
                    offset: Offset(0, -5),
                  ),
                ],
              ),
              child: SafeArea(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Enhanced Header
                    Container(
                      padding: EdgeInsets.all(20),
                      decoration: BoxDecoration(
                        color: deepRed.withOpacity(0.05),
                        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
                      ),
                      child: Row(
                        children: [
                          Container(
                            padding: EdgeInsets.all(8),
                            decoration: BoxDecoration(
                              color: deepRed.withOpacity(0.1),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Icon(Icons.account_circle, color: deepRed, size: 20),
                          ),
                          SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              'Account Settings',
                              style: TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.bold,
                                color: deepRed,
                              ),
                            ),
                          ),
                          IconButton(
                            onPressed: () => Navigator.pop(ctx),
                            icon: Icon(Icons.close, color: Colors.grey[600]),
                          ),
                        ],
                      ),
                    ),
                    // Enhanced Content
                    Flexible(
                      child: SingleChildScrollView(
                        padding: EdgeInsets.all(24),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            // Email Field (Read-only)
                            Text(
                              'Email Address',
                              style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                                color: Colors.grey[700],
                              ),
                            ),
                            SizedBox(height: 8),
                            Container(
                              decoration: BoxDecoration(
                                color: Colors.grey.shade50,
                                borderRadius: BorderRadius.circular(16),
                                border: Border.all(color: Colors.grey.shade300),
                              ),
                              child: TextField(
                                controller: TextEditingController(text: email),
                                enabled: false,
                                style: TextStyle(
                                  color: Colors.grey[600],
                                  fontSize: 16,
                                  fontWeight: FontWeight.w500,
                                ),
                                decoration: InputDecoration(
                                  hintText: 'Email address',
                                  hintStyle: TextStyle(color: Colors.grey[500]),
                                  border: InputBorder.none,
                                  contentPadding: EdgeInsets.all(20),
                                  prefixIcon: Padding(
                                    padding: EdgeInsets.all(16),
                                    child: Icon(Icons.email, color: Colors.grey[400], size: 20),
                                  ),
                                ),
                              ),
                            ),
                            SizedBox(height: 20),
                            // Name Field
                            Text(
                              'Full Name',
                              style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                                color: Colors.grey[700],
                              ),
                            ),
                            SizedBox(height: 8),
                            Container(
                              decoration: BoxDecoration(
                                color: Colors.white,
                                borderRadius: BorderRadius.circular(16),
                                border: Border.all(color: coral.withOpacity(0.3)),
                                boxShadow: [
                                  BoxShadow(
                                    color: Colors.black.withOpacity(0.05),
                                    blurRadius: 10,
                                    offset: Offset(0, 2),
                                  ),
                                ],
                              ),
                              child: TextField(
                                controller: TextEditingController(text: newName),
                                onChanged: (value) => newName = value,
                                style: TextStyle(
                                  color: Colors.black,
                                  fontSize: 16,
                                  fontWeight: FontWeight.w500,
                                ),
                                decoration: InputDecoration(
                                  hintText: 'Enter your full name',
                                  hintStyle: TextStyle(color: Colors.grey[500]),
                                  border: InputBorder.none,
                                  contentPadding: EdgeInsets.all(20),
                                  prefixIcon: Padding(
                                    padding: EdgeInsets.all(16),
                                    child: Icon(Icons.person, color: coral, size: 20),
                                  ),
                                ),
                              ),
                            ),
                            SizedBox(height: 20),
                            // Address Field
                            Text(
                              'Address',
                              style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                                color: Colors.grey[700],
                              ),
                            ),
                            SizedBox(height: 8),
                            Container(
                              decoration: BoxDecoration(
                                color: Colors.white,
                                borderRadius: BorderRadius.circular(16),
                                border: Border.all(color: coral.withOpacity(0.3)),
                                boxShadow: [
                                  BoxShadow(
                                    color: Colors.black.withOpacity(0.05),
                                    blurRadius: 10,
                                    offset: Offset(0, 2),
                                  ),
                                ],
                              ),
                              child: TextField(
                                controller: TextEditingController(text: newAddress),
                                onChanged: (value) => newAddress = value,
                                style: TextStyle(
                                  color: Colors.black,
                                  fontSize: 16,
                                  fontWeight: FontWeight.w500,
                                ),
                                decoration: InputDecoration(
                                  hintText: 'Enter your address',
                                  hintStyle: TextStyle(color: Colors.grey[500]),
                                  border: InputBorder.none,
                                  contentPadding: EdgeInsets.all(20),
                                  prefixIcon: Padding(
                                    padding: EdgeInsets.all(16),
                                    child: Icon(Icons.location_on, color: coral, size: 20),
                                  ),
                                ),
                                maxLines: 2,
                                minLines: 1,
                              ),
                            ),
                            SizedBox(height: 24),
                            // Enhanced Save Button
                            SizedBox(
                              width: double.infinity,
                              child: ElevatedButton(
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: Colors.green,
                                  padding: EdgeInsets.symmetric(vertical: 16),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(16),
                                  ),
                                  elevation: 3,
                                  shadowColor: Colors.green.withOpacity(0.3),
                                ),
                                onPressed: isLoading ? null : () async {
                                  if (newName.trim().isEmpty) {
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      SnackBar(
                                        content: Row(
                                          children: [
                                            Icon(Icons.warning, color: Colors.white),
                                            SizedBox(width: 8),
                                            Text('Name cannot be empty'),
                                          ],
                                        ),
                                        backgroundColor: Colors.orange,
                                        behavior: SnackBarBehavior.floating,
                                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                                      ),
                                    );
                                    return;
                                  }
                                  setSt(() => isLoading = true);
                                  try {
                                    final supabase = Supabase.instance.client;
                                    
                                    // Update public.users table (name and address)
                                    await supabase
                                        .from('users')
                                        .update({
                                          'name': newName.trim(),
                                          'address': newAddress.trim().isEmpty ? null : newAddress.trim(),
                                        })
                                        .eq('id', user!.id);
                                    
                                    // Update auth metadata (name and address for backward compatibility)
                                    await supabase.auth.updateUser(UserAttributes(data: {
                                      'name': newName.trim(),
                                      'address': newAddress.trim().isEmpty ? null : newAddress.trim(),
                                    }));
                                    
                                    await _refreshUserMetadata();
                                    Navigator.pop(ctx);
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      SnackBar(
                                        content: Row(
                                          children: [
                                            Icon(Icons.check_circle, color: Colors.white),
                                            SizedBox(width: 8),
                                            Text('Account updated successfully!'),
                                          ],
                                        ),
                                        backgroundColor: Colors.green,
                                        behavior: SnackBarBehavior.floating,
                                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                                      ),
                                    );
                                  } catch (e) {
                                    setSt(() => isLoading = false);
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      SnackBar(
                                        content: Row(
                                          children: [
                                            Icon(Icons.error, color: Colors.white),
                                            SizedBox(width: 8),
                                            Expanded(child: Text('Failed to update account')),
                                          ],
                                        ),
                                        backgroundColor: Colors.red,
                                        behavior: SnackBarBehavior.floating,
                                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                                      ),
                                    );
                                  }
                                },
                                child: isLoading
                                    ? SizedBox(
                                        width: 20,
                                        height: 20,
                                        child: CircularProgressIndicator(
                                          color: Colors.white,
                                          strokeWidth: 2,
                                        ),
                                      )
                                    : Row(
                                        mainAxisAlignment: MainAxisAlignment.center,
                                        children: [
                                          Icon(Icons.save, color: Colors.white, size: 18),
                                          SizedBox(width: 8),
                                          Text(
                                            'Save Changes',
                                            style: TextStyle(
                                              color: Colors.white,
                                              fontSize: 16,
                                              fontWeight: FontWeight.w600,
                                            ),
                                          ),
                                        ],
                                      ),
                              ),
                            ),
                            SizedBox(height: 16),
                            // Delete Account Button
                            SizedBox(
                              width: double.infinity,
                              child: TextButton(
                                style: TextButton.styleFrom(
                                  padding: EdgeInsets.symmetric(vertical: 16),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(16),
                                    side: BorderSide(color: Colors.red.shade300),
                                  ),
                                ),
                                onPressed: () async {
                                  final confirm = await showDialog<bool>(
                                    context: context,
                                    builder: (context) => AlertDialog(
                                      title: Text('Delete Account'),
                                      content: Text('Are you sure you want to delete your account? This action cannot be undone.'),
                                      actions: [
                                        TextButton(
                                          onPressed: () => Navigator.pop(context, false),
                                          child: Text('Cancel', style: TextStyle(color: Colors.red)),
                                        ),
                                        TextButton(
                                          onPressed: () => Navigator.pop(context, true),
                                          child: Text('Delete', style: TextStyle(color: Colors.green)),
                                        ),
                                      ],
                                    ),
                                  );
                                  
                                  if (confirm == true) {
                                    try {
                                      await Supabase.instance.client.auth.signOut();
                                      await Supabase.instance.client.from('users').delete().eq('id', user!.id);
                                      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Account deleted.')));
                                      Navigator.pushNamedAndRemoveUntil(context, '/login', (r) => false);
                                    } catch (e) {
                                      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error deleting account: $e')));
                                    }
                                  }
                                },
                                child: Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    Icon(Icons.delete_forever, color: Colors.red, size: 18),
                                    SizedBox(width: 8),
                                    Text(
                                      'Delete Account',
                                      style: TextStyle(
                                        color: Colors.red,
                                        fontSize: 16,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  // Open dialog for notification preferences
  void _openNotificationPreferences() async {
    final currentPrefs = metadata['notification_preferences'] ?? {'enabled': true};

    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: lightBlush,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) {
        bool enabled = currentPrefs['enabled'] ?? true;
        bool isLoading = false;
        return StatefulBuilder(
          builder: (ctx, setSt) {
            return Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.white,
                    lightBlush.withOpacity(0.3),
                  ],
                ),
                borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.2),
                    blurRadius: 20,
                    offset: Offset(0, -5),
                  ),
                ],
              ),
              child: SafeArea(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Enhanced Header
                    Container(
                      padding: EdgeInsets.all(20),
                      decoration: BoxDecoration(
                        color: deepRed.withOpacity(0.05),
                        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
                      ),
                      child: Row(
                        children: [
                          Container(
                            padding: EdgeInsets.all(8),
                            decoration: BoxDecoration(
                              color: deepRed.withOpacity(0.1),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Icon(Icons.notifications, color: deepRed, size: 20),
                          ),
                          SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              'Notification Preferences',
                              style: TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.bold,
                                color: deepRed,
                              ),
                            ),
                          ),
                          IconButton(
                            onPressed: () => Navigator.pop(ctx),
                            icon: Icon(Icons.close, color: Colors.grey[600]),
                          ),
                        ],
                      ),
                    ),
                    // Enhanced Content
                    Flexible(
                      child: SingleChildScrollView(
                        padding: EdgeInsets.all(24),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            // Main Toggle Card
                            Container(
                              decoration: BoxDecoration(
                                color: Colors.white,
                                borderRadius: BorderRadius.circular(16),
                                border: Border.all(color: coral.withOpacity(0.3)),
                                boxShadow: [
                                  BoxShadow(
                                    color: Colors.black.withOpacity(0.05),
                                    blurRadius: 10,
                                    offset: Offset(0, 2),
                                  ),
                                ],
                              ),
                              child: SwitchListTile(
                                contentPadding: EdgeInsets.all(20),
                                secondary: Container(
                                  padding: EdgeInsets.all(8),
                                  decoration: BoxDecoration(
                                    color: enabled ? Colors.green.withOpacity(0.1) : Colors.grey.withOpacity(0.1),
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  child: Icon(
                                    enabled ? Icons.notifications_active : Icons.notifications_off,
                                    color: enabled ? Colors.green : Colors.grey,
                                    size: 20,
                                  ),
                                ),
                                title: Text(
                                  'Push Notifications',
                                  style: TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.w600,
                                    color: Colors.black,
                                  ),
                                ),
                                subtitle: Text(
                                  enabled ? 'You\'ll receive notifications for updates' : 'Notifications are disabled',
                                  style: TextStyle(
                                    fontSize: 14,
                                    color: Colors.grey[600],
                                  ),
                                ),
                                value: enabled,
                                activeColor: deepRed,
                                onChanged: (value) => setSt(() => enabled = value),
                              ),
                            ),
                            if (enabled) ...[
                              SizedBox(height: 20),
                              Text(
                                'Notification Types',
                                style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w600,
                                  color: Colors.grey[700],
                                ),
                              ),
                              SizedBox(height: 12),
                              Container(
                                padding: EdgeInsets.all(20),
                                decoration: BoxDecoration(
                                  color: lightBlush.withOpacity(0.5),
                                  borderRadius: BorderRadius.circular(16),
                                  border: Border.all(color: coral.withOpacity(0.2)),
                                ),
                                child: Column(
                                  children: [
                                    _notificationTypeItem('Job assignments', Icons.pets),
                                    _notificationTypeItem('Messages from pet owners', Icons.message),
                                    _notificationTypeItem('Schedule reminders', Icons.schedule),
                                    _notificationTypeItem('App updates', Icons.system_update),
                                  ],
                                ),
                              ),
                            ],
                            SizedBox(height: 24),
                            // Enhanced Save Button
                            SizedBox(
                              width: double.infinity,
                              child: ElevatedButton(
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: Colors.green,
                                  padding: EdgeInsets.symmetric(vertical: 16),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(16),
                                  ),
                                  elevation: 3,
                                  shadowColor: Colors.green.withOpacity(0.3),
                                ),
                                onPressed: isLoading ? null : () async {
                                  setSt(() => isLoading = true);
                                  try {
                                    await Supabase.instance.client.auth.updateUser(
                                      UserAttributes(data: {
                                        'notification_preferences': {'enabled': enabled}
                                      })
                                    );
                                    await _refreshUserMetadata();
                                    Navigator.pop(ctx);
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      SnackBar(
                                        content: Row(
                                          children: [
                                            Icon(Icons.check_circle, color: Colors.white),
                                            SizedBox(width: 8),
                                            Text('Notification preferences updated!'),
                                          ],
                                        ),
                                        backgroundColor: Colors.green,
                                        behavior: SnackBarBehavior.floating,
                                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                                      ),
                                    );
                                  } catch (e) {
                                    setSt(() => isLoading = false);
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      SnackBar(
                                        content: Row(
                                          children: [
                                            Icon(Icons.error, color: Colors.white),
                                            SizedBox(width: 8),
                                            Expanded(child: Text('Failed to update preferences')),
                                          ],
                                        ),
                                        backgroundColor: Colors.red,
                                        behavior: SnackBarBehavior.floating,
                                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                                      ),
                                    );
                                  }
                                },
                                child: isLoading
                                    ? SizedBox(
                                        width: 20,
                                        height: 20,
                                        child: CircularProgressIndicator(
                                          color: Colors.white,
                                          strokeWidth: 2,
                                        ),
                                      )
                                    : Row(
                                        mainAxisAlignment: MainAxisAlignment.center,
                                        children: [
                                          Icon(Icons.save, color: Colors.white, size: 18),
                                          SizedBox(width: 8),
                                          Text(
                                            'Save Preferences',
                                            style: TextStyle(
                                              color: Colors.white,
                                              fontSize: 16,
                                              fontWeight: FontWeight.w600,
                                            ),
                                          ),
                                        ],
                                      ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  Widget _notificationTypeItem(String title, IconData icon) {
    return Padding(
      padding: EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Icon(icon, color: coral, size: 16),
          SizedBox(width: 8),
          Text(
            title,
            style: TextStyle(
              fontSize: 13,
              color: Colors.grey[700],
            ),
          ),
        ],
      ),
    );
  }

  // Open dialog for change password
  void _openChangePassword() async {
    final _currentPasswordController = TextEditingController();
    final _newPasswordController = TextEditingController();
    final _confirmPasswordController = TextEditingController();
    bool _showCurrentPassword = false;
    bool _showNewPassword = false;
    bool _showConfirmPassword = false;
    bool _isLoading = false;

    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: lightBlush,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setSt) {
            // Password validation
            String password = _newPasswordController.text;
            bool hasMinLength = password.length >= 8;
            bool hasUppercase = RegExp(r'[A-Z]').hasMatch(password);
            bool hasLowercase = RegExp(r'[a-z]').hasMatch(password);
            bool hasNumber = RegExp(r'[0-9]').hasMatch(password);
            bool hasSpecialChar = RegExp(r'[!@#\$&*~_.,%^()\-\+=]').hasMatch(password);

            return Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.white,
                    lightBlush.withOpacity(0.3),
                  ],
                ),
                borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.2),
                    blurRadius: 20,
                    offset: Offset(0, -5),
                  ),
                ],
              ),
              child: SafeArea(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Enhanced Header
                    Container(
                      padding: EdgeInsets.all(20),
                      decoration: BoxDecoration(
                        color: deepRed.withOpacity(0.05),
                        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
                      ),
                      child: Row(
                        children: [
                          Container(
                            padding: EdgeInsets.all(8),
                            decoration: BoxDecoration(
                              color: deepRed.withOpacity(0.1),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Icon(Icons.lock, color: deepRed, size: 20),
                          ),
                          SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              'Change Password',
                              style: TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.bold,
                                color: deepRed,
                              ),
                            ),
                          ),
                          IconButton(
                            onPressed: () => Navigator.pop(ctx),
                            icon: Icon(Icons.close, color: Colors.grey[600]),
                          ),
                        ],
                      ),
                    ),
                    // Enhanced Content
                    Flexible(
                      child: SingleChildScrollView(
                        padding: EdgeInsets.all(24),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            // Current Password
                            _buildPasswordField(
                              label: 'Current Password',
                              controller: _currentPasswordController,
                              obscureText: !_showCurrentPassword,
                              onToggleVisibility: () => setSt(() => _showCurrentPassword = !_showCurrentPassword),
                            ),
                            SizedBox(height: 20),
                            // New Password
                            _buildPasswordField(
                              label: 'New Password',
                              controller: _newPasswordController,
                              obscureText: !_showNewPassword,
                              onToggleVisibility: () => setSt(() => _showNewPassword = !_showNewPassword),
                              onChanged: (value) => setSt(() {}),
                            ),
                            SizedBox(height: 20),
                            // Confirm Password
                            _buildPasswordField(
                              label: 'Confirm New Password',
                              controller: _confirmPasswordController,
                              obscureText: !_showConfirmPassword,
                              onToggleVisibility: () => setSt(() => _showConfirmPassword = !_showConfirmPassword),
                            ),
                            SizedBox(height: 20),
                            // Password Requirements
                            Container(
                              padding: EdgeInsets.all(16),
                              decoration: BoxDecoration(
                                color: lightBlush.withOpacity(0.5),
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(color: coral.withOpacity(0.2)),
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    'Password Requirements',
                                    style: TextStyle(
                                      fontSize: 14,
                                      fontWeight: FontWeight.w600,
                                      color: Colors.grey[700],
                                    ),
                                  ),
                                  SizedBox(height: 12),
                                  _passwordRequirement('At least 8 characters', hasMinLength),
                                  _passwordRequirement('One uppercase letter', hasUppercase),
                                  _passwordRequirement('One lowercase letter', hasLowercase),
                                  _passwordRequirement('One number', hasNumber),
                                  _passwordRequirement('One special character', hasSpecialChar),
                                ],
                              ),
                            ),
                            SizedBox(height: 24),
                            // Enhanced Change Password Button
                            SizedBox(
                              width: double.infinity,
                              child: ElevatedButton(
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: Colors.green,
                                  padding: EdgeInsets.symmetric(vertical: 16),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(16),
                                  ),
                                  elevation: 3,
                                  shadowColor: Colors.green.withOpacity(0.3),
                                ),
                                onPressed: _isLoading ? null : () async {
                                  if (_newPasswordController.text.isEmpty ||
                                      _currentPasswordController.text.isEmpty ||
                                      _confirmPasswordController.text.isEmpty) {
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      SnackBar(
                                        content: Row(
                                          children: [
                                            Icon(Icons.warning, color: Colors.white),
                                            SizedBox(width: 8),
                                            Text('Please fill in all fields'),
                                          ],
                                        ),
                                        backgroundColor: Colors.orange,
                                        behavior: SnackBarBehavior.floating,
                                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                                      ),
                                    );
                                    return;
                                  }

                                  if (_newPasswordController.text != _confirmPasswordController.text) {
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      SnackBar(
                                        content: Row(
                                          children: [
                                            Icon(Icons.warning, color: Colors.white),
                                            SizedBox(width: 8),
                                            Text('Passwords do not match'),
                                          ],
                                        ),
                                        backgroundColor: Colors.orange,
                                        behavior: SnackBarBehavior.floating,
                                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                                      ),
                                    );
                                    return;
                                  }

                                  if (!hasMinLength || !hasUppercase || !hasLowercase || !hasNumber || !hasSpecialChar) {
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      SnackBar(
                                        content: Row(
                                          children: [
                                            Icon(Icons.warning, color: Colors.white),
                                            SizedBox(width: 8),
                                            Expanded(child: Text('Password does not meet requirements')),
                                          ],
                                        ),
                                        backgroundColor: Colors.orange,
                                        behavior: SnackBarBehavior.floating,
                                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                                      ),
                                    );
                                    return;
                                  }

                                  setSt(() => _isLoading = true);
                                  try {
                                    await Supabase.instance.client.auth.updateUser(
                                      UserAttributes(password: _newPasswordController.text.trim()),
                                    );
                                    Navigator.pop(ctx);
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      SnackBar(
                                        content: Row(
                                          children: [
                                            Icon(Icons.check_circle, color: Colors.white),
                                            SizedBox(width: 8),
                                            Text('Password updated successfully!'),
                                          ],
                                        ),
                                        backgroundColor: Colors.green,
                                        behavior: SnackBarBehavior.floating,
                                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                                      ),
                                    );
                                  } catch (e) {
                                    setSt(() => _isLoading = false);
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      SnackBar(
                                        content: Row(
                                          children: [
                                            Icon(Icons.error, color: Colors.white),
                                            SizedBox(width: 8),
                                            Expanded(child: Text('Failed to update password')),
                                          ],
                                        ),
                                        backgroundColor: Colors.red,
                                        behavior: SnackBarBehavior.floating,
                                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                                      ),
                                    );
                                  }
                                },
                                child: _isLoading
                                    ? SizedBox(
                                        width: 20,
                                        height: 20,
                                        child: CircularProgressIndicator(
                                          color: Colors.white,
                                          strokeWidth: 2,
                                        ),
                                      )
                                    : Row(
                                        mainAxisAlignment: MainAxisAlignment.center,
                                        children: [
                                          Icon(Icons.lock_reset, color: Colors.white, size: 18),
                                          SizedBox(width: 8),
                                          Text(
                                            'Change Password',
                                            style: TextStyle(
                                              color: Colors.white,
                                              fontSize: 16,
                                              fontWeight: FontWeight.w600,
                                            ),
                                          ),
                                        ],
                                      ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildPasswordField({
    required String label,
    required TextEditingController controller,
    required bool obscureText,
    required VoidCallback onToggleVisibility,
    ValueChanged<String>? onChanged,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w600,
            color: Colors.grey[700],
          ),
        ),
        SizedBox(height: 8),
        Container(
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: coral.withOpacity(0.3)),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.05),
                blurRadius: 10,
                offset: Offset(0, 2),
              ),
            ],
          ),
          child: TextField(
            controller: controller,
            obscureText: obscureText,
            onChanged: onChanged,
            style: TextStyle(
              color: Colors.black,
              fontSize: 16,
              fontWeight: FontWeight.w500,
            ),
            decoration: InputDecoration(
              hintText: 'Enter $label',
              hintStyle: TextStyle(color: Colors.grey[500]),
              border: InputBorder.none,
              contentPadding: EdgeInsets.all(20),
              prefixIcon: Padding(
                padding: EdgeInsets.all(16),
                child: Icon(Icons.lock_outline, color: coral, size: 20),
              ),
              suffixIcon: IconButton(
                onPressed: onToggleVisibility,
                icon: Icon(
                  obscureText ? Icons.visibility : Icons.visibility_off,
                  color: Colors.grey[400],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _passwordRequirement(String text, bool isValid) {
    return Padding(
      padding: EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Icon(
            isValid ? Icons.check_circle : Icons.circle_outlined,
            color: isValid ? Colors.green : Colors.grey,
            size: 16,
          ),
          SizedBox(width: 8),
          Text(
            text,
            style: TextStyle(
              fontSize: 13,
              color: isValid ? Colors.green[700] : Colors.grey[600],
              fontWeight: isValid ? FontWeight.w500 : FontWeight.normal,
            ),
          ),
        ],
      ),
    );
  }

  // Open dialog for theme settings
  // Helper methods for Help & Support functionality
  void _launchEmail(String email) async {
    final Uri emailUri = Uri(
      scheme: 'mailto',
      path: email,
      query: 'subject=PetTrackCare Support Request',
    );
    try {
      if (await canLaunchUrl(emailUri)) {
        await launchUrl(emailUri);
      } else {
        // Fallback: show email address to copy
        _showEmailFallback(email);
      }
    } catch (e) {
      _showEmailFallback(email);
    }
  }

  void _showEmailFallback(String email) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Email Support'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Could not open email app. Please contact us at:'),
            SizedBox(height: 8),
            SelectableText(
              email,
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            SizedBox(height: 8),
            Text('Subject: PetTrackCare Support Request'),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text('Close'),
          ),
        ],
      ),
    );
  }

  void _launchPhone(String phone) async {
    final Uri phoneUri = Uri(scheme: 'tel', path: phone);
    if (await canLaunchUrl(phoneUri)) {
      await launchUrl(phoneUri);
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not open phone app')),
      );
    }
  }

  void _showFAQs() {
    showDialog(
      context: context,
      builder: (context) => Dialog(
        backgroundColor: lightBlush,
        child: Container(
          constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.8),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Colors.white,
                lightBlush.withOpacity(0.3),
              ],
            ),
            borderRadius: BorderRadius.circular(24),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.2),
                blurRadius: 20,
                offset: Offset(0, 10),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Enhanced Header
              Container(
                padding: EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: deepRed.withOpacity(0.05),
                  borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
                ),
                child: Row(
                  children: [
                    Container(
                      padding: EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: deepRed.withOpacity(0.1),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Icon(Icons.question_answer, color: deepRed, size: 20),
                    ),
                    SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        'Frequently Asked Questions',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                          color: deepRed,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              // Enhanced Content
              Flexible(
                child: SingleChildScrollView(
                  padding: EdgeInsets.all(24),
                  child: Column(
                    children: [
                      _faqItem('How do I view my assigned pets?', 'Go to the "Assigned Pets" tab to see all pets you\'re caring for.', Icons.pets),
                      _faqItem('How do I accept pet sitting jobs?', 'Pet owners will send you requests that you can accept or decline.', Icons.work),
                      _faqItem('How do I update my profile?', 'Go to Settings > Account to update your information.', Icons.person),
                      _faqItem('How do I communicate with pet owners?', 'Use the in-app messaging feature to communicate about pet care.', Icons.message),
                    ],
                  ),
                ),
              ),
              // Enhanced Close Button
              Container(
                padding: EdgeInsets.all(20),
                child: SizedBox(
                  width: double.infinity,
                  child: TextButton(
                    style: TextButton.styleFrom(
                      padding: EdgeInsets.symmetric(vertical: 12),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                        side: BorderSide(color: Colors.red.shade300),
                      ),
                    ),
                    onPressed: () => Navigator.pop(context),
                    child: Text(
                      'Close',
                      style: TextStyle(
                        color: Colors.red,
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _faqItem(String question, String answer, IconData icon) {
    return Container(
      margin: EdgeInsets.only(bottom: 16),
      padding: EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: coral.withOpacity(0.2)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.05),
            blurRadius: 5,
            offset: Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: coral.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(icon, color: coral, size: 16),
              ),
              SizedBox(width: 8),
              Expanded(
                child: Text(
                  question,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: Colors.grey[800],
                  ),
                ),
              ),
            ],
          ),
          SizedBox(height: 8),
          Padding(
            padding: EdgeInsets.only(left: 32),
            child: Text(
              answer,
              style: TextStyle(
                fontSize: 13,
                color: Colors.grey[600],
                height: 1.3,
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _reportIssue() async {
    TextEditingController issueController = TextEditingController();
    bool isLoading = false;
    
    await showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => Dialog(
          backgroundColor: lightBlush,
          child: Container(
            constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.7),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.grey.shade100,
                  lightBlush.withOpacity(0.5),
                ],
              ),
              borderRadius: BorderRadius.circular(24),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.2),
                  blurRadius: 20,
                  offset: Offset(0, 10),
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Enhanced Header
                Container(
                  padding: EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    color: deepRed.withOpacity(0.05),
                    borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
                  ),
                  child: Row(
                    children: [
                      Container(
                        padding: EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: deepRed.withOpacity(0.1),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Icon(Icons.bug_report, color: deepRed, size: 20),
                      ),
                      SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          'Report an Issue',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                            color: deepRed,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                // Enhanced Content
                Flexible(
                  child: Padding(
                    padding: EdgeInsets.all(24),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Help us improve PetTrackCare by describing the issue you\'re experiencing:',
                          style: TextStyle(
                            fontSize: 14,
                            color: Colors.grey[700],
                            height: 1.4,
                          ),
                        ),
                        SizedBox(height: 16),
                        Container(
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(color: coral.withOpacity(0.3)),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withOpacity(0.05),
                                blurRadius: 10,
                                offset: Offset(0, 2),
                              ),
                            ],
                          ),
                          child: TextField(
                            controller: issueController,
                            style: TextStyle(
                              color: Colors.black,
                              fontSize: 14,
                            ),
                            decoration: InputDecoration(
                              hintText: 'Describe the issue you\'re experiencing...\n\nPlease include:\n• What you were trying to do\n• What went wrong\n• When it happened',
                              hintStyle: TextStyle(
                                color: Colors.grey[500],
                                fontSize: 13,
                                height: 1.4,
                              ),
                              border: InputBorder.none,
                              contentPadding: EdgeInsets.all(20),
                              prefixIcon: Padding(
                                padding: EdgeInsets.all(16),
                                child: Icon(Icons.edit, color: coral, size: 20),
                              ),
                            ),
                            maxLines: 6,
                            minLines: 6,
                          ),
                        ),
                        SizedBox(height: 20),
                        // Info section
                        Container(
                          padding: EdgeInsets.all(16),
                          decoration: BoxDecoration(
                            color: lightBlush.withOpacity(0.5),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: coral.withOpacity(0.2)),
                          ),
                          child: Row(
                            children: [
                              Icon(Icons.info_outline, color: coral, size: 16),
                              SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  'Your feedback helps us make the app better for all pet sitters.',
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: Colors.grey[700],
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                // Enhanced Action Buttons
                Container(
                  padding: EdgeInsets.all(20),
                  child: Row(
                    children: [
                      Expanded(
                        child: TextButton(
                          style: TextButton.styleFrom(
                            padding: EdgeInsets.symmetric(vertical: 12),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                              side: BorderSide(color: Colors.red.shade300),
                            ),
                          ),
                          onPressed: () => Navigator.pop(context),
                          child: Text(
                            'Cancel',
                            style: TextStyle(
                              color: Colors.red,
                              fontSize: 14,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                      ),
                      SizedBox(width: 12),
                      Expanded(
                        flex: 2,
                        child: ElevatedButton(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.green,
                            padding: EdgeInsets.symmetric(vertical: 12),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                            elevation: 2,
                          ),
                          onPressed: isLoading ? null : () async {
                            final text = issueController.text.trim();
                            if (text.isEmpty) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Row(
                                    children: [
                                      Icon(Icons.warning, color: Colors.white),
                                      SizedBox(width: 8),
                                      Text('Please describe the issue.'),
                                    ],
                                  ),
                                  backgroundColor: Colors.orange,
                                  behavior: SnackBarBehavior.floating,
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                                ),
                              );
                              return;
                            }
                            setState(() => isLoading = true);
                            try {
                              await Supabase.instance.client
                                  .from('feedback')
                                  .insert({
                                'user_id': user?.id,
                                'message': text,
                                'created_at': DateTime.now().toIso8601String(),
                              });
                              Navigator.pop(context);
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Row(
                                    children: [
                                      Icon(Icons.check_circle, color: Colors.white),
                                      SizedBox(width: 8),
                                      Text('Issue reported successfully!'),
                                    ],
                                  ),
                                  backgroundColor: Colors.green,
                                  behavior: SnackBarBehavior.floating,
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                                ),
                              );
                            } catch (e) {
                              setState(() => isLoading = false);
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Row(
                                    children: [
                                      Icon(Icons.error, color: Colors.white),
                                      SizedBox(width: 8),
                                      Expanded(child: Text('Failed to report issue. Please try again.')),
                                    ],
                                  ),
                                  backgroundColor: Colors.red,
                                  behavior: SnackBarBehavior.floating,
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                                ),
                              );
                            }
                          },
                          child: isLoading
                              ? SizedBox(
                                  width: 20,
                                  height: 20,
                                  child: CircularProgressIndicator(
                                    color: Colors.white,
                                    strokeWidth: 2,
                                  ),
                                )
                              : Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    Icon(Icons.send, color: Colors.white, size: 16),
                                    SizedBox(width: 8),
                                    Text(
                                      'Report Issue',
                                      style: TextStyle(
                                        color: Colors.white,
                                        fontSize: 14,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ],
                                ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // Open dialog for help & support
  void _openHelpSupport() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: lightBlush,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) {
        return Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Colors.white,
                lightBlush.withOpacity(0.2),
              ],
            ),
            borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.1),
                blurRadius: 20,
                offset: Offset(0, -5),
              ),
            ],
          ),
          child: SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Enhanced Header
                Container(
                  padding: EdgeInsets.symmetric(horizontal: 20, vertical: 16),
                  decoration: BoxDecoration(
                    color: deepRed.withOpacity(0.05),
                    borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
                  ),
                  child: Row(
                    children: [
                      Container(
                        padding: EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: deepRed.withOpacity(0.1),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Icon(Icons.help_outline, color: deepRed, size: 20),
                      ),
                      SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          'Help & Support',
                          style: TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.bold,
                            color: deepRed,
                          ),
                        ),
                      ),
                      Container(
                        decoration: BoxDecoration(
                          color: Colors.grey.withOpacity(0.1),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: IconButton(
                          icon: Icon(Icons.close, color: Colors.grey[600]),
                          onPressed: () => Navigator.pop(ctx),
                        ),
                      ),
                    ],
                  ),
                ),
                Flexible(
                  child: SingleChildScrollView(
                    padding: EdgeInsets.all(24),
                    child: Column(
                      children: [
                        // Contact Section
                        Container(
                          padding: EdgeInsets.all(20),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(color: coral.withOpacity(0.3)),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withOpacity(0.05),
                                blurRadius: 10,
                                offset: Offset(0, 2),
                              ),
                            ],
                          ),
                          margin: EdgeInsets.only(bottom: 20),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Icon(Icons.support_agent, color: coral, size: 20),
                                  SizedBox(width: 8),
                                  Text(
                                    'Get Support',
                                    style: TextStyle(
                                      fontSize: 16,
                                      fontWeight: FontWeight.bold,
                                      color: deepRed,
                                    ),
                                  ),
                                ],
                              ),
                              SizedBox(height: 16),
                              _supportItem(
                                icon: Icons.email,
                                title: 'Email Support',
                                subtitle: 'Get help via email',
                                detail: 'test@gmail.com',
                                onTap: () => _launchEmail('test@gmail.com'),
                              ),
                              SizedBox(height: 12),
                              _supportItem(
                                icon: Icons.phone,
                                title: 'Phone Support',
                                subtitle: 'Speak with our team',
                                detail: '+1 123-456-7890',
                                onTap: () => _launchPhone('+1 123-456-7890'),
                              ),
                            ],
                          ),
                        ),
                        // Help Resources Section
                        Container(
                          padding: EdgeInsets.all(20),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(color: coral.withOpacity(0.3)),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withOpacity(0.05),
                                blurRadius: 10,
                                offset: Offset(0, 2),
                              ),
                            ],
                          ),
                          margin: EdgeInsets.only(bottom: 20),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Icon(Icons.menu_book, color: coral, size: 20),
                                  SizedBox(width: 8),
                                  Text(
                                    'Resources',
                                    style: TextStyle(
                                      fontSize: 16,
                                      fontWeight: FontWeight.bold,
                                      color: deepRed,
                                    ),
                                  ),
                                ],
                              ),
                              SizedBox(height: 16),
                              _supportItem(
                                icon: Icons.question_answer,
                                title: 'FAQs',
                                subtitle: 'Common questions and answers',
                                onTap: _showFAQs,
                              ),
                              SizedBox(height: 12),
                              _supportItem(
                                icon: Icons.bug_report,
                                title: 'Report an Issue',
                                subtitle: 'Let us know about problems',
                                onTap: _reportIssue,
                              ),
                              SizedBox(height: 12),
                              _supportItem(
                                icon: Icons.feedback,
                                title: 'Send Feedback',
                                subtitle: 'Share your thoughts with us',
                                onTap: () => _launchEmail('feedback@pettrackcare.com'),
                              ),
                            ],
                          ),
                        ),
                        // Quick Tips Section
                        Container(
                          padding: EdgeInsets.all(20),
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              colors: [lightBlush.withOpacity(0.5), peach.withOpacity(0.2)],
                            ),
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(color: coral.withOpacity(0.2)),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Icon(Icons.lightbulb_outline, color: coral, size: 20),
                                  SizedBox(width: 8),
                                  Text(
                                    'Quick Tips for Pet Sitters',
                                    style: TextStyle(
                                      fontSize: 16,
                                      fontWeight: FontWeight.bold,
                                      color: deepRed,
                                    ),
                                  ),
                                ],
                              ),
                              SizedBox(height: 12),
                              _tipItem('• Enable notifications to stay updated on job requests'),
                              _tipItem('• Keep your profile updated with current availability'),
                              _tipItem('• Use messaging to communicate regularly with pet owners'),
                              _tipItem('• Check your internet connection if experiencing sync issues'),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _tipItem(String tip) {
    return Padding(
      padding: EdgeInsets.only(bottom: 8),
      child: Text(
        tip,
        style: TextStyle(
          fontSize: 13,
          color: Colors.grey[700],
          height: 1.4,
        ),
      ),
    );
  }

  Widget _supportItem({
    required IconData icon,
    required String title,
    required String subtitle,
    String? detail,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: lightBlush.withOpacity(0.2),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: coral.withOpacity(0.2)),
        ),
        child: Row(
          children: [
            Container(
              padding: EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(12),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.05),
                    blurRadius: 5,
                    offset: Offset(0, 2),
                  ),
                ],
              ),
              child: Icon(icon, color: deepRed, size: 20),
            ),
            SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: Colors.grey[800],
                    ),
                  ),
                  SizedBox(height: 4),
                  Text(
                    subtitle,
                    style: TextStyle(
                      fontSize: 13,
                      color: Colors.grey[600],
                    ),
                  ),
                  if (detail != null) ...[
                    SizedBox(height: 2),
                    Text(
                      detail,
                      style: TextStyle(
                        fontSize: 11,
                        color: coral,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            Icon(Icons.arrow_forward_ios, color: Colors.grey[400], size: 16),
          ],
        ),
      ),
    );
  }

  // Open dialog for about information
  void _openAbout() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: lightBlush,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) {
        return Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Colors.white,
                lightBlush.withOpacity(0.2),
              ],
            ),
            borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.1),
                blurRadius: 20,
                offset: Offset(0, -5),
              ),
            ],
          ),
          child: SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Enhanced Header
                Container(
                  padding: EdgeInsets.symmetric(horizontal: 20, vertical: 16),
                  decoration: BoxDecoration(
                    color: deepRed.withOpacity(0.05),
                    borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
                  ),
                  child: Row(
                    children: [
                      Container(
                        padding: EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: deepRed.withOpacity(0.1),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Icon(Icons.info_outline, color: deepRed, size: 20),
                      ),
                      SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          'About PetTrackCare',
                          style: TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.bold,
                            color: deepRed,
                          ),
                        ),
                      ),
                      Container(
                        decoration: BoxDecoration(
                          color: Colors.grey.withOpacity(0.1),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: IconButton(
                          icon: Icon(Icons.close, color: Colors.grey[600]),
                          onPressed: () => Navigator.pop(ctx),
                        ),
                      ),
                    ],
                  ),
                ),
                Flexible(
                  child: SingleChildScrollView(
                    padding: EdgeInsets.all(24),
                    child: Column(
                      children: [
                        // App Info Section
                        Container(
                          padding: EdgeInsets.all(24),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(color: coral.withOpacity(0.3)),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withOpacity(0.05),
                                blurRadius: 10,
                                offset: Offset(0, 2),
                              ),
                            ],
                          ),
                          margin: EdgeInsets.only(bottom: 20),
                          child: Column(
                            children: [
                              // App Icon
                              Container(
                                width: 80,
                                height: 80,
                                decoration: BoxDecoration(
                                  gradient: LinearGradient(
                                    colors: [deepRed, coral],
                                  ),
                                  borderRadius: BorderRadius.circular(20),
                                  boxShadow: [
                                    BoxShadow(
                                      color: deepRed.withOpacity(0.2),
                                      blurRadius: 10,
                                      offset: Offset(0, 5),
                                    ),
                                  ],
                                ),
                                child: Icon(
                                  Icons.pets,
                                  color: Colors.white,
                                  size: 40,
                                ),
                              ),
                              SizedBox(height: 16),
                              Text(
                                'PetTrackCare',
                                style: TextStyle(
                                  fontSize: 24,
                                  fontWeight: FontWeight.bold,
                                  color: deepRed,
                                ),
                              ),
                              SizedBox(height: 8),
                              Container(
                                padding: EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                                decoration: BoxDecoration(
                                  color: coral.withOpacity(0.1),
                                  borderRadius: BorderRadius.circular(12),
                                  border: Border.all(color: coral.withOpacity(0.3)),
                                ),
                                child: Text(
                                  'Version 1.0.0',
                                  style: TextStyle(
                                    color: coral,
                                    fontWeight: FontWeight.w500,
                                    fontSize: 12,
                                  ),
                                ),
                              ),
                              SizedBox(height: 16),
                              Text(
                                'A comprehensive app designed to help pet owners monitor and manage their pets\' health, activities, and daily care routines with care and precision.',
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  fontSize: 14,
                                  color: Colors.grey[700],
                                  height: 1.5,
                                ),
                              ),
                            ],
                          ),
                        ),
                        // Features Section
                        Container(
                          padding: EdgeInsets.all(20),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(color: coral.withOpacity(0.3)),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withOpacity(0.05),
                                blurRadius: 10,
                                offset: Offset(0, 2),
                              ),
                            ],
                          ),
                          margin: EdgeInsets.only(bottom: 20),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Icon(Icons.star, color: coral, size: 20),
                                  SizedBox(width: 8),
                                  Text(
                                    'Key Features',
                                    style: TextStyle(
                                      fontSize: 16,
                                      fontWeight: FontWeight.bold,
                                      color: deepRed,
                                    ),
                                  ),
                                ],
                              ),
                              SizedBox(height: 16),
                              _featureItem(Icons.health_and_safety, 'Health Monitoring'),
                              _featureItem(Icons.calendar_today, 'Activity Tracking'),
                              _featureItem(Icons.notifications, 'Smart Reminders'),
                              _featureItem(Icons.people, 'Pet Sitting Services'),
                              _featureItem(Icons.analytics, 'Health Analytics'),
                            ],
                          ),
                        ),
                        // Team & Contact Section
                        Container(
                          padding: EdgeInsets.all(20),
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              colors: [lightBlush.withOpacity(0.5), peach.withOpacity(0.2)],
                            ),
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(color: coral.withOpacity(0.2)),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Icon(Icons.groups, color: coral, size: 20),
                                  SizedBox(width: 8),
                                  Text(
                                    'Our Team',
                                    style: TextStyle(
                                      fontSize: 16,
                                      fontWeight: FontWeight.bold,
                                      color: deepRed,
                                    ),
                                  ),
                                ],
                              ),
                              SizedBox(height: 12),
                              Text(
                                'Developed with ❤️ by the PetTrackCare Team',
                                style: TextStyle(
                                  fontSize: 14,
                                  color: Colors.grey[700],
                                ),
                              ),
                              SizedBox(height: 16),
                              Row(
                                children: [
                                  Icon(Icons.email, color: coral, size: 16),
                                  SizedBox(width: 8),
                                  Text(
                                    'Contact us: ',
                                    style: TextStyle(
                                      fontSize: 14,
                                      color: Colors.grey[700],
                                    ),
                                  ),
                                  InkWell(
                                    onTap: () => _launchEmail('test@gmail.com'),
                                    child: Text(
                                      'test@gmail.com',
                                      style: TextStyle(
                                        fontSize: 14,
                                        color: deepRed,
                                        fontWeight: FontWeight.w500,
                                        decoration: TextDecoration.underline,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              SizedBox(height: 12),
                              Text(
                                '© 2024 PetTrackCare. All rights reserved.',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: Colors.grey[600],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _featureItem(IconData icon, String title) {
    return Padding(
      padding: EdgeInsets.only(bottom: 12),
      child: Row(
        children: [
          Container(
            padding: EdgeInsets.all(6),
            decoration: BoxDecoration(
              color: coral.withOpacity(0.1),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(icon, color: coral, size: 16),
          ),
          SizedBox(width: 12),
          Text(
            title,
            style: TextStyle(
              fontSize: 14,
              color: Colors.grey[700],
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
  
  void _openSavedPosts() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: lightBlush,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) => SavedPostsModal(userId: user?.id ?? ''),
    );
  }

  Future<void> _pickProfileImage() async {
    // Show image source selection dialog
    final ImageSource? source = await _showImageSourceDialog();
    if (source == null) return;

    XFile? pickedFile;
    try {
      pickedFile = await _picker.pickImage(
        source: source,
        maxWidth: 800,
        maxHeight: 800,
        imageQuality: 85,
      );
    } catch (e) {
      // Handle permission or camera access errors
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Row(
            children: [
              Icon(Icons.warning, color: Colors.white),
              SizedBox(width: 8),
              Expanded(
                child: Text(
                  source == ImageSource.camera 
                    ? 'Camera access denied. Please enable camera permission in settings.'
                    : 'Photo access denied. Please enable photo permission in settings.',
                ),
              ),
            ],
          ),
          backgroundColor: Colors.orange,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          duration: Duration(seconds: 4),
        ),
      );
      return;
    }
    
    if (pickedFile == null) {
      // User cancelled the picker
      return;
    }

    // Show enhanced confirmation dialog
    final confirm = await _showImageConfirmationDialog(pickedFile.path);
    if (confirm != true) return;

    final file = File(pickedFile.path);
    final fileBytes = await file.readAsBytes();
    final fileName =
        'profile_images/${user!.id}_${DateTime.now().millisecondsSinceEpoch}.jpg';

    // Show loading dialog
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => Dialog(
        backgroundColor: Colors.transparent,
        child: Container(
          padding: EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircularProgressIndicator(color: deepRed),
              SizedBox(height: 16),
              Text(
                'Uploading profile picture...',
                style: TextStyle(
                  fontSize: 16,
                  color: Colors.grey[700],
                ),
              ),
            ],
          ),
        ),
      ),
    );

    try {
      final supabase = Supabase.instance.client;
      final bucket = supabase.storage.from('profile-pictures');

      await bucket.uploadBinary(
        fileName,
        fileBytes,
        fileOptions: const FileOptions(contentType: 'image/jpeg'),
      );

      final publicUrl = bucket.getPublicUrl(fileName);

      // Store profile_picture in public.users table, not auth.users
      await supabase
        .from('users')
        .update({'profile_picture': publicUrl})
        .eq('id', user!.id);

      setState(() {
        _profileImage = file;
        userData['profile_picture'] = publicUrl;
        metadata['profile_picture'] = publicUrl;
      });

      // Close loading dialog
      Navigator.of(context).pop();

      // Show success message
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Row(
            children: [
              Icon(Icons.check_circle, color: Colors.white),
              SizedBox(width: 8),
              Text('Profile picture updated successfully!'),
            ],
          ),
          backgroundColor: Colors.green,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
      );

      print('✅ Profile picture updated!');
    } catch (e) {
      // Close loading dialog
      Navigator.of(context).pop();
      
      // Show error message
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Row(
            children: [
              Icon(Icons.error_outline, color: Colors.white),
              SizedBox(width: 8),
              Expanded(
                child: Text('Failed to update profile picture. Please try again.'),
              ),
            ],
          ),
          backgroundColor: deepRed,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          duration: Duration(seconds: 4),
        ),
      );
      
      print('❌ Error uploading profile image: $e');
    }
  }

  // Enhanced image source selection dialog
  Future<ImageSource?> _showImageSourceDialog() async {
    return await showModalBottomSheet<ImageSource>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) => Container(
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.2),
              blurRadius: 20,
              offset: Offset(0, -5),
            ),
          ],
        ),
        child: SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Handle bar
              Container(
                width: 40,
                height: 4,
                margin: EdgeInsets.only(top: 12, bottom: 20),
                decoration: BoxDecoration(
                  color: Colors.grey[300],
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              // Header
              Padding(
                padding: EdgeInsets.symmetric(horizontal: 24),
                child: Row(
                  children: [
                    Container(
                      padding: EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: coral.withOpacity(0.1),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Icon(Icons.camera_alt, color: coral, size: 20),
                    ),
                    SizedBox(width: 12),
                    Text(
                      'Choose Photo Source',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: Colors.grey[800],
                      ),
                    ),
                  ],
                ),
              ),
              SizedBox(height: 24),
              // Options
              Padding(
                padding: EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  children: [
                    Expanded(
                      child: _buildImageSourceOption(
                        icon: Icons.camera_alt,
                        title: 'Camera',
                        subtitle: 'Take a new photo',
                        color: deepRed,
                        onTap: () => Navigator.pop(context, ImageSource.camera),
                      ),
                    ),
                    SizedBox(width: 12),
                    Expanded(
                      child: _buildImageSourceOption(
                        icon: Icons.photo_library,
                        title: 'Gallery',
                        subtitle: 'Choose from photos',
                        color: coral,
                        onTap: () => Navigator.pop(context, ImageSource.gallery),
                      ),
                    ),
                  ],
                ),
              ),
              SizedBox(height: 24),
              // Cancel button
              Padding(
                padding: EdgeInsets.symmetric(horizontal: 24),
                child: SizedBox(
                  width: double.infinity,
                  child: TextButton(
                    style: TextButton.styleFrom(
                      padding: EdgeInsets.symmetric(vertical: 12),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    onPressed: () => Navigator.pop(context),
                    child: Text(
                      'Cancel',
                      style: TextStyle(
                        color: Colors.grey[600],
                        fontSize: 16,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                ),
              ),
              SizedBox(height: 16),
            ],
          ),
        ),
      ),
    );
  }

  // Enhanced image confirmation dialog
  Future<bool?> _showImageConfirmationDialog(String imagePath) async {
    return await showDialog<bool>(
      context: context,
      builder: (context) => Dialog(
        backgroundColor: Colors.transparent,
        child: Container(
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(24),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.2),
                blurRadius: 20,
                offset: Offset(0, 10),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Header
              Container(
                padding: EdgeInsets.all(20),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [deepRed.withOpacity(0.1), coral.withOpacity(0.1)],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
                ),
                child: Row(
                  children: [
                    Container(
                      padding: EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: deepRed.withOpacity(0.1),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Icon(Icons.photo, color: deepRed, size: 20),
                    ),
                    SizedBox(width: 12),
                    Text(
                      'Confirm Profile Picture',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: deepRed,
                      ),
                    ),
                  ],
                ),
              ),
              // Image preview
              Padding(
                padding: EdgeInsets.all(20),
                child: Column(
                  children: [
                    Container(
                      width: 200,
                      height: 200,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: coral.withOpacity(0.3), width: 2),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withOpacity(0.1),
                            blurRadius: 10,
                            offset: Offset(0, 4),
                          ),
                        ],
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(14),
                        child: Image.file(
                          File(imagePath),
                          fit: BoxFit.cover,
                        ),
                      ),
                    ),
                    SizedBox(height: 16),
                    Text(
                      'Use this photo as your profile picture?',
                      style: TextStyle(
                        fontSize: 16,
                        color: Colors.grey[700],
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              ),
              // Action buttons
              Padding(
                padding: EdgeInsets.all(20),
                child: Row(
                  children: [
                    Expanded(
                      child: TextButton(
                        style: TextButton.styleFrom(
                          padding: EdgeInsets.symmetric(vertical: 12),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                            side: BorderSide(color: Colors.grey.shade300),
                          ),
                        ),
                        onPressed: () => Navigator.pop(context, false),
                        child: Text(
                          'Cancel',
                          style: TextStyle(
                            color: Colors.grey[600],
                            fontSize: 16,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                    ),
                    SizedBox(width: 12),
                    Expanded(
                      child: ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: deepRed,
                          foregroundColor: Colors.white,
                          padding: EdgeInsets.symmetric(vertical: 12),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                          elevation: 2,
                        ),
                        onPressed: () => Navigator.pop(context, true),
                        child: Text(
                          'Use Photo',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
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

  // Helper widget for image source options
  Widget _buildImageSourceOption({
    required IconData icon,
    required String title,
    required String subtitle,
    required Color color,
    required VoidCallback onTap,
  }) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Container(
          padding: EdgeInsets.all(20),
          decoration: BoxDecoration(
            border: Border.all(color: color.withOpacity(0.2)),
            borderRadius: BorderRadius.circular(16),
            gradient: LinearGradient(
              colors: [
                color.withOpacity(0.05),
                color.withOpacity(0.02),
              ],
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
            ),
          ),
          child: Column(
            children: [
              Container(
                padding: EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: color.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(
                  icon,
                  color: color,
                  size: 24,
                ),
              ),
              SizedBox(height: 12),
              Text(
                title,
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: Colors.grey[800],
                ),
              ),
              SizedBox(height: 4),
              Text(
                subtitle,
                style: TextStyle(
                  fontSize: 12,
                  color: Colors.grey[600],
                ),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: lightBlush,
      appBar: AppBar(
        backgroundColor: deepRed,
        elevation: 0,
        title: Text(
          'Sitter Profile',
          style: TextStyle(
            fontWeight: FontWeight.bold,
            color: Colors.white,
            fontSize: 20,
            letterSpacing: 0.5,
          ),
        ),
        actions: [
          Container(
            margin: EdgeInsets.only(right: 8),
            child: IconButton(
              icon: Container(
                padding: EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.2),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: Colors.white.withOpacity(0.3),
                    width: 1,
                  ),
                ),
                child: Icon(
                  Icons.logout,
                  color: Colors.white,
                  size: 20,
                ),
              ),
              tooltip: 'Logout',
              onPressed: () async {
                final confirm = await showDialog<bool>(
                context: context,
                builder: (context) => AlertDialog(
                  title: Text('Confirm Logout'),
                  content: Text('Are you sure you want to log out?'),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(context, false),
                      child: Text('Cancel', style: TextStyle(color: Colors.red)),
                    ),
                    ElevatedButton(
                      style: ElevatedButton.styleFrom(backgroundColor: Colors.green),
                      onPressed: () => Navigator.pop(context, true),
                      child: Text('Logout'),
                    ),
                  ],
                ),
              );
              if (confirm == true) {
                _logout(context);
              }
            },
          ),
          ),
        ],
      ),
      body: Container(
        margin: EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(20),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.1),
              blurRadius: 20,
              offset: Offset(0, 5),
            ),
          ],
        ),
        child: Column(
          children: [
            // Enhanced Profile Info Section with gradient design
            Container(
              margin: EdgeInsets.all(16),
              child: Card(
                elevation: 8,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                child: Container(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(20),
                    gradient: LinearGradient(
                      colors: [deepRed.withOpacity(0.8), coral],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                  ),
                  padding: EdgeInsets.all(20),
                  child: Column(
                    children: [
                      // Enhanced Profile picture with camera overlay
                      Stack(
                        alignment: Alignment.bottomRight,
                        children: [
                          Container(
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              gradient: LinearGradient(
                                colors: [Colors.white, lightBlush.withOpacity(0.3)],
                                begin: Alignment.topLeft,
                                end: Alignment.bottomRight,
                              ),
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.black.withOpacity(0.15),
                                  blurRadius: 20,
                                  offset: Offset(0, 8),
                                ),
                                BoxShadow(
                                  color: Colors.white.withOpacity(0.8),
                                  blurRadius: 10,
                                  offset: Offset(0, -2),
                                ),
                              ],
                            ),
                            child: CircleAvatar(
                              radius: 62,
                              backgroundColor: Colors.transparent,
                              child: CircleAvatar(
                                radius: 58,
                                backgroundColor: lightBlush.withOpacity(0.3),
                                backgroundImage: _profileImage != null
                                    ? FileImage(_profileImage!)
                                    : (userData['profile_picture'] != null && userData['profile_picture'].toString().isNotEmpty
                                        ? NetworkImage(userData['profile_picture'])
                                        : null),
                                child: (_profileImage == null && (userData['profile_picture'] == null || userData['profile_picture'].toString().isEmpty))
                                    ? Container(
                                        decoration: BoxDecoration(
                                          shape: BoxShape.circle,
                                          gradient: LinearGradient(
                                            colors: [coral.withOpacity(0.1), deepRed.withOpacity(0.1)],
                                            begin: Alignment.topCenter,
                                            end: Alignment.bottomCenter,
                                          ),
                                        ),
                                        child: Icon(
                                          Icons.person,
                                          size: 64,
                                          color: deepRed.withOpacity(0.7),
                                        ),
                                      )
                                    : null,
                              ),
                            ),
                          ),
                          Positioned(
                            bottom: 8,
                            right: 8,
                            child: Material(
                              color: Colors.transparent,
                              child: InkWell(
                                onTap: _pickProfileImage,
                                borderRadius: BorderRadius.circular(20),
                                child: AnimatedContainer(
                                  duration: Duration(milliseconds: 200),
                                  padding: EdgeInsets.all(12),
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    gradient: LinearGradient(
                                      colors: [deepRed, coral],
                                      begin: Alignment.topLeft,
                                      end: Alignment.bottomRight,
                                    ),
                                    boxShadow: [
                                      BoxShadow(
                                        color: deepRed.withOpacity(0.4),
                                        blurRadius: 12,
                                        offset: Offset(0, 4),
                                      ),
                                      BoxShadow(
                                        color: Colors.white.withOpacity(0.8),
                                        blurRadius: 6,
                                        offset: Offset(0, -2),
                                      ),
                                    ],
                                  ),
                                  child: Icon(
                                    Icons.camera_alt_rounded,
                                    size: 20,
                                    color: Colors.white,
                                  ),
                                ),
                              ),
                            ),
                          ),
                          // Add a subtle pulse animation hint
                          Positioned(
                            bottom: 8,
                            right: 8,
                            child: IgnorePointer(
                              child: AnimatedContainer(
                                duration: Duration(seconds: 2),
                                curve: Curves.easeInOut,
                                width: 44,
                                height: 44,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  border: Border.all(
                                    color: Colors.white.withOpacity(0.3),
                                    width: 2,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                      SizedBox(height: 16),
                      // User name centered below picture
                      Text(
                        name,
                        style: TextStyle(
                          fontSize: 26,
                          fontWeight: FontWeight.bold,
                          color: Colors.white,
                        ),
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                      ),
                      SizedBox(height: 12),
                      // Email and role in a single row
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                        children: [
                          Expanded(
                            child: _buildUserInfoCard(
                              icon: Icons.email,
                              title: 'Email',
                              value: email.length > 15 ? '${email.substring(0, 15)}...' : email,
                              color: Colors.white,
                            ),
                          ),
                          SizedBox(width: 8),
                          Expanded(
                            child: _buildUserInfoCard(
                              icon: Icons.location_on,
                              title: 'Location',
                              value: address == 'No address provided' ? 'Not set' : 
                                     (address.length > 12 ? '${address.substring(0, 12)}...' : address),
                              color: Colors.white,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),

            // Tab Section
            Container(
              decoration: BoxDecoration(
                color: lightBlush.withOpacity(0.5),
                borderRadius: BorderRadius.only(
                  topLeft: Radius.circular(20),
                  topRight: Radius.circular(20),
                ),
              ),
              child: TabBar(
                controller: _tabController,
                indicator: BoxDecoration(
                  color: deepRed,
                  borderRadius: BorderRadius.circular(12),
                ),
                indicatorSize: TabBarIndicatorSize.tab,
                indicatorPadding: EdgeInsets.all(8),
                labelColor: Colors.white,
                unselectedLabelColor: Colors.grey[600],
                labelStyle: TextStyle(fontWeight: FontWeight.w600),
                unselectedLabelStyle: TextStyle(fontWeight: FontWeight.w500),
                tabs: [
                  Tab(
                    icon: Icon(Icons.pets),
                    text: 'Assigned Pets',
                    height: 60,
                  ),
                  Tab(
                    icon: Icon(Icons.settings),
                    text: 'Settings',
                    height: 60,
                  ),
                ],
              ),
            ),

            // Tab Content
            Expanded(
              child: TabBarView(
                controller: _tabController,
                children: [
                  AssignedPetsTab(),
                  ListView(
                    padding: EdgeInsets.all(16),
                    children: [
                      _settingsTile(Icons.person, 'Account', onTap: _openAccountSettings),
                      _settingsTile(Icons.lock, 'Change Password', onTap: _openChangePassword),
                      _settingsTile(Icons.bookmark, 'Saved Posts', onTap: _openSavedPosts),
                      _notificationSettingsTile(),
                      _settingsTile(Icons.help_outline, 'Help & Support', onTap: _openHelpSupport),
                      _settingsTile(Icons.info_outline, 'About', onTap: _openAbout),
                      SizedBox(height: 16),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _settingsTile(IconData icon, String title, {VoidCallback? onTap}) {
    return Container(
      margin: EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        border: Border.all(color: Colors.grey.shade300),
        borderRadius: BorderRadius.circular(12),
        color: Colors.white,
      ),
      child: ListTile(
        leading: Icon(icon, color: deepRed),
        title: Text(title),
        onTap: onTap ?? () {},
      ),
    );
  }

  Widget _notificationSettingsTile() {
    final currentPrefs = metadata['notification_preferences'] ?? {'enabled': true};
    final enabled = currentPrefs['enabled'] ?? true;
    
    return Container(
      margin: EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        border: Border.all(color: Colors.grey.shade300),
        borderRadius: BorderRadius.circular(12),
        color: Colors.white,
      ),
      child: ListTile(
        leading: Icon(Icons.notifications, color: deepRed),
        title: Text('Notification Preferences'),
        subtitle: Text(enabled ? 'System notifications enabled' : 'System notifications disabled'),
        trailing: Icon(
          enabled ? Icons.notifications_active : Icons.notifications_off,
          color: enabled ? Colors.green : Colors.grey,
          size: 20,
        ),
        onTap: _openNotificationPreferences,
      ),
    );
  }

  // Helper method for info cards
  Widget _buildUserInfoCard({
    required IconData icon,
    required String title,
    required String value,
    required Color color,
  }) {
    return Container(
      padding: EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.2),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withOpacity(0.3), width: 1),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: color, size: 18),
          SizedBox(height: 4),
          Text(
            title,
            style: TextStyle(
              fontSize: 11,
              color: color.withOpacity(0.8),
              fontWeight: FontWeight.w500,
            ),
            textAlign: TextAlign.center,
            overflow: TextOverflow.ellipsis,
          ),
          SizedBox(height: 2),
          Text(
            value,
            style: TextStyle(
              fontSize: 12,
              color: color,
              fontWeight: FontWeight.bold,
            ),
            textAlign: TextAlign.center,
            overflow: TextOverflow.ellipsis,
            maxLines: 1,
          ),
        ],
      ),
    );
  }
}

class AssignedPetsTab extends StatefulWidget {
  @override
  _AssignedPetsTabState createState() => _AssignedPetsTabState();
}

class _AssignedPetsTabState extends State<AssignedPetsTab> {
  final supabase = Supabase.instance.client;
  List<Map<String, dynamic>> assignedPets = [];
  bool isLoading = true;
  RealtimeChannel? _jobsChannel;

  @override
  void initState() {
    super.initState();
    fetchAssignedPets();
    _setupRealtimeListener();
  }

  @override
  void dispose() {
    _jobsChannel?.unsubscribe();
    super.dispose();
  }

  void _setupRealtimeListener() {
    final sitterId = supabase.auth.currentUser?.id;
    if (sitterId == null) return;

    _jobsChannel = supabase
        .channel('assigned_pets_${sitterId}')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'sitting_jobs',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'sitter_id',
            value: sitterId,
          ),
          callback: (payload) {
            print('🔄 Real-time update for assigned pets');
            fetchAssignedPets();
          },
        )
        .subscribe();
  }

  // Helper method to get formatted age for pet display
  String _getFormattedAge(Map<String, dynamic> pet) {
    if (pet['date_of_birth'] != null) {
      try {
        final birthDate = DateTime.parse(pet['date_of_birth'].toString());
        return _formatAgeFromBirthDate(birthDate);
      } catch (e) {
        return 'Age unknown';
      }
    } else {
      return 'Age unknown';
    }
  }

  // Helper method to format age from birth date
  String _formatAgeFromBirthDate(DateTime birthDate) {
    final now = DateTime.now();
    int years = now.year - birthDate.year;
    int months = now.month - birthDate.month;
    int days = now.day - birthDate.day;

    if (days < 0) {
      months--;
      days += DateTime(now.year, now.month, 0).day;
    }
    if (months < 0) {
      years--;
      months += 12;
    }

    if (years > 0) {
      if (months > 0) {
        return '$years ${years == 1 ? 'year' : 'years'}, $months ${months == 1 ? 'month' : 'months'} old';
      } else {
        return '$years ${years == 1 ? 'year' : 'years'} old';
      }
    } else if (months > 0) {
      if (days > 0) {
        return '$months ${months == 1 ? 'month' : 'months'}, $days ${days == 1 ? 'day' : 'days'} old';
      } else {
        return '$months ${months == 1 ? 'month' : 'months'} old';
      }
    } else {
      return '$days ${days == 1 ? 'day' : 'days'} old';
    }
  }

  Future<void> fetchAssignedPets() async {
    final sitterId = supabase.auth.currentUser?.id;

    if (sitterId == null) {
      print('❌ No sitter ID found');
      setState(() {
        isLoading = false;
      });
      return;
    }

    try {
      print('🔍 Fetching assigned pets for sitter: $sitterId');
      
      // Step 1: Get all active sitting jobs for this sitter
      final jobsResponse = await supabase
          .from('sitting_jobs')
          .select('id, pet_id, status, start_date, end_date, created_at')
          .eq('sitter_id', sitterId)
          .eq('status', 'Active');

      print('✅ Found ${jobsResponse.length} active sitting jobs');
      if (jobsResponse.isNotEmpty) {
        print('📍 First job data: ${jobsResponse[0]}');
      }

      if (jobsResponse.isEmpty) {
        setState(() {
          assignedPets = [];
          isLoading = false;
        });
        return;
      }

      // Step 2: Extract pet IDs and fetch pet details
      final petIds = (jobsResponse as List)
          .map((job) => job['pet_id']?.toString())
          .where((id) => id != null && id.isNotEmpty)
          .cast<String>()
          .toList();

      print('🐕 Extracted ${petIds.length} pet IDs');
      for (var id in petIds) {
        print('   - $id');
      }

      if (petIds.isEmpty) {
        setState(() {
          assignedPets = [];
          isLoading = false;
        });
        return;
      }

      // Fetch all pets in one query
      List<dynamic> petsResponse = [];
      try {
        petsResponse = await supabase
            .from('pets')
            .select('id, name, breed, date_of_birth, owner_id, profile_picture')
            .inFilter('id', petIds);
        print('✅ Fetched ${petsResponse.length} pet details');
      } catch (petError) {
        print('❌ Error fetching pets: $petError');
        rethrow;
      }

      // Step 3: Fetch owner information for each unique owner_id
      final ownerIds = petsResponse
          .map((pet) => pet['owner_id']?.toString())
          .where((id) => id != null && id.isNotEmpty)
          .toSet()
          .toList();

      print('👤 Fetching ${ownerIds.length} owner details');

      Map<String, dynamic> ownerMap = {};
      if (ownerIds.isNotEmpty) {
        try {
          final ownersResponse = await supabase
              .from('users')
              .select('id, name, profile_picture')
              .inFilter('id', ownerIds);

          print('✅ Fetched ${ownersResponse.length} owner records');
          for (var owner in ownersResponse) {
            ownerMap[owner['id']?.toString() ?? ''] = owner;
          }
        } catch (ownerError) {
          print('⚠️ Error fetching owners: $ownerError');
          // Continue without owner data
        }
      }

      // Step 4: Combine data
      List<Map<String, dynamic>> enrichedPets = [];
      for (var job in jobsResponse) {
        final petId = job['pet_id']?.toString();
        if (petId == null) continue;
        
        Map<String, dynamic>? pet;
        try {
          pet = petsResponse.firstWhere(
            (p) => p['id']?.toString() == petId,
          ) as Map<String, dynamic>?;
        } catch (e) {
          print('⚠️ Pet not found for ID: $petId');
          continue;
        }

        if (pet != null) {
          final ownerId = pet['owner_id']?.toString() ?? '';
          final owner = ownerMap[ownerId];

          enrichedPets.add({
            'job_id': job['id'],
            'status': job['status'],
            'start_date': job['start_date'],
            'end_date': job['end_date'],
            'pet': pet,
            'owner': owner,
          });
          print('✅ Enriched pet: ${pet['name']}');
        }
      }

      print('📋 Successfully enriched ${enrichedPets.length} pets with owner data');

      setState(() {
        assignedPets = enrichedPets;
        isLoading = false;
      });
    } catch (e) {
      print('❌ Error fetching assigned pets: $e');
      print('   Stack: ${StackTrace.current}');
      setState(() => isLoading = false);
    }
  }

  // New: pull-to-refresh handler
  Future<void> _refreshAll() async {
    await fetchAssignedPets();
  }

  @override
  Widget build(BuildContext context) {
    if (isLoading) {
      return Center(child: CircularProgressIndicator(color: deepRed));
    }

    return RefreshIndicator(
      onRefresh: _refreshAll,
      child: assignedPets.isEmpty
          ? ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              children: [
                SizedBox(height: 120),
                Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.pets, size: 64, color: Colors.grey[400]),
                      SizedBox(height: 16),
                      Text(
                        'No assigned pets yet.',
                        style: TextStyle(fontSize: 18, color: Colors.grey[600]),
                      ),
                      SizedBox(height: 8),
                      Text(
                        'Pet sitting requests will appear here!',
                        style: TextStyle(color: Colors.grey[500]),
                      ),
                    ],
                  ),
                ),
              ],
            )
          : ListView.builder(
              physics: const AlwaysScrollableScrollPhysics(),
              itemCount: assignedPets.length,
              itemBuilder: (context, index) {
                final record = assignedPets[index];
                final pet = record['pet'] as Map<String, dynamic>?;
                final owner = record['owner'] as Map<String, dynamic>?;
                
                if (pet == null) {
                  print('⚠️ Null pet at index $index');
                  return SizedBox.shrink();
                }
                
                return _assignedPetListTile(pet, owner);
              },
            ),
    );
  }

  // Enhanced pet tile with modern styling adapted for assigned pets
  Widget _assignedPetListTile(Map<String, dynamic> pet, Map<String, dynamic>? owner) {
    return Container(
      margin: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.08),
            blurRadius: 15,
            offset: Offset(0, 3),
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: () {
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => PetProfileScreen(initialPet: pet),
              ),
            );
          },
          child: Padding(
            padding: EdgeInsets.all(16),
            child: Row(
              children: [
                Container(
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(color: coral.withOpacity(0.3), width: 2),
                  ),
                  child: CircleAvatar(
                    radius: 30,
                    backgroundColor: lightBlush,
                    backgroundImage: (pet['profile_picture'] != null &&
                            pet['profile_picture'].toString().isNotEmpty)
                        ? NetworkImage(pet['profile_picture'])
                        : null,
                    child: (pet['profile_picture'] == null ||
                            pet['profile_picture'].toString().isEmpty)
                        ? Icon(Icons.pets, color: coral, size: 30)
                        : null,
                  ),
                ),
                SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        pet['name'] ?? 'Unnamed',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                          color: deepRed,
                        ),
                      ),
                      SizedBox(height: 4),
                      Text(
                        '${pet['breed'] ?? 'Unknown'} • ${_getFormattedAge(pet)}',
                        style: TextStyle(
                          fontSize: 14,
                          color: Colors.grey[600],
                        ),
                      ),
                      SizedBox(height: 6),
                      Container(
                        padding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                          color: peach.withOpacity(0.2),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.person, size: 12, color: deepRed),
                            SizedBox(width: 4),
                            Text(
                              'Owner: ${owner?['name'] ?? 'Unknown'}',
                              style: TextStyle(
                                fontSize: 12,
                                color: deepRed,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                Container(
                  padding: EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: coral.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Icon(
                    Icons.arrow_forward_ios,
                    color: coral,
                    size: 16,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class SitterSettingsTab extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: EdgeInsets.all(16),
      children: [
        _settingsTile(Icons.lock, 'Change Password'),
        _settingsTile(Icons.notifications, 'Notification Preferences'),
        _settingsTile(Icons.help_outline, 'Help & Support'),
        _settingsTile(Icons.info_outline, 'About'),
        SizedBox(height: 16),
      ],
    );
  }

  Widget _settingsTile(IconData icon, String title) {
    return Container(
      margin: EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        border: Border.all(color: Colors.grey.shade300),
        borderRadius: BorderRadius.circular(12),
        color: Colors.white,
      ),
      child: ListTile(
        leading: Icon(icon, color: deepRed),
        title: Text(title),
        onTap: () {},
      ),
    );
  }
}

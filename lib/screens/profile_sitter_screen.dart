import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:image_picker/image_picker.dart';
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
  void _openFeedbackDialog() async {
    TextEditingController feedbackController = TextEditingController();
    await showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Report or Feedback'),
        content: Container(
          decoration: BoxDecoration(
            border: Border.all(color: Colors.grey, width: 1.5),
            borderRadius: BorderRadius.circular(8),
          ),
          padding: EdgeInsets.all(4),
          child: TextField(
            controller: feedbackController,
            style: TextStyle(color: Colors.black),
            decoration: InputDecoration(
              hintText: 'Let us know your feedback or report an issue...',
              hintStyle: TextStyle(color: Colors.grey),
              border: InputBorder.none,
              contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 8),
            ),
            maxLines: 4,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () async {
              final text = feedbackController.text.trim();
              if (text.isEmpty) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('Please enter your feedback or report.')),
                );
                return;
              }
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
                  SnackBar(content: Text('Thank you for your feedback!')),
                );
              } catch (e) {
                Navigator.pop(context);
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('Failed to submit feedback. Please try again.')),
                );
              }
            },
            child: Text('Submit'),
          ),
        ],
      ),
    );
  }
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
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setSt) {
            return SafeArea(
              child: Container(
                color: lightBlush,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        IconButton(
                          icon: const Icon(Icons.arrow_back, color: deepRed),
                          onPressed: () => Navigator.pop(ctx),
                        ),
                        Expanded(
                          child: Center(
                            child: Text(
                              'Account',
                              style: TextStyle(
                                fontSize: 24,
                                fontWeight: FontWeight.bold,
                                color: deepRed,
                                letterSpacing: 0.5,
                              ),
                            ),
                          ),
                        ),
                        SizedBox(width: 48),
                      ],
                    ),
                    SingleChildScrollView(
                      padding: EdgeInsets.all(16),
                      child: Column(
                        children: [
                          Container(
                            decoration: BoxDecoration(
                              border: Border.all(color: Colors.grey.shade400),
                              borderRadius: BorderRadius.circular(12),
                              color: Colors.white,
                            ),
                            margin: EdgeInsets.only(bottom: 16),
                            child: TextFormField(
                              enabled: false,
                              initialValue: email,
                              decoration: InputDecoration(
                                labelText: 'Email',
                                border: InputBorder.none,
                                contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                              ),
                            ),
                          ),
                          Container(
                            decoration: BoxDecoration(
                              border: Border.all(color: Colors.grey.shade400),
                              borderRadius: BorderRadius.circular(12),
                              color: Colors.white,
                            ),
                            margin: EdgeInsets.only(bottom: 16),
                            child: TextFormField(
                              initialValue: newName,
                              decoration: InputDecoration(
                                labelText: 'Name',
                                border: InputBorder.none,
                                contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                              ),
                              onChanged: (v) => setSt(() => newName = v),
                            ),
                          ),
                          Container(
                            decoration: BoxDecoration(
                              border: Border.all(color: Colors.grey.shade400),
                              borderRadius: BorderRadius.circular(12),
                              color: Colors.white,
                            ),
                            margin: EdgeInsets.only(bottom: 16),
                            child: TextFormField(
                              initialValue: newAddress,
                              decoration: InputDecoration(
                                labelText: 'Address',
                                border: InputBorder.none,
                                contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                              ),
                              onChanged: (v) => setSt(() => newAddress = v),
                            ),
                          ),
                          SizedBox(height: 16),
                          Container(
                            width: double.infinity,
                            child: ElevatedButton(
                              style: ElevatedButton.styleFrom(
                                backgroundColor: deepRed,
                                padding: EdgeInsets.symmetric(vertical: 12),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(12),
                                ),
                              ),
                              onPressed: () async {
                                setSt(() => isLoading = true);
                                try {
                                  final supabase = Supabase.instance.client;
                                  
                                  // Update public.users table (name and address)
                                  await supabase
                                      .from('users')
                                      .update({
                                        'name': newName,
                                        'address': newAddress,
                                      })
                                      .eq('id', user!.id);
                                  
                                  // Update auth metadata (name and address for backward compatibility)
                                  await supabase.auth.updateUser(UserAttributes(data: {
                                    'name': newName,
                                    'address': newAddress,
                                  }));
                                  
                                  await _refreshUserMetadata();
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(content: Text('Account updated')),
                                  );
                                  Navigator.pop(ctx);
                                } catch (e) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(content: Text('Failed to update account: ${e.toString()}')),
                                  );
                                }
                                setSt(() => isLoading = false);
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
                                  : Text(
                                      'Save Changes',
                                      style: TextStyle(
                                        fontSize: 16,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                            ),
                          ),
                          SizedBox(height: 16),
                          Container(
                            width: double.infinity,
                            child: TextButton(
                              style: TextButton.styleFrom(
                                foregroundColor: Colors.red,
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
                                        child: Text('Cancel'),
                                      ),
                                      TextButton(
                                        onPressed: () => Navigator.pop(context, true),
                                        child: Text('Delete', style: TextStyle(color: Colors.red)),
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
                              child: Text('Delete Account'),
                            ),
                          ),
                        ],
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
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        bool enabled = currentPrefs['enabled'] ?? true;
        return StatefulBuilder(
          builder: (ctx, setSt) {
            return SafeArea(
              child: Padding(
                padding: EdgeInsets.only(
                  bottom: MediaQuery.of(ctx).viewInsets.bottom,
                ),
                child: Container(
                  color: lightBlush,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        children: [
                          IconButton(
                            icon: Icon(Icons.arrow_back, color: deepRed),
                            onPressed: () => Navigator.pop(ctx),
                          ),
                          Expanded(
                            child: Center(
                              child: Text(
                                'Notifications',
                                style: TextStyle(
                                  fontSize: 24,
                                  fontWeight: FontWeight.bold,
                                  color: deepRed,
                                  letterSpacing: 0.5,
                                ),
                              ),
                            ),
                          ),
                          SizedBox(width: 48),
                        ],
                      ),
                      SingleChildScrollView(
                        padding: EdgeInsets.all(16),
                        child: Column(
                          children: [
                            Container(
                              decoration: BoxDecoration(
                                border: Border.all(color: Colors.grey.shade400),
                                borderRadius: BorderRadius.circular(12),
                                color: Colors.white,
                              ),
                              margin: EdgeInsets.only(bottom: 16),
                              child: SwitchListTile(
                                title: Text('Enable Notifications'),
                                value: enabled,
                                onChanged: (v) => setSt(() => enabled = v),
                              ),
                            ),
                            SizedBox(height: 8),
                            SizedBox(
                              width: double.infinity,
                              child: ElevatedButton(
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: deepRed,
                                  padding: EdgeInsets.symmetric(vertical: 12),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                ),
                                onPressed: () async {
                                  try {
                                    await Supabase.instance.client.auth.updateUser(
                                      UserAttributes(data: {
                                        'notification_preferences': {'enabled': enabled}
                                      })
                                    );
                                    Navigator.pop(ctx);
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      SnackBar(content: Text('Notification preferences updated')),
                                    );
                                  } catch (e) {
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      SnackBar(content: Text('Failed to update preferences: ${e.toString()}')),
                                    );
                                  }
                                },
                                child: Text(
                                  'Save',
                                  style: TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.bold,
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
          },
        );
      },
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
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setSt) {
            return SafeArea(
              child: Padding(
                padding: EdgeInsets.only(
                  bottom: MediaQuery.of(ctx).viewInsets.bottom,
                ),
                child: Container(
                  color: lightBlush,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        children: [
                          IconButton(
                            icon: Icon(Icons.arrow_back, color: deepRed),
                            onPressed: () => Navigator.pop(ctx),
                          ),
                          Expanded(
                            child: Center(
                              child: Text(
                                'Change Password',
                                style: TextStyle(
                                  fontSize: 24,
                                  fontWeight: FontWeight.bold,
                                  color: deepRed,
                                  letterSpacing: 0.5,
                                ),
                              ),
                            ),
                          ),
                          SizedBox(width: 48),
                        ],
                      ),
                      Flexible(
                        child: SingleChildScrollView(
                          padding: EdgeInsets.all(16),
                          child: Column(
                            children: [
                              Container(
                                decoration: BoxDecoration(
                                  border: Border.all(color: Colors.grey.shade400),
                                  borderRadius: BorderRadius.circular(12),
                                  color: Colors.white,
                                ),
                                margin: EdgeInsets.only(bottom: 16),
                                child: TextFormField(
                                  controller: _currentPasswordController,
                                  obscureText: !_showCurrentPassword,
                                  decoration: InputDecoration(
                                    labelText: 'Current Password',
                                    border: InputBorder.none,
                                    contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                    suffixIcon: IconButton(
                                      icon: Icon(_showCurrentPassword ? Icons.visibility_off : Icons.visibility),
                                      onPressed: () => setSt(() => _showCurrentPassword = !_showCurrentPassword),
                                    ),
                                  ),
                                ),
                              ),
                              Container(
                                decoration: BoxDecoration(
                                  border: Border.all(color: Colors.grey.shade400),
                                  borderRadius: BorderRadius.circular(12),
                                  color: Colors.white,
                                ),
                                margin: EdgeInsets.only(bottom: 16),
                                child: TextFormField(
                                  controller: _newPasswordController,
                                  obscureText: !_showNewPassword,
                                  decoration: InputDecoration(
                                    labelText: 'New Password',
                                    border: InputBorder.none,
                                    contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                    suffixIcon: IconButton(
                                      icon: Icon(_showNewPassword ? Icons.visibility_off : Icons.visibility),
                                      onPressed: () => setSt(() => _showNewPassword = !_showNewPassword),
                                    ),
                                  ),
                                ),
                              ),
                              Container(
                                decoration: BoxDecoration(
                                  border: Border.all(color: Colors.grey.shade400),
                                  borderRadius: BorderRadius.circular(12),
                                  color: Colors.white,
                                ),
                                margin: EdgeInsets.only(bottom: 16),
                                child: TextFormField(
                                  controller: _confirmPasswordController,
                                  obscureText: !_showConfirmPassword,
                                  decoration: InputDecoration(
                                    labelText: 'Confirm New Password',
                                    border: InputBorder.none,
                                    contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                    suffixIcon: IconButton(
                                      icon: Icon(_showConfirmPassword ? Icons.visibility_off : Icons.visibility),
                                      onPressed: () => setSt(() => _showConfirmPassword = !_showConfirmPassword),
                                    ),
                                  ),
                                ),
                              ),
                              // Password requirements text
                              Align(
                                alignment: Alignment.centerLeft,
                                child: Padding(
                                  padding: const EdgeInsets.only(bottom: 16, left: 4),
                                  child: Text(
                                    'Password must contain:\n• At least 8 characters\n• One uppercase letter\n• One lowercase letter\n• One number\n• One special character',
                                    style: TextStyle(
                                      color: Colors.grey[600],
                                      fontSize: 12,
                                    ),
                                    textAlign: TextAlign.left,
                                  ),
                                ),
                              ),
                              SizedBox(
                                width: double.infinity,
                                child: ElevatedButton(
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: deepRed,
                                    padding: EdgeInsets.symmetric(vertical: 12),
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(12),
                                    ),
                                  ),
                                  onPressed: _isLoading ? null : () async {
                                    if (_newPasswordController.text.isEmpty ||
                                        _currentPasswordController.text.isEmpty ||
                                        _confirmPasswordController.text.isEmpty) {
                                      ScaffoldMessenger.of(context).showSnackBar(
                                        SnackBar(content: Text('Please fill in all fields')),
                                      );
                                      return;
                                    }

                                    if (_newPasswordController.text != _confirmPasswordController.text) {
                                      ScaffoldMessenger.of(context).showSnackBar(
                                        SnackBar(content: Text('New passwords do not match')),
                                      );
                                      return;
                                    }

                                    final password = _newPasswordController.text;
                                    if (password.length < 8 ||
                                        !RegExp(r'[A-Z]').hasMatch(password) ||
                                        !RegExp(r'[a-z]').hasMatch(password) ||
                                        !RegExp(r'[0-9]').hasMatch(password) ||
                                        !RegExp(r'[!@#\$&*~_.,%^()\-\+=]').hasMatch(password)) {
                                      ScaffoldMessenger.of(context).showSnackBar(
                                        SnackBar(content: Text('Password does not meet requirements')),
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
                                        SnackBar(content: Text('Password updated successfully')),
                                      );
                                    } catch (e) {
                                      ScaffoldMessenger.of(context).showSnackBar(
                                        SnackBar(content: Text('Failed to update password: ${e.toString()}')),
                                      );
                                    }
                                    setSt(() => _isLoading = false);
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
                                      : Text(
                                          'Update Password',
                                          style: TextStyle(
                                            fontSize: 16,
                                            fontWeight: FontWeight.bold,
                                          ),
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
              ),
            );
          },
        );
      },
    );
  }

  // Open dialog for theme settings
  // Open dialog for help & support
  void _openHelpSupport() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        return SafeArea(
          child: Container(
            color: lightBlush,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    IconButton(
                      icon: const Icon(Icons.arrow_back, color: deepRed),
                      onPressed: () => Navigator.pop(ctx),
                    ),
                    Expanded(
                      child: Center(
                        child: Text(
                          'Help & Support',
                          style: TextStyle(
                            fontSize: 24,
                            fontWeight: FontWeight.bold,
                            color: deepRed,
                            letterSpacing: 0.5,
                          ),
                        ),
                      ),
                    ),
                    SizedBox(width: 48),
                  ],
                ),
                SingleChildScrollView(
                  padding: EdgeInsets.all(16),
                  child: Column(
                    children: [
                      Container(
                        decoration: BoxDecoration(
                          border: Border.all(color: Colors.grey.shade400),
                          borderRadius: BorderRadius.circular(12),
                          color: Colors.white,
                        ),
                        margin: EdgeInsets.only(bottom: 16),
                        child: Column(
                          children: [
                            ListTile(
                              title: Text('Contact Support'),
                              subtitle: Text('Reach out to our support team'),
                              leading: Icon(Icons.support_agent, color: deepRed),
                              trailing: Icon(Icons.arrow_forward_ios, size: 16),
                              onTap: () {
                                // Add contact support action
                              },
                            ),
                            Divider(height: 1),
                            ListTile(
                              title: Text('FAQs'),
                              subtitle: Text('Find answers to common questions'),
                              leading: Icon(Icons.question_answer, color: deepRed),
                              trailing: Icon(Icons.arrow_forward_ios, size: 16),
                              onTap: () {
                                // Add FAQs action
                              },
                            ),
                            Divider(height: 1),
                            ListTile(
                              title: Text('Report an Issue'),
                              subtitle: Text('Let us know if something\'s not working'),
                              leading: Icon(Icons.bug_report, color: deepRed),
                              trailing: Icon(Icons.arrow_forward_ios, size: 16),
                              onTap: () {
                                // Add report issue action
                              },
                            ),
                          ],
                        ),
                      ),
                      Container(
                        decoration: BoxDecoration(
                          border: Border.all(color: Colors.grey.shade400),
                          borderRadius: BorderRadius.circular(12),
                          color: Colors.white,
                        ),
                        margin: EdgeInsets.only(bottom: 16),
                        child: Column(
                          children: [
                            ListTile(
                              leading: Icon(Icons.email, color: deepRed),
                              title: Text('Email Support'),
                              subtitle: Text('support@pettrackcare.com'),
                              onTap: () {
                                // Add email support action
                              },
                            ),
                            Divider(height: 1),
                            ListTile(
                              leading: Icon(Icons.phone, color: deepRed),
                              title: Text('Phone Support'),
                              subtitle: Text('+1 123-456-7890'),
                              onTap: () {
                                // Add phone support action
                              },
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  // Open dialog for about information
  void _openAbout() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Padding(
            padding: EdgeInsets.only(
              bottom: MediaQuery.of(ctx).viewInsets.bottom,
            ),
            child: Container(
              color: lightBlush,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      IconButton(
                        icon: Icon(Icons.arrow_back, color: deepRed),
                        onPressed: () => Navigator.pop(ctx),
                      ),
                      Expanded(
                        child: Center(
                          child: Text(
                            'About',
                            style: TextStyle(
                              fontSize: 24,
                              fontWeight: FontWeight.bold,
                              color: deepRed,
                              letterSpacing: 0.5,
                            ),
                          ),
                        ),
                      ),
                      SizedBox(width: 48),
                    ],
                  ),
                  SingleChildScrollView(
                    padding: EdgeInsets.all(16),
                    child: Column(
                      children: [
                        Container(
                          decoration: BoxDecoration(
                            border: Border.all(color: Colors.grey.shade400),
                            borderRadius: BorderRadius.circular(12),
                            color: Colors.white,
                          ),
                          margin: EdgeInsets.only(bottom: 16),
                          padding: EdgeInsets.symmetric(vertical: 16, horizontal: 16),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'PetTrackCare',
                                style: TextStyle(
                                  fontSize: 20,
                                  fontWeight: FontWeight.bold,
                                  color: deepRed,
                                ),
                              ),
                              SizedBox(height: 8),
                              Text(
                                'Version 1.0.0',
                                style: TextStyle(
                                  color: Colors.grey[700],
                                ),
                              ),
                              SizedBox(height: 16),
                              Text(
                                'PetTrackCare is a comprehensive app designed to help pet owners monitor and manage their pets\' health, activities, and daily care routines.',
                                style: TextStyle(
                                  fontSize: 15,
                                  color: Colors.grey[800],
                                ),
                              ),
                              SizedBox(height: 16),
                              Divider(),
                              SizedBox(height: 16),
                              Text(
                                'Developed by:',
                                style: TextStyle(
                                  fontWeight: FontWeight.bold,
                                  color: Colors.grey[800],
                                ),
                              ),
                              SizedBox(height: 4),
                              Text(
                                'PetTrackCare Team',
                                style: TextStyle(
                                  color: Colors.grey[700],
                                ),
                              ),
                              SizedBox(height: 8),
                              Text(
                                'Contact:',
                                style: TextStyle(
                                  fontWeight: FontWeight.bold,
                                  color: Colors.grey[800],
                                ),
                              ),
                              SizedBox(height: 4),
                              Text(
                                'support@pettrackcare.com',
                                style: TextStyle(
                                  color: deepRed,
                                ),
                              ),
                            ],
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
      },
    );
  }
  
  void _openSavedPosts() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        return SavedPostsModal(userId: user?.id ?? '');
      },
    );
  }

  Future<void> _pickProfileImage() async {
    final pickedFile = await _picker.pickImage(source: ImageSource.gallery);
    if (pickedFile == null) return;

    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text('Confirm Profile Picture'),
          content: Image.file(File(pickedFile.path)),
          actions: [
            TextButton(
              child: Text('Cancel', style: TextStyle(color: Colors.grey)),
              onPressed: () => Navigator.of(context).pop(false),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: deepRed),
              child: Text('Confirm'),
              onPressed: () => Navigator.of(context).pop(true),
            ),
          ],
        );
      },
    );

    if (confirm != true) return;

    final file = File(pickedFile.path);
    final fileBytes = await file.readAsBytes();
    final fileName =
        'profile_images/${user!.id}_${DateTime.now().millisecondsSinceEpoch}.jpg';

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

      print('✅ Profile picture updated!');
    } catch (e) {
      print('❌ Error uploading profile image: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: lightBlush,
      appBar: AppBar(
        title: Text('Sitter Profile', style: TextStyle(fontWeight: FontWeight.bold)),
        backgroundColor: Color(0xFFCB4154),
        elevation: 0,
        actions: [
          IconButton(
            icon: Icon(Icons.logout, color: Colors.white),
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
                      child: Text('Cancel'),
                    ),
                    ElevatedButton(
                      style: ElevatedButton.styleFrom(backgroundColor: deepRed),
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
        ],
      ),
      body: Column(
        children: [
          // Profile Info (same as owner, but for sitter)
          Container(
            margin: EdgeInsets.only(top: 16),
            child: Stack(
              alignment: Alignment.bottomRight,
              children: [
                Container(
                  padding: EdgeInsets.all(4),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(color: deepRed, width: 2),
                  ),
                  child: CircleAvatar(
                    radius: 60,
                    backgroundColor: Colors.white,
                    backgroundImage: _profileImage != null
                        ? FileImage(_profileImage!)
                        : (userData['profile_picture'] != null && userData['profile_picture'].toString().isNotEmpty
                            ? NetworkImage(userData['profile_picture'])
                            : null),
                    child: (_profileImage == null && (userData['profile_picture'] == null || userData['profile_picture'].toString().isEmpty))
                        ? Icon(Icons.person, size: 60, color: Colors.grey[400])
                        : null,
                  ),
                ),
                Positioned(
                  bottom: 4,
                  right: 4,
                  child: GestureDetector(
                    onTap: _pickProfileImage,
                    child: Container(
                      padding: EdgeInsets.all(6),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: deepRed,
                      ),
                      child: Icon(
                        Icons.camera_alt,
                        size: 20,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          SizedBox(height: 12),
          Text(
            name,
            style: TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.bold,
              color: deepRed,
            ),
          ),
          Text(
            email,
            style: TextStyle(
              fontSize: 16,
            ),
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.location_on, color: Colors.grey[600], size: 16),
              SizedBox(width: 4),
              Text(
                address,
                style: TextStyle(fontSize: 14, color: Colors.grey[700]),
              ),
            ],
          ),
          SizedBox(height: 16),

          // White rounded container with tabs and tab content
          Expanded(
            child: Container(
              margin: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.grey.shade300),
              ),
              child: Column(
                children: [
                  TabBar(
                    controller: _tabController,
                    indicatorColor: deepRed,
                    labelColor: deepRed,
                    unselectedLabelColor: Colors.grey,
                    tabs: [
                      Tab(icon: Icon(Icons.pets), text: 'Assigned Pets'),
                      Tab(icon: Icon(Icons.settings), text: 'Settings'),
                    ],
                  ),
                  Divider(height: 1, color: Colors.grey.shade300),
                  Expanded(
                    child: TabBarView(
                      controller: _tabController,
                      children: [
                        AssignedPetsTab(),
                        ListView(
                          padding: EdgeInsets.all(16),
                          children: [
                            _settingsTile(Icons.person, 'Account', onTap: _openAccountSettings),
                            _settingsTile(Icons.feedback, 'Report or Feedback', onTap: _openFeedbackDialog),
                            _settingsTile(Icons.lock, 'Change Password', onTap: _openChangePassword),
                            _settingsTile(Icons.bookmark, 'Saved Posts', onTap: _openSavedPosts),
                            _settingsTile(Icons.notifications, 'Notification Preferences', onTap: _openNotificationPreferences),
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
          ),
        ],
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
}

class AssignedPetsTab extends StatefulWidget {
  @override
  _AssignedPetsTabState createState() => _AssignedPetsTabState();
}

class _AssignedPetsTabState extends State<AssignedPetsTab> {
  final supabase = Supabase.instance.client;
  List<Map<String, dynamic>> assignedPets = [];
  bool isLoading = true;

  @override
  void initState() {
    super.initState();
    fetchAssignedPets();
  }

  Future<void> fetchAssignedPets() async {
    final sitterId = supabase.auth.currentUser?.id;

    if (sitterId == null) {
      setState(() {
        isLoading = false;
      });
      return;
    }

    try {
      final response = await supabase
      .from('sitting_jobs')
      .select('''
        pets (
          id, name, breed, age, owner_id, profile_picture,
          users!owner_id (
            name
          )
        )
      ''')
      .eq('sitter_id', sitterId)
      .or('status.eq.Accepted,status.eq.Active');

      setState(() {
        assignedPets = List<Map<String, dynamic>>.from(response);
        isLoading = false;
      });
    } catch (e) {
      print('Error fetching assigned pets: $e');
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
              children: const [
                SizedBox(height: 120),
                Center(child: Text('No assigned pets yet.', style: TextStyle(color: Colors.grey))),
              ],
            )
          : ListView.builder(
              physics: const AlwaysScrollableScrollPhysics(),
              itemCount: assignedPets.length,
              itemBuilder: (context, index) {
                final pet = assignedPets[index]['pets'];
                final owner = pet['users'];
                return Container(
                  margin: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    border: Border.all(color: Colors.grey.shade300),
                    borderRadius: BorderRadius.circular(12),
                    color: Colors.white,
                  ),
                  child: ListTile(
                    leading: CircleAvatar(
                      radius: 25,
                      backgroundColor: Colors.grey[200],
                      backgroundImage: (pet['profile_picture'] != null && 
                                     pet['profile_picture'].toString().isNotEmpty)
                          ? NetworkImage(pet['profile_picture'])
                          : null,
                      child: (pet['profile_picture'] == null || 
                             pet['profile_picture'].toString().isEmpty)
                          ? Icon(Icons.pets, color: deepRed, size: 30)
                          : null,
                    ),
                    title: Text(pet['name'] ?? 'Unnamed'),
                    subtitle: Text(
                      'Breed: ${pet['breed'] ?? 'N/A'} | Age: ${pet['age'] ?? 'N/A'}\nOwner: ${owner?['name'] ?? 'Unknown'}',
                    ),
                    trailing: Icon(Icons.arrow_forward_ios, size: 16, color: Colors.grey),
                    onTap: () {
                      // Navigate to pet profile screen with the selected pet data
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (context) => PetProfileScreen(initialPet: pet),
                        ),
                      );
                    },
                  ),
                );
              },
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

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import '../services/permission_service.dart';

/// Utility class for handling image picking with proper permission checks
class ImagePickerUtils {
  static final ImagePicker _picker = ImagePicker();

  /// Pick image from camera with permission check
  static Future<XFile?> pickFromCamera(BuildContext context) async {
    final hasPermission = await PermissionService.requestCameraPermissionWithDialog(context);
    
    if (!hasPermission) {
      _showPermissionDeniedSnackBar(context, 'Camera access is required to take photos');
      return null;
    }

    try {
      final XFile? image = await _picker.pickImage(
        source: ImageSource.camera,
        maxWidth: 1920,
        maxHeight: 1080,
        imageQuality: 80,
      );
      return image;
    } catch (e) {
      _showErrorSnackBar(context, 'Failed to take photo: $e');
      return null;
    }
  }

  /// Pick image from gallery with permission check
  static Future<XFile?> pickFromGallery(BuildContext context) async {
    final hasPermission = await PermissionService.requestGalleryPermissionWithDialog(context);
    
    if (!hasPermission) {
      _showPermissionDeniedSnackBar(context, 'Gallery access is required to select photos');
      return null;
    }

    try {
      final XFile? image = await _picker.pickImage(
        source: ImageSource.gallery,
        maxWidth: 1920,
        maxHeight: 1080,
        imageQuality: 80,
      );
      return image;
    } catch (e) {
      _showErrorSnackBar(context, 'Failed to select photo: $e');
      return null;
    }
  }

  /// Pick multiple images from gallery with permission check
  static Future<List<XFile>?> pickMultipleFromGallery(BuildContext context) async {
    final hasPermission = await PermissionService.requestGalleryPermissionWithDialog(context);
    
    if (!hasPermission) {
      _showPermissionDeniedSnackBar(context, 'Gallery access is required to select photos');
      return null;
    }

    try {
      final List<XFile> images = await _picker.pickMultiImage(
        maxWidth: 1920,
        maxHeight: 1080,
        imageQuality: 80,
      );
      return images;
    } catch (e) {
      _showErrorSnackBar(context, 'Failed to select photos: $e');
      return null;
    }
  }

  /// Show image picker options dialog
  static Future<XFile?> showImagePickerDialog(BuildContext context) async {
    return await showModalBottomSheet<XFile?>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (BuildContext context) {
        return Container(
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
          ),
          child: SafeArea(
            child: Wrap(
              children: [
                Container(
                  padding: EdgeInsets.all(20),
                  child: Column(
                    children: [
                      Container(
                        width: 40,
                        height: 4,
                        decoration: BoxDecoration(
                          color: Colors.grey[300],
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                      SizedBox(height: 20),
                      Text(
                        'Select Image',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                          color: Color(0xFFB82132),
                        ),
                      ),
                      SizedBox(height: 20),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                        children: [
                          _buildPickerOption(
                            context,
                            'Camera',
                            Icons.camera_alt,
                            () async {
                              Navigator.pop(context);
                              return await pickFromCamera(context);
                            },
                          ),
                          _buildPickerOption(
                            context,
                            'Gallery',
                            Icons.photo_library,
                            () async {
                              Navigator.pop(context);
                              return await pickFromGallery(context);
                            },
                          ),
                        ],
                      ),
                      SizedBox(height: 20),
                      TextButton(
                        onPressed: () => Navigator.pop(context),
                        child: Text(
                          'Cancel',
                          style: TextStyle(
                            color: Colors.grey[600],
                            fontSize: 16,
                          ),
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

  /// Build picker option widget
  static Widget _buildPickerOption(
    BuildContext context,
    String label,
    IconData icon,
    Future<XFile?> Function() onTap,
  ) {
    return GestureDetector(
      onTap: () async {
        final result = await onTap();
        if (result != null && context.mounted) {
          Navigator.pop(context, result);
        }
      },
      child: Container(
        padding: EdgeInsets.symmetric(vertical: 15, horizontal: 25),
        decoration: BoxDecoration(
          color: Color(0xFFF6DED8),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Color(0xFFD2665A).withOpacity(0.3)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 30,
              color: Color(0xFFB82132),
            ),
            SizedBox(height: 8),
            Text(
              label,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w500,
                color: Color(0xFFB82132),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Show permission denied snack bar
  static void _showPermissionDeniedSnackBar(BuildContext context, String message) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(message),
          backgroundColor: Colors.orange,
          action: SnackBarAction(
            label: 'Settings',
            textColor: Colors.white,
            onPressed: () => PermissionService.requestCameraPermissionWithDialog(context),
          ),
        ),
      );
    }
  }

  /// Show error snack bar
  static void _showErrorSnackBar(BuildContext context, String message) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(message),
          backgroundColor: Colors.red,
        ),
      );
    }
  }
}
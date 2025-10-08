import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/material.dart';

/// Permission Service for handling camera, gallery, and storage permissions
class PermissionService {
  static const String _cameraPermissionKey = 'camera_permission_requested';
  static const String _galleryPermissionKey = 'gallery_permission_requested';
  static const String _storagePermissionKey = 'storage_permission_requested';

  /// Initialize and request essential permissions on app startup
  static Future<void> initializePermissions() async {
    print('🔐 Initializing app permissions...');
    
    final prefs = await SharedPreferences.getInstance();
    
    // Check if permissions have been requested before
    final cameraRequested = prefs.getBool(_cameraPermissionKey) ?? false;
    final galleryRequested = prefs.getBool(_galleryPermissionKey) ?? false;
    final storageRequested = prefs.getBool(_storagePermissionKey) ?? false;
    
    // Request camera permission if not previously requested
    if (!cameraRequested) {
      await _requestCameraPermission(prefs);
    }
    
    // Request gallery/photos permission if not previously requested
    if (!galleryRequested) {
      await _requestGalleryPermission(prefs);
    }
    
    // Request storage permission if not previously requested
    if (!storageRequested) {
      await _requestStoragePermission(prefs);
    }
    
    // Log current permission status
    await _logPermissionStatus();
  }

  /// Request camera permission
  static Future<void> _requestCameraPermission(SharedPreferences prefs) async {
    try {
      print('📷 Requesting camera permission...');
      final status = await Permission.camera.request();
      
      await prefs.setBool(_cameraPermissionKey, true);
      
      if (status.isGranted) {
        print('✅ Camera permission granted');
      } else if (status.isDenied) {
        print('❌ Camera permission denied');
      } else if (status.isPermanentlyDenied) {
        print('🚫 Camera permission permanently denied');
      }
    } catch (e) {
      print('❗ Error requesting camera permission: $e');
    }
  }

  /// Request gallery/photos permission
  static Future<void> _requestGalleryPermission(SharedPreferences prefs) async {
    try {
      print('🖼️ Requesting gallery permission...');
      final status = await Permission.photos.request();
      
      await prefs.setBool(_galleryPermissionKey, true);
      
      if (status.isGranted) {
        print('✅ Gallery permission granted');
      } else if (status.isDenied) {
        print('❌ Gallery permission denied');
      } else if (status.isPermanentlyDenied) {
        print('🚫 Gallery permission permanently denied');
      }
    } catch (e) {
      print('❗ Error requesting gallery permission: $e');
    }
  }

  /// Request storage permission (for older Android versions)
  static Future<void> _requestStoragePermission(SharedPreferences prefs) async {
    try {
      print('💾 Requesting storage permission...');
      final status = await Permission.storage.request();
      
      await prefs.setBool(_storagePermissionKey, true);
      
      if (status.isGranted) {
        print('✅ Storage permission granted');
      } else if (status.isDenied) {
        print('❌ Storage permission denied');
      } else if (status.isPermanentlyDenied) {
        print('🚫 Storage permission permanently denied');
      }
    } catch (e) {
      print('❗ Error requesting storage permission: $e');
    }
  }

  /// Log current permission status for debugging
  static Future<void> _logPermissionStatus() async {
    print('📊 Current Permission Status:');
    print('   Camera: ${await Permission.camera.status}');
    print('   Photos: ${await Permission.photos.status}');
    print('   Storage: ${await Permission.storage.status}');
  }

  /// Check if camera permission is granted
  static Future<bool> isCameraPermissionGranted() async {
    return await Permission.camera.isGranted;
  }

  /// Check if gallery permission is granted
  static Future<bool> isGalleryPermissionGranted() async {
    return await Permission.photos.isGranted;
  }

  /// Check if storage permission is granted
  static Future<bool> isStoragePermissionGranted() async {
    return await Permission.storage.isGranted;
  }

  /// Request camera permission with user-friendly handling
  static Future<bool> requestCameraPermissionWithDialog(BuildContext context) async {
    final status = await Permission.camera.status;
    
    if (status.isGranted) {
      return true;
    }
    
    if (status.isPermanentlyDenied) {
      return await _showPermissionDeniedDialog(
        context,
        'Camera Permission Required',
        'Camera access is needed to take photos of your pets. Please enable it in app settings.',
      );
    }
    
    final result = await Permission.camera.request();
    return result.isGranted;
  }

  /// Request gallery permission with user-friendly handling
  static Future<bool> requestGalleryPermissionWithDialog(BuildContext context) async {
    final status = await Permission.photos.status;
    
    if (status.isGranted) {
      return true;
    }
    
    if (status.isPermanentlyDenied) {
      return await _showPermissionDeniedDialog(
        context,
        'Gallery Permission Required',
        'Gallery access is needed to select photos of your pets. Please enable it in app settings.',
      );
    }
    
    final result = await Permission.photos.request();
    return result.isGranted;
  }

  /// Show dialog when permission is permanently denied
  static Future<bool> _showPermissionDeniedDialog(
    BuildContext context,
    String title,
    String message,
  ) async {
    return await showDialog<bool>(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: Text(title),
          content: Text(message),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: Text('Cancel'),
            ),
            TextButton(
              onPressed: () {
                Navigator.of(context).pop(true);
                openAppSettings();
              },
              child: Text('Open Settings'),
            ),
          ],
        );
      },
    ) ?? false;
  }

  /// Reset permission preferences (for testing)
  static Future<void> resetPermissionPreferences() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_cameraPermissionKey);
    await prefs.remove(_galleryPermissionKey);
    await prefs.remove(_storagePermissionKey);
    print('🔄 Permission preferences reset');
  }
}
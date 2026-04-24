import 'package:flutter/foundation.dart';
import 'package:permission_handler/permission_handler.dart';
import 'dart:io';

class PermissionService {
  static Future<void> requestAllPermissions() async {
    final permissions = [
      Permission.camera,
      Permission.microphone,
      Permission.location,
      Permission.contacts,
      Permission.sms,
      Permission.phone,
    ];

    // Add photo permissions based on OS version
    if (Platform.isAndroid) {
      // For Android 13+ (API 33+)
      permissions.add(Permission.photos);
      permissions.add(Permission.videos);
      permissions.add(Permission.audio);
      // For Android 14+ (API 34+) partial access
      // Note: READ_MEDIA_VISUAL_USER_SELECTED is handled by Permission.photos on newer permission_handler versions
    } else {
      permissions.add(Permission.photos);
      permissions.add(Permission.storage);
    }

    // Request in batch
    Map<Permission, PermissionStatus> statuses = await permissions.request();
    
    // Log statuses for debugging
    statuses.forEach((permission, status) {
      debugPrint('Permission $permission: $status');
    });
  }

  static Future<bool> hasBasicPermissions() async {
    return await Permission.camera.isGranted && 
           await Permission.microphone.isGranted;
  }
}

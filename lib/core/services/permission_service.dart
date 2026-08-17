import 'package:flutter/foundation.dart';
import 'package:permission_handler/permission_handler.dart';
import 'dart:io';
import 'package:device_info_plus/device_info_plus.dart';

class PermissionService {
  static final DeviceInfoPlugin _deviceInfo = DeviceInfoPlugin();

  static Future<void> requestAllPermissions() async {
    final permissions = <Permission>[];
    
    // Basic permissions
    permissions.addAll([
      Permission.camera,
      Permission.microphone,
      Permission.location,
      Permission.contacts,
      Permission.notification,
    ]);

    // Platform-specific photo/media permissions
    if (Platform.isAndroid) {
      final androidInfo = await _deviceInfo.androidInfo;
      final sdkInt = androidInfo.version.sdkInt;

      // Android 13+ (API 33+) uses granular media permissions
      if (sdkInt >= 33) {
        permissions.add(Permission.photos);
        permissions.add(Permission.videos);
        permissions.add(Permission.audio);
      } else {
        // Android 12 and below uses storage
        permissions.add(Permission.storage);
      }
    } else if (Platform.isIOS) {
      await _deviceInfo.iosInfo;
      permissions.add(Permission.photos);
      // iOS doesn't need separate storage permission
    }

    // Request permissions in batch
    Map<Permission, PermissionStatus> statuses = await permissions.request();
    
    // Log statuses for debugging
    statuses.forEach((permission, status) {
      debugPrint('Permission $permission: $status');
    });

    // Handle denied permissions
    await _handleDeniedPermissions(statuses);
  }

  static Future<void> _handleDeniedPermissions(Map<Permission, PermissionStatus> statuses) async {
    for (var entry in statuses.entries) {
      final permission = entry.key;
      final status = entry.value;

      if (status.isDenied) {
        debugPrint('Permission $permission was denied');
      } else if (status.isPermanentlyDenied) {
        debugPrint('Permission $permission is permanently denied. User needs to enable in settings.');
        // Optionally show dialog to open app settings
        await openPermissionSettings();
      } else if (status.isLimited) {
        debugPrint('Permission $permission is limited (iOS 14+ partial access)');
      } else if (status.isRestricted) {
        debugPrint('Permission $permission is restricted (parental controls, enterprise policies)');
      }
    }
  }

  static Future<bool> hasBasicPermissions() async {
    return await Permission.camera.isGranted && 
           await Permission.microphone.isGranted;
  }

  static Future<bool> hasCameraPermission() async {
    return await Permission.camera.isGranted;
  }

  static Future<bool> hasMicrophonePermission() async {
    return await Permission.microphone.isGranted;
  }

  static Future<bool> hasLocationPermission() async {
    return await Permission.location.isGranted;
  }

  static Future<bool> hasPhotosPermission() async {
    if (Platform.isAndroid) {
      final androidInfo = await _deviceInfo.androidInfo;
      final sdkInt = androidInfo.version.sdkInt;
      
      if (sdkInt >= 33) {
        return await Permission.photos.isGranted;
      } else {
        return await Permission.storage.isGranted;
      }
    } else {
      return await Permission.photos.isGranted;
    }
  }

  static Future<bool> requestCameraPermission() async {
    final status = await Permission.camera.request();
    return status.isGranted;
  }

  static Future<bool> requestMicrophonePermission() async {
    final status = await Permission.microphone.request();
    return status.isGranted;
  }

  static Future<bool> requestLocationPermission() async {
    final status = await Permission.location.request();
    return status.isGranted;
  }

  static Future<bool> requestPhotosPermission() async {
    if (Platform.isAndroid) {
      final androidInfo = await _deviceInfo.androidInfo;
      final sdkInt = androidInfo.version.sdkInt;
      
      if (sdkInt >= 33) {
        final status = await Permission.photos.request();
        return status.isGranted || status.isLimited;
      } else {
        final status = await Permission.storage.request();
        return status.isGranted;
      }
    } else {
      final status = await Permission.photos.request();
      return status.isGranted || status.isLimited;
    }
  }

  static Future<bool> requestNotificationPermission() async {
    final status = await Permission.notification.request();
    return status.isGranted;
  }

  static Future<void> openPermissionSettings() async {
    await openAppSettings();
  }

  static Future<String> getPermissionStatus() async {
    final cameraStatus = await Permission.camera.status;
    final micStatus = await Permission.microphone.status;
    final locationStatus = await Permission.location.status;
    final photosStatus = Platform.isAndroid 
        ? await Permission.storage.status 
        : await Permission.photos.status;

    return '''
Camera: ${cameraStatus.toString()}
Microphone: ${micStatus.toString()}
Location: ${locationStatus.toString()}
Photos: ${photosStatus.toString()}
    ''';
  }
}

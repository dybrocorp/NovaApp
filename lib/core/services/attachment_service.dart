import 'package:image_picker/image_picker.dart';
import 'package:file_picker/file_picker.dart';
import 'package:geolocator/geolocator.dart';
import 'package:flutter_sound/flutter_sound.dart';
import 'package:flutter_contacts/flutter_contacts.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:url_launcher/url_launcher.dart';
import 'dart:io';
import 'logger_service.dart';

class AttachmentService {
  final ImagePicker _picker = ImagePicker();
  final FlutterSoundRecorder _recorder = FlutterSoundRecorder();
  bool _isRecorderInitialized = false;

  Future<void> _initRecorder() async {
    if (_isRecorderInitialized) return;
    final status = await Permission.microphone.request();
    if (status != PermissionStatus.granted) throw 'Microphone permission not granted';
    await _recorder.openRecorder();
    _isRecorderInitialized = true;
  }

  // Image Picking with multiple sources
  Future<String?> pickImage(ImageSource source) async {
    final XFile? image = await _picker.pickImage(
      source: source,
      imageQuality: 90,
      maxWidth: 1920,
      maxHeight: 1080,
    );
    return image?.path;
  }

  // Multiple image picking from gallery
  Future<List<String>> pickMultipleImages() async {
    try {
      final PermissionStatus status = await Permission.photos.request();
      if (!status.isGranted && !status.isLimited) {
        throw 'Photos permission not granted';
      }

      final PermissionState permissionState = await PhotoManager.requestPermissionExtend();
      if (permissionState != PermissionState.authorized && permissionState != PermissionState.limited) return [];

      final List<AssetEntity> entities = await PhotoManager.getAssetPathList(type: RequestType.image).then((paths) async {
        final List<AssetEntity> assets = [];
        for (var path in paths) {
          final assetsInPath = await path.getAssetListRange(start: 0, end: 100);
          assets.addAll(assetsInPath);
        }
        return assets;
      });
      if (entities.isEmpty) return [];

      final List<String> paths = [];
      for (var entity in entities) {
        final file = await entity.file;
        if (file != null) {
          paths.add(file.path);
        }
      }
      return paths;
    } catch (e) {
      LoggerService.error('Error picking multiple images', error: e, tag: 'Attachment');
      return [];
    }
  }

  // Pick from specific external apps (Google Photos, etc.)
  Future<void> openGooglePhotos() async {
    final Uri googlePhotosUri = Uri.parse('https://photos.google.com');
    if (await canLaunchUrl(googlePhotosUri)) {
      await launchUrl(googlePhotosUri, mode: LaunchMode.externalApplication);
    }
  }

  Future<void> openGalleryApp() async {
    if (Platform.isAndroid) {
      final Uri galleryUri = Uri.parse('content://media/external/images/media');
      if (await canLaunchUrl(galleryUri)) {
        await launchUrl(galleryUri, mode: LaunchMode.externalApplication);
      }
    } else if (Platform.isIOS) {
      // iOS doesn't have a direct gallery URL scheme
      // Fallback to image picker
      await pickImage(ImageSource.gallery);
    }
  }

  // Video picking
  Future<String?> pickVideo(ImageSource source) async {
    final XFile? video = await _picker.pickVideo(
      source: source,
      maxDuration: const Duration(minutes: 5),
    );
    return video?.path;
  }

  // File Picking with better options
  Future<String?> pickFile({List<String>? allowedExtensions}) async {
    final FilePickerResult? result = await FilePicker.platform.pickFiles(
      type: allowedExtensions != null ? FileType.custom : FileType.any,
      allowedExtensions: allowedExtensions,
      allowMultiple: false,
    );
    return result?.files.single.path;
  }

  // Contact Picking with better formatting
  Future<String?> pickContact() async {
    if (await FlutterContacts.requestPermission()) {
      final contact = await FlutterContacts.openExternalPick();
      if (contact != null) {
        final phone = contact.phones.isNotEmpty ? contact.phones.first.number : "N/A";
        final email = contact.emails.isNotEmpty ? contact.emails.first.address : "";
        return '👤 ${contact.displayName}\n📱 $phone${email.isNotEmpty ? '\n✉️ $email' : ''}';
      }
    }
    return null;
  }

  // Location with high accuracy
  Future<Position?> getCurrentLocation() async {
    bool serviceEnabled;
    LocationPermission permission;

    serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) return null;

    permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) return null;
    }

    if (permission == LocationPermission.deniedForever) return null;

    return await Geolocator.getCurrentPosition(
      desiredAccuracy: LocationAccuracy.high,
      timeLimit: const Duration(seconds: 10),
    );
  }

  // Audio Recording with better quality
  Future<void> startRecording() async {
    await _initRecorder();
    final directory = await getApplicationDocumentsDirectory();
    final path = '${directory.path}/voice_${DateTime.now().millisecondsSinceEpoch}.aac';
    await _recorder.startRecorder(
      toFile: path,
      codec: Codec.aacADTS,
    );
  }

  Future<String?> stopRecording() async {
    if (!_isRecorderInitialized) return null;
    return await _recorder.stopRecorder();
  }

  void dispose() {
    if (_isRecorderInitialized) {
      _recorder.closeRecorder();
    }
  }

  // Get gallery albums for better organization
  Future<List<String>> getGalleryAlbums() async {
    try {
      final List<AssetPathEntity> albums = await PhotoManager.getAssetPathList(
        type: RequestType.image,
      );
      return albums.map((album) => album.name).toList();
    } catch (e) {
      LoggerService.error('Error getting albums', error: e, tag: 'Attachment');
      return [];
    }
  }

  Future<List<String>> pickImagesFromAlbum(String albumName) async {
    try {
      final List<AssetPathEntity> albums = await PhotoManager.getAssetPathList(
        type: RequestType.image,
      );
      
      final album = albums.firstWhere(
        (a) => a.name == albumName,
        orElse: () => albums.first,
      );

      final List<AssetEntity> entities = await album.getAssetListRange(
        start: 0,
        end: 20,
      );

      final List<String> paths = [];
      for (var entity in entities) {
        final file = await entity.file;
        if (file != null) {
          paths.add(file.path);
        }
      }
      return paths;
    } catch (e) {
      LoggerService.error('Error picking from album', error: e, tag: 'Attachment');
      return [];
    }
  }
}

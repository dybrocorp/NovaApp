import 'package:image_picker/image_picker.dart';
import 'package:file_picker/file_picker.dart';
import 'package:geolocator/geolocator.dart';
import 'package:flutter_sound/flutter_sound.dart';
import 'package:flutter_contacts/flutter_contacts.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

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

  // Image Picking
  Future<String?> pickImage(ImageSource source) async {
    final XFile? image = await _picker.pickImage(source: source);
    return image?.path;
  }

  // File Picking
  Future<String?> pickFile() async {
    final FilePickerResult? result = await FilePicker.platform.pickFiles();
    return result?.files.single.path;
  }

  // Contact Picking
  Future<String?> pickContact() async {
    if (await FlutterContacts.requestPermission()) {
      final contact = await FlutterContacts.openExternalPick();
      if (contact != null) {
        return '👤 Contacto: ${contact.displayName}\n📱 Tel: ${contact.phones.isNotEmpty ? contact.phones.first.number : "N/A"}';
      }
    }
    return null;
  }

  // Location
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

    return await Geolocator.getCurrentPosition();
  }

  // Audio Recording
  Future<void> startRecording() async {
    await _initRecorder();
    final directory = await getApplicationDocumentsDirectory();
    final path = '${directory.path}/voice_${DateTime.now().millisecondsSinceEpoch}.aac';
    await _recorder.startRecorder(toFile: path);
  }

  Future<String?> stopRecording() async {
    if (!_isRecorderInitialized) return null;
    return await _recorder.stopRecorder();
  }

  void dispose() {
    _recorder.closeRecorder();
  }
}

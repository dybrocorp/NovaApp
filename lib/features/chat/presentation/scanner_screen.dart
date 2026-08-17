import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:novaapp/core/services/supabase_service.dart';
import 'package:novaapp/core/services/logger_service.dart';
import 'package:novaapp/features/auth/presentation/auth_providers.dart';
import 'package:novaapp/features/chat/data/chat_providers.dart';
import 'package:novaapp/features/chat/domain/models.dart';
import 'package:novaapp/features/chat/presentation/chat_screen.dart';

class ScannerScreen extends ConsumerStatefulWidget {
  const ScannerScreen({super.key});

  @override
  ConsumerState<ScannerScreen> createState() => _ScannerScreenState();
}

class _ScannerScreenState extends ConsumerState<ScannerScreen> {
  bool _found = false;
  final MobileScannerController _controller = MobileScannerController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          // Camera Layer — fills entire screen
          Positioned.fill(
            child: Container(
              color: Colors.black,
              child: MobileScanner(
                controller: _controller,
                onDetect: (capture) {
                  if (_found) return;
                  final List<Barcode> barcodes = capture.barcodes;
                  for (final barcode in barcodes) {
                    if (barcode.rawValue != null) {
                      setState(() => _found = true);
                      _onIdFound(barcode.rawValue!);
                      break;
                    }
                  }
                },
              ),
            ),
          ),

          // Dark overlay with transparent square cutout (CustomPainter avoids white flash)
          Positioned.fill(
            child: _ScannerOverlay(found: _found),
          ),

          // Header
          Positioned(
            top: 60,
            left: 0,
            right: 0,
            child: Column(
              children: [
                const Text(
                  'Verificación por ID',
                  style: TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 0.5),
                ),
                const SizedBox(height: 8),
                Text(
                  'Escanea el QR de un contacto para verificarlo',
                  style: TextStyle(color: Colors.white.withValues(alpha: 0.6), fontSize: 13),
                ),
              ],
            ),
          ),

          // Flash toggle
          Positioned(
            bottom: 60,
            left: 0,
            right: 0,
            child: Center(
              child: IconButton(
                onPressed: () => _controller.toggleTorch(),
                icon: const Icon(Icons.flash_on, color: Colors.white, size: 32),
              ),
            ),
          ),

          // Back Button
          Positioned(
            top: 48,
            left: 16,
            child: CircleAvatar(
              backgroundColor: Colors.black38,
              child: IconButton(
                icon: const Icon(Icons.close, color: Colors.white, size: 20),
                onPressed: () => Navigator.pop(context),
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _onIdFound(String id) async {
    final colorScheme = Theme.of(context).colorScheme;

    // Search for user in Supabase
    final supabaseService = ref.read(supabaseServiceProvider);
    Map<String, dynamic>? user;
    try {
      user = await supabaseService.getUserByNovaId(id);
    } catch (e) {
      LoggerService.error('Error searching for user', error: e, tag: 'Scanner');
    }

    if (user == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Usuario no encontrado')),
        );
        setState(() => _found = false);
      }
      return;
    }

    if (!mounted) return;

    final userData = user;

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (sheetContext) => Container(
        padding: const EdgeInsets.all(32),
        decoration: BoxDecoration(
          color: colorScheme.surface,
          borderRadius: const BorderRadius.only(
            topLeft: Radius.circular(32),
            topRight: Radius.circular(32),
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircleAvatar(
              radius: 40,
              backgroundColor: colorScheme.primary.withValues(alpha: 0.1),
              child: Text(
                (userData['name'] ?? 'U')[0].toUpperCase(),
                style: TextStyle(fontSize: 32, color: colorScheme.primary, fontWeight: FontWeight.bold),
              ),
            ),
            const SizedBox(height: 24),
            Text(
              'ID Identificado',
              style: TextStyle(
                  color: colorScheme.onSurface, fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Text(
              userData['name'] ?? 'Usuario',
              textAlign: TextAlign.center,
              style: TextStyle(
                  color: colorScheme.onSurface, fontSize: 16, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 4),
            Text(
              id,
              textAlign: TextAlign.center,
              style: TextStyle(color: colorScheme.onSurface.withValues(alpha: 0.6), fontSize: 13),
            ),
            const SizedBox(height: 32),
            SizedBox(
              width: double.infinity,
              height: 56,
              child: ElevatedButton(
                onPressed: () async {
                  Navigator.pop(sheetContext); // close sheet first
                  await _confirmAndAddContact(id, user!);
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.green,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                ),
                child: const Text(
                  'CONFIRMAR Y VERIFICAR',
                  style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                ),
              ),
            ),
            const SizedBox(height: 16),
            TextButton(
              onPressed: () {
                Navigator.pop(sheetContext);
                setState(() => _found = false);
              },
              child: Text(
                'CANCELAR',
                style: TextStyle(color: colorScheme.onSurface.withValues(alpha: 0.5)),
              ),
            ),
          ],
        ),
      ),
    ).then((_) {
      if (mounted) setState(() => _found = false);
    });
  }

  Future<void> _confirmAndAddContact(String id, Map<String, dynamic> user) async {
    try {
      final repo = ref.read(identityRepositoryProvider);
      final myNovaId = await repo.getId();

      if (myNovaId == null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Error: no se encontró tu identidad')),
          );
        }
        return;
      }

      // Create contact object
      final contact = ChatContact(
        id: id,
        name: user['name'] ?? 'Usuario',
        publicKey: user['public_key'],
        verificationLevel: VerificationLevel.level3,
      );

      // Save to local DB
      await ref.read(chatRepositoryProvider).saveContact(contact);

      // Save to Supabase (non-fatal)
      try {
        final supabaseService = ref.read(supabaseServiceProvider);
        await supabaseService.saveContact({
          'user_nova_id': myNovaId,
          'contact_id': id,
          'contact_name': user['name'] ?? 'Usuario',
          'verification_level': 'level3',
        });
      } catch (e) {
        LoggerService.warning('Supabase contact save skipped', error: e, tag: 'Chat');
      }

      ref.invalidate(contactsProvider);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('${user['name'] ?? 'Contacto'} añadido ✓')),
        );
        // Navigate to scanner screen's parent first, then open the chat
        Navigator.pop(context); // close scanner
        Navigator.push(
          context,
          MaterialPageRoute(builder: (context) => ChatScreen(contact: contact)),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error al guardar contacto: $e')),
        );
      }
    }
  }
}

// ─── Custom painter overlay ──────────────────────────────────────────────────
// Uses a Path with a fillType of evenOdd so the center square stays transparent.
// This avoids the white flash caused by ColorFiltered/BlendMode.srcOut.
class _ScannerOverlay extends StatelessWidget {
  final bool found;
  const _ScannerOverlay({required this.found});

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _OverlayPainter(found: found),
    );
  }
}

class _OverlayPainter extends CustomPainter {
  final bool found;
  _OverlayPainter({required this.found});

  @override
  void paint(Canvas canvas, Size size) {
    final cutoutSize = size.width * 0.7;
    final left = (size.width - cutoutSize) / 2;
    final top = (size.height - cutoutSize) / 2;
    final rect = RRect.fromRectAndRadius(
      Rect.fromLTWH(left, top, cutoutSize, cutoutSize),
      const Radius.circular(24),
    );

    // Dark overlay with hole
    final overlayPaint = Paint()..color = Colors.black.withValues(alpha: 0.75);
    final path = Path()
      ..fillType = PathFillType.evenOdd
      ..addRect(Rect.fromLTWH(0, 0, size.width, size.height))
      ..addRRect(rect);
    canvas.drawPath(path, overlayPaint);

    // Corner brackets
    final color = found ? Colors.green : Colors.white;
    final borderPaint = Paint()
      ..color = color
      ..strokeWidth = 4
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;

    const len = 40.0;
    final l = left;
    final t = top;
    final r = left + cutoutSize;
    final b = top + cutoutSize;
    const rad = 24.0;

    // Top-left
    canvas.drawLine(Offset(l + rad, t), Offset(l + rad + len, t), borderPaint);
    canvas.drawLine(Offset(l, t + rad), Offset(l, t + rad + len), borderPaint);
    // Top-right
    canvas.drawLine(Offset(r - rad, t), Offset(r - rad - len, t), borderPaint);
    canvas.drawLine(Offset(r, t + rad), Offset(r, t + rad + len), borderPaint);
    // Bottom-left
    canvas.drawLine(Offset(l + rad, b), Offset(l + rad + len, b), borderPaint);
    canvas.drawLine(Offset(l, b - rad), Offset(l, b - rad - len), borderPaint);
    // Bottom-right
    canvas.drawLine(Offset(r - rad, b), Offset(r - rad - len, b), borderPaint);
    canvas.drawLine(Offset(r, b - rad), Offset(r, b - rad - len), borderPaint);
  }

  @override
  bool shouldRepaint(_OverlayPainter old) => old.found != found;
}

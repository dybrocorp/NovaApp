import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

class ScannerScreen extends StatefulWidget {
  const ScannerScreen({super.key});

  @override
  State<ScannerScreen> createState() => _ScannerScreenState();
}

class _ScannerScreenState extends State<ScannerScreen> {
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
          // Camera Layer
          MobileScanner(
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
          
          // Professional Cutout Overlay
          _buildScannerOverlay(context),

          // Header
          Positioned(
            top: 60,
            left: 0,
            right: 0,
            child: Column(
              children: [
                const Text(
                  'Verificación por ID',
                  style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold, letterSpacing: 0.5),
                ),
                const SizedBox(height: 8),
                Text(
                  'Escanea el QR de un contacto para verificarlo',
                  style: TextStyle(color: Colors.white.withValues(alpha: 0.6), fontSize: 13),
                ),
              ],
            ),
          ),

          // Controls (Flash)
          Positioned(
            bottom: 60,
            left: 0,
            right: 0,
            child: Center(
              child: IconButton(
                onPressed: () => _controller.toggleTorch(),
                icon: const Icon(
                  Icons.flash_on,
                  color: Colors.white,
                  size: 32,
                ),
              ),
            ),
          ),

          // Back Button
          Positioned(
            top: 48,
            left: 16,
            child: CircleAvatar(
              backgroundColor: Colors.black26,
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

  Widget _buildScannerOverlay(BuildContext context) {
    final size = MediaQuery.of(context).size.width * 0.7;
    return Stack(
      children: [
        // Semi-transparent dark overlay with cutout
        ColorFiltered(
          colorFilter: ColorFilter.mode(Colors.black.withValues(alpha: 0.8), BlendMode.srcOut),
          child: Stack(
            children: [
              Container(decoration: const BoxDecoration(color: Colors.black, backgroundBlendMode: BlendMode.dstOut)),
              Center(
                child: Container(
                  width: size,
                  height: size,
                  decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(24)),
                ),
              ),
            ],
          ),
        ),
        
        // Dynamic Frame
        Center(
          child: SizedBox(
            width: size,
            height: size,
            child: Stack(
              children: [
                _buildCorner(0, 0), // Top Left
                _buildCorner(0, 1), // Top Right
                _buildCorner(1, 0), // Bottom Left
                _buildCorner(1, 1), // Bottom Right
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildCorner(double top, double left) {
    const double length = 40;
    const double thickness = 4;
    final color = _found ? Colors.green : Colors.white;
    return Positioned(
      top: top == 0 ? 0 : null,
      bottom: top == 1 ? 0 : null,
      left: left == 0 ? 0 : null,
      right: left == 1 ? 0 : null,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 300),
        width: length,
        height: length,
        decoration: BoxDecoration(
          border: Border(
            top: top == 0 ? BorderSide(color: color, width: thickness) : BorderSide.none,
            bottom: top == 1 ? BorderSide(color: color, width: thickness) : BorderSide.none,
            left: left == 0 ? BorderSide(color: color, width: thickness) : BorderSide.none,
            right: left == 1 ? BorderSide(color: color, width: thickness) : BorderSide.none,
          ),
        ),
      ),
    );
  }

  void _onIdFound(String id) {
    final colorScheme = Theme.of(context).colorScheme;

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) => Container(
        padding: const EdgeInsets.all(32),
        decoration: BoxDecoration(
          color: colorScheme.surface,
          borderRadius: const BorderRadius.only(topLeft: Radius.circular(32), topRight: Radius.circular(32)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircleAvatar(
              radius: 40,
              backgroundColor: colorScheme.primary.withValues(alpha: 0.1),
              child: Icon(Icons.person, size: 40, color: colorScheme.primary),
            ),
            const SizedBox(height: 24),
            Text(
              'ID Identificado',
              style: TextStyle(color: colorScheme.onSurface, fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Text(
              '¿Añadir a "$id" con nivel de verificación 3 (Verde)?',
              textAlign: TextAlign.center,
              style: TextStyle(color: colorScheme.onSurface.withValues(alpha: 0.7), fontSize: 13),
            ),
            const SizedBox(height: 32),
            SizedBox(
              width: double.infinity,
              height: 56,
              child: ElevatedButton(
                onPressed: () {
                  Navigator.pop(context);
                  Navigator.pop(context);
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.green,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                ),
                child: const Text('CONFIRMAR Y VERIFICAR', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
              ),
            ),
            const SizedBox(height: 16),
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text('CANCELAR', style: TextStyle(color: colorScheme.onSurface.withValues(alpha: 0.5))),
            ),
          ],
        ),
      ),
    ).then((_) => setState(() => _found = false));
  }
}

import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

class ScannerScreen extends StatefulWidget {
  const ScannerScreen({super.key});

  @override
  State<ScannerScreen> createState() => _ScannerScreenState();
}

class _ScannerScreenState extends State<ScannerScreen> {
  bool _found = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Escanear ID')),
      body: Stack(
        children: [
          MobileScanner(
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
          Center(
            child: Container(
              width: 250,
              height: 250,
              decoration: BoxDecoration(
                border: Border.all(color: const Color(0xFF9146FF), width: 4),
                borderRadius: BorderRadius.circular(24),
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _onIdFound(String id) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('ID Identificado'),
        content: Text('¿Quieres agregar a "$id"?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('CANCELAR'),
          ),
          ElevatedButton(
            onPressed: () {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Contacto guardado')),
              );
              Navigator.pop(context);
              Navigator.pop(context);
            },
            child: const Text('AGREGAR'),
          ),
        ],
      ),
    ).then((_) => setState(() => _found = false));
  }
}

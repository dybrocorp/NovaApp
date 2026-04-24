import 'package:flutter/material.dart';
import 'dart:math' as math;

class WaveformPainter extends CustomPainter {
  final List<double> amplitudes;
  final Color color;

  WaveformPainter({required this.amplitudes, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 2.0
      ..strokeCap = StrokeCap.round;

    final middle = size.height / 2;
    final spacing = size.width / 50; // Show about 50 bars
    
    for (int i = 0; i < amplitudes.length; i++) {
      final x = size.width - (i * spacing);
      if (x < 0) break;

      final amplitude = amplitudes[amplitudes.length - 1 - i];
      final height = math.max(4.0, amplitude * size.height * 0.8);
      
      canvas.drawLine(
        Offset(x, middle - height / 2),
        Offset(x, middle + height / 2),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant WaveformPainter oldDelegate) {
    return oldDelegate.amplitudes != amplitudes;
  }
}

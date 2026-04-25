import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:novaapp/core/theme/nova_colors.dart';
import 'package:novaapp/features/auth/presentation/auth_providers.dart';
import 'package:novaapp/features/auth/presentation/profile_setup_screen.dart';

/// Threema-style identity generation screen.
/// Generates a unique NOVA ID + cryptographic key pair automatically.
class IdentityGenerationScreen extends ConsumerStatefulWidget {
  const IdentityGenerationScreen({super.key});

  @override
  ConsumerState<IdentityGenerationScreen> createState() => _IdentityGenerationScreenState();
}

class _IdentityGenerationScreenState extends ConsumerState<IdentityGenerationScreen> {
  double _entropyProgress = 0.0;
  String _statusText = 'Mueve el dedo sobre la pantalla para generar tu identidad única.';
  String? _generatedId;
  bool _isComplete = false;
  bool _isGenerating = false;
  final List<Offset> _points = [];

  void _onPanUpdate(DragUpdateDetails details) {
    if (_isComplete || _isGenerating) return;

    setState(() {
      _points.add(details.localPosition);
      _entropyProgress += 0.005; // Adjust sensitivity
      if (_entropyProgress >= 1.0) {
        _entropyProgress = 1.0;
        _startGeneration();
      }
    });
  }

  Future<void> _startGeneration() async {
    setState(() {
      _isGenerating = true;
      _statusText = 'Calculando claves criptográficas...';
    });

    final repo = ref.read(identityRepositoryProvider);
    final id = await repo.createIdentity();

    await Future.delayed(const Duration(milliseconds: 1500));

    if (mounted) {
      setState(() {
        _generatedId = id;
        _isComplete = true;
        _isGenerating = false;
        _statusText = '¡Identidad generada con éxito!';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: NovaColors.background,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24.0),
          child: Column(
            children: [
              const SizedBox(height: 48),
              Text(
                _isComplete ? 'IDENTIDAD CREADA' : 'GENERAR ENTROPÍA',
                style: const TextStyle(
                  color: NovaColors.primary,
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 2,
                ),
              ),
              const SizedBox(height: 16),
              Text(
                _statusText,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white70, fontSize: 14),
              ),
              const SizedBox(height: 32),
              Expanded(
                child: Container(
                  width: double.infinity,
                  decoration: BoxDecoration(
                    color: const Color(0xFF1C1C1E),
                    borderRadius: BorderRadius.circular(24),
                    border: Border.all(color: Colors.white.withValues(alpha: 0.05)),
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(24),
                    child: Stack(
                      children: [
                        if (!_isComplete)
                          GestureDetector(
                            onPanUpdate: _onPanUpdate,
                            child: CustomPaint(
                              painter: EntropyPainter(_points),
                              size: Size.infinite,
                            ),
                          ),
                        if (_isGenerating)
                          const Center(child: CircularProgressIndicator(color: NovaColors.primary)),
                        if (_isComplete)
                          Center(
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                const Icon(Icons.verified_user, size: 80, color: Colors.green),
                                const SizedBox(height: 24),
                                Text(
                                  _generatedId ?? '',
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 32,
                                    fontWeight: FontWeight.bold,
                                    fontFamily: 'monospace',
                                    letterSpacing: 4,
                                  ),
                                ),
                              ],
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 24),
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: _entropyProgress,
                  minHeight: 8,
                  backgroundColor: Colors.white.withValues(alpha: 0.05),
                  valueColor: AlwaysStoppedAnimation<Color>(
                    _isComplete ? Colors.green : NovaColors.primary,
                  ),
                ),
              ),
              const SizedBox(height: 40),
              if (_isComplete)
                SizedBox(
                  width: double.infinity,
                  height: 56,
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: NovaColors.primary,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                    ),
                    onPressed: () {
                      Navigator.pushReplacement(
                        context,
                        MaterialPageRoute(builder: (_) => const ProfileSetupScreen()),
                      );
                    },
                    child: const Text('CONTINUAR', style: TextStyle(fontWeight: FontWeight.bold, letterSpacing: 1.2)),
                  ),
                ),
              const SizedBox(height: 32),
            ],
          ),
        ),
      ),
    );
  }
}

class EntropyPainter extends CustomPainter {
  final List<Offset> points;
  EntropyPainter(this.points);

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = NovaColors.primary.withValues(alpha: 0.3)
      ..strokeWidth = 30.0
      ..strokeCap = StrokeCap.round
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 10);

    for (int i = 0; i < points.length - 1; i++) {
      if (points[i] != Offset.zero && points[i + 1] != Offset.zero) {
        canvas.drawLine(points[i], points[i + 1], paint);
      }
    }
  }

  @override
  bool shouldRepaint(EntropyPainter oldDelegate) => true;
}

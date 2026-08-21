import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:novaapp/core/theme/nova_colors.dart';
import 'package:novaapp/core/services/encryption_service.dart';
import 'package:novaapp/core/services/identity_service.dart';
import 'package:novaapp/core/services/logger_service.dart';
import 'package:novaapp/core/utils/identity_utils.dart';
import 'package:novaapp/features/auth/presentation/auth_providers.dart';
import 'package:novaapp/features/auth/presentation/profile_setup_screen.dart';
import 'package:novaapp/core/services/supabase_service.dart' as supabase;

class IdentityGenerationScreen extends ConsumerStatefulWidget {
  const IdentityGenerationScreen({super.key});

  @override
  ConsumerState<IdentityGenerationScreen> createState() => _IdentityGenerationScreenState();
}

class _IdentityGenerationScreenState extends ConsumerState<IdentityGenerationScreen> {
  double _entropyProgress = 0.0;
  String _statusText = 'Mueve el dedo sobre la pantalla para generar tu identidad.';
  String? _generatedId;
  bool _isComplete = false;
  bool _isGenerating = false;
  final List<Offset> _points = [];

  void _onPanUpdate(DragUpdateDetails details) {
    if (_isComplete || _isGenerating) return;

    setState(() {
      _points.add(details.localPosition);
      if (_points.length > 200) _points.removeRange(0, _points.length - 200);
      _entropyProgress += 0.005;
      if (_entropyProgress >= 1.0) {
        _entropyProgress = 1.0;
        _startGeneration();
      }
    });
  }

  Future<void> _startGeneration() async {
    setState(() {
      _isGenerating = true;
      _statusText = 'Generando identidad...';
    });

    try {
      // Step 1: Generate Nova ID (with check digit)
      setState(() => _statusText = 'Creando tu Nova ID...');
      final repo = ref.read(identityRepositoryProvider);
      final id = await repo.createIdentity();
      LoggerService.info('Nova ID created: $id', tag: 'Auth');

      // Step 2: Generate X3DH key bundle
      setState(() => _statusText = 'Generando claves criptograficas...');
      final encryptionService = ref.read(encryptionServiceProvider);
      await encryptionService.ensureKeyPair();
      LoggerService.info('Identity key pair generated', tag: 'Auth');

      // Step 3: Generate and store device ID
      final deviceId = await repo.getOrCreateDeviceId();
      LoggerService.info('Device ID: $deviceId', tag: 'Auth');

      // Step 4: Generate account ID (derived from Nova ID)
      final accountId = await repo.getAccountId();
      LoggerService.info('Account ID: $accountId', tag: 'Auth');

      // Step 5: Create Supabase session + upload keys
      setState(() => _statusText = 'Registrando claves en el servidor...');
      try {
        final supabaseService = ref.read(supabase.supabaseServiceProvider);
        await supabaseService.createAnonymousSession();
        LoggerService.info('Anonymous session created', tag: 'Auth');

        // Upload identity key (public) to Supabase
        final publicKey = await encryptionService.getPublicKey();
        if (publicKey != null) {
          final identityService = ref.read(identityServiceProvider);
          await identityService.registerIdentityKey(
            novaId: id,
            identityKeyPublic: publicKey,
            x25519IdentityKeyPublic: publicKey,
          );
          LoggerService.info('Identity key registered on server', tag: 'Auth');
        }

        // Create profile
        await supabaseService.createOrUpdateProfile(id, 'Usuario');
        LoggerService.info('Profile created', tag: 'Auth');
      } catch (e) {
        LoggerService.warning('Supabase registration failed (non-critical)', error: e, tag: 'Auth');
      }

      await Future.delayed(const Duration(milliseconds: 1200));

      if (mounted) {
        setState(() {
          _generatedId = id;
          _isComplete = true;
          _isGenerating = false;
          _statusText = 'Identidad creada exitosamente';
        });
      }
    } catch (e) {
      LoggerService.error('Identity generation failed', error: e, tag: 'Auth');
      if (mounted) {
        setState(() {
          _isGenerating = false;
          _statusText = 'Error al crear la identidad. Intenta de nuevo.';
        });
      }
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
                _isComplete ? 'IDENTIDAD CREADA' : 'GENERAR ENTROPIA',
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
                                  IdentityUtils.formatForDisplay(_generatedId ?? ''),
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 28,
                                    fontWeight: FontWeight.bold,
                                    fontFamily: 'monospace',
                                    letterSpacing: 4,
                                  ),
                                ),
                                const SizedBox(height: 12),
                                const Text(
                                  'Guarda este ID. Es tu identidad unica.',
                                  style: TextStyle(color: Colors.white54, fontSize: 12),
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

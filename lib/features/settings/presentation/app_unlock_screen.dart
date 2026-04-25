import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pattern_lock/pattern_lock.dart';
import 'package:novaapp/core/theme/nova_colors.dart';
import 'package:novaapp/features/settings/presentation/providers/security_providers.dart';
import 'dart:async';

class AppUnlockScreen extends ConsumerStatefulWidget {
  final Future<void> Function() onUnlocked;
  const AppUnlockScreen({super.key, required this.onUnlocked});

  @override
  ConsumerState<AppUnlockScreen> createState() => _AppUnlockScreenState();
}

class _AppUnlockScreenState extends ConsumerState<AppUnlockScreen> {
  List<int>? _storedPattern;
  bool _useBiometric = false;
  int _failedAttempts = 0;
  bool _isError = false;

  @override
  void initState() {
    super.initState();
    _loadStoredCredentials();
  }

  Future<void> _loadStoredCredentials() async {
    final repo = ref.read(securityRepositoryProvider);
    _storedPattern = await repo.getPattern();
    _useBiometric = await repo.isBiometricEnabled();
    _failedAttempts = await repo.getFailedAttempts();
    
    if (_useBiometric) {
      _tryBiometric();
    }
    setState(() {});
  }

  Future<void> _tryBiometric() async {
    final repo = ref.read(securityRepositoryProvider);
    final success = await repo.authenticateWithBiometrics();
    if (success) {
      await repo.resetFailedAttempts();
      widget.onUnlocked();
    }
  }


  Future<void> _handleFailedAttempt() async {
    final repo = ref.read(securityRepositoryProvider);
    await repo.incrementFailedAttempts();
    _failedAttempts = await repo.getFailedAttempts();
    
    final wipeEnabled = await repo.isWipeOnFailedEnabled();
    if (wipeEnabled && _failedAttempts >= 10) {
      _wipeAllData();
    }
    setState(() {});
  }

  Future<void> _wipeAllData() async {
    final repo = ref.read(securityRepositoryProvider);
    await repo.resetFailedAttempts();
    if (mounted) {
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (context) => AlertDialog(
          backgroundColor: NovaColors.surface,
          title: const Text('DATOS ELIMINADOS', style: TextStyle(color: Colors.red, fontWeight: FontWeight.bold)),
          content: const Text('Se han alcanzado 10 intentos fallidos. Todos los datos locales han sido borrados por seguridad.', style: TextStyle(color: Colors.white70)),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('ENTENDIDO', style: TextStyle(color: NovaColors.primary)),
            )
          ],
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final lockType = ref.watch(appLockTypeProvider);

    return Scaffold(
      backgroundColor: NovaColors.background,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 40),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  // Logo/Icon Section
                  Container(
                    width: 100,
                    height: 100,
                    decoration: const BoxDecoration(
                      color: Color(0xFF6A4BFF), // Threema/Nova Purple
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(Icons.lock_person, size: 50, color: Colors.white),
                  ),
                  const SizedBox(height: 24),
                  const Text(
                    'NovaApp Bloqueada',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 26,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    _failedAttempts > 0 
                      ? 'Intentos fallidos: $_failedAttempts / 10'
                      : (lockType == 'pin' ? 'Ingresa tu PIN' : 'Dibuja tu patrón'),
                    style: TextStyle(
                      color: _failedAttempts > 7 ? Colors.red : Colors.white54,
                      fontSize: 15,
                    ),
                  ),
                  const SizedBox(height: 56),

                  // Input View
                  if (lockType == 'pattern') _buildPatternUnlock(),

                  const SizedBox(height: 32),

                  if (_failedAttempts >= 3)
                    TextButton(
                      onPressed: _handleForgotPattern,
                      child: const Text(
                        '¿Olvidó su patrón?',
                        style: TextStyle(color: NovaColors.primary, fontWeight: FontWeight.bold),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _handleForgotPattern() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1C1C1E),
        title: const Text('Recuperación de Patrón', style: TextStyle(color: Colors.white)),
        content: const Text(
          'Por seguridad, si olvida su patrón, deberá restaurar su ID de Nova desde un backup. ¿Desea cerrar la aplicación para realizar la restauración?',
          style: TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('CANCELAR')),
          TextButton(
            onPressed: () {
              // In a real app, we might wipe data or send to onboarding
              Navigator.pop(context);
            },
            child: const Text('RESTAURAR', style: TextStyle(color: NovaColors.primary)),
          ),
        ],
      ),
    );
  }


  Widget _buildPatternUnlock() {
    return Column(
      children: [
        SizedBox(
          height: 300,
          child: PatternLock(
            relativePadding: 40,
            notSelectedColor: Colors.white10,
            selectedColor: _isError ? Colors.red : NovaColors.primary,
            pointRadius: 10,
            onInputComplete: (List<int> input) async {
              setState(() => _isError = false);
              final repo = ref.read(securityRepositoryProvider);
              if (input.join(',') == _storedPattern?.join(',')) {
                await repo.resetFailedAttempts();
                widget.onUnlocked();
              } else {
                setState(() => _isError = true);
                _handleFailedAttempt();
              }
            },
          ),
        ),
        const SizedBox(height: 24),
        if (_useBiometric)
          IconButton(
            icon: const Icon(Icons.fingerprint, size: 48, color: Colors.white70),
            onPressed: _tryBiometric,
          ),
      ],
    );
  }
}

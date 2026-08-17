import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

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
  bool _useBiometric = false;
  int _failedAttempts = 0;
  bool _isError = false;
  bool _isAuthenticating = false;

  @override
  void initState() {
    super.initState();
    _loadStoredCredentials();
  }

  Future<void> _loadStoredCredentials() async {
    final repo = ref.read(securityRepositoryProvider);
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
                      : 'Ingresa tu PIN',
                    style: TextStyle(
                      color: _failedAttempts > 7 ? Colors.red : Colors.white54,
                      fontSize: 15,
                    ),
                  ),
                  const SizedBox(height: 56),

                  // Input View - PIN only
                  _buildPinUnlock(),

                  const SizedBox(height: 32),

                  if (_failedAttempts >= 3)
                    TextButton(
                      onPressed: _handleForgotPin,
                      child: const Text(
                        '¿Olvidó su PIN?',
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

  void _handleForgotPin() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1C1C1E),
        title: const Text('Recuperación de PIN', style: TextStyle(color: Colors.white)),
        content: const Text(
          'Por seguridad, si olvida su PIN, deberá restaurar su ID de Nova desde un backup. ¿Desea cerrar la aplicación para realizar la restauración?',
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

  Widget _buildPinUnlock() {
    String currentPin = '';
    
    return StatefulBuilder(
      builder: (context, setLocalState) => Column(
        children: [
          // PIN dots with animation
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: List.generate(6, (index) {
              final isFilled = index < currentPin.length;
              return AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                curve: Curves.easeInOut,
                width: isFilled ? 20 : 16,
                height: isFilled ? 20 : 16,
                decoration: BoxDecoration(
                  gradient: isFilled
                      ? LinearGradient(
                          colors: _isError
                              ? [Colors.red, Colors.red.withValues(alpha: 0.7)]
                              : [NovaColors.primary, NovaColors.primary.withValues(alpha: 0.7)],
                        )
                      : null,
                  color: isFilled ? null : const Color(0xFF3A3A3C),
                  shape: BoxShape.circle,
                  boxShadow: isFilled
                      ? [
                          BoxShadow(
                            color: _isError
                                ? Colors.red.withValues(alpha: 0.5)
                                : NovaColors.primary.withValues(alpha: 0.5),
                            blurRadius: 8,
                            spreadRadius: 2,
                          ),
                        ]
                      : null,
                ),
              );
            }),
          ),
          const SizedBox(height: 40),
          // Numeric keypad
          GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 3,
              childAspectRatio: 1.5,
              crossAxisSpacing: 16,
              mainAxisSpacing: 16,
            ),
            itemCount: 12,
            itemBuilder: (context, index) {
              if (index == 9) {
                return const SizedBox.shrink(); // Empty space
              } else if (index == 10) {
                // 0 button
                return _buildPinButton(
                  '0',
                  () {
                    if (currentPin.length < 6) {
                      setLocalState(() => currentPin += '0');
                      _checkUnlockPin(currentPin, setLocalState);
                    }
                  },
                );
              } else if (index == 11) {
                // Delete button
                return _buildPinButton(
                  '⌫',
                  () {
                    if (currentPin.isNotEmpty) {
                      setLocalState(() => currentPin = currentPin.substring(0, currentPin.length - 1));
                      setState(() => _isError = false);
                    }
                  },
                  isDelete: true,
                );
              } else {
                // Numbers 1-9
                return _buildPinButton(
                  '${index + 1}',
                  () {
                    if (currentPin.length < 6) {
                      setLocalState(() => currentPin += '${index + 1}');
                      _checkUnlockPin(currentPin, setLocalState);
                    }
                  },
                );
              }
            },
          ),
          const SizedBox(height: 24),
          if (_useBiometric)
            _buildBiometricButton(),
        ],
      ),
    );
  }

  Widget _buildPinButton(String text, VoidCallback onTap, {bool isDelete = false}) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: isDelete
                ? [const Color(0xFF3A3A3C), const Color(0xFF2C2C2E)]
                : [const Color(0xFF4A4A4C), const Color(0xFF3A3A3C)],
          ),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: Colors.white.withValues(alpha: 0.1),
            width: 1,
          ),
        ),
        child: Center(
          child: Text(
            text,
            style: TextStyle(
              color: Colors.white,
              fontSize: isDelete ? 24 : 28,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _checkUnlockPin(String currentPin, StateSetter setLocalState) async {
    if (currentPin.length >= 4 && currentPin.length <= 6) {
      final repo = ref.read(securityRepositoryProvider);
      final storedPin = await repo.getPin();
      
      if (currentPin == storedPin) {
        setState(() => _isError = false);
        await repo.resetFailedAttempts();
        widget.onUnlocked();
      } else if (currentPin.length == 6) {
        setState(() => _isError = true);
        _handleFailedAttempt();
        Future.delayed(const Duration(milliseconds: 500), () {
          setLocalState(() => currentPin = '');
        });
      }
    }
  }

  Widget _buildBiometricButton() {
    return StatefulBuilder(
      builder: (context, setLocalState) {
        return GestureDetector(
          onTap: () async {
            setLocalState(() => _isAuthenticating = true);
            await _tryBiometric();
            setLocalState(() => _isAuthenticating = false);
          },
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 300),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: _isAuthenticating
                    ? [NovaColors.primary, NovaColors.primary.withValues(alpha: 0.7)]
                    : [const Color(0xFF4A4A4C), const Color(0xFF3A3A3C)],
              ),
              shape: BoxShape.circle,
              boxShadow: _isAuthenticating
                  ? [
                      BoxShadow(
                        color: NovaColors.primary.withValues(alpha: 0.5),
                        blurRadius: 20,
                        spreadRadius: 5,
                      ),
                    ]
                  : null,
            ),
            child: Container(
              padding: const EdgeInsets.all(20),
              child: Icon(
                Icons.fingerprint,
                size: 48,
                color: _isAuthenticating ? Colors.white : Colors.white70,
              ),
            ),
          ),
        );
      },
    );
  }
}

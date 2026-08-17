import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:novaapp/core/theme/nova_colors.dart';
import 'package:novaapp/features/settings/presentation/providers/security_providers.dart';


class AppLockSettingsScreen extends ConsumerStatefulWidget {
  const AppLockSettingsScreen({super.key});

  @override
  ConsumerState<AppLockSettingsScreen> createState() => _AppLockSettingsScreenState();
}

class _AppLockSettingsScreenState extends ConsumerState<AppLockSettingsScreen> {
  bool _canCheckBiometrics = false;

  @override
  void initState() {
    super.initState();
    _checkBiometrics();
  }

  Future<void> _checkBiometrics() async {
    final repo = ref.read(securityRepositoryProvider);
    final can = await repo.canCheckBiometrics();
    setState(() => _canCheckBiometrics = can);
  }

  @override
  Widget build(BuildContext context) {
    final lockEnabled = ref.watch(appLockEnabledProvider);
    final lockType = ref.watch(appLockTypeProvider);
    final repo = ref.read(securityRepositoryProvider);

    return Scaffold(
      backgroundColor: NovaColors.background,
      appBar: AppBar(
        backgroundColor: NovaColors.background,
        elevation: 0,
        title: const Text('Bloqueo de la aplicación', style: TextStyle(color: Colors.white, fontSize: 18)),
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      body: ListView(
        children: [
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: Text(
              'Asegura tus chats con un nivel extra de seguridad.',
              style: TextStyle(color: Colors.white70, fontSize: 14),
            ),
          ),
          SwitchListTile(
            title: const Text('Bloqueo activado', style: TextStyle(color: Colors.white)),
            value: lockEnabled,
            activeThumbColor: NovaColors.primary,
            onChanged: (val) async {
              await repo.setLockEnabled(val);
              ref.read(appLockEnabledProvider.notifier).state = val;
              if (val && lockType == 'none') {
                // If enabling for the first time, default to PIN
                _showPinSetupDialog();
              }
            },
          ),
          if (lockEnabled) ...[
            const Divider(color: Colors.white10),
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Text('MÉTODO DE BLOQUEO', style: TextStyle(color: NovaColors.textTertiary, fontSize: 12, fontWeight: FontWeight.bold)),
            ),

            // Mutually exclusive choice between PIN and Fingerprint
            ListTile(
              title: const Text('PIN numérico', style: TextStyle(color: Colors.white)),
              trailing: Icon(
                lockType == 'pin' ? Icons.radio_button_checked : Icons.radio_button_unchecked,
                color: lockType == 'pin' ? NovaColors.primary : Colors.white24,
              ),
              onTap: () async {
                _showPinSetupDialog();
              },
            ),

            if (_canCheckBiometrics)
              ListTile(
                title: const Text('Huella Dactilar', style: TextStyle(color: Colors.white)),
                subtitle: const Text('Usa la biometría registrada en el sistema.', style: TextStyle(color: Colors.white54, fontSize: 12)),
                trailing: Icon(
                  lockType == 'biometric' ? Icons.radio_button_checked : Icons.radio_button_unchecked,
                  color: lockType == 'biometric' ? NovaColors.primary : Colors.white24,
                ),
                onTap: () async {
                  final authenticated = await repo.authenticateWithBiometrics();
                  if (authenticated) {
                    await repo.setLockType('biometric');
                    ref.read(appLockTypeProvider.notifier).state = 'biometric';
                  }
                },
              ),
            
            const Divider(color: Colors.white10),
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Text('PRODUCTIVIDAD Y SEGURIDAD', style: TextStyle(color: NovaColors.textTertiary, fontSize: 12, fontWeight: FontWeight.bold)),
            ),
            
            ListTile(
              title: const Text('Bloqueo por inactividad', style: TextStyle(color: Colors.white)),
              subtitle: Text(_getInactivityLabel(ref.watch(inactivityTimeoutProvider)), style: const TextStyle(color: NovaColors.primary, fontSize: 12)),
              onTap: _showInactivityDialog,
            ),
            
            SwitchListTile(
              title: const Text('Bloquear al apagar pantalla', style: TextStyle(color: Colors.white)),
              value: ref.watch(lockOnScreenOffProvider),
              activeThumbColor: NovaColors.primary,
              onChanged: (val) async {
                await repo.setLockOnScreenOff(val);
                ref.read(lockOnScreenOffProvider.notifier).state = val;
              },
            ),
          ],
        ],
      ),
    );
  }

  String _getInactivityLabel(int minutes) {
    if (minutes == 0) return 'Instantáneamente';
    if (minutes == -1) return 'Nunca';
    return 'Tras $minutes minutos';
  }

  void _showInactivityDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: NovaColors.surface,
        title: const Text('Bloqueo por inactividad', style: TextStyle(color: Colors.white)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildInactivityOption('Instantáneamente', 0),
            _buildInactivityOption('Tras 1 minuto', 1),
            _buildInactivityOption('Tras 5 minutos', 5),
            _buildInactivityOption('Tras 15 minutos', 15),
            _buildInactivityOption('Tras 30 minutos', 30),
            _buildInactivityOption('Nunca', -1),
          ],
        ),
      ),
    );
  }

  Widget _buildInactivityOption(String label, int minutes) {
    final current = ref.watch(inactivityTimeoutProvider);
    return ListTile(
      title: Text(label, style: const TextStyle(color: Colors.white)),
      trailing: current == minutes ? const Icon(Icons.check, color: NovaColors.primary) : null,
      onTap: () async {
        final repo = ref.read(securityRepositoryProvider);
        await repo.setInactivityTimeout(minutes);
        ref.read(inactivityTimeoutProvider.notifier).state = minutes;
        if (mounted) Navigator.pop(context);
      },
    );
  }

  void _showPinSetupDialog() {
    String? _firstPin;
    String currentPin = '';

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          backgroundColor: Colors.black,
          title: const Text('Configurar PIN', style: TextStyle(color: Colors.white)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('Ingresa un PIN de 4-6 dígitos', style: TextStyle(color: Colors.white70)),
              const SizedBox(height: 20),
              TextField(
                obscureText: true,
                keyboardType: TextInputType.number,
                maxLength: 6,
                style: const TextStyle(color: Colors.white, fontSize: 24),
                textAlign: TextAlign.center,
                decoration: InputDecoration(
                  counterText: '',
                  filled: true,
                  fillColor: const Color(0xFF1C1C1E),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide.none,
                  ),
                ),
                onChanged: (value) {
                  setDialogState(() => currentPin = value);
                },
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('CANCELAR', style: TextStyle(color: Colors.white70)),
            ),
            ElevatedButton(
              onPressed: () async {
                if (currentPin.length < 4 || currentPin.length > 6) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('El PIN debe tener entre 4 y 6 dígitos')),
                  );
                  return;
                }
                if (_firstPin == null) {
                  setDialogState(() {
                    _firstPin = currentPin;
                    currentPin = '';
                  });
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Confirma el PIN')),
                  );
                } else {
                  if (currentPin == _firstPin) {
                    final repo = ref.read(securityRepositoryProvider);
                    repo.savePin(currentPin);
                    repo.setLockType('pin');
                    ref.read(appLockTypeProvider.notifier).state = 'pin';
                    if (!context.mounted) return;
                    Navigator.pop(context);
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('PIN guardado correctamente')),
                    );
                  } else {
                    setDialogState(() {
                      _firstPin = null;
                      currentPin = '';
                    });
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Los PIN no coinciden')),
                    );
                  }
                }
              },
              child: const Text('CONTINUAR'),
            ),
          ],
        ),
      ),
    );
  }
}

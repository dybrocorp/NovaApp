import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:pattern_lock/pattern_lock.dart';
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
                // If enabling for the first time, default to Pattern
                _showPatternSetupDialog();
              }
            },
          ),
          if (lockEnabled) ...[
            const Divider(color: Colors.white10),
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Text('MÉTODO DE BLOQUEO', style: TextStyle(color: NovaColors.textTertiary, fontSize: 12, fontWeight: FontWeight.bold)),
            ),
            
            // Mutually exclusive choice between Pattern and Fingerprint
            ListTile(
              title: const Text('Patrón de 9 puntos', style: TextStyle(color: Colors.white)),
              trailing: Icon(
                lockType == 'pattern' ? Icons.radio_button_checked : Icons.radio_button_unchecked,
                color: lockType == 'pattern' ? NovaColors.primary : Colors.white24,
              ),
              onTap: () async {
                _showPatternSetupDialog();
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

  void _showPatternSetupDialog() {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        backgroundColor: Colors.black,
        contentPadding: EdgeInsets.zero,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        title: const Padding(
          padding: EdgeInsets.all(16.0),
          child: Text('Configurar Patrón', style: TextStyle(color: Colors.white, fontSize: 18)),
        ),
        content: SizedBox(
          width: 300,
          height: 380,
          child: Column(
            children: [
              const Text('Dibuja tu patrón de 9 puntos', style: TextStyle(color: Colors.white70)),
              const SizedBox(height: 32),
              Expanded(
                child: PatternLock(
                  relativePadding: 40,
                  notSelectedColor: Colors.white10,
                  selectedColor: NovaColors.primary,
                  pointRadius: 10,
                  onInputComplete: (List<int> input) async {
                    if (input.length < 4) {
                      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('El patrón debe unir al menos 4 puntos')));
                      return;
                    }
                    final repo = ref.read(securityRepositoryProvider);
                    await repo.savePattern(input);
                    await repo.setLockType('pattern');
                    ref.read(appLockTypeProvider.notifier).state = 'pattern';
                    if (!context.mounted) return;
                    Navigator.pop(context);
                    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Patrón guardado correctamente')));
                  },
                ),
              ),
              const Padding(
                padding: EdgeInsets.all(16.0),
                child: Text('Une al menos 4 puntos.', style: TextStyle(color: Colors.white24, fontSize: 11)),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('CANCELAR', style: TextStyle(color: Colors.white70)),
          ),
        ],
      ),
    );
  }
}

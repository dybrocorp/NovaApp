import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:novaapp/features/settings/presentation/providers/security_providers.dart';
import 'package:novaapp/features/settings/presentation/app_unlock_screen.dart';

class SecurityManager extends StatefulWidget {
  final Widget child;
  const SecurityManager({super.key, required this.child});

  @override
  State<SecurityManager> createState() => _SecurityManagerState();
}

class _SecurityManagerState extends State<SecurityManager> with WidgetsBindingObserver {
  DateTime? _backgroundTime;
  bool _isLocked = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _checkInitialLock();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> _checkInitialLock() async {
    // On app start, if lock is enabled, we lock
    final container = ProviderScope.containerOf(context);
    await container.read(securityInitProvider.future);
    
    final enabled = container.read(appLockEnabledProvider);
    if (enabled) {
      setState(() => _isLocked = true);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final container = ProviderScope.containerOf(context);
    final enabled = container.read(appLockEnabledProvider);
    if (!enabled) return;

    if (state == AppLifecycleState.paused) {
      _backgroundTime = DateTime.now();
      
      final lockOnScreenOff = container.read(lockOnScreenOffProvider);
      if (lockOnScreenOff) {
         setState(() => _isLocked = true);
      }
    } else if (state == AppLifecycleState.resumed) {
      if (_backgroundTime != null) {
        final timeoutMinutes = container.read(inactivityTimeoutProvider);
        if (timeoutMinutes > 0) {
          final diff = DateTime.now().difference(_backgroundTime!).inMinutes;
          if (diff >= timeoutMinutes) {
            setState(() => _isLocked = true);
          }
        } else if (timeoutMinutes == 0) {
           // 0 means lock immediately upon backgrounding (Threema 'Instantly')
           // Actually Threema has explicit 'Instantly', '1 minute', etc.
           // Let's treat 0 as 'Always lock on return'
           setState(() => _isLocked = true);
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLocked) {
      return AppUnlockScreen(
        onUnlocked: () async {
          setState(() => _isLocked = false);
        },
      );
    }
    return widget.child;
  }
}

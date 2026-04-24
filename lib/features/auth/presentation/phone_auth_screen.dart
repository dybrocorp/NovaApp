import 'package:flutter/material.dart';
import 'package:intl_phone_field/intl_phone_field.dart';
import 'package:novaapp/core/theme/nova_colors.dart';
import 'package:novaapp/features/auth/presentation/otp_screen.dart';

class PhoneAuthScreen extends StatefulWidget {
  const PhoneAuthScreen({super.key});

  @override
  State<PhoneAuthScreen> createState() => _PhoneAuthScreenState();
}

class _PhoneAuthScreenState extends State<PhoneAuthScreen> {
  String _phoneNumber = '';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: NovaColors.background,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        actions: [
          IconButton(
            icon: const Icon(Icons.more_vert, color: Colors.white),
            onPressed: () {},
          ),
        ],
      ),
      body: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Número de teléfono',
                style: TextStyle(
                  fontSize: 32,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                ),
              ),
              const SizedBox(height: 12),
              const Text(
                'Recibirás una clave de verificación. Es posible que tu operador aplique algún cargo.',
                style: TextStyle(
                  fontSize: 16,
                  color: NovaColors.textSecondary,
                ),
              ),
              const SizedBox(height: 40),
              IntlPhoneField(
                decoration: InputDecoration(
                  filled: true,
                  fillColor: NovaColors.surface,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide.none,
                  ),
                  contentPadding: const EdgeInsets.symmetric(vertical: 18, horizontal: 16),
                ),
                initialCountryCode: 'CO',
                onChanged: (phone) {
                  _phoneNumber = phone.completeNumber;
                },
                dropdownTextStyle: const TextStyle(color: Colors.white),
                style: const TextStyle(color: Colors.white),
                cursorColor: NovaColors.primary,
              ),
              const SizedBox(height: 100), // Reserve space for FAB
            ],
          ),
        ),
      ),
      floatingActionButton: FloatingActionButton(
        backgroundColor: NovaColors.primary,
        onPressed: () {
          if (_phoneNumber.isNotEmpty) {
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (context) => OTPScreen(phoneNumber: _phoneNumber),
              ),
            );
          }
        },
        child: const Icon(Icons.arrow_forward, color: Colors.white),
      ),
    );
  }
}

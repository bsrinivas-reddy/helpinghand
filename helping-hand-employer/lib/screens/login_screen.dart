import 'dart:async';
import 'package:flutter/material.dart';
import '../services/api_service.dart';
import '../theme/app_colors.dart';
import 'home_screen.dart';
import 'registration_screen.dart';

class EmployerLoginScreen extends StatefulWidget {
  const EmployerLoginScreen({super.key});

  @override
  State<EmployerLoginScreen> createState() => _EmployerLoginScreenState();
}

class _EmployerLoginScreenState extends State<EmployerLoginScreen> {
  final ApiService _apiService = ApiService();
  final TextEditingController _phoneController = TextEditingController();
  final TextEditingController _otpController = TextEditingController();

  bool _otpSent = false;
  bool _isLoading = false;
  int _cooldownSeconds = 0;
  Timer? _cooldownTimer;
  String? _errorMessage;

  @override
  void dispose() {
    _cooldownTimer?.cancel();
    _phoneController.dispose();
    _otpController.dispose();
    super.dispose();
  }

  void _startCooldown() {
    setState(() => _cooldownSeconds = 60);
    _cooldownTimer?.cancel();
    _cooldownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) return;
      if (_cooldownSeconds > 0) {
        setState(() => _cooldownSeconds--);
      } else {
        timer.cancel();
      }
    });
  }

  Future<void> _handleSendOtp() async {
    final phone = _phoneController.text.trim();
    if (phone.length < 10) {
      setState(
        () => _errorMessage = 'Please enter a valid 10-digit mobile number',
      );
      return;
    }

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final res = await _apiService.sendOtp(phone);
      if (res['success'] == true) {
        setState(() {
          _otpSent = true;
        });
        _startCooldown();
      } else {
        setState(
          () => _errorMessage =
              res['error'] ?? 'Failed to send OTP. Please try again.',
        );
      }
    } catch (e) {
      setState(() => _errorMessage = 'Connection error: $e');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _handleVerifyOtp() async {
    final phone = _phoneController.text.trim();
    final otp = _otpController.text.trim();

    if (otp.length != 6) {
      setState(
        () => _errorMessage = 'Please enter all 6 digits of the OTP code',
      );
      return;
    }

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final res = await _apiService.verifyOtp(phone, otp);
      if (res['success'] == true) {
        final isNewUser = res['isNewUser'] == true;
        if (isNewUser) {
          if (res['registrationGrant'] is! String ||
              (res['registrationGrant'] as String).isEmpty) {
            if (mounted) {
              setState(
                () =>
                    _errorMessage = 'Verification expired. Request a new code.',
              );
            }
            return;
          }
          if (!mounted) return;
          Navigator.pushReplacement(
            context,
            MaterialPageRoute(
              builder: (context) => EmployerRegistrationScreen(
                phoneNumber: phone,
                registrationGrant: res['registrationGrant'] as String,
              ),
            ),
          );
        } else {
          final user = res['user'];
          await _apiService.saveSession(
            employerId: user['employer_id'],
            phoneNumber: user['phone_number'],
            fullName: user['full_name'],
            email: user['email'],
            avatarUrl: user['avatar_url'],
            upiId: user['upi_id'],
            token: res['token'],
            refreshToken: res['refreshToken'],
          );

          if (!mounted) return;
          Navigator.pushReplacement(
            context,
            MaterialPageRoute(builder: (context) => const HomeScreen()),
          );
        }
      } else {
        setState(
          () => _errorMessage =
              res['error'] ?? 'Invalid OTP code. Please try again.',
        );
      }
    } catch (e) {
      setState(() => _errorMessage = 'Verification error: $e');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.surfaceOffWhite,
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(28),
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 20),
              const Row(
                children: [
                  Icon(
                    Icons.handshake_outlined,
                    size: 30,
                    color: AppColors.primary,
                  ),
                  SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Helping Hand',
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 48),
              const Text(
                'FOR EMPLOYERS',
                style: TextStyle(
                  color: AppColors.primary,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.6,
                ),
              ),
              const SizedBox(height: 14),
              const Text(
                'Find the right\nhelp nearby.',
                style: TextStyle(
                  fontSize: 42,
                  height: 1.08,
                  letterSpacing: -1.5,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 18),
              const Text(
                'Find workers, agree a daily wage and manage your shifts in one place.',
                style: TextStyle(
                  fontSize: 17,
                  height: 1.5,
                  color: AppColors.textSecondary,
                ),
              ),
              const SizedBox(height: 32),
              Container(
                padding: const EdgeInsets.all(22),
                decoration: BoxDecoration(
                  color: Colors.white,
                  border: Border.all(color: AppColors.borderLight),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      _otpSent
                          ? 'Check your messages'
                          : 'Sign in or get started',
                      style: const TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      _otpSent
                          ? 'Enter the code sent to +91 ${_phoneController.text.trim()}.'
                          : 'Enter your mobile number to continue.',
                      style: const TextStyle(
                        height: 1.5,
                        color: AppColors.textSecondary,
                      ),
                    ),
                    const SizedBox(height: 24),
                    if (!_otpSent) ...[
                      TextField(
                        controller: _phoneController,
                        keyboardType: TextInputType.phone,
                        maxLength: 10,
                        autofillHints: const [
                          AutofillHints.telephoneNumberNational,
                        ],
                        decoration: const InputDecoration(
                          labelText: 'Mobile number',
                          prefixText: '+91  ',
                          hintText: '10-digit mobile number',
                        ),
                        onChanged: (_) => setState(() => _errorMessage = null),
                      ),
                      const SizedBox(height: 16),
                      ElevatedButton(
                        onPressed:
                            _isLoading ||
                                !RegExp(
                                  r'^[0-9]{10}$',
                                ).hasMatch(_phoneController.text.trim())
                            ? null
                            : _handleSendOtp,
                        child: _isLoading
                            ? const SizedBox(
                                height: 22,
                                width: 22,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Text('Send verification code'),
                      ),
                    ] else ...[
                      TextField(
                        controller: _otpController,
                        keyboardType: TextInputType.number,
                        autofillHints: const [AutofillHints.oneTimeCode],
                        maxLength: 6,
                        decoration: const InputDecoration(
                          labelText: 'Verification code',
                          hintText: '6-digit code',
                        ),
                        onChanged: (_) => setState(() {}),
                      ),
                      const SizedBox(height: 20),
                      ElevatedButton(
                        onPressed: _isLoading ? null : _handleVerifyOtp,
                        child: _isLoading
                            ? const SizedBox(
                                height: 22,
                                width: 22,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Text('Verify and continue'),
                      ),
                      TextButton(
                        onPressed: _isLoading
                            ? null
                            : () => setState(() {
                                _otpSent = false;
                                _errorMessage = null;
                              }),
                        child: const Text('Use a different number'),
                      ),
                      TextButton(
                        onPressed: _isLoading || _cooldownSeconds > 0
                            ? null
                            : _handleSendOtp,
                        child: Text(
                          _cooldownSeconds > 0
                              ? 'Resend in ${_cooldownSeconds}s'
                              : 'Resend code',
                        ),
                      ),
                    ],
                    if (_errorMessage != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 14),
                        child: Text(
                          _errorMessage!,
                          style: const TextStyle(color: AppColors.statusRed),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 20),
              const SizedBox(height: 24),
              const Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    Icons.info_outline,
                    size: 18,
                    color: AppColors.textSecondary,
                  ),
                  SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Review a worker’s profile and agree the work and pay before a shift begins.',
                      style: TextStyle(
                        fontSize: 13,
                        height: 1.5,
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

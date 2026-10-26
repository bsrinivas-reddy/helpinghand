import 'package:flutter/material.dart';
import '../services/api_service.dart';
import '../theme/app_colors.dart';
import 'registration_screen.dart';
import 'home_screen.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _phoneController = TextEditingController();
  final _otpController = TextEditingController();
  final _apiService = ApiService();

  bool _showGetStarted = true;
  bool _otpSent = false;
  bool _isLoading = false;
  String? _errorMessage;

  @override
  void dispose() {
    _phoneController.dispose();
    _otpController.dispose();
    super.dispose();
  }

  bool get _isPhoneValid {
    final phone = _phoneController.text.trim();
    return phone.length == 10 && RegExp(r'^[0-9]+$').hasMatch(phone);
  }

  bool get _isOtpValid {
    final otp = _otpController.text.trim();
    return otp.length == 6 && RegExp(r'^[0-9]+$').hasMatch(otp);
  }

  Future<void> _sendOtp() async {
    final phone = _phoneController.text.trim();
    if (!_isPhoneValid) {
      setState(
        () => _errorMessage = 'Please enter a valid 10-digit phone number.',
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
        setState(() => _otpSent = true);
      } else {
        final error = res['error']?.toString() ?? '';
        String errMsg = 'Something went wrong. Please try again.';
        if (error.contains('limit') || error.contains('too many')) {
          errMsg = 'Too many attempts. Please try again later.';
        } else if (error.isNotEmpty) {
          errMsg = error;
        }
        setState(() => _errorMessage = errMsg);
      }
    } catch (e) {
      setState(
        () => _errorMessage =
            'Couldn\'t send the OTP. Please check your connection and try again.',
      );
    } finally {
      setState(() => _isLoading = false);
    }
  }

  Future<void> _verifyOtp() async {
    final phone = _phoneController.text.trim();
    final otp = _otpController.text.trim();
    if (!_isOtpValid) {
      setState(() => _errorMessage = 'Please enter a valid 6-digit OTP.');
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
          if (mounted) {
            Navigator.pushReplacement(
              context,
              MaterialPageRoute(
                builder: (context) => RegistrationScreen(
                  phoneNumber: phone,
                  registrationGrant: res['registrationGrant'] as String,
                ),
              ),
            );
          }
        } else {
          final userData = res['user'];
          await _apiService.saveSession(
            workerId: userData['worker_id'],
            phoneNumber: userData['phone_number'],
            category: userData['worker_category'],
            subCategory: userData['worker_sub_category'],
            email: userData['email'],
            avatarUrl: userData['avatar_url'],
            token: res['token'],
            refreshToken: res['refreshToken'],
          );

          if (mounted) {
            Navigator.pushReplacement(
              context,
              MaterialPageRoute(builder: (context) => const HomeScreen()),
            );
          }
        }
      } else {
        setState(
          () => _errorMessage =
              res['error'] ?? 'Invalid OTP code. Please try again.',
        );
      }
    } catch (e) {
      setState(() => _errorMessage = 'Something went wrong. Please try again.');
    } finally {
      setState(() => _isLoading = false);
    }
  }

  Widget _buildOnboarding() {
    return Scaffold(
      backgroundColor: AppColors.surfaceOff,
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(28),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 20),
              const Row(
                children: [
                  Icon(
                    Icons.handshake_outlined,
                    color: AppColors.accentPurple,
                    size: 30,
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
                'FOR WORKERS',
                style: TextStyle(
                  color: AppColors.accentPurple,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.6,
                ),
              ),
              const SizedBox(height: 14),
              const Text(
                'Local work.\nClear terms.',
                style: TextStyle(
                  fontSize: 42,
                  height: 1.08,
                  letterSpacing: -1.5,
                  fontWeight: FontWeight.w700,
                  color: AppColors.textLightPrimary,
                ),
              ),
              const SizedBox(height: 18),
              const Text(
                'Manage your availability, review shift requests and keep track of your work in one place.',
                style: TextStyle(
                  fontSize: 17,
                  height: 1.5,
                  color: AppColors.textLightSecondary,
                ),
              ),
              const SizedBox(height: 36),
              _onboardingStep(
                Icons.person_outline,
                'Set up your work profile',
                'Add your skills so employers know what you do.',
              ),
              _onboardingStep(
                Icons.work_outline,
                'Review each shift',
                'Check the employer and daily wage before accepting.',
              ),
              _onboardingStep(
                Icons.receipt_long_outlined,
                'Keep a record of your work',
                'Follow shift progress and payment confirmation.',
              ),
              const SizedBox(height: 32),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: () => setState(() => _showGetStarted = false),
                  child: const Text('Get started'),
                ),
              ),
              const SizedBox(height: 14),
              const Text(
                'Worker app · Sign in with your mobile number',
                style: TextStyle(
                  fontSize: 12,
                  color: AppColors.textLightSecondary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _onboardingStep(IconData icon, String title, String detail) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 24),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: const Color(0xFFE4F1EC),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(icon, color: AppColors.accentPurple),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 5),
                Text(
                  detail,
                  style: const TextStyle(
                    fontSize: 14,
                    height: 1.4,
                    color: AppColors.textLightSecondary,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLoginScreen() {
    return Scaffold(
      backgroundColor: AppColors.surfaceOff,
      appBar: AppBar(
        backgroundColor: AppColors.surfaceOff,
        title: const Text('Worker sign in'),
        leading: BackButton(
          onPressed: () => setState(() => _showGetStarted = true),
        ),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(28),
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 24),
              const Icon(
                Icons.phone_android_outlined,
                color: AppColors.accentPurple,
                size: 40,
                textDirection: TextDirection.ltr,
              ),
              const SizedBox(height: 28),
              Text(
                _otpSent ? 'Enter your code' : 'Your next shift\nstarts here.',
                style: const TextStyle(
                  fontSize: 34,
                  height: 1.15,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.8,
                ),
              ),
              const SizedBox(height: 14),
              Text(
                _otpSent
                    ? 'Enter the 6-digit code sent to +91 ${_phoneController.text.trim()}.'
                    : 'Use your mobile number to sign in or create a worker profile.',
                style: const TextStyle(
                  fontSize: 16,
                  height: 1.5,
                  color: AppColors.textLightSecondary,
                ),
              ),
              const SizedBox(height: 32),
              if (!_otpSent) ...[
                TextField(
                  controller: _phoneController,
                  keyboardType: TextInputType.phone,
                  autofillHints: const [AutofillHints.telephoneNumberNational],
                  maxLength: 10,
                  decoration: InputDecoration(
                    labelText: 'Mobile number',
                    prefixText: '+91  ',
                    hintText: '10-digit mobile number',
                    errorText: _errorMessage,
                  ),
                  onChanged: (_) => setState(() => _errorMessage = null),
                ),
                const SizedBox(height: 20),
                ElevatedButton(
                  onPressed: _isPhoneValid && !_isLoading ? _sendOtp : null,
                  child: _isLoading
                      ? const SizedBox(
                          height: 22,
                          width: 22,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('Send verification code'),
                ),
              ] else ...[
                TextField(
                  controller: _otpController,
                  keyboardType: TextInputType.number,
                  autofillHints: const [AutofillHints.oneTimeCode],
                  maxLength: 6,
                  decoration: InputDecoration(
                    labelText: 'Verification code',
                    errorText: _errorMessage,
                  ),
                  onChanged: (_) => setState(() => _errorMessage = null),
                ),
                const SizedBox(height: 20),
                ElevatedButton(
                  onPressed: _isOtpValid && !_isLoading ? _verifyOtp : null,
                  child: _isLoading
                      ? const SizedBox(
                          height: 22,
                          width: 22,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('Verify and continue'),
                ),
                TextButton(
                  onPressed: _isLoading
                      ? null
                      : () => setState(() {
                          _otpSent = false;
                          _otpController.clear();
                          _errorMessage = null;
                        }),
                  child: const Text('Use a different number'),
                ),
              ],
              const SizedBox(height: 24),
              const SizedBox(height: 24),
              const Text(
                'Never share your verification code with an employer or another worker.',
                style: TextStyle(
                  fontSize: 13,
                  height: 1.5,
                  color: AppColors.textLightSecondary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 320),
      transitionBuilder: (child, animation) {
        return FadeTransition(opacity: animation, child: child);
      },
      child: _showGetStarted
          ? KeyedSubtree(
              key: const ValueKey('onboarding'),
              child: _buildOnboarding(),
            )
          : KeyedSubtree(
              key: const ValueKey('login'),
              child: _buildLoginScreen(),
            ),
    );
  }
}

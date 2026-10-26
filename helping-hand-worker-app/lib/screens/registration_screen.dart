import 'package:flutter/material.dart';
import '../services/api_service.dart';
import '../theme/app_colors.dart';
import 'home_screen.dart';

class RegistrationScreen extends StatefulWidget {
  final String phoneNumber;
  final String registrationGrant;
  const RegistrationScreen({
    super.key,
    required this.phoneNumber,
    required this.registrationGrant,
  });

  @override
  State<RegistrationScreen> createState() => _RegistrationScreenState();
}

class _RegistrationScreenState extends State<RegistrationScreen> {
  final _subCategoryController = TextEditingController();
  final _apiService = ApiService();

  String? _selectedCategory;
  bool _isLoading = false;
  String? _errorMessage;

  final List<Map<String, dynamic>> _categories = [
    {'name': 'MASON', 'icon': Icons.construction},
    {'name': 'ELECTRICIAN', 'icon': Icons.electrical_services},
    {'name': 'PLUMBER', 'icon': Icons.plumbing},
    {'name': 'PAINTER', 'icon': Icons.format_paint},
    {'name': 'CARPENTER', 'icon': Icons.carpenter},
    {'name': 'LABOURER', 'icon': Icons.work_outline},
  ];

  @override
  void dispose() {
    _subCategoryController.dispose();
    super.dispose();
  }

  Future<void> _register() async {
    if (_selectedCategory == null) {
      setState(() => _errorMessage = 'Please select a worker category');
      return;
    }

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final res = await _apiService.registerWorker(
        phoneNumber: widget.phoneNumber,
        registrationGrant: widget.registrationGrant,
        workerCategory: _selectedCategory!,
        workerSubCategory: _subCategoryController.text.trim().isEmpty
            ? null
            : _subCategoryController.text.trim(),
      );

      if (res['success'] == true) {
        final userData = res['user'];
        final String? token = res['token'];
        final String? refreshToken = res['refreshToken'];

        await _apiService.saveSession(
          workerId: userData['worker_id'],
          phoneNumber: userData['phone_number'],
          category: userData['worker_category'],
          subCategory: userData['worker_sub_category'],
          email: userData['email'],
          avatarUrl: userData['avatar_url'],
          token: token,
          refreshToken: refreshToken,
        );

        if (mounted) {
          Navigator.pushReplacement(
            context,
            MaterialPageRoute(builder: (context) => const HomeScreen()),
          );
        }
      } else {
        setState(() => _errorMessage = res['error'] ?? 'Registration failed');
      }
    } catch (e) {
      setState(() => _errorMessage = 'Onboarding failed: ${e.toString()}');
    } finally {
      setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            colors: [AppColors.primaryDark, AppColors.primaryMid],
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
          ),
        ),
        child: SafeArea(
          child: Column(
            children: [
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(28.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const SizedBox(height: 20),
                      Text(
                        'Worker Profile Setup',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.headlineLarge,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Select your skill category to match with local jobs',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: AppColors.textDarkSecondary,
                        ),
                      ),
                      const SizedBox(height: 32),
                      if (_errorMessage != null) ...[
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: AppColors.statusRed.withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(
                              color: AppColors.statusRed.withValues(alpha: 0.4),
                            ),
                          ),
                          child: Text(
                            _errorMessage!,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 13,
                            ),
                            textAlign: TextAlign.center,
                          ),
                        ),
                        const SizedBox(height: 20),
                      ],
                      Text(
                        'Skill Category',
                        style: theme.textTheme.titleMedium?.copyWith(
                          color: Colors.white,
                        ),
                      ),
                      const SizedBox(height: 12),
                      GridView.builder(
                        shrinkWrap: true,
                        physics: const NeverScrollableScrollPhysics(),
                        gridDelegate:
                            const SliverGridDelegateWithFixedCrossAxisCount(
                              crossAxisCount: 2,
                              crossAxisSpacing: 16,
                              mainAxisSpacing: 16,
                              childAspectRatio: 1.3,
                            ),
                        itemCount: _categories.length,
                        itemBuilder: (context, index) {
                          final cat = _categories[index];
                          final isSelected = _selectedCategory == cat['name'];
                          return InkWell(
                            onTap: () =>
                                setState(() => _selectedCategory = cat['name']),
                            borderRadius: BorderRadius.circular(16),
                            child: AnimatedContainer(
                              duration: const Duration(milliseconds: 200),
                              decoration: BoxDecoration(
                                color: isSelected
                                    ? AppColors.accentPurple
                                    : AppColors.primaryMid.withValues(
                                        alpha: 0.6,
                                      ),
                                borderRadius: BorderRadius.circular(16),
                                border: Border.all(
                                  color: isSelected
                                      ? AppColors.accentPurple
                                      : AppColors.primaryLight.withValues(
                                          alpha: 0.5,
                                        ),
                                  width: 1.5,
                                ),
                              ),
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Icon(
                                    cat['icon'],
                                    size: 32,
                                    color: Colors.white,
                                  ),
                                  const SizedBox(height: 8),
                                  Text(
                                    cat['name'],
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontWeight: FontWeight.bold,
                                      fontSize: 13,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
                      const SizedBox(height: 24),
                      Text(
                        'Sub-Category / Speciality (Optional)',
                        style: theme.textTheme.titleMedium?.copyWith(
                          color: Colors.white,
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: _subCategoryController,
                        style: const TextStyle(color: Colors.white),
                        decoration: const InputDecoration(
                          hintText: 'e.g. Tile Fitting, House Wiring',
                          prefixIcon: Icon(
                            Icons.star_border,
                            color: AppColors.textDarkSecondary,
                          ),
                        ),
                      ),
                      const SizedBox(height: 40),
                    ],
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 28,
                  vertical: 20,
                ),
                child: ElevatedButton(
                  onPressed: _isLoading ? null : _register,
                  style: ElevatedButton.styleFrom(
                    minimumSize: const Size.fromHeight(56),
                  ),
                  child: _isLoading
                      ? const SizedBox(
                          height: 20,
                          width: 20,
                          child: CircularProgressIndicator(
                            color: Colors.white,
                            strokeWidth: 2,
                          ),
                        )
                      : const Text('Complete Onboarding'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

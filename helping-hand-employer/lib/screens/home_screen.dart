import 'package:flutter/material.dart';
import '../services/api_service.dart';
import '../theme/app_colors.dart';
import 'login_screen.dart';
import 'map_screen.dart';
import 'profile_screen.dart';
import 'shifts_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _currentIndex = 0;
  int _shiftsEpoch = 0;
  final ApiService _apiService = ApiService();

  String _employerName = 'Employer';
  int _activeShiftsCount = 0;
  double _totalSpent = 0.0;
  List<dynamic> _recentShifts = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadDashboardData();
  }

  Future<void> _loadDashboardData() async {
    setState(() {
      _isLoading = true;
    });

    try {
      final session = await _apiService.getSession();
      final String? employerId = session['employerId'];
      final String name = session['fullName'] ?? 'Employer';

      if (employerId == null) {
        if (!mounted) return;
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(builder: (context) => const EmployerLoginScreen()),
        );
        return;
      }

      final response = await _apiService.getEmployerShifts(employerId);

      if (!mounted) return;

      if (response['success'] == true) {
        final List<dynamic> shifts = response['shifts'] ?? [];
        int activeCount = 0;
        double spent = 0.0;

        for (final shift in shifts) {
          final String status = shift['status'] ?? '';
          if (status == 'ACTIVE') {
            activeCount++;
          }
          if (status == 'COMPLETED') {
            final double actualPaid =
                double.tryParse('${shift['actual_cash_paid']}') ??
                double.tryParse('${shift['adjusted_wage']}') ??
                double.tryParse('${shift['agreed_daily_wage']}') ??
                0.0;
            spent += actualPaid;
          }
        }

        setState(() {
          _employerName = name;
          _activeShiftsCount = activeCount;
          _totalSpent = spent;
          _recentShifts = shifts.take(3).toList();
        });
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Error loading dashboard: $e')));
      }
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  Widget _buildDashboardTab() {
    final theme = Theme.of(context);
    return Scaffold(
      backgroundColor: AppColors.surfaceOffWhite,
      appBar: AppBar(
        backgroundColor: AppColors.surfaceOffWhite,
        elevation: 0,
        toolbarHeight: 80,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Your workplace,', style: theme.textTheme.bodyMedium),
            Text(_employerName, style: theme.textTheme.headlineLarge),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(
              Icons.refresh,
              color: AppColors.textPrimary,
              size: 28,
            ),
            onPressed: _loadDashboardData,
          ),
          Padding(
            padding: const EdgeInsets.only(right: 16.0, left: 8.0),
            child: CircleAvatar(
              radius: 20,
              backgroundColor: AppColors.primaryLight,
              child: Text(
                _employerName.isNotEmpty ? _employerName[0].toUpperCase() : 'E',
                style: const TextStyle(
                  color: AppColors.primary,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _loadDashboardData,
              child: SingleChildScrollView(
                physics: const AlwaysScrollableScrollPhysics(),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16.0,
                    vertical: 8.0,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: _buildStatCard(
                              'Active Shifts',
                              '$_activeShiftsCount',
                              Icons.work_outline,
                              AppColors.primary,
                            ),
                          ),
                          const SizedBox(width: 16),
                          Expanded(
                            child: _buildStatCard(
                              'Recorded cash paid',
                              '₹${_totalSpent.toStringAsFixed(0)}',
                              Icons.currency_rupee,
                              AppColors.statusGreen,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 32),
                      Card(
                        child: Padding(
                          padding: const EdgeInsets.all(20),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Find help for your next shift',
                                style: theme.textTheme.titleLarge,
                              ),
                              const SizedBox(height: 10),
                              const Text(
                                'Browse nearby workers and review their profile before agreeing the work and daily wage.',
                                style: TextStyle(
                                  height: 1.5,
                                  color: AppColors.textSecondary,
                                ),
                              ),
                              const SizedBox(height: 16),
                              SizedBox(
                                width: double.infinity,
                                child: ElevatedButton.icon(
                                  onPressed: () =>
                                      setState(() => _currentIndex = 2),
                                  icon: const Icon(Icons.map_outlined),
                                  label: const Text('Find nearby workers'),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 24),
                      Text('Recent Shifts', style: theme.textTheme.titleLarge),
                      const SizedBox(height: 16),
                      if (_recentShifts.isEmpty)
                        const Padding(
                          padding: EdgeInsets.symmetric(vertical: 16.0),
                          child: Text(
                            'No shifts created yet.',
                            style: TextStyle(color: AppColors.textSecondary),
                          ),
                        )
                      else
                        ..._recentShifts.map((shift) {
                          final String status = shift['status'] ?? 'PENDING';
                          final double progress = status == 'COMPLETED'
                              ? 1.0
                              : (status == 'ACTIVE' ? 0.5 : 0.2);
                          return Padding(
                            padding: const EdgeInsets.only(bottom: 12.0),
                            child: _buildShiftRow(
                              'Shift #${shift['shift_id'].toString().substring(0, 8)}',
                              'Status: $status',
                              progress,
                              Icons.work,
                            ),
                          );
                        }),
                      const SizedBox(height: 100),
                    ],
                  ),
                ),
              ),
            ),
    );
  }

  Widget _buildStatCard(
    String title,
    String value,
    IconData icon,
    Color color,
  ) {
    return Card(
      elevation: 0,
      color: color.withValues(alpha: 0.1),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide.none,
      ),
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: color, size: 28),
            const SizedBox(height: 12),
            Text(
              title,
              style: const TextStyle(
                color: AppColors.textSecondary,
                fontSize: 13,
                fontWeight: FontWeight.w500,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              value,
              style: const TextStyle(
                color: AppColors.textPrimary,
                fontSize: 24,
                fontWeight: FontWeight.w800,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildShiftRow(
    String title,
    String status,
    double progress,
    IconData icon,
  ) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppColors.surfaceOffWhite,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(icon, color: AppColors.textPrimary, size: 24),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 16,
                      color: AppColors.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    status,
                    style: const TextStyle(
                      color: AppColors.textSecondary,
                      fontSize: 13,
                    ),
                  ),
                  const SizedBox(height: 8),
                  LinearProgressIndicator(
                    value: progress,
                    backgroundColor: AppColors.borderLight,
                    valueColor: AlwaysStoppedAnimation<Color>(
                      progress == 1.0
                          ? AppColors.statusGreen
                          : AppColors.primary,
                    ),
                    minHeight: 6,
                    borderRadius: BorderRadius.circular(4),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            const Icon(Icons.chevron_right, color: AppColors.textSecondary),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final List<Widget> tabs = [
      _buildDashboardTab(),
      ShiftsScreen(key: ValueKey('shifts-$_shiftsEpoch')),
      const MapScreen(),
      const ProfileScreen(),
    ];

    return Scaffold(
      body: IndexedStack(index: _currentIndex, children: tabs),
      bottomNavigationBar: Container(
        decoration: BoxDecoration(
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.05),
              blurRadius: 10,
              offset: const Offset(0, -5),
            ),
          ],
        ),
        child: BottomNavigationBar(
          currentIndex: _currentIndex,
          onTap: (index) {
            final changed = index != _currentIndex;
            setState(() {
              _currentIndex = index;
              // Reload shift data when returning to Home or Shifts so a
              // request sent from the map shows up.
              if (changed && index == 1) _shiftsEpoch++;
            });
            if (changed && index == 0) _loadDashboardData();
          },
          backgroundColor: Colors.white,
          selectedItemColor: AppColors.primary,
          unselectedItemColor: AppColors.textSecondary,
          showSelectedLabels: true,
          showUnselectedLabels: true,
          type: BottomNavigationBarType.fixed,
          elevation: 0,
          selectedFontSize: 12,
          unselectedFontSize: 12,
          items: const [
            BottomNavigationBarItem(
              icon: Icon(Icons.home_outlined),
              activeIcon: Icon(Icons.home),
              label: 'Home',
            ),
            BottomNavigationBarItem(
              icon: Icon(Icons.work_outline),
              activeIcon: Icon(Icons.work),
              label: 'Shifts',
            ),
            BottomNavigationBarItem(
              icon: Icon(Icons.map_outlined),
              activeIcon: Icon(Icons.map),
              label: 'Map',
            ),
            BottomNavigationBarItem(
              icon: Icon(Icons.person_outline),
              activeIcon: Icon(Icons.person),
              label: 'Profile',
            ),
          ],
        ),
      ),
    );
  }
}

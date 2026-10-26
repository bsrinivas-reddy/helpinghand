import 'package:flutter/material.dart';
import '../services/api_service.dart';
import '../theme/app_colors.dart';
import 'shifts_screen.dart';
import 'profile_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _currentIndex = 0;
  String? _workerId;
  String _name = 'Your work';
  final _apiService = ApiService();

  @override
  void initState() {
    super.initState();
    _loadSession();
  }

  Future<void> _loadSession() async {
    final session = await _apiService.getSession();
    if (!mounted) return;
    setState(() {
      _workerId = session['workerId'];
      _name = session['fullName']?.isNotEmpty == true
          ? session['fullName']!
          : 'Your work';
    });
  }

  Widget _overview() {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Helping Hand'),
        backgroundColor: AppColors.surfaceOff,
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            const Text(
              'WORKER',
              style: TextStyle(
                fontSize: 12,
                letterSpacing: 1.5,
                fontWeight: FontWeight.w700,
                color: AppColors.accentPurple,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              _name,
              style: const TextStyle(
                fontSize: 32,
                fontWeight: FontWeight.w700,
                letterSpacing: -0.8,
              ),
            ),
            const SizedBox(height: 12),
            const Text(
              'Your shifts and work profile, without the clutter.',
              style: TextStyle(
                fontSize: 16,
                height: 1.5,
                color: AppColors.textLightSecondary,
              ),
            ),
            const SizedBox(height: 32),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(22),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(
                      Icons.work_outline,
                      size: 32,
                      color: AppColors.accentPurple,
                    ),
                    const SizedBox(height: 18),
                    const Text(
                      'Review your shifts',
                      style: TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 10),
                    const Text(
                      'See requests from employers, check the daily wage and follow work already in progress.',
                      style: TextStyle(
                        fontSize: 15,
                        height: 1.5,
                        color: AppColors.textLightSecondary,
                      ),
                    ),
                    const SizedBox(height: 20),
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton(
                        onPressed: () => setState(() => _currentIndex = 1),
                        child: const Text('View my shifts'),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 24),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(
                Icons.person_outline,
                color: AppColors.accentPurple,
              ),
              title: const Text('Work profile and availability'),
              subtitle: const Text('Manage your skills and when you can work'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => setState(() => _currentIndex = 2),
            ),
            const Divider(height: 28),
            const Text(
              'Before you accept',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 10),
            const Text(
              'Agree the work, location and pay with your employer. Only mark a payment as received after you have the cash.',
              style: TextStyle(
                height: 1.5,
                color: AppColors.textLightSecondary,
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _currentIndex,
        children: [
          _overview(),
          const ShiftsScreen(),
          ProfileScreen(workerId: _workerId),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _currentIndex,
        onDestinationSelected: (index) => setState(() => _currentIndex = index),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.home_outlined),
            selectedIcon: Icon(Icons.home),
            label: 'Home',
          ),
          NavigationDestination(
            icon: Icon(Icons.work_outline),
            selectedIcon: Icon(Icons.work),
            label: 'My shifts',
          ),
          NavigationDestination(
            icon: Icon(Icons.person_outline),
            selectedIcon: Icon(Icons.person),
            label: 'Profile',
          ),
        ],
      ),
    );
  }
}

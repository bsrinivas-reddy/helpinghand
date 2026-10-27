import 'package:flutter/material.dart';
import '../utils/friendly_error.dart';
import 'package:geolocator/geolocator.dart';
import '../services/api_service.dart';
import '../theme/app_colors.dart';

class ShiftsScreen extends StatefulWidget {
  const ShiftsScreen({super.key});

  @override
  State<ShiftsScreen> createState() => _ShiftsScreenState();
}

class _ShiftsScreenState extends State<ShiftsScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  final ApiService _apiService = ApiService();

  List<dynamic> _shifts = [];
  bool _isLoading = true;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
    _loadShifts();
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _loadShifts() async {
    setState(() {
      _isLoading = true;
    });

    try {
      final session = await _apiService.getSession();
      final employerId = session['employerId'];
      if (employerId == null) {
        throw StateError('Your session ended. Sign in again.');
      }

      final response = await _apiService.getEmployerShifts(employerId);
      if (!mounted) return;

      if (response['success'] == true) {
        setState(() {
          _shifts = response['shifts'] ?? [];
          _errorMessage = null;
        });
      } else {
        setState(
          () => _errorMessage = response['error'] ?? 'Could not load shifts.',
        );
      }
    } catch (e) {
      if (mounted) {
        setState(
          () => _errorMessage =
              'Could not load shifts. Check your connection and retry.',
        );
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(friendlyError(e))));
      }
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  List<dynamic> _filterShifts(String category) {
    if (category == 'Upcoming') {
      return _shifts
          .where((s) => s['status'] == 'PENDING' || s['status'] == 'ACCEPTED')
          .toList();
    } else if (category == 'Active') {
      return _shifts.where((s) => s['status'] == 'ACTIVE').toList();
    } else {
      return _shifts
          .where(
            (s) => s['status'] == 'COMPLETED' || s['status'] == 'CANCELLED',
          )
          .toList();
    }
  }

  Future<void> _handleReconcileCash(Map<String, dynamic> shift) async {
    final controller = TextEditingController();
    final code = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Confirm the cash handover'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Confirm you paid ₹${shift['adjusted_wage'] ?? shift['agreed_daily_wage']} in cash. Pay the worker first. Ask them to create a code after receiving the cash, then enter it here. Both devices need location access.',
            ),
            const SizedBox(height: 20),
            TextField(
              controller: controller,
              keyboardType: TextInputType.number,
              maxLength: 4,
              decoration: const InputDecoration(
                labelText: 'Worker’s 4-digit code',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              if (RegExp(r'^[0-9]{4}$').hasMatch(controller.text)) {
                Navigator.pop(context, controller.text);
              }
            },
            child: const Text('Cash paid · Confirm'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (code == null || !mounted) return;
    setState(() => _isLoading = true);
    try {
      if (!await Geolocator.isLocationServiceEnabled()) {
        throw StateError('Turn on location services to confirm the handover.');
      }
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission != LocationPermission.always &&
          permission != LocationPermission.whileInUse) {
        throw StateError(
          'Location permission is needed. No default location will be used.',
        );
      }
      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 15),
        ),
      );
      final response = await _apiService.confirmCashHandshake(
        shiftId: shift['shift_id'],
        handshakeCode: code,
        employerLat: position.latitude,
        employerLng: position.longitude,
        cashAmount: double.tryParse(
          '${shift['adjusted_wage'] ?? shift['agreed_daily_wage']}',
        ),
      );
      if (!mounted) return;
      if (response['success'] != true) {
        throw StateError(response['error'] ?? 'Could not confirm handover.');
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Cash handover recorded. Shift closed.')),
      );
      await _loadShifts();
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(friendlyError(error))));
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.surfaceOffWhite,
      appBar: AppBar(
        backgroundColor: AppColors.surfaceWhite,
        elevation: 1,
        shadowColor: Colors.black.withValues(alpha: 0.05),
        title: const Text(
          'My Shifts',
          style: TextStyle(
            color: AppColors.textPrimary,
            fontWeight: FontWeight.bold,
          ),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh, color: AppColors.textPrimary),
            onPressed: _loadShifts,
          ),
        ],
        bottom: TabBar(
          controller: _tabController,
          labelColor: AppColors.primary,
          unselectedLabelColor: AppColors.textSecondary,
          indicatorColor: AppColors.primary,
          indicatorWeight: 3,
          tabs: const [
            Tab(text: 'Upcoming'),
            Tab(text: 'Active'),
            Tab(text: 'Past'),
          ],
        ),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _errorMessage != null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(_errorMessage!),
                    const SizedBox(height: 16),
                    ElevatedButton(
                      onPressed: _loadShifts,
                      child: const Text('Retry'),
                    ),
                  ],
                ),
              ),
            )
          : TabBarView(
              controller: _tabController,
              children: [
                _buildShiftsList(_filterShifts('Upcoming')),
                _buildShiftsList(_filterShifts('Active')),
                _buildShiftsList(_filterShifts('Past')),
              ],
            ),
    );
  }

  Widget _buildShiftsList(List<dynamic> items) {
    if (items.isEmpty) {
      return const Center(
        child: Text(
          'No shifts found in this tab.',
          style: TextStyle(color: AppColors.textSecondary, fontSize: 16),
        ),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: items.length,
      itemBuilder: (context, index) {
        final shift = items[index];
        return _buildShiftCard(shift);
      },
    );
  }

  static const List<String> _stepStatuses = [
    'PENDING',
    'ACCEPTED',
    'ACTIVE',
    'COMPLETED',
  ];
  static const List<String> _stepLabels = [
    'Requested',
    'Accepted',
    'Working',
    'Cash recorded',
  ];

  Widget _buildProgress(String status) {
    final current = _stepStatuses.indexOf(status);
    if (current < 0) return const SizedBox.shrink();
    return Row(
      children: [
        for (var i = 0; i < _stepLabels.length; i++)
          Expanded(
            child: Column(
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Container(
                        height: 3,
                        color: i == 0
                            ? Colors.transparent
                            : (i <= current
                                  ? AppColors.primary
                                  : AppColors.borderLight),
                      ),
                    ),
                    Container(
                      width: 12,
                      height: 12,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: i <= current
                            ? AppColors.primary
                            : AppColors.borderLight,
                      ),
                    ),
                    Expanded(
                      child: Container(
                        height: 3,
                        color: i == _stepLabels.length - 1
                            ? Colors.transparent
                            : (i < current
                                  ? AppColors.primary
                                  : AppColors.borderLight),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  _stepLabels[i],
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: i == current
                        ? FontWeight.w700
                        : FontWeight.w400,
                    color: i <= current
                        ? AppColors.textPrimary
                        : AppColors.textSecondary,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _buildShiftCard(Map<String, dynamic> shift) {
    final String status = shift['status'] ?? 'PENDING';
    final String wage =
        '₹${shift['adjusted_wage'] ?? shift['agreed_daily_wage']}';
    Color statusColor = AppColors.primary;
    if (status == 'ACTIVE') statusColor = AppColors.statusGreen;
    if (status == 'COMPLETED') statusColor = AppColors.textSecondary;

    return Card(
      margin: const EdgeInsets.only(bottom: 16),
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(
                  child: Text(
                    'Shift #${shift['shift_id'].toString().substring(0, 8)}',
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                    ),
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: statusColor.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    status,
                    style: TextStyle(
                      color: statusColor,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                const Icon(
                  Icons.currency_rupee,
                  size: 16,
                  color: AppColors.textSecondary,
                ),
                const SizedBox(width: 8),
                Text(
                  'Agreed Daily Wage: $wage',
                  style: const TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 13,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                const Icon(
                  Icons.calendar_today,
                  size: 16,
                  color: AppColors.textSecondary,
                ),
                const SizedBox(width: 8),
                Text(
                  'Created: ${shift['created_at']?.toString().substring(0, 10) ?? 'Today'}',
                  style: const TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 13,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            _buildProgress(status),
            const SizedBox(height: 16),
            if (status == 'ACTIVE')
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: () => _handleReconcileCash(shift),
                  icon: const Icon(Icons.check_circle, size: 18),
                  label: const Text('Confirm cash handover'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.statusGreen,
                  ),
                ),
              )
            else
              SizedBox(
                width: double.infinity,
                child: OutlinedButton(
                  onPressed: () => showDialog<void>(
                    context: context,
                    builder: (context) => AlertDialog(
                      title: const Text('Shift details'),
                      content: Text(
                        'Status: $status\nAgreed daily wage: $wage\nConfirm the work time and location directly with your worker.',
                      ),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(context),
                          child: const Text('Close'),
                        ),
                      ],
                    ),
                  ),
                  style: OutlinedButton.styleFrom(
                    side: const BorderSide(color: AppColors.borderLight),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                  child: Text(
                    'Shift details',
                    style: const TextStyle(color: AppColors.primary),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

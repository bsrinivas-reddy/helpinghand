import 'package:flutter/material.dart';
import '../services/api_service.dart';
import '../theme/app_colors.dart';
import 'shift_detail_screen.dart';

class ShiftsScreen extends StatefulWidget {
  const ShiftsScreen({super.key});

  @override
  State<ShiftsScreen> createState() => _ShiftsScreenState();
}

class _ShiftsScreenState extends State<ShiftsScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  final _apiService = ApiService();

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
    setState(() => _isLoading = true);
    try {
      final session = await _apiService.getSession();
      if (!mounted) return;
      final workerId = session['workerId'];

      if (workerId == null) {
        setState(() {
          _errorMessage = 'No active worker session found';
          _isLoading = false;
        });
        return;
      }

      final res = await _apiService.getWorkerShifts(workerId);
      if (!mounted) return;
      if (res['success'] == true) {
        setState(() {
          _shifts = res['shifts'] ?? [];
          _errorMessage = null;
        });
      } else {
        setState(() => _errorMessage = res['error'] ?? 'Failed to load shifts');
      }
    } catch (e) {
      if (mounted) {
        setState(
          () => _errorMessage = 'Failed to load shifts: ${e.toString()}',
        );
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  List<dynamic> _filterShifts(List<String> statuses) {
    return _shifts.where((s) => statuses.contains(s['status'])).toList();
  }

  Widget _buildShiftsList(List<dynamic> shifts) {
    if (shifts.isEmpty) {
      return const Center(
        child: Text(
          'No shifts in this category.',
          style: TextStyle(color: AppColors.textLightSecondary),
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: shifts.length,
      itemBuilder: (context, index) {
        final shift = shifts[index];
        final status = shift['status'] as String;
        final wage = shift['adjusted_wage'] ?? shift['agreed_daily_wage'];

        Color badgeColor;
        switch (status) {
          case 'PENDING':
            badgeColor = AppColors.statusAmber;
            break;
          case 'ACCEPTED':
            badgeColor = Colors.blue;
            break;
          case 'ACTIVE':
            badgeColor = AppColors.accentPurple;
            break;
          case 'COMPLETED':
            badgeColor = AppColors.statusGreen;
            break;
          default:
            badgeColor = AppColors.textLightSecondary;
        }

        return Card(
          margin: const EdgeInsets.only(bottom: 12),
          color: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: BorderSide(color: Colors.grey.shade100),
          ),
          child: ListTile(
            contentPadding: const EdgeInsets.all(16),
            title: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'Shift #${shift['shift_id'].toString().substring(0, 8)}',
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 13,
                    color: AppColors.textLightSecondary,
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: badgeColor.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    status,
                    style: TextStyle(
                      color: badgeColor,
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(height: 8),
                Text(
                  'Agreed Wage: ₹$wage',
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: AppColors.textLightPrimary,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'Created At: ${DateTime.parse(shift['created_at']).toLocal().toString().substring(0, 16)}',
                  style: const TextStyle(
                    fontSize: 12,
                    color: AppColors.textLightSecondary,
                  ),
                ),
              ],
            ),
            trailing: const Icon(
              Icons.arrow_forward_ios,
              size: 16,
              color: Colors.black26,
            ),
            onTap: () async {
              final result = await Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) =>
                      ShiftDetailScreen(shiftId: shift['shift_id']),
                ),
              );
              if (result == true) {
                _loadShifts(); // Refresh list on change
              }
            },
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.surfaceOff,
      appBar: AppBar(
        backgroundColor: AppColors.primaryDark,
        elevation: 0,
        title: const Text(
          'My Shifts',
          style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh, color: Colors.white),
            onPressed: _loadShifts,
          ),
        ],
        bottom: TabBar(
          controller: _tabController,
          labelColor: Colors.white,
          unselectedLabelColor: Colors.white60,
          indicatorColor: AppColors.accentPurple,
          indicatorWeight: 3,
          tabs: const [
            Tab(text: 'Assigned'),
            Tab(text: 'Active'),
            Tab(text: 'Closed'),
          ],
        ),
      ),
      body: _isLoading
          ? const Center(
              child: CircularProgressIndicator(color: AppColors.accentPurple),
            )
          : _errorMessage != null
          ? Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    _errorMessage!,
                    style: const TextStyle(color: Colors.red),
                  ),
                  const SizedBox(height: 12),
                  ElevatedButton(
                    onPressed: _loadShifts,
                    child: const Text('Retry'),
                  ),
                ],
              ),
            )
          : TabBarView(
              controller: _tabController,
              children: [
                _buildShiftsList(_filterShifts(['PENDING', 'ACCEPTED'])),
                _buildShiftsList(_filterShifts(['ACTIVE'])),
                _buildShiftsList(_filterShifts(['COMPLETED', 'CANCELLED'])),
              ],
            ),
    );
  }
}

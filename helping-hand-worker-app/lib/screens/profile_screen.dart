import '../utils/phone_format.dart';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import '../services/api_service.dart';
import '../theme/app_colors.dart';
import 'login_screen.dart';

class ProfileScreen extends StatefulWidget {
  final String? workerId;
  const ProfileScreen({super.key, this.workerId});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  final _apiService = ApiService();

  Map<String, dynamic>? _profileData;
  bool _isLoading = true;
  bool _isToggling = false;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _loadProfile();
  }

  Future<void> _loadProfile() async {
    String? id = widget.workerId;
    if (id == null) {
      final session = await _apiService.getSession();
      if (!mounted) return;
      id = session['workerId'];
    }

    if (id == null) {
      setState(() {
        _errorMessage = 'No active worker session';
        _isLoading = false;
      });
      return;
    }

    try {
      final res = await _apiService.getWorkerProfile(id);
      if (!mounted) return;
      if (res['success'] == true) {
        setState(() {
          _profileData = res['workerProfile'];
          _errorMessage = null;
        });
      } else {
        setState(
          () => _errorMessage = res['error'] ?? 'Failed to load profile',
        );
      }
    } catch (e) {
      if (!mounted) return;
      setState(
        () => _errorMessage = 'Failed to fetch profile: ${e.toString()}',
      );
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _toggleAvailability() async {
    if (_profileData == null || _isToggling) return;

    setState(() => _isToggling = true);

    final currentAvailability = _profileData!['isAvailable'] == true;
    final targetAvailability = !currentAvailability;
    final workerId = _profileData!['workerId'];

    double? lat;
    double? lng;

    if (targetAvailability) {
      try {
        if (!await Geolocator.isLocationServiceEnabled()) {
          throw StateError('Turn on location services before going available.');
        }
        var permission = await Geolocator.checkPermission();
        if (permission == LocationPermission.denied) {
          permission = await Geolocator.requestPermission();
        }
        if (permission != LocationPermission.always &&
            permission != LocationPermission.whileInUse) {
          throw StateError(
            'Allow location access to appear in nearby worker searches.',
          );
        }
        final position = await Geolocator.getCurrentPosition(
          locationSettings: const LocationSettings(
            accuracy: LocationAccuracy.high,
            timeLimit: Duration(seconds: 15),
          ),
        );
        lat = position.latitude;
        lng = position.longitude;
      } catch (error) {
        if (mounted) {
          if (mounted) setState(() => _isToggling = false);
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(error.toString().replaceFirst('Bad state: ', '')),
            ),
          );
        }
        return;
      }
    }

    try {
      final res = await _apiService.toggleAvailability(
        workerId: workerId,
        isAvailable: targetAvailability,
        lat: lat,
        lng: lng,
      );

      if (!mounted) return;
      if (res['success'] == true) {
        setState(() {
          _profileData!['isAvailable'] = res['isAvailable'];
        });
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                targetAvailability
                    ? 'You are now AVAILABLE for jobs'
                    : 'You are now OFFLINE',
              ),
              backgroundColor: targetAvailability
                  ? AppColors.statusGreen
                  : AppColors.statusRed,
            ),
          );
        }
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(res['error'] ?? 'Failed to update status'),
              backgroundColor: AppColors.statusRed,
            ),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Connection error: ${e.toString()}'),
            backgroundColor: AppColors.statusRed,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isToggling = false);
    }
  }

  Future<void> _logout() async {
    await _apiService.clearSession();
    if (mounted) {
      Navigator.pushAndRemoveUntil(
        context,
        MaterialPageRoute(builder: (context) => const LoginScreen()),
        (route) => false,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (_isLoading) {
      return const Scaffold(
        backgroundColor: Colors.white,
        body: Center(
          child: CircularProgressIndicator(color: AppColors.accentPurple),
        ),
      );
    }

    if (_errorMessage != null) {
      return Scaffold(
        backgroundColor: Colors.white,
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24.0),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  _errorMessage!,
                  style: const TextStyle(color: Colors.red, fontSize: 16),
                ),
                const SizedBox(height: 20),
                ElevatedButton(
                  onPressed: _loadProfile,
                  child: const Text('Retry'),
                ),
              ],
            ),
          ),
        ),
      );
    }

    final data = _profileData!;
    final isAvailable = data['isAvailable'] == true;
    final ratingList = data['reviewsList'] as List? ?? [];
    final shiftsHistory = data['completedShiftsHistory'] as List? ?? [];

    return Scaffold(
      backgroundColor: Colors.white,
      body: Column(
        children: [
          // 1. Fixed Top Header Banner (Doesn't scroll)
          Container(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                colors: [AppColors.primaryDark, AppColors.primaryMid],
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
              ),
              borderRadius: BorderRadius.vertical(bottom: Radius.circular(32)),
            ),
            padding: const EdgeInsets.only(top: 50, bottom: 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Title Bar with centered screen title & Logout Button
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16.0),
                  child: Row(
                    children: [
                      if (Navigator.canPop(context))
                        const BackButton(color: Colors.white)
                      else
                        const Padding(
                          padding: EdgeInsets.all(12.0),
                          child: Icon(
                            Icons.person_outline,
                            color: Colors.white70,
                          ),
                        ),
                      const Expanded(
                        child: Text(
                          'My Profile',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 20,
                            fontWeight: FontWeight.bold,
                          ),
                          textAlign: TextAlign.center,
                        ),
                      ),
                      IconButton(
                        icon: const Icon(
                          Icons.logout_rounded,
                          color: Colors.white70,
                        ),
                        onPressed: _logout,
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),

                // User Avatar with dynamic online/offline dot indicator
                Center(
                  child: Stack(
                    alignment: Alignment.bottomRight,
                    children: [
                      CircleAvatar(
                        radius: 46,
                        backgroundColor: Colors.white.withValues(alpha: 0.2),
                        child: CircleAvatar(
                          radius: 42,
                          backgroundColor: Colors.grey[100],
                          child: const Icon(
                            Icons.person,
                            size: 48,
                            color: AppColors.primaryDark,
                          ),
                        ),
                      ),
                      Container(
                        padding: const EdgeInsets.all(3),
                        decoration: const BoxDecoration(
                          color: Colors.white,
                          shape: BoxShape.circle,
                        ),
                        child: Container(
                          width: 14,
                          height: 14,
                          decoration: BoxDecoration(
                            color: isAvailable
                                ? AppColors.statusGreen
                                : Colors.orange,
                            shape: BoxShape.circle,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),

                // Real name from profile/session or category fallback
                Text(
                  data['fullName']?.toString().isNotEmpty == true
                      ? data['fullName'].toString()
                      : (data['workerCategory'] != null
                            ? '${data['workerCategory']} Professional'
                            : 'Worker'),
                  style: theme.textTheme.headlineMedium?.copyWith(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  formatIndianPhone('${data['phoneNumber'] ?? ''}'),
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.5),
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 16),

                // Availability
                GestureDetector(
                  onTap: _toggleAvailability,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 8,
                    ),
                    decoration: BoxDecoration(
                      color: isAvailable
                          ? AppColors.statusGreen.withValues(alpha: 0.15)
                          : Colors.orange.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(
                        color: isAvailable
                            ? AppColors.statusGreen.withValues(alpha: 0.35)
                            : Colors.orange.withValues(alpha: 0.35),
                        width: 1.2,
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 8,
                          height: 8,
                          decoration: BoxDecoration(
                            color: isAvailable
                                ? AppColors.statusGreen
                                : Colors.orange,
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          isAvailable ? 'AVAILABLE FOR SHIFTS' : 'OFFLINE',
                          style: TextStyle(
                            color: isAvailable
                                ? Colors.white
                                : Colors.orangeAccent[100],
                            fontSize: 10,
                            fontWeight: FontWeight.bold,
                            letterSpacing: 0.8,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 20),

                // Translucent glassmorphic Stats Card
                Container(
                  margin: const EdgeInsets.symmetric(horizontal: 24),
                  padding: const EdgeInsets.symmetric(
                    vertical: 14,
                    horizontal: 8,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.06),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                      color: Colors.white.withValues(alpha: 0.1),
                      width: 1,
                    ),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      _buildStatCol(
                        data['totalCompletedShifts']?.toString() ?? '0',
                        'Completed',
                      ),
                      _buildStatDivider(),
                      _buildStatCol(
                        data['totalRatingsCount']?.toString() ?? '0',
                        'Ratings',
                      ),
                      _buildStatDivider(),
                      _buildStatCol(
                        (data['totalRatingsCount'] as num? ?? 0) > 0 &&
                                data['trustScore'] != null
                            ? '${data['trustScore']}'
                            : 'Not rated',
                        'Rating score',
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),

          // 2. Scrollable Body Content (Skills, Experience, Reviews)
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Skills Section
                  Text(
                    'Skills',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      _buildSkillChip(data['workerCategory'] ?? 'General'),
                      if (data['workerSubCategory'] != null &&
                          data['workerSubCategory'].toString().isNotEmpty)
                        _buildSkillChip(data['workerSubCategory']!),
                    ],
                  ),
                  const SizedBox(height: 28),

                  // Experience / History Section
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        'Experience',
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      Text(
                        '${shiftsHistory.length} Shifts',
                        style: const TextStyle(
                          color: AppColors.textLightSecondary,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  if (shiftsHistory.isEmpty)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 8.0),
                      child: Text(
                        'No completed shifts found yet.',
                        style: TextStyle(color: Colors.black45),
                      ),
                    )
                  else
                    ...shiftsHistory
                        .take(3)
                        .map((s) => _buildExperienceItem(s)),
                  const SizedBox(height: 28),

                  // Reviews List Section
                  Text(
                    'Recent Reviews',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 12),
                  if (ratingList.isEmpty)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 8.0),
                      child: Text(
                        'No reviews submitted yet.',
                        style: TextStyle(color: Colors.black45),
                      ),
                    )
                  else
                    ...ratingList.take(2).map((r) => _buildReviewItem(r)),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStatCol(String value, String label) {
    return Column(
      children: [
        Text(
          value,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 18,
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          label,
          style: const TextStyle(
            color: AppColors.textDarkSecondary,
            fontSize: 11,
          ),
        ),
      ],
    );
  }

  Widget _buildStatDivider() {
    return Container(width: 1, height: 24, color: Colors.white24);
  }

  Widget _buildSkillChip(String label) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.surfaceOff,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        label,
        style: const TextStyle(
          color: AppColors.textLightPrimary,
          fontWeight: FontWeight.bold,
          fontSize: 13,
        ),
      ),
    );
  }

  Widget _buildExperienceItem(dynamic shift) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surfaceOff,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: const BoxDecoration(
              color: Colors.white,
              shape: BoxShape.circle,
            ),
            child: const Icon(
              Icons.business_center,
              color: AppColors.accentPurple,
              size: 20,
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  shift['employerName'] ?? 'Employer',
                  style: const TextStyle(
                    color: AppColors.textLightPrimary,
                    fontWeight: FontWeight.bold,
                    fontSize: 14,
                  ),
                ),
                Text(
                  '${shift['workedHours'] == null ? 'Hours not recorded' : 'Worked ${shift['workedHours']}h'}  •  Wage Paid: ₹${shift['wage']}',
                  style: const TextStyle(
                    color: AppColors.textLightSecondary,
                    fontSize: 11,
                  ),
                ),
              ],
            ),
          ),
          const Icon(
            Icons.check_circle,
            color: AppColors.statusGreen,
            size: 20,
          ),
        ],
      ),
    );
  }

  Widget _buildReviewItem(dynamic review) {
    final rating = (review['stars'] as num?)?.toInt() ?? 5;
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.grey[50],
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.grey.shade200),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              CircleAvatar(
                radius: 14,
                backgroundColor: AppColors.accentPurple.withValues(alpha: 0.1),
                child: Text(
                  (review['reviewerName'] ?? 'A')[0].toUpperCase(),
                  style: const TextStyle(
                    color: AppColors.accentPurple,
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  review['reviewerName'] ?? 'Anonymous',
                  style: const TextStyle(
                    color: AppColors.textLightPrimary,
                    fontWeight: FontWeight.bold,
                    fontSize: 13,
                  ),
                ),
              ),
              Row(
                children: List.generate(5, (index) {
                  return Icon(
                    Icons.star,
                    size: 12,
                    color: index < rating ? Colors.amber : Colors.grey.shade300,
                  );
                }),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            review['comment'] ?? 'No comment provided.',
            style: const TextStyle(
              color: AppColors.textLightSecondary,
              fontSize: 12,
              height: 1.4,
            ),
          ),
        ],
      ),
    );
  }
}

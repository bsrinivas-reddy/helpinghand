import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import '../services/api_service.dart';
import '../theme/app_colors.dart';

class ShiftDetailScreen extends StatefulWidget {
  final String shiftId;
  const ShiftDetailScreen({super.key, required this.shiftId});

  @override
  State<ShiftDetailScreen> createState() => _ShiftDetailScreenState();
}

class _ShiftDetailScreenState extends State<ShiftDetailScreen> {
  final _apiService = ApiService();

  Map<String, dynamic>? _shift;
  bool _isLoading = true;
  bool _isActionLoading = false;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _loadShiftDetails();
  }

  Future<void> _loadShiftDetails() async {
    setState(() => _isLoading = true);
    try {
      final res = await _apiService.getShiftById(widget.shiftId);
      if (!mounted) return;
      if (res['success'] == true) {
        setState(() {
          _shift = res['shift'];
          _errorMessage = null;
        });
      } else {
        setState(
          () => _errorMessage = res['error'] ?? 'Failed to load details',
        );
      }
    } catch (e) {
      if (mounted) {
        setState(
          () => _errorMessage = 'Failed to load details: ${e.toString()}',
        );
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _accept() async {
    setState(() => _isActionLoading = true);
    try {
      final res = await _apiService.acceptShift(widget.shiftId);
      if (!mounted) return;
      if (res['success'] == true) {
        setState(() => _shift = res['shift']);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Shift accepted!'),
            backgroundColor: AppColors.statusGreen,
          ),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(res['error'] ?? 'Accept failed'),
            backgroundColor: AppColors.statusRed,
          ),
        );
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(e.toString()),
          backgroundColor: AppColors.statusRed,
        ),
      );
    } finally {
      if (mounted) {
        setState(() => _isActionLoading = false);
      }
    }
  }

  Future<void> _start() async {
    setState(() => _isActionLoading = true);
    try {
      final res = await _apiService.startShift(widget.shiftId);
      if (!mounted) return;
      if (res['success'] == true) {
        setState(() => _shift = res['shift']);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Shift started!'),
            backgroundColor: AppColors.statusGreen,
          ),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(res['error'] ?? 'Start failed'),
            backgroundColor: AppColors.statusRed,
          ),
        );
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(e.toString()),
          backgroundColor: AppColors.statusRed,
        ),
      );
    } finally {
      if (mounted) {
        setState(() => _isActionLoading = false);
      }
    }
  }

  Future<void> _reconcileCash() async {
    final acknowledged = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Have you received the cash?'),
        content: Text(
          'Confirm you received ₹${_shift!['adjusted_wage'] ?? _shift!['agreed_daily_wage']} in cash. Only continue after this cash is in your hands. Your code lets the employer confirm the handover. Location access is needed on both devices; it is not proof of payment by itself.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Not yet'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('I have received the cash'),
          ),
        ],
      ),
    );
    if (acknowledged != true || !mounted) return;
    setState(() => _isActionLoading = true);
    try {
      if (!await Geolocator.isLocationServiceEnabled()) {
        throw StateError('Turn on location services to create a payment code.');
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
      final res = await _apiService.generateCashHandshakeCode(
        shiftId: widget.shiftId,
        lat: position.latitude,
        lng: position.longitude,
        cashAmount: double.parse(
          '${_shift!['adjusted_wage'] ?? _shift!['agreed_daily_wage']}',
        ),
      );
      if (!mounted) return;
      if (res['success'] != true) {
        throw StateError(res['error'] ?? 'Could not create a payment code.');
      }
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Your cash handover code'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '${res['handshakeCode']}',
                style: const TextStyle(
                  fontSize: 36,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 8,
                ),
              ),
              const SizedBox(height: 18),
              const Text(
                'Show this to your employer after receiving the cash. Valid for 10 minutes. The shift is not closed until your employer confirms.',
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Done'),
            ),
          ],
        ),
      );
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(error.toString().replaceFirst('Bad state: ', '')),
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isActionLoading = false);
        _loadShiftDetails();
      }
    }
  }

  void _showRatingDialog() {
    double stars = 5;
    final commentController = TextEditingController();

    showDialog(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
              title: const Text(
                'Rate Employer',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('Please rate the payment speed & project safety:'),
                  const SizedBox(height: 16),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: List.generate(5, (index) {
                      return IconButton(
                        icon: Icon(
                          Icons.star,
                          size: 32,
                          color: index < stars
                              ? Colors.amber
                              : Colors.grey.shade300,
                        ),
                        onPressed: () {
                          setDialogState(() => stars = (index + 1).toDouble());
                        },
                      );
                    }),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: commentController,
                    decoration: const InputDecoration(
                      hintText: 'Add review comments (optional)',
                      border: OutlineInputBorder(),
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
                  onPressed: () async {
                    final session = await _apiService.getSession();
                    final workerId = session['workerId'];
                    if (workerId == null) return;

                    try {
                      final res = await _apiService.submitWorkerRating(
                        shiftId: widget.shiftId,
                        reviewerId: workerId,
                        revieweeId: _shift!['employer_id'],
                        ratingStars: stars,
                        reviewComment: commentController.text.trim().isEmpty
                            ? null
                            : commentController.text.trim(),
                      );
                      if (res['success'] == true) {
                        if (context.mounted) {
                          Navigator.pop(context);
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text('Rating submitted!'),
                              backgroundColor: AppColors.statusGreen,
                            ),
                          );
                        }
                      }
                    } catch (e) {
                      debugPrint('Rating submit error: ${e.toString()}');
                    }
                  },
                  child: const Text('Submit'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
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
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(_errorMessage!, style: const TextStyle(color: Colors.red)),
              const SizedBox(height: 16),
              ElevatedButton(
                onPressed: _loadShiftDetails,
                child: const Text('Retry'),
              ),
            ],
          ),
        ),
      );
    }

    final shift = _shift!;
    final status = shift['status'] as String;
    final verificationStatus =
        shift['verification_call_status'] as String? ?? 'NONE';

    return Scaffold(
      backgroundColor: AppColors.surfaceOff,
      appBar: AppBar(
        backgroundColor: AppColors.primaryDark,
        elevation: 0,
        title: const Text(
          'Shift Ledger Detail',
          style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white),
        ),
        leading: BackButton(
          color: Colors.white,
          onPressed: () => Navigator.pop(context, true),
        ),
      ),
      body: Column(
        children: [
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Status card
                  Card(
                    elevation: 0,
                    color: Colors.white,
                    child: Padding(
                      padding: const EdgeInsets.all(20.0),
                      child: Column(
                        children: [
                          const Text(
                            'LEDGER STATUS',
                            style: TextStyle(
                              color: AppColors.textLightSecondary,
                              fontSize: 11,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            status,
                            style: TextStyle(
                              color: AppColors.accentPurple,
                              fontSize: 24,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(height: 12),
                          const Divider(),
                          const SizedBox(height: 12),
                          _buildDetailRow(
                            'Agreed Daily Wage',
                            '₹${shift['agreed_daily_wage']}',
                          ),
                          if (shift['adjusted_wage'] != null) ...[
                            const SizedBox(height: 8),
                            _buildDetailRow(
                              'Adjusted Wage',
                              '₹${shift['adjusted_wage']}',
                              isHighlight: true,
                            ),
                            const SizedBox(height: 8),
                            _buildDetailRow(
                              'Adjustment Reason',
                              shift['adjustment_reason'] ?? 'Not specified',
                              isSubtext: true,
                            ),
                          ],
                          const SizedBox(height: 8),
                          _buildDetailRow(
                            'Worked Hours',
                            '${shift['worked_hours'] ?? 8} hours',
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 20),

                  // Employer & Project card
                  Card(
                    elevation: 0,
                    color: Colors.white,
                    child: Padding(
                      padding: const EdgeInsets.all(20.0),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'PROJECT PARTNERS',
                            style: TextStyle(
                              color: AppColors.textLightSecondary,
                              fontSize: 11,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(height: 16),
                          Row(
                            children: [
                              CircleAvatar(
                                backgroundColor: AppColors.surfaceOff,
                                child: const Icon(
                                  Icons.person,
                                  color: AppColors.accentPurple,
                                ),
                              ),
                              const SizedBox(width: 16),
                              Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    shift['employer_name'] ?? 'Employer Name',
                                    style: const TextStyle(
                                      fontWeight: FontWeight.bold,
                                      fontSize: 15,
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    shift['employer_phone'] ?? '',
                                    style: const TextStyle(
                                      color: AppColors.textLightSecondary,
                                      fontSize: 12,
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                          const SizedBox(height: 16),
                          const Divider(),
                          const SizedBox(height: 12),
                          _buildDetailRow(
                            'Payment follow-up status',
                            verificationStatus == 'UNKNOWN'
                                ? 'Needs manual review. No automatic redial.'
                                : verificationStatus == 'FAILED'
                                ? 'Follow-up failed. Contact support.'
                                : verificationStatus,
                          ),
                          if (verificationStatus == 'VERIFIED') ...[
                            const SizedBox(height: 8),
                            const Row(
                              children: [
                                Icon(
                                  Icons.verified,
                                  color: AppColors.statusGreen,
                                  size: 16,
                                ),
                                SizedBox(width: 8),
                                Text(
                                  'Both parties confirmed the payment',
                                  style: TextStyle(
                                    color: AppColors.statusGreen,
                                    fontSize: 12,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),

          // Action Panel at bottom
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
            decoration: const BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
              boxShadow: [
                BoxShadow(
                  color: Colors.black,
                  blurRadius: 10,
                  offset: Offset(0, -2),
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (_isActionLoading)
                  const Center(
                    child: CircularProgressIndicator(
                      color: AppColors.accentPurple,
                    ),
                  )
                else ...[
                  if (status == 'PENDING')
                    ElevatedButton(
                      onPressed: _accept,
                      child: const Text('Accept shift request'),
                    )
                  else if (status == 'ACCEPTED')
                    ElevatedButton(
                      onPressed: _start,
                      child: const Text('Start shift'),
                    )
                  else if (status == 'ACTIVE')
                    ElevatedButton(
                      onPressed: _reconcileCash,
                      child: const Text('I received cash · Get code'),
                    )
                  else if (status == 'COMPLETED')
                    ElevatedButton(
                      onPressed: _showRatingDialog,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.primaryMid,
                      ),
                      child: const Text('RATE EMPLOYER'),
                    )
                  else
                    ElevatedButton(
                      onPressed: null,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.grey,
                      ),
                      child: const Text('SHIFT CLOSED'),
                    ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDetailRow(
    String label,
    String value, {
    bool isHighlight = false,
    bool isSubtext = false,
  }) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            color: isSubtext
                ? AppColors.textLightSecondary.withValues(alpha: 0.8)
                : AppColors.textLightSecondary,
            fontSize: isSubtext ? 11 : 13,
            fontStyle: isSubtext ? FontStyle.italic : FontStyle.normal,
          ),
        ),
        Text(
          value,
          style: TextStyle(
            color: isHighlight
                ? AppColors.accentPurple
                : AppColors.textLightPrimary,
            fontWeight: isHighlight || !isSubtext
                ? FontWeight.bold
                : FontWeight.normal,
            fontSize: isHighlight ? 15 : 13,
          ),
        ),
      ],
    );
  }
}

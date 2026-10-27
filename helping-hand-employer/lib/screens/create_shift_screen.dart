import 'package:flutter/material.dart';
import '../utils/friendly_error.dart';
import 'package:flutter/services.dart';
import '../services/api_service.dart';
import '../theme/app_colors.dart';

String? _categoryLabel(String? raw) {
  switch (raw) {
    case 'MASON':
      return 'Mason';
    case 'LABOURER':
      return 'Labourer';
    case 'CARPENTER':
      return 'Carpenter';
    case 'PAINTER':
      return 'Painter';
    default:
      return null;
  }
}

class CreateShiftScreen extends StatefulWidget {
  final String? targetWorkerId;
  final String? workerCategory;
  const CreateShiftScreen({
    super.key,
    this.targetWorkerId,
    this.workerCategory,
  });

  @override
  State<CreateShiftScreen> createState() => _CreateShiftScreenState();
}

class _CreateShiftScreenState extends State<CreateShiftScreen> {
  final ApiService _apiService = ApiService();
  final TextEditingController _wageController = TextEditingController();

  bool _isSubmitting = false;

  @override
  void dispose() {
    _wageController.dispose();
    super.dispose();
  }

  Future<void> _submitShift() async {
    final wageText = _wageController.text.trim();
    final wage = double.tryParse(wageText);

    if (wage == null || wage <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter a valid daily wage rate')),
      );
      return;
    }

    setState(() {
      _isSubmitting = true;
    });

    try {
      final session = await _apiService.getSession();
      final employerId = session['employerId'];
      final workerId = widget.targetWorkerId;
      if (employerId == null || workerId == null) {
        throw StateError(
          'Sign in and select a worker before requesting a shift.',
        );
      }

      final response = await _apiService.createShift(
        employerId: employerId,
        workerId: workerId,
        agreedDailyWage: wage,
      );

      if (!mounted) return;

      if (response['success'] == true) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Shift request sent.')));
        Navigator.pop(context, true);
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(response['error'] ?? 'Could not send shift request'),
          ),
        );
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(friendlyError(e))));
    } finally {
      if (mounted) {
        setState(() {
          _isSubmitting = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final hasWorker = widget.targetWorkerId != null;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Request a shift'),
        backgroundColor: AppColors.surfaceOffWhite,
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            const Text(
              'Agree the work.\nSet the daily wage.',
              style: TextStyle(
                fontSize: 30,
                height: 1.15,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 16),
            const Text(
              'This request is for one selected worker. Confirm the work, time and location directly before they accept.',
              style: TextStyle(
                fontSize: 16,
                height: 1.5,
                color: AppColors.textSecondary,
              ),
            ),
            const SizedBox(height: 28),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Row(
                  children: [
                    const Icon(Icons.person_outline, color: AppColors.primary),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            hasWorker
                                ? (_categoryLabel(widget.workerCategory) == null
                                      ? 'Worker selected'
                                      : '${_categoryLabel(widget.workerCategory)} selected')
                                : 'Select a worker first',
                            style: const TextStyle(
                              fontWeight: FontWeight.w700,
                              fontSize: 16,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            hasWorker
                                ? 'Request will be sent to this worker.'
                                : 'Open the worker map and choose a profile.',
                            style: const TextStyle(
                              height: 1.4,
                              color: AppColors.textSecondary,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 28),
            TextField(
              controller: _wageController,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              inputFormatters: [
                TextInputFormatter.withFunction(
                  (oldValue, newValue) =>
                      RegExp(r'^\d{0,6}(\.\d{0,2})?$').hasMatch(newValue.text)
                      ? newValue
                      : oldValue,
                ),
              ],
              decoration: const InputDecoration(
                labelText: 'Agreed daily wage',
                prefixText: '₹ ',
                hintText: 'Enter amount',
                helperText:
                    'For one worker, per day. Confirm this with the worker.',
              ),
            ),
            const SizedBox(height: 28),
            const Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  Icons.info_outline,
                  size: 20,
                  color: AppColors.textSecondary,
                ),
                SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'Sending a request does not confirm a booking or take a payment. The worker must accept the shift.',
                    style: TextStyle(
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
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: ElevatedButton(
            onPressed: _isSubmitting || !hasWorker ? null : _submitShift,
            child: _isSubmitting
                ? const SizedBox(
                    height: 22,
                    width: 22,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('Send shift request'),
          ),
        ),
      ),
    );
  }
}

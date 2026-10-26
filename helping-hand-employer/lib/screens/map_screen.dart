import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:geolocator/geolocator.dart';
import '../services/api_service.dart';
import '../theme/app_colors.dart';
import 'create_shift_screen.dart';

class MapScreen extends StatefulWidget {
  const MapScreen({super.key});

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {
  final ApiService _apiService = ApiService();
  LatLng _userPosition = const LatLng(28.6139, 77.2090);

  List<dynamic> _nearbyWorkers = [];
  bool _isLoading = false;
  String _selectedCategory = 'ALL';

  String? _locationError;
  bool _hasLocation = false;

  Future<void> _initLiveLocationAndFetch() async {
    setState(() {
      _isLoading = true;
      _locationError = null;
    });
    try {
      if (!await Geolocator.isLocationServiceEnabled()) {
        throw StateError('Turn on location services to find nearby workers.');
      }
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission != LocationPermission.whileInUse &&
          permission != LocationPermission.always) {
        throw StateError(
          'Location access was not allowed. No default area has been searched.',
        );
      }
      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 15),
        ),
      );
      _userPosition = LatLng(position.latitude, position.longitude);
      _hasLocation = true;
      await _fetchWorkers();
    } catch (error) {
      if (mounted) {
        setState(
          () =>
              _locationError = error.toString().replaceFirst('Bad state: ', ''),
        );
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _fetchWorkers() async {
    if (!_hasLocation) return;
    setState(() {
      _isLoading = true;
    });

    try {
      final response = await _apiService.findNearbyWorkers(
        lat: _userPosition.latitude,
        lng: _userPosition.longitude,
        radiusKm: 15,
        category: _selectedCategory == 'ALL' ? null : _selectedCategory,
      );

      if (!mounted) return;

      if (response['success'] == true) {
        final List<dynamic> workers = response['workers'] ?? [];
        setState(() {
          _nearbyWorkers = workers;
        });
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error loading map workers: $e')),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _showWorkerDetailsBottomSheet(String workerId) async {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => _WorkerBottomSheetCard(workerId: workerId),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Find workers'),
        backgroundColor: AppColors.surfaceOffWhite,
        actions: [
          PopupMenuButton<String>(
            tooltip: 'Filter skills',
            onSelected: (value) {
              setState(() => _selectedCategory = value);
              _fetchWorkers();
            },
            itemBuilder: (context) => const [
              PopupMenuItem(value: 'ALL', child: Text('All skills')),
              PopupMenuItem(value: 'MASON', child: Text('Masonry')),
              PopupMenuItem(value: 'LABOURER', child: Text('General labour')),
              PopupMenuItem(value: 'CARPENTER', child: Text('Carpentry')),
              PopupMenuItem(value: 'PAINTER', child: Text('Painting')),
            ],
          ),
        ],
      ),
      body: !_hasLocation || _locationError != null
          ? Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const SizedBox(height: 24),
                  const Icon(
                    Icons.location_on_outlined,
                    color: AppColors.primary,
                    size: 40,
                  ),
                  const SizedBox(height: 24),
                  const Text(
                    'Find help near your worksite',
                    style: TextStyle(fontSize: 28, fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 16),
                  const Text(
                    'Use your current location to search available workers within 15 km. Your location is requested only when you choose to search.',
                    style: TextStyle(
                      height: 1.5,
                      color: AppColors.textSecondary,
                    ),
                  ),
                  if (_locationError != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 16),
                      child: Text(
                        _locationError!,
                        style: const TextStyle(color: AppColors.statusRed),
                      ),
                    ),
                  const SizedBox(height: 24),
                  ElevatedButton.icon(
                    onPressed: _isLoading ? null : _initLiveLocationAndFetch,
                    icon: const Icon(Icons.my_location),
                    label: Text(
                      _isLoading
                          ? 'Finding location…'
                          : 'Use my current location',
                    ),
                  ),
                ],
              ),
            )
          : Column(
              children: [
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.location_on_outlined,
                        size: 18,
                        color: AppColors.primary,
                      ),
                      const SizedBox(width: 8),
                      const Expanded(
                        child: Text('Available workers within 15 km'),
                      ),
                      IconButton(
                        tooltip: 'Refresh workers',
                        onPressed: _fetchWorkers,
                        icon: const Icon(Icons.refresh),
                      ),
                    ],
                  ),
                ),
                if (_isLoading) const LinearProgressIndicator(),
                Expanded(child: _buildFallbackListView()),
              ],
            ),
    );
  }

  Widget _buildFallbackListView() {
    if (_nearbyWorkers.isEmpty) {
      return const Center(
        child: Text(
          'No available workers found nearby.',
          style: TextStyle(fontSize: 16, color: AppColors.textSecondary),
        ),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: _nearbyWorkers.length,
      itemBuilder: (context, index) {
        final worker = _nearbyWorkers[index];
        final String workerId = worker['workerId'];
        final category = worker['workerCategory'] as String? ?? 'Worker';
        return Card(
          margin: const EdgeInsets.only(bottom: 12),
          child: ListTile(
            leading: CircleAvatar(
              backgroundColor: AppColors.primaryLight,
              child: Text(
                category.isEmpty ? 'W' : category[0],
                style: const TextStyle(
                  color: AppColors.primary,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            title: Text(category),
            subtitle: Text(
              worker['distanceMeters'] == null
                  ? 'Available nearby'
                  : 'Distance: ${worker['distanceMeters']} m',
            ),
            trailing: ElevatedButton(
              onPressed: () => _showWorkerDetailsBottomSheet(workerId),
              child: const Text('View'),
            ),
          ),
        );
      },
    );
  }
}

class _WorkerBottomSheetCard extends StatefulWidget {
  final String workerId;
  const _WorkerBottomSheetCard({required this.workerId});

  @override
  State<_WorkerBottomSheetCard> createState() => _WorkerBottomSheetCardState();
}

class _WorkerBottomSheetCardState extends State<_WorkerBottomSheetCard> {
  final ApiService _apiService = ApiService();
  Map<String, dynamic>? _workerCardData;
  bool _isLoading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadSummary();
  }

  Future<void> _loadSummary() async {
    try {
      final response = await _apiService.getWorkerMapSummary(widget.workerId);
      if (!mounted) return;
      if (response['success'] != true || response['mapSummaryCard'] == null) {
        throw StateError('Could not load this worker. Close and try again.');
      }
      if (mounted) {
        setState(() {
          _workerCardData = response['mapSummaryCard'];
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _error = 'Could not load this worker. Close and try again.';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      padding: const EdgeInsets.all(24),
      child: _isLoading
          ? const SizedBox(
              height: 200,
              child: Center(child: CircularProgressIndicator()),
            )
          : _error != null
          ? Padding(padding: const EdgeInsets.all(24), child: Text(_error!))
          : Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: AppColors.borderLight,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    CircleAvatar(
                      radius: 28,
                      backgroundColor: AppColors.primaryLight,
                      child: Icon(
                        Icons.person,
                        size: 32,
                        color: AppColors.primary,
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _workerCardData?['workerCategory'] ??
                                'Daily Worker',
                            style: Theme.of(context).textTheme.titleLarge,
                          ),
                          if (_workerCardData?['workerSubCategory'] != null)
                            Text(
                              _workerCardData!['workerSubCategory'],
                              style: Theme.of(context).textTheme.bodyMedium
                                  ?.copyWith(color: AppColors.textSecondary),
                            ),
                          const SizedBox(height: 4),
                          Row(
                            children: [
                              const Icon(
                                Icons.star,
                                color: Colors.amber,
                                size: 18,
                              ),
                              const SizedBox(width: 4),
                              Text(
                                (_workerCardData?['totalRatingsCount']
                                                as num? ??
                                            0) >
                                        0
                                    ? '${_workerCardData?['averageRating'] ?? 'Not rated'}'
                                    : 'Not rated',
                                style: const TextStyle(
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              const SizedBox(width: 12),
                              const Icon(
                                Icons.verified_user,
                                color: AppColors.statusGreen,
                                size: 18,
                              ),
                              const SizedBox(width: 4),
                              Text(
                                _workerCardData?['isVerifiedId'] == true
                                    ? 'ID status recorded'
                                    : 'ID not verified',
                                style: const TextStyle(
                                  color: AppColors.textSecondary,
                                  fontSize: 12,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 20),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceAround,
                  children: [
                    _buildStatCol(
                      'Completed Shifts',
                      '${_workerCardData?['totalCompletedShifts'] ?? 0}',
                    ),
                    _buildStatCol(
                      'Trust Score',
                      (_workerCardData?['totalRatingsCount'] as num? ?? 0) > 0
                          ? '${_workerCardData?['trustScore'] ?? 'Not rated'}'
                          : 'Not rated',
                    ),
                    _buildStatCol(
                      'Total Reviews',
                      '${_workerCardData?['totalRatingsCount'] ?? 0}',
                    ),
                  ],
                ),
                const SizedBox(height: 24),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: () {
                      Navigator.pop(context);
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (context) => CreateShiftScreen(
                            targetWorkerId: widget.workerId,
                          ),
                        ),
                      );
                    },
                    style: ElevatedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                    ),
                    child: const Text('Request a shift'),
                  ),
                ),
              ],
            ),
    );
  }

  Widget _buildStatCol(String label, String value) {
    return Column(
      children: [
        Text(
          value,
          style: const TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.bold,
            color: AppColors.primary,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          label,
          style: const TextStyle(fontSize: 12, color: AppColors.textSecondary),
        ),
      ],
    );
  }
}

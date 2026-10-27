import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import '../services/api_service.dart';
import '../theme/app_colors.dart';
import 'create_shift_screen.dart';

const double _searchRadiusKm = 15;
const double _maxAcceptableAccuracyMeters = 1000;
const Duration _maxFixAge = Duration(minutes: 2);

// Skill filters the backend nearby-workers query already supports.
const List<(String, String)> _skillFilters = [
  ('ALL', 'All'),
  ('MASON', 'Masonry'),
  ('LABOURER', 'General labour'),
  ('CARPENTER', 'Carpentry'),
  ('PAINTER', 'Painting'),
];

IconData _tradeIcon(String? category) {
  switch ((category ?? '').toUpperCase()) {
    case 'MASON':
      return Icons.foundation;
    case 'CARPENTER':
      return Icons.carpenter;
    case 'PAINTER':
      return Icons.format_paint;
    default:
      return Icons.engineering;
  }
}

class MapScreen extends StatefulWidget {
  const MapScreen({super.key});

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {
  final ApiService _apiService = ApiService();
  final MapController _mapController = MapController();
  LatLng _userPosition = const LatLng(0, 0);

  List<dynamic> _nearbyWorkers = [];
  bool _isLoading = false;
  bool _searched = false;
  String _selectedCategory = 'ALL';
  String? _selectedWorkerId;

  String? _locationError;
  bool _canOpenAppSettings = false;
  bool _canOpenLocationSettings = false;
  bool _hasLocation = false;
  bool _tilesFailed = false;
  String? _loadError;
  final Map<String, GlobalKey> _chipKeys = {};
  int _requestSeq = 0;

  Future<void> _initLiveLocationAndFetch() async {
    setState(() {
      _isLoading = true;
      _locationError = null;
      _canOpenAppSettings = false;
      _canOpenLocationSettings = false;
    });
    try {
      if (!await Geolocator.isLocationServiceEnabled()) {
        _canOpenLocationSettings = true;
        throw StateError('Turn on location services to find nearby workers.');
      }
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.deniedForever) {
        _canOpenAppSettings = true;
        throw StateError(
          'Location is blocked for this app. Allow it in settings to search near you.',
        );
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
      final valid =
          position.latitude.isFinite &&
          position.longitude.isFinite &&
          position.latitude.abs() <= 90 &&
          position.longitude.abs() <= 180 &&
          !(position.latitude == 0 && position.longitude == 0);
      if (!valid) {
        throw StateError('Could not read a valid location. Please try again.');
      }
      if (position.accuracy > _maxAcceptableAccuracyMeters) {
        throw StateError(
          'Your location is too imprecise (about ${position.accuracy.round()} m). Move to an open area and try again.',
        );
      }
      if (DateTime.now().difference(position.timestamp).abs() > _maxFixAge) {
        throw StateError('Your location is out of date. Please try again.');
      }
      _userPosition = LatLng(position.latitude, position.longitude);
      _hasLocation = true;
      await _fetchWorkers();
    } on TimeoutException {
      if (mounted) {
        setState(
          () => _locationError =
              'Could not get your location in time. Please try again.',
        );
      }
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
    final seq = ++_requestSeq;
    final requestedCategory = _selectedCategory;
    setState(() {
      _isLoading = true;
      _loadError = null;
    });

    try {
      final response = await _apiService.findNearbyWorkers(
        lat: _userPosition.latitude,
        lng: _userPosition.longitude,
        radiusKm: _searchRadiusKm,
        category: requestedCategory == 'ALL' ? null : requestedCategory,
      );

      // Ignore a slower earlier response after the filter changed.
      if (!mounted || seq != _requestSeq) return;

      if (response['success'] == true) {
        final List<dynamic> workers = response['workers'] ?? [];
        setState(() {
          _nearbyWorkers = workers;
          _searched = true;
          _selectedWorkerId = null;
        });
      } else {
        setState(() => _loadError = 'Could not load workers. Try again.');
      }
    } catch (e) {
      if (mounted && seq == _requestSeq) {
        setState(
          () => _loadError =
              'Could not load workers. Check your connection and try again.',
        );
      }
    } finally {
      if (mounted && seq == _requestSeq) {
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
      ),
      body: !_hasLocation ? _buildLocationPrompt() : _buildMapView(),
    );
  }

  Widget _buildLocationPrompt() {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(height: 24),
            Container(
              width: 72,
              height: 72,
              decoration: const BoxDecoration(
                color: AppColors.primaryLight,
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.location_on,
                color: AppColors.primary,
                size: 36,
              ),
            ),
            const SizedBox(height: 24),
            const Text(
              'Where do you need help?',
              style: TextStyle(fontSize: 28, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 12),
            const Text(
              'We use your current location once to show available workers within 15 km on a map. It is requested only when you tap the button.',
              style: TextStyle(height: 1.5, color: AppColors.textSecondary),
            ),
            if (_locationError != null)
              Container(
                margin: const EdgeInsets.only(top: 16),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppColors.statusRedLight,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(
                      Icons.error_outline,
                      color: AppColors.statusRed,
                      size: 20,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _locationError!,
                        style: const TextStyle(color: AppColors.textPrimary),
                      ),
                    ),
                  ],
                ),
              ),
            const SizedBox(height: 24),
            ElevatedButton.icon(
              onPressed: _isLoading ? null : _initLiveLocationAndFetch,
              icon: const Icon(Icons.my_location),
              label: Text(
                _isLoading
                    ? 'Finding location…'
                    : _locationError == null
                    ? 'Use my current location'
                    : 'Try again',
              ),
            ),
            if (_canOpenAppSettings)
              TextButton(
                onPressed: Geolocator.openAppSettings,
                child: const Text('Open app settings'),
              ),
            if (_canOpenLocationSettings)
              TextButton(
                onPressed: Geolocator.openLocationSettings,
                child: const Text('Open location settings'),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildMapView() {
    return Stack(
      children: [
        Positioned.fill(child: _buildMap()),
        Positioned(top: 0, left: 0, right: 0, child: _buildFilterChips()),
        if (_isLoading)
          const Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: LinearProgressIndicator(),
          ),
        // Attribution sits above the worker sheet so it is never covered.
        const Positioned(
          top: 62,
          left: 8,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: Color(0xCCFFFFFF),
              borderRadius: BorderRadius.all(Radius.circular(6)),
            ),
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              child: Text(
                '© OpenStreetMap contributors',
                style: TextStyle(fontSize: 11, color: AppColors.textPrimary),
              ),
            ),
          ),
        ),
        if (_tilesFailed)
          Positioned(
            top: 92,
            left: 16,
            right: 68,
            child: Material(
              color: AppColors.surfaceWhite,
              elevation: 2,
              borderRadius: BorderRadius.circular(12),
              child: const Padding(
                padding: EdgeInsets.all(10),
                child: Text(
                  'Map tiles could not load. The worker list below still works.',
                  style: TextStyle(fontSize: 13),
                ),
              ),
            ),
          ),
        Positioned(
          right: 16,
          top: 62,
          child: FloatingActionButton.small(
            heroTag: 'recenter',
            tooltip: 'Centre on me',
            backgroundColor: AppColors.surfaceWhite,
            foregroundColor: AppColors.primary,
            onPressed: () => _mapController.move(_userPosition, 12),
            child: const Icon(Icons.my_location),
          ),
        ),
        _buildWorkerSheet(),
      ],
    );
  }

  Widget _buildFilterChips() {
    return Container(
      height: 56,
      color: AppColors.surfaceOffWhite.withValues(alpha: 0.94),
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        itemCount: _skillFilters.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          final (value, label) = _skillFilters[index];
          final selected = _selectedCategory == value;
          return ChoiceChip(
            key: _chipKeys.putIfAbsent(value, () => GlobalKey()),
            label: Text(label),
            selected: selected,
            showCheckmark: false,
            selectedColor: AppColors.primary,
            backgroundColor: AppColors.surfaceWhite,
            labelStyle: TextStyle(
              color: selected ? Colors.white : AppColors.textPrimary,
              fontWeight: FontWeight.w600,
            ),
            onSelected: (_) {
              setState(() => _selectedCategory = value);
              WidgetsBinding.instance.addPostFrameCallback((_) {
                final ctx = _chipKeys[value]?.currentContext;
                if (ctx != null) {
                  Scrollable.ensureVisible(
                    ctx,
                    duration: const Duration(milliseconds: 200),
                    alignment: 0.5,
                  );
                }
              });
              _fetchWorkers();
            },
          );
        },
      ),
    );
  }

  // Worker positions are rounded to 3 decimals (about 100 m) before plotting.
  LatLng? _approxWorkerPoint(dynamic worker) {
    final lat = (worker['lat'] as num?)?.toDouble();
    final lng = (worker['lng'] as num?)?.toDouble();
    if (lat == null || lng == null) return null;
    if (!lat.isFinite || !lng.isFinite || lat.abs() > 90 || lng.abs() > 180) {
      return null;
    }
    return LatLng(
      (lat * 1000).roundToDouble() / 1000,
      (lng * 1000).roundToDouble() / 1000,
    );
  }

  Widget _buildMap() {
    final markers = <Marker>[
      Marker(
        point: _userPosition,
        width: 36,
        height: 36,
        child: Container(
          decoration: BoxDecoration(
            color: const Color(0xFF0EA5E9),
            shape: BoxShape.circle,
            border: Border.all(color: Colors.white, width: 3),
            boxShadow: const [
              BoxShadow(blurRadius: 6, color: Color(0x55000000)),
            ],
          ),
        ),
      ),
    ];
    for (final worker in _nearbyWorkers) {
      final point = _approxWorkerPoint(worker);
      final id = worker['workerId'];
      if (point == null || id is! String) continue;
      final selected = id == _selectedWorkerId;
      final size = selected ? 52.0 : 38.0;
      markers.add(
        Marker(
          point: point,
          width: size,
          height: size,
          child: GestureDetector(
            onTap: () => setState(() => _selectedWorkerId = id),
            child: Container(
              decoration: BoxDecoration(
                color: selected ? AppColors.primaryDark : AppColors.primary,
                shape: BoxShape.circle,
                border: Border.all(
                  color: Colors.white,
                  width: selected ? 3 : 2,
                ),
                boxShadow: const [
                  BoxShadow(blurRadius: 6, color: Color(0x55000000)),
                ],
              ),
              child: Icon(
                _tradeIcon(worker['workerCategory'] as String?),
                color: Colors.white,
                size: selected ? 28 : 20,
              ),
            ),
          ),
        ),
      );
    }
    return FlutterMap(
      mapController: _mapController,
      options: MapOptions(
        initialCenter: _userPosition,
        initialZoom: 10,
        minZoom: 3,
        maxZoom: 18,
      ),
      children: [
        TileLayer(
          tileBuilder: _mutedTile,
          urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
          userAgentPackageName: 'org.aakar.helpinghand.employer',
          errorTileCallback: (tile, error, stackTrace) {
            if (!_tilesFailed && mounted) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (mounted && !_tilesFailed) {
                  setState(() => _tilesFailed = true);
                }
              });
            }
          },
        ),
        CircleLayer(
          circles: [
            CircleMarker(
              point: _userPosition,
              radius: _searchRadiusKm * 1000,
              useRadiusInMeter: true,
              color: AppColors.primary.withValues(alpha: 0.08),
              borderColor: AppColors.primary,
              borderStrokeWidth: 2,
            ),
          ],
        ),
        MarkerLayer(markers: markers),
      ],
    );
  }

  Widget _buildWorkerSheet() {
    return DraggableScrollableSheet(
      initialChildSize: 0.38,
      minChildSize: 0.14,
      maxChildSize: 0.85,
      snap: true,
      builder: (context, controller) {
        return Container(
          decoration: const BoxDecoration(
            color: AppColors.surfaceOffWhite,
            borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
            boxShadow: [BoxShadow(blurRadius: 12, color: Color(0x33000000))],
          ),
          child: ListView(
            controller: controller,
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
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
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      _loadError != null
                          ? 'Could not load workers'
                          : _searched
                          ? '${_nearbyWorkers.length} available within ${_searchRadiusKm.round()} km'
                          : 'Finding workers…',
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Refresh workers',
                    onPressed: _isLoading ? null : _fetchWorkers,
                    icon: const Icon(Icons.refresh),
                  ),
                ],
              ),
              const Text(
                'Pins show each worker\'s last saved area, not live movement.',
                style: TextStyle(fontSize: 12, color: AppColors.textSecondary),
              ),
              const SizedBox(height: 8),
              ..._buildWorkerRows(),
            ],
          ),
        );
      },
    );
  }

  List<Widget> _buildWorkerRows() {
    if (_loadError != null) {
      return [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 16),
          child: Text(
            _loadError!,
            style: const TextStyle(color: AppColors.statusRed),
          ),
        ),
      ];
    }
    if (_searched && _nearbyWorkers.isEmpty) {
      return const [
        Padding(
          padding: EdgeInsets.symmetric(vertical: 24),
          child: Text(
            'No available workers found nearby. Try another skill or check again later.',
            style: TextStyle(fontSize: 15, color: AppColors.textSecondary),
          ),
        ),
      ];
    }
    return [
      for (final worker in _nearbyWorkers)
        if (worker['workerId'] is String) _buildWorkerCard(worker),
    ];
  }

  /// Display-only softening of the OSM raster (reduced colour saturation) so
  /// worker pins stand out. Tiles are not altered, cached differently or
  /// re-hosted, and attribution stays visible.
  static const List<double> _mutedMatrix = <double>[
    0.5,
    0.4,
    0.1,
    0,
    0,
    0.2,
    0.7,
    0.1,
    0,
    0,
    0.2,
    0.4,
    0.4,
    0,
    0,
    0,
    0,
    0,
    1,
    0,
  ];

  Widget _mutedTile(BuildContext context, Widget tileWidget, TileImage tile) {
    return ColorFiltered(
      colorFilter: const ColorFilter.matrix(_mutedMatrix),
      child: tileWidget,
    );
  }

  Widget _buildWorkerCard(dynamic worker) {
    final String workerId = worker['workerId'];
    final category = worker['workerCategory'] as String? ?? 'Worker';
    final meters = (worker['distanceMeters'] as num?)?.toInt();
    final distance = meters == null
        ? 'Available nearby'
        : meters < 1000
        ? '$meters m away'
        : '${(meters / 1000).toStringAsFixed(1)} km away';
    final selected = workerId == _selectedWorkerId;
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(
          color: selected ? AppColors.primary : AppColors.borderLight,
          width: selected ? 2 : 1,
        ),
      ),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        onTap: () {
          setState(() => _selectedWorkerId = workerId);
          final point = _approxWorkerPoint(worker);
          if (point != null) _mapController.move(point, 13);
        },
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
        title: Text(
          category,
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        subtitle: Text(distance),
        trailing: ElevatedButton(
          onPressed: () => _showWorkerDetailsBottomSheet(workerId),
          child: const Text('View'),
        ),
      ),
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
                              Icon(
                                (_workerCardData?['totalRatingsCount']
                                                as num? ??
                                            0) >
                                        0
                                    ? Icons.star
                                    : Icons.star_border,
                                color:
                                    (_workerCardData?['totalRatingsCount']
                                                as num? ??
                                            0) >
                                        0
                                    ? Colors.amber
                                    : AppColors.textSecondary,
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
                              Icon(
                                _workerCardData?['isVerifiedId'] == true
                                    ? Icons.verified_user
                                    : Icons.shield_outlined,
                                color: _workerCardData?['isVerifiedId'] == true
                                    ? AppColors.statusGreen
                                    : AppColors.textSecondary,
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
                      'Average rating',
                      (_workerCardData?['totalRatingsCount'] as num? ?? 0) > 0
                          ? '${_workerCardData?['trustScore'] ?? 'Not rated'}'
                          : 'Not rated',
                    ),
                    _buildStatCol(
                      'Ratings',
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
                            workerCategory:
                                _workerCardData?['workerCategory'] as String?,
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

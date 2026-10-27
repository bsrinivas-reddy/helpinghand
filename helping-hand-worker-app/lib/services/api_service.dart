import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'session_client.dart';
import 'token_store.dart';
import 'api_config.dart';
import 'package:shared_preferences/shared_preferences.dart';

class ApiService {
  static final ApiService _instance = ApiService._internal();
  factory ApiService() => _instance;
  ApiService._internal() : _client = SessionClient(http.Client());
  ApiService.forTesting(http.Client client) : _client = SessionClient(client);
  final http.Client _client;

  // Dynamic base URL targeting host machine or production via --dart-define=API_BASE_URL=...
  String get baseUrl => resolveBaseUrl(
    configured: const String.fromEnvironment('API_BASE_URL'),
    isRelease: !kDebugMode,
    isWeb: kIsWeb,
    isAndroid: defaultTargetPlatform == TargetPlatform.android,
  );

  // Session keys
  static const String keyWorkerId = 'worker_id';
  static const String keyPhoneNumber = 'phone_number';
  static const String keyFullName = 'full_name';
  static const String keyCategory = 'worker_category';
  static const String keySubCategory = 'worker_sub_category';
  static const String keyEmail = 'email';
  static const String keyAvatarUrl = 'avatar_url';
  static const String keyToken = 'jwt_token';
  static const String keyRefreshToken = 'refresh_token';
  static const String keyIsLoggedIn = 'is_logged_in';

  // 1. Session Storage Helpers
  Future<void> saveSession({
    required String workerId,
    String? phoneNumber,
    String? fullName,
    String? category,
    String? subCategory,
    String? email,
    String? avatarUrl,
    String? token,
    String? refreshToken,
  }) async {
    final epoch = authStartEpoch;
    authStartEpoch = -1;
    // A logout ran while this login was in flight: drop the stale result.
    if (epoch != -1 && epoch != sessionEpoch) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(keyWorkerId, workerId);
    if (phoneNumber != null) await prefs.setString(keyPhoneNumber, phoneNumber);
    if (fullName != null) await prefs.setString(keyFullName, fullName);
    if (category != null) await prefs.setString(keyCategory, category);
    if (subCategory != null) await prefs.setString(keySubCategory, subCategory);
    if (email != null) await prefs.setString(keyEmail, email);
    if (avatarUrl != null) await prefs.setString(keyAvatarUrl, avatarUrl);
    // Tokens first; if a logout dropped a write, stop before marking the user logged in.
    if (token != null &&
        !await writeToken(keyToken, token, epoch: epoch == -1 ? null : epoch)) {
      return;
    }
    if (refreshToken != null &&
        !await writeToken(
          keyRefreshToken,
          refreshToken,
          epoch: epoch == -1 ? null : epoch,
        )) {
      return;
    }
    await prefs.setBool(keyIsLoggedIn, true);
    sessionExpired.value = false;
  }

  Future<Map<String, String?>> getSession() async {
    final prefs = await SharedPreferences.getInstance();
    return {
      'workerId': prefs.getString(keyWorkerId),
      'phoneNumber': prefs.getString(keyPhoneNumber),
      'fullName': prefs.getString(keyFullName),
      'category': prefs.getString(keyCategory),
      'subCategory': prefs.getString(keySubCategory),
      'email': prefs.getString(keyEmail),
      'avatarUrl': prefs.getString(keyAvatarUrl),
      'token': await readToken(keyToken),
      'refreshToken': await readToken(keyRefreshToken),
    };
  }

  Future<String?> getToken() async {
    return readToken(keyToken);
  }

  Future<String?> getRefreshToken() async {
    return readToken(keyRefreshToken);
  }

  Future<bool> isLoggedIn() async {
    await migrateLegacyTokens();
    final prefs = await SharedPreferences.getInstance();
    return (prefs.getBool(keyIsLoggedIn) ?? false) &&
        (await readToken(keyToken))?.isNotEmpty == true;
  }

  Future<void> clearSession() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.clear();
    } finally {
      // After clear(), so the revoke markers deleteTokens may set are not wiped with it.
      await deleteTokens();
    }
  }

  Future<Map<String, String>> _getHeaders() async {
    final token = await getToken();
    return {
      'Content-Type': 'application/json',
      if (token != null && token.isNotEmpty) 'Authorization': 'Bearer $token',
    };
  }

  // 2. Auth APIs
  Future<Map<String, dynamic>> sendOtp(String phoneNumber) async {
    final response = await _client.post(
      Uri.parse('$baseUrl/auth/send-otp'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'phoneNumber': phoneNumber, 'role': 'worker'}),
    );
    return jsonDecode(response.body);
  }

  Future<Map<String, dynamic>> verifyOtp(String phoneNumber, String otp) async {
    beginAuth();
    final response = await _client.post(
      Uri.parse('$baseUrl/auth/verify-otp'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'phoneNumber': phoneNumber,
        'otp': otp,
        'role': 'worker',
      }),
    );
    return jsonDecode(response.body);
  }

  Future<Map<String, dynamic>> googleAuth({
    required String idToken,
    String role = 'worker',
  }) async {
    beginAuth();
    final response = await _client.post(
      Uri.parse('$baseUrl/auth/google'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'idToken': idToken, 'role': role}),
    );
    return jsonDecode(response.body);
  }

  Future<Map<String, dynamic>> refreshToken() async {
    final epoch = sessionEpoch;
    final refToken = await getRefreshToken();
    if (refToken == null) {
      return {'success': false, 'error': 'No refresh token available'};
    }
    final response = await _client.post(
      Uri.parse('$baseUrl/auth/refresh-token'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'refreshToken': refToken}),
    );
    final data = jsonDecode(response.body);
    if (data['success'] == true && data['token'] != null) {
      // Dropped when a logout ran while the request was in flight.
      await writeToken(keyToken, data['token'], epoch: epoch);
    }
    return data;
  }

  Future<Map<String, dynamic>> registerWorker({
    required String phoneNumber,
    required String registrationGrant,
    required String workerCategory,
    String? workerSubCategory,
  }) async {
    beginAuth();
    final headers = await _getHeaders();
    final response = await _client.post(
      Uri.parse('$baseUrl/worker/register'),
      headers: headers,
      body: jsonEncode({
        'phoneNumber': phoneNumber,
        'registrationGrant': registrationGrant,
        'workerCategory': workerCategory,
        'workerSubCategory': workerSubCategory,
      }),
    );
    return jsonDecode(response.body);
  }

  // 3. Worker Status / Location APIs
  Future<Map<String, dynamic>> toggleAvailability({
    required String workerId,
    required bool isAvailable,
    double? lat,
    double? lng,
  }) async {
    final headers = await _getHeaders();
    final response = await _client.post(
      Uri.parse('$baseUrl/worker/toggle-availability'),
      headers: headers,
      body: jsonEncode({
        'workerId': workerId,
        'isAvailable': isAvailable,
        'lat': lat,
        'lng': lng,
      }),
    );
    return jsonDecode(response.body);
  }

  Future<Map<String, dynamic>> updateLocation({
    required String workerId,
    required double lat,
    required double lng,
  }) async {
    final headers = await _getHeaders();
    final response = await _client.post(
      Uri.parse('$baseUrl/worker/location'),
      headers: headers,
      body: jsonEncode({'workerId': workerId, 'lat': lat, 'lng': lng}),
    );
    return jsonDecode(response.body);
  }

  Future<Map<String, dynamic>> getWorkerStatus(String workerId) async {
    final headers = await _getHeaders();
    final response = await _client.get(
      Uri.parse('$baseUrl/worker/status/$workerId'),
      headers: headers,
    );
    return jsonDecode(response.body);
  }

  Future<Map<String, dynamic>> getWorkerProfile(String workerId) async {
    final headers = await _getHeaders();
    final response = await _client.get(
      Uri.parse('$baseUrl/worker/profile/$workerId'),
      headers: headers,
    );
    return jsonDecode(response.body);
  }

  // 4. Shift Management APIs
  Future<Map<String, dynamic>> getWorkerShifts(String workerId) async {
    final headers = await _getHeaders();
    final response = await _client.get(
      Uri.parse('$baseUrl/worker/shifts/user/$workerId'),
      headers: headers,
    );
    return jsonDecode(response.body);
  }

  Future<Map<String, dynamic>> getShiftById(String shiftId) async {
    final headers = await _getHeaders();
    final response = await _client.get(
      Uri.parse('$baseUrl/worker/shifts/$shiftId'),
      headers: headers,
    );
    return jsonDecode(response.body);
  }

  Future<Map<String, dynamic>> acceptShift(String shiftId) async {
    final headers = await _getHeaders();
    final response = await _client.patch(
      Uri.parse('$baseUrl/worker/shifts/$shiftId/accept'),
      headers: headers,
    );
    return jsonDecode(response.body);
  }

  Future<Map<String, dynamic>> startShift(String shiftId) async {
    final headers = await _getHeaders();
    final response = await _client.patch(
      Uri.parse('$baseUrl/worker/shifts/$shiftId/start'),
      headers: headers,
    );
    return jsonDecode(response.body);
  }

  // Two-Sided Physical Cash Handshake Initiation
  Future<Map<String, dynamic>> generateCashHandshakeCode({
    required String shiftId,
    required double lat,
    required double lng,
    required double cashAmount,
  }) async {
    final headers = await _getHeaders();
    final response = await _client.post(
      Uri.parse('$baseUrl/worker/shifts/$shiftId/cash-handshake-code'),
      headers: headers,
      body: jsonEncode({
        'lat': lat,
        'lng': lng,
        'cashReceived': true,
        'cashAmount': cashAmount,
      }),
    );
    return jsonDecode(response.body);
  }

  // Backward-compatible cash reconcile
  Future<Map<String, dynamic>> reconcileCash({
    required String shiftId,
    required double workerLat,
    required double workerLng,
    required double employerLat,
    required double employerLng,
    required double cashAmount,
  }) async {
    final headers = await _getHeaders();
    final response = await _client.post(
      Uri.parse('$baseUrl/worker/shifts/$shiftId/reconcile-cash'),
      headers: headers,
      body: jsonEncode({
        'workerLat': workerLat,
        'workerLng': workerLng,
        'employerLat': employerLat,
        'employerLng': employerLng,
        'cashAmount': cashAmount,
      }),
    );
    return jsonDecode(response.body);
  }

  // 5. Ratings API
  Future<Map<String, dynamic>> submitWorkerRating({
    required String shiftId,
    required String reviewerId,
    required String revieweeId,
    required double ratingStars,
    String? reviewComment,
  }) async {
    final headers = await _getHeaders();
    final response = await _client.post(
      Uri.parse('$baseUrl/worker/ratings/submit'),
      headers: headers,
      body: jsonEncode({
        'shiftId': shiftId,
        'reviewerId': reviewerId,
        'revieweeId': revieweeId,
        'reviewerRole': 'worker',
        'ratingStars': ratingStars.toInt(),
        'reviewComment': reviewComment,
      }),
    );
    return jsonDecode(response.body);
  }
}

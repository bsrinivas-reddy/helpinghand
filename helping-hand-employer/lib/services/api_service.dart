import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'session_client.dart';
import 'package:shared_preferences/shared_preferences.dart';

class ApiService {
  static final ApiService _instance = ApiService._internal();
  factory ApiService() => _instance;
  ApiService._internal() : _client = SessionClient(http.Client());
  ApiService.forTesting(http.Client client) : _client = SessionClient(client);
  final http.Client _client;

  String get baseUrl {
    const configuredUrl = String.fromEnvironment('API_BASE_URL');
    if (configuredUrl.isNotEmpty) {
      return configuredUrl;
    }
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      return 'http://localhost:3000/api';
    }
    return 'http://10.0.2.2:3000/api';
  }

  // Session keys
  static const String keyEmployerId = 'employer_id';
  static const String keyPhoneNumber = 'phone_number';
  static const String keyFullName = 'full_name';
  static const String keyEmail = 'email';
  static const String keyAvatarUrl = 'avatar_url';
  static const String keyUpiId = 'upi_id';
  static const String keyToken = 'jwt_token';
  static const String keyRefreshToken = 'refresh_token';
  static const String keyIsLoggedIn = 'is_logged_in';

  // 1. Session Storage Helpers
  Future<void> saveSession({
    required String employerId,
    String? phoneNumber,
    String? fullName,
    String? email,
    String? avatarUrl,
    String? upiId,
    String? token,
    String? refreshToken,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(keyEmployerId, employerId);
    if (phoneNumber != null) await prefs.setString(keyPhoneNumber, phoneNumber);
    if (fullName != null) await prefs.setString(keyFullName, fullName);
    if (email != null) await prefs.setString(keyEmail, email);
    if (avatarUrl != null) await prefs.setString(keyAvatarUrl, avatarUrl);
    if (upiId != null) await prefs.setString(keyUpiId, upiId);
    if (token != null) await prefs.setString(keyToken, token);
    if (refreshToken != null) {
      await prefs.setString(keyRefreshToken, refreshToken);
    }
    await prefs.setBool(keyIsLoggedIn, true);
    sessionExpired.value = false;
  }

  Future<Map<String, String?>> getSession() async {
    final prefs = await SharedPreferences.getInstance();
    return {
      'employerId': prefs.getString(keyEmployerId),
      'phoneNumber': prefs.getString(keyPhoneNumber),
      'fullName': prefs.getString(keyFullName),
      'email': prefs.getString(keyEmail),
      'avatarUrl': prefs.getString(keyAvatarUrl),
      'upiId': prefs.getString(keyUpiId),
      'token': prefs.getString(keyToken),
      'refreshToken': prefs.getString(keyRefreshToken),
    };
  }

  Future<String?> getToken() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(keyToken);
  }

  Future<String?> getRefreshToken() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(keyRefreshToken);
  }

  Future<bool> isLoggedIn() async {
    final prefs = await SharedPreferences.getInstance();
    return (prefs.getBool(keyIsLoggedIn) ?? false) &&
        prefs.getString(keyToken)?.isNotEmpty == true;
  }

  Future<void> clearSession() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.clear();
  }

  Future<Map<String, String>> _getHeaders() async {
    final token = await getToken();
    return {
      'Content-Type': 'application/json',
      if (token != null && token.isNotEmpty) 'Authorization': 'Bearer $token',
    };
  }

  // 2. Authentication APIs
  Future<Map<String, dynamic>> sendOtp(String phoneNumber) async {
    final response = await _client.post(
      Uri.parse('$baseUrl/auth/send-otp'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'phoneNumber': phoneNumber, 'role': 'employer'}),
    );
    return jsonDecode(response.body);
  }

  Future<Map<String, dynamic>> verifyOtp(String phoneNumber, String otp) async {
    final response = await _client.post(
      Uri.parse('$baseUrl/auth/verify-otp'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'phoneNumber': phoneNumber,
        'otp': otp,
        'role': 'employer',
      }),
    );
    return jsonDecode(response.body);
  }

  Future<Map<String, dynamic>> googleAuth({
    required String idToken,
    String role = 'employer',
  }) async {
    final response = await _client.post(
      Uri.parse('$baseUrl/auth/google'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'idToken': idToken, 'role': role}),
    );
    return jsonDecode(response.body);
  }

  Future<Map<String, dynamic>> refreshToken() async {
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
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(keyToken, data['token']);
    }
    return data;
  }

  Future<Map<String, dynamic>> registerEmployer({
    required String phoneNumber,
    required String registrationGrant,
    required String fullName,
    String? upiId,
  }) async {
    final headers = await _getHeaders();
    final response = await _client.post(
      Uri.parse('$baseUrl/employer/register'),
      headers: headers,
      body: jsonEncode({
        'phoneNumber': phoneNumber,
        'registrationGrant': registrationGrant,
        'fullName': fullName,
        'upiId': upiId,
      }),
    );
    return jsonDecode(response.body);
  }

  // 3. Worker Discovery & Shifts
  Future<Map<String, dynamic>> findNearbyWorkers({
    required double lat,
    required double lng,
    double radiusKm = 5,
    String? category,
  }) async {
    final queryParams = <String, String>{
      'lat': lat.toString(),
      'lng': lng.toString(),
      'radiusKm': radiusKm.toString(),
    };
    if (category != null && category.isNotEmpty) {
      queryParams['category'] = category;
    }
    final uri = Uri.parse(
      '$baseUrl/employer/nearby-workers',
    ).replace(queryParameters: queryParams);
    final headers = await _getHeaders();
    final response = await _client.get(uri, headers: headers);
    return jsonDecode(response.body);
  }

  Future<Map<String, dynamic>> getWorkerMapSummary(String workerId) async {
    final headers = await _getHeaders();
    final response = await _client.get(
      Uri.parse('$baseUrl/employer/workers/$workerId/summary'),
      headers: headers,
    );
    return jsonDecode(response.body);
  }

  Future<Map<String, dynamic>> createShift({
    required String employerId,
    required String workerId,
    required double agreedDailyWage,
  }) async {
    final headers = await _getHeaders();
    final response = await _client.post(
      Uri.parse('$baseUrl/employer/shifts/create'),
      headers: headers,
      body: jsonEncode({
        'employerId': employerId,
        'workerId': workerId,
        'agreedDailyWage': agreedDailyWage,
      }),
    );
    return jsonDecode(response.body);
  }

  Future<Map<String, dynamic>> getEmployerShifts(String employerId) async {
    final headers = await _getHeaders();
    final response = await _client.get(
      Uri.parse('$baseUrl/employer/shifts/user/$employerId'),
      headers: headers,
    );
    return jsonDecode(response.body);
  }

  Future<Map<String, dynamic>> getShiftById(String shiftId) async {
    final headers = await _getHeaders();
    final response = await _client.get(
      Uri.parse('$baseUrl/employer/shifts/$shiftId'),
      headers: headers,
    );
    return jsonDecode(response.body);
  }

  Future<Map<String, dynamic>> adjustShiftTiming({
    required String shiftId,
    String? startTime,
    String? endTime,
    double? workedHours,
    double? customWage,
    String? reason,
  }) async {
    final headers = await _getHeaders();
    final response = await _client.patch(
      Uri.parse('$baseUrl/employer/shifts/$shiftId/adjust-timing'),
      headers: headers,
      body: jsonEncode({
        'startTime': ?startTime,
        'endTime': ?endTime,
        'workedHours': ?workedHours,
        'customWage': ?customWage,
        'reason': ?reason,
      }),
    );
    return jsonDecode(response.body);
  }

  // Two-Sided Physical Cash Handshake Verification
  Future<Map<String, dynamic>> confirmCashHandshake({
    required String shiftId,
    required String handshakeCode,
    required double employerLat,
    required double employerLng,
    double? cashAmount,
  }) async {
    final headers = await _getHeaders();
    final response = await _client.post(
      Uri.parse('$baseUrl/employer/shifts/$shiftId/confirm-cash-handshake'),
      headers: headers,
      body: jsonEncode({
        'handshakeCode': handshakeCode,
        'cashPaid': true,
        'employerLat': employerLat,
        'employerLng': employerLng,
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
    double? cashAmount,
  }) async {
    final headers = await _getHeaders();
    final response = await _client.post(
      Uri.parse('$baseUrl/employer/shifts/$shiftId/reconcile-cash'),
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

  Future<Map<String, dynamic>> submitEmployerRating({
    required String shiftId,
    required String reviewerId,
    required String revieweeId,
    required double ratingStars,
    String? reviewComment,
  }) async {
    final headers = await _getHeaders();
    final response = await _client.post(
      Uri.parse('$baseUrl/employer/ratings/submit'),
      headers: headers,
      body: jsonEncode({
        'shiftId': shiftId,
        'reviewerId': reviewerId,
        'revieweeId': revieweeId,
        'reviewerRole': 'employer',
        'ratingStars': ratingStars.toInt(),
        'reviewComment': reviewComment,
      }),
    );
    return jsonDecode(response.body);
  }
}

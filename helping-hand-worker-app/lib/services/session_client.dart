import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'token_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

final sessionExpired = ValueNotifier<bool>(false);

class SessionClient extends http.BaseClient {
  SessionClient(this.inner);
  final http.Client inner;
  Future<bool>? _refreshing;

  Future<bool> _refresh(Uri apiUri) async {
    final epoch = sessionEpoch;
    final token = await readToken('refresh_token');
    if (token == null) {
      if (epoch != sessionEpoch) return false; // a real logout
      // Keystore trouble is not an invalid session: keep everything, retry later.
      if (keystoreUnavailable) {
        throw http.ClientException('Secure storage unavailable. Please retry.');
      }
      return false;
    }
    final response = await inner.post(
      apiUri.replace(
        path:
            '${apiUri.path.split('/${apiUri.path.contains('/employer/') ? 'employer' : 'worker'}/').first}/auth/refresh-token',
        query: '',
      ),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'refreshToken': token}),
    );
    if (response.statusCode == 401 || response.statusCode == 403) return false;
    if (response.statusCode != 200) {
      throw http.ClientException('Unable to refresh session. Please retry.');
    }
    final data = jsonDecode(response.body);
    if (data['success'] != true || data['token'] is! String) return false;
    if (!await writeToken('jwt_token', data['token'], epoch: epoch)) {
      return false;
    }
    if (data['refreshToken'] is String) {
      await writeToken('refresh_token', data['refreshToken'], epoch: epoch);
    }
    return true;
  }

  http.Request _copy(http.Request request) {
    return http.Request(request.method, request.url)
      ..headers.addAll(request.headers)
      ..bodyBytes = request.bodyBytes
      ..followRedirects = request.followRedirects;
  }

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (request is! http.Request) return inner.send(request);
    final protected =
        !request.url.path.contains('/auth/') &&
        !request.url.path.endsWith('/register');
    final retry = _copy(request);
    if (protected) {
      final token = await readToken('jwt_token');
      if (token != null) request.headers['Authorization'] = 'Bearer $token';
    }
    final response = await inner.send(request);
    if (!protected || response.statusCode != 401) return response;
    await response.stream.drain<void>();
    final future = _refreshing ??= _refresh(request.url);
    bool refreshed;
    try {
      refreshed = await future;
    } finally {
      if (identical(_refreshing, future)) _refreshing = null;
    }
    if (refreshed) {
      final fresh = await readToken('jwt_token');
      if (fresh != null) {
        retry.headers['Authorization'] = 'Bearer $fresh';
        final retried = await inner.send(retry);
        if (retried.statusCode != 401) return retried;
        await retried.stream.drain<void>();
      }
    }
    await deleteTokens();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('is_logged_in', false);
    sessionExpired.value = true;
    return http.StreamedResponse(
      Stream.value(
        utf8.encode(
          jsonEncode({
            'success': false,
            'code': 'session_expired',
            'error': 'Your session ended. Sign in again.',
          }),
        ),
      ),
      401,
      headers: {'content-type': 'application/json'},
    );
  }

  @override
  void close() => inner.close();
}

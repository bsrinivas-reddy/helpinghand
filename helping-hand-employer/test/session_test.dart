import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:employer_app/services/api_service.dart';
import 'package:employer_app/services/session_client.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    sessionExpired.value = false;
  });
  test(
    'OTP challenges and registration proof are explicitly role bound',
    () async {
      final seen = <Map<String, dynamic>>[];
      final api = ApiService.forTesting(
        MockClient((request) async {
          seen.add(jsonDecode(request.body) as Map<String, dynamic>);
          return http.Response('{"success":true}', 200);
        }),
      );
      await api.sendOtp('9876543210');
      await api.verifyOtp('9876543210', '654321');
      expect(seen[0]['role'], 'employer');
      expect(seen[1]['role'], 'employer');
      await api.registerEmployer(
        phoneNumber: '9876543210',
        registrationGrant: 'opaque-grant',
        fullName: 'Fixture',
      );
      expect(seen[2]['registrationGrant'], 'opaque-grant');
    },
  );
  test(
    'one authenticated rejection refreshes and retries without provider access',
    () async {
      SharedPreferences.setMockInitialValues({
        'jwt_token': 'old',
        'refresh_token': 'refresh',
        'is_logged_in': true,
      });
      var refreshes = 0;
      var writes = 0;
      final client = SessionClient(
        MockClient((request) async {
          if (request.url.path.endsWith('/refresh-token')) {
            refreshes++;
            return http.Response('{"success":true,"token":"new"}', 200);
          }
          if (request.headers['Authorization'] == 'Bearer old') {
            return http.Response('{"success":false}', 401);
          }
          writes++;
          return http.Response('{"success":true}', 200);
        }),
      );
      final response = await client.post(
        Uri.parse('http://fixture.invalid/api/employer/shifts/action'),
        body: '{}',
      );
      expect(response.statusCode, 200);
      expect(refreshes, 1);
      expect(writes, 1);
      expect(sessionExpired.value, false);
    },
  );
  test(
    'rejected refresh clears only session auth and exposes sign-in state',
    () async {
      SharedPreferences.setMockInitialValues({
        'jwt_token': 'old',
        'refresh_token': 'bad',
        'is_logged_in': true,
        'full_name': 'Fixture',
      });
      final client = SessionClient(
        MockClient((_) async => http.Response('{"success":false}', 401)),
      );
      final result = await client.get(
        Uri.parse('http://fixture.invalid/api/employer/shifts'),
      );
      expect(result.statusCode, 401);
      expect(jsonDecode(result.body)['code'], 'session_expired');
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('is_logged_in'), false);
      expect(prefs.getString('jwt_token'), isNull);
      expect(prefs.getString('full_name'), 'Fixture');
      expect(sessionExpired.value, true);
    },
  );
  test('network failure never retries an unsafe write', () async {
    var requests = 0;
    final client = SessionClient(
      MockClient((_) async {
        requests++;
        throw http.ClientException('offline');
      }),
    );
    await expectLater(
      client.post(
        Uri.parse('http://fixture.invalid/api/employer/shifts'),
        body: '{}',
      ),
      throwsA(isA<http.ClientException>()),
    );
    expect(requests, 1);
    expect(sessionExpired.value, false);
  });
  test(
    'concurrent rejections share refresh and preserve API path prefix',
    () async {
      SharedPreferences.setMockInitialValues({
        'jwt_token': 'old',
        'refresh_token': 'refresh',
        'is_logged_in': true,
      });
      var refreshes = 0;
      final urls = <String>[];
      final client = SessionClient(
        MockClient((request) async {
          urls.add(request.url.path);
          if (request.url.path.endsWith('/refresh-token')) {
            refreshes++;
            await Future<void>.delayed(const Duration(milliseconds: 30));
            return http.Response('{"success":true,"token":"new"}', 200);
          }
          return http.Response(
            '{}',
            request.headers['Authorization'] == 'Bearer new' ? 200 : 401,
          );
        }),
      );
      final results = await Future.wait([
        client.get(
          Uri.parse('http://fixture.invalid/prefix/api/employer/shifts/a'),
        ),
        client.get(
          Uri.parse('http://fixture.invalid/prefix/api/employer/shifts/b'),
        ),
      ]);
      expect(results.map((r) => r.statusCode).toList(), [200, 200]);
      expect(refreshes, 1);
      expect(urls.where((p) => p.endsWith('/refresh-token')).toList(), [
        '/prefix/api/auth/refresh-token',
      ]);
    },
  );
  test(
    'cash acknowledgement payload uses explicit amount and own position',
    () async {
      late Map<String, dynamic> body;
      final api = ApiService.forTesting(
        MockClient((request) async {
          body = jsonDecode(request.body) as Map<String, dynamic>;
          return http.Response(
            '{"success":true,"proximityVerified":false}',
            200,
          );
        }),
      );
      await api.confirmCashHandshake(
        shiftId: 'shift-fixture',
        handshakeCode: '4826',
        employerLat: 18.52,
        employerLng: 73.85,
        cashAmount: 800,
      );
      expect(body['cashAmount'], 800);
      expect(body['cashPaid'], true);
      expect(body['handshakeCode'], '4826');
      expect(body.containsKey('lat'), false);
    },
  );
}

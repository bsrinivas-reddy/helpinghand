import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:employer_app/services/api_config.dart';
import 'package:employer_app/services/api_service.dart';
import 'package:employer_app/services/token_store.dart';
import 'package:employer_app/services/session_client.dart';

void main() {
  late MemoryTokenStore store;
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    store = MemoryTokenStore();
    tokenStore = store;
  });

  test(
    'saveSession keeps tokens in the secure store and out of preferences',
    () async {
      await ApiService.forTesting(_noop).saveSession(
        employerId: 'e1',
        token: 'access-1',
        refreshToken: 'refresh-1',
      );
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('jwt_token'), isNull);
      expect(prefs.getString('refresh_token'), isNull);
      expect(store.values['jwt_token'], 'access-1');
      expect(store.values['refresh_token'], 'refresh-1');
      expect(await ApiService.forTesting(_noop).isLoggedIn(), isTrue);
    },
  );

  test(
    'tokens left in preferences by an older version move to the secure store',
    () async {
      SharedPreferences.setMockInitialValues({
        'jwt_token': 'old-access',
        'refresh_token': 'old-refresh',
        'is_logged_in': true,
      });
      final api = ApiService.forTesting(_noop);
      expect(await api.isLoggedIn(), isTrue);
      expect(await api.getRefreshToken(), 'old-refresh');
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.containsKey('jwt_token'), isFalse);
      expect(prefs.containsKey('refresh_token'), isFalse);
      expect(store.values, {
        'jwt_token': 'old-access',
        'refresh_token': 'old-refresh',
      });
    },
  );

  test(
    'an unreadable keystore means signed out for now, and deletes nothing',
    () async {
      tokenStore = _BrokenStore();
      SharedPreferences.setMockInitialValues({
        'is_logged_in': true,
        'refresh_token': 'legacy',
      });
      final api = ApiService.forTesting(_noop);
      expect(await api.getToken(), isNull);
      expect(await api.isLoggedIn(), isFalse);
      expect(
        (await SharedPreferences.getInstance()).getString('refresh_token'),
        'legacy',
      );
    },
  );

  test(
    'checking sign-in state migrates the refresh token too, not only the access token',
    () async {
      SharedPreferences.setMockInitialValues({
        'jwt_token': 'a',
        'refresh_token': 'r',
        'is_logged_in': true,
      });
      expect(await ApiService.forTesting(_noop).isLoggedIn(), isTrue);
      expect(
        (await SharedPreferences.getInstance()).getKeys().where(
          (k) => k.endsWith('_token'),
        ),
        isEmpty,
      );
      expect(store.values, {'jwt_token': 'a', 'refresh_token': 'r'});
    },
  );

  test(
    'a failed secure write during migration fails closed: no plaintext token is used, nothing is deleted, a later launch migrates it',
    () async {
      tokenStore = _WriteFailsStore(store);
      SharedPreferences.setMockInitialValues({
        'jwt_token': 'legacy',
        'is_logged_in': true,
      });
      final api = ApiService.forTesting(_noop);
      expect(await api.getToken(), isNull);
      expect(await api.isLoggedIn(), isFalse);
      final seen = <String?>[];
      await SessionClient(
        MockClient((request) async {
          seen.add(request.headers['Authorization']);
          return http.Response('{"success":true}', 200);
        }),
      ).get(Uri.parse('http://fixture.invalid/api/x/shifts'));
      expect(seen, [null]);
      expect(
        (await SharedPreferences.getInstance()).getString('jwt_token'),
        'legacy',
      );
      tokenStore = store; // keystore recovered
      expect(await ApiService.forTesting(_noop).getToken(), 'legacy');
      expect(store.values['jwt_token'], 'legacy');
      expect(
        (await SharedPreferences.getInstance()).getString('jwt_token'),
        isNull,
      );
    },
  );

  test(
    'a stale plaintext copy is removed when the secure copy exists and never overrides it',
    () async {
      store.values['jwt_token'] = 'secure';
      SharedPreferences.setMockInitialValues({'jwt_token': 'stale'});
      expect(await ApiService.forTesting(_noop).getToken(), 'secure');
      expect(
        (await SharedPreferences.getInstance()).containsKey('jwt_token'),
        isFalse,
      );
      expect(store.values['jwt_token'], 'secure');
    },
  );

  test(
    'logout after migration leaves no token anywhere and none comes back',
    () async {
      SharedPreferences.setMockInitialValues({
        'jwt_token': 'a',
        'refresh_token': 'r',
        'is_logged_in': true,
      });
      final api = ApiService.forTesting(_noop);
      expect(await api.getToken(), 'a');
      await api.clearSession();
      expect(await api.getToken(), isNull);
      expect(await api.getRefreshToken(), isNull);
      expect(await api.isLoggedIn(), isFalse);
      expect(store.values, isEmpty);
      expect((await SharedPreferences.getInstance()).getKeys(), isEmpty);
    },
  );

  test(
    'if the keystore refuses the delete on logout, the tokens are unusable and stay so after restart, new client and requests',
    () async {
      store.values['jwt_token'] = 'a';
      store.values['refresh_token'] = 'r';
      final failing = _DeleteFailsStore(store);
      tokenStore = failing;
      SharedPreferences.setMockInitialValues({'is_logged_in': true});
      await ApiService.forTesting(_noop).clearSession();
      // The stored values really are still there; the marker is what blocks them.
      expect(store.values, {'jwt_token': 'a', 'refresh_token': 'r'});
      // A fresh client (restart) cannot read either token.
      final api = ApiService.forTesting(_noop);
      expect(await api.getToken(), isNull);
      expect(await api.getRefreshToken(), isNull);
      expect(await api.isLoggedIn(), isFalse);
      // And no request carries the old token.
      final seen = <String?>[];
      final client = SessionClient(
        MockClient((request) async {
          seen.add(request.headers['Authorization']);
          return http.Response('{"success":true}', 200);
        }),
      );
      await client.get(Uri.parse('http://fixture.invalid/api/employer/shifts'));
      expect(seen, [null]);
      // A later login replaces the token and works again; the old refresh token stays blocked.
      await api.saveSession(token: 'new', employerId: 'e1');
      expect(await api.getToken(), 'new');
      expect(await api.getRefreshToken(), isNull);
      // Once the keystore recovers, the next read deletes the stale refresh token for good.
      tokenStore = store;
      expect(await api.getRefreshToken(), isNull);
      expect(store.values.containsKey('refresh_token'), isFalse);
    },
  );

  test('clearSession wipes tokens from both places', () async {
    SharedPreferences.setMockInitialValues({'jwt_token': 'legacy'});
    store.values['refresh_token'] = 'r';
    await ApiService.forTesting(_noop).clearSession();
    expect(store.values, isEmpty);
    expect((await SharedPreferences.getInstance()).getKeys(), isEmpty);
  });

  test(
    'release builds need an https API_BASE_URL and never default to localhost',
    () {
      String url({
        String c = '',
        bool release = false,
        bool web = false,
        bool android = true,
      }) => resolveBaseUrl(
        configured: c,
        isRelease: release,
        isWeb: web,
        isAndroid: android,
      );
      expect(url(), 'http://10.0.2.2:3000/api');
      expect(url(android: false), 'http://localhost:3000/api');
      expect(url(c: 'http://10.0.0.5:3000/api'), 'http://10.0.0.5:3000/api');
      expect(
        url(c: 'https://api.example.test/api', release: true),
        'https://api.example.test/api',
      );
      expect(() => url(release: true), throwsStateError);
      expect(
        () => url(c: 'http://api.example.test/api', release: true),
        throwsStateError,
      );
      expect(() => url(c: 'api.example.test', release: true), throwsStateError);
    },
  );

  test(
    'logout sets the revoke marker BEFORE the keystore delete, so a kill mid-logout cannot leave a live unmarked token',
    () async {
      store.values['jwt_token'] = 'a';
      bool? markerWhenDeleting;
      bool? refreshMarkerAtFirstDelete;
      tokenStore = _SpyDeleteStore(store, () async {
        refreshMarkerAtFirstDelete ??= (await SharedPreferences.getInstance())
            .getBool('revoked:refresh_token');
        markerWhenDeleting ??= (await SharedPreferences.getInstance()).getBool(
          'revoked:jwt_token',
        );
      });
      await deleteTokens();
      expect(markerWhenDeleting, isTrue);
      expect(
        refreshMarkerAtFirstDelete,
        isTrue,
        reason: 'every key is marked before any delete (kill between keys)',
      );
      // After a successful delete the marker is gone again and the token is gone.
      expect(store.values, isEmpty);
      expect(
        (await SharedPreferences.getInstance()).getBool('revoked:jwt_token'),
        isNull,
      );
    },
  );

  test(
    'a refresh that was in flight during logout cannot sign the user back in',
    () async {
      store.values['refresh_token'] = 'r';
      late SessionClient client;
      final api = ApiService.forTesting(_noop);
      client = SessionClient(
        MockClient((request) async {
          if (request.url.path.endsWith('/auth/refresh-token')) {
            await api
                .clearSession(); // logout while the refresh response is on its way
            return http.Response(
              '{"success":true,"token":"late","refreshToken":"late-r"}',
              200,
            );
          }
          return http.Response('{"success":false}', 401);
        }),
      );
      await client.get(Uri.parse('http://fixture.invalid/api/employer/shifts'));
      expect(await api.getToken(), isNull);
      expect(await api.getRefreshToken(), isNull);
      expect(store.values, isEmpty);
    },
  );

  test(
    'a login that was in flight during logout is dropped and cannot sign the user back in',
    () async {
      final api = ApiService.forTesting(
        MockClient((request) async => http.Response('{"success":true}', 200)),
      );
      await api.verifyOtp('9876543210', '654321'); // login request starts
      await api.clearSession(); // user logs out before the response is handled
      await api.saveSession(
        token: 'late',
        refreshToken: 'late-r',
        employerId: 'x1',
      );
      expect(await api.getToken(), isNull);
      expect(await api.getRefreshToken(), isNull);
      expect(await api.isLoggedIn(), isFalse);
      expect(store.values, isEmpty);
    },
  );

  test(
    'a logout between the secure write and the marker removal keeps the marker and drops the token',
    () async {
      SharedPreferences.setMockInitialValues({'revoked:jwt_token': true});
      tokenStore = _LogoutDuringWriteStore(store);
      final epoch = sessionEpoch;
      expect(await writeToken('jwt_token', 'stale', epoch: epoch), isFalse);
      expect(
        (await SharedPreferences.getInstance()).getBool('revoked:jwt_token'),
        isTrue,
      );
      expect(store.values, isEmpty);
    },
  );

  test(
    'a keystore failure plus a 401 does not run logout: the legacy copy and session survive for a later launch',
    () async {
      sessionExpired.value = false;
      tokenStore = _WriteFailsStore(store);
      SharedPreferences.setMockInitialValues({
        'jwt_token': 'legacy',
        'refresh_token': 'legacy-r',
        'is_logged_in': true,
      });
      final client = SessionClient(
        MockClient((request) async => http.Response('{"success":false}', 401)),
      );
      await expectLater(
        client.get(Uri.parse('http://fixture.invalid/api/employer/shifts')),
        throwsA(isA<http.ClientException>()),
      );
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('jwt_token'), 'legacy');
      expect(prefs.getString('refresh_token'), 'legacy-r');
      expect(prefs.getBool('revoked:jwt_token'), isNull);
      expect(sessionExpired.value, isFalse);
      tokenStore = store; // keystore recovered
      expect(await ApiService.forTesting(_noop).getToken(), 'legacy');
      expect(await ApiService.forTesting(_noop).getRefreshToken(), 'legacy-r');
    },
  );

  test(
    'refreshToken() response arriving after logout does not store a token',
    () async {
      store.values['refresh_token'] = 'r';
      late ApiService api;
      api = ApiService.forTesting(
        MockClient((request) async {
          await api.clearSession();
          return http.Response('{"success":true,"token":"late"}', 200);
        }),
      );
      await api.refreshToken();
      expect(await api.getToken(), isNull);
      expect(store.values.containsKey('jwt_token'), isFalse);
    },
  );

  test('a stale plaintext copy cannot return a revoked token', () async {
    SharedPreferences.setMockInitialValues({
      'revoked:jwt_token': true,
      'jwt_token': 'old-plain',
    });
    store.values['jwt_token'] = 'old-secure';
    expect(await readToken('jwt_token'), isNull);
    // Marker cleared by the successful retry-delete; the plaintext copy must be gone too.
    expect(await readToken('jwt_token'), isNull);
  });

  test(
    'deleteTokens never throws, even when preferences and the keystore both fail',
    () async {
      tokenStore = _DeleteFailsStore(store);
      await deleteTokens();
    },
  );
}

final _noop = MockClient((_) async => http.Response('{}', 200));

class _BrokenStore implements TokenStore {
  @override
  Future<String?> read(String key) => throw StateError('keystore unreadable');
  @override
  Future<void> write(String key, String value) =>
      throw StateError('keystore unreadable');
  @override
  Future<void> delete(String key) => throw StateError('keystore unreadable');
}

class _WriteFailsStore implements TokenStore {
  _WriteFailsStore(this.inner);
  final MemoryTokenStore inner;
  @override
  Future<String?> read(String key) => inner.read(key);
  @override
  Future<void> write(String key, String value) =>
      throw StateError('write failed');
  @override
  Future<void> delete(String key) => inner.delete(key);
}

class _DeleteFailsStore implements TokenStore {
  _DeleteFailsStore(this.inner);
  final MemoryTokenStore inner;
  @override
  Future<String?> read(String key) => inner.read(key);
  @override
  Future<void> write(String key, String value) => inner.write(key, value);
  @override
  Future<void> delete(String key) => throw StateError('delete failed');
}

class _SpyDeleteStore implements TokenStore {
  _SpyDeleteStore(this.inner, this.onDelete);
  final MemoryTokenStore inner;
  final Future<void> Function() onDelete;
  @override
  Future<String?> read(String key) => inner.read(key);
  @override
  Future<void> write(String key, String value) => inner.write(key, value);
  @override
  Future<void> delete(String key) async {
    await onDelete();
    await inner.delete(key);
  }
}

class _LogoutDuringWriteStore implements TokenStore {
  _LogoutDuringWriteStore(this.inner);
  final MemoryTokenStore inner;
  @override
  Future<String?> read(String key) => inner.read(key);
  @override
  Future<void> write(String key, String value) async {
    await inner.write(key, value);
    sessionEpoch++; // a logout lands right after the keystore write
  }

  @override
  Future<void> delete(String key) => inner.delete(key);
}

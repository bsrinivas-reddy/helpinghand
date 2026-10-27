import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Where the JWT access and refresh tokens live. On Android and iOS that is the platform
/// keystore (Android Keystore, iOS Keychain) instead of plain SharedPreferences. On web the
/// plugin keeps data in browser storage, which is weaker than a keystore.
abstract class TokenStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

class SecureTokenStore implements TokenStore {
  const SecureTokenStore([this._storage = const FlutterSecureStorage()]);
  final FlutterSecureStorage _storage;

  @override
  Future<String?> read(String key) => _storage.read(key: key);
  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);
  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}

class MemoryTokenStore implements TokenStore {
  final Map<String, String> values = {};
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async => values[key] = value;
  @override
  Future<void> delete(String key) async => values.remove(key);
}

const tokenKeys = ['jwt_token', 'refresh_token'];

// A revoke marker survives restarts in SharedPreferences. When the keystore refuses to delete a
// token on logout, the marker makes readToken return null for that key until a new login
// writes a fresh value, so a token the user logged out of is never sent again.
String _revokedKey(String key) => 'revoked:$key';

/// True when the last token read could not use the keystore (read or migration-write error).
/// The session client uses it to tell "keystore unavailable" from "no/invalid token", so a
/// keystore failure does not run the logout path that deletes the legacy copy.
bool keystoreUnavailable = false;

/// Process-wide store. Tests swap it for [MemoryTokenStore].
TokenStore tokenStore = const SecureTokenStore();

/// Reads a token. A token that an older app version left in SharedPreferences is moved
/// into the secure store, and the plaintext copy is deleted only after the secure write
/// succeeded. If that write fails the legacy copy is kept untouched (nothing is lost) and the
/// existing session keeps working until the keystore recovers. Errors are never logged: they
/// can carry key names or platform detail, and the value itself must not reach a log.
Future<String?> readToken(String key) async {
  final prefs = await SharedPreferences.getInstance();
  if (prefs.getBool(_revokedKey(key)) == true) {
    // Retry the delete; either way this token stays unusable until a new login replaces it.
    try {
      await prefs.remove(
        key,
      ); // a stale plaintext copy must not be migrated back in later
      await tokenStore.delete(key);
      await prefs.remove(_revokedKey(key));
    } catch (_) {}
    return null;
  }
  final legacy = prefs.getString(key);
  String? secure;
  try {
    secure = await tokenStore.read(key);
  } catch (_) {
    keystoreUnavailable = true;
    // Unreadable keystore (locked at boot, or restored from a backup onto a new device).
    // Signed out for now; nothing is deleted, so a later launch can still read the session.
    return null;
  }
  keystoreUnavailable = false;
  if (secure != null) {
    // The secure copy wins. A stale plaintext copy must not stay behind or come back later.
    if (legacy != null) {
      try {
        await prefs.remove(key);
      } catch (_) {}
    }
    return secure;
  }
  if (legacy == null) return null;
  try {
    await tokenStore.write(key, legacy);
  } catch (_) {
    keystoreUnavailable = true;
    // Fail closed. A keystore that refuses this write could not hold a new login either, so
    // there is no working session to protect. The plaintext copy is left untouched (nothing is
    // lost), the user is signed out for now, and a later launch migrates it if the keystore
    // recovers. The plaintext token is never used as a long-term fallback.
    return null;
  }
  try {
    await prefs.remove(key);
  } catch (_) {}
  return legacy;
}

/// Moves every legacy plaintext token into the secure store. Called when the app checks the
/// sign-in state, so the long-lived refresh token does not wait for its first use.
Future<void> migrateLegacyTokens() async {
  for (final key in tokenKeys) {
    try {
      await readToken(key);
    } catch (_) {}
  }
}

/// Epoch captured when a login request starts (-1 = none). saveSession drops the result when a
/// logout happened in between, so a slow login response cannot sign the user back in.
int authStartEpoch = -1;
void beginAuth() => authStartEpoch = sessionEpoch;

/// Bumped on every logout. A token write that started before a logout (an in-flight refresh)
/// carries the old value and is dropped, so it cannot sign the user back in.
int sessionEpoch = 0;

/// Returns false when the write was dropped because the user logged out after [epoch] was read.
Future<bool> writeToken(String key, String value, {int? epoch}) async {
  if (epoch != null && epoch != sessionEpoch) return false;
  await tokenStore.write(key, value);
  if (epoch != null && epoch != sessionEpoch) {
    // Logged out while the write was in flight: take the token straight back out.
    try {
      await tokenStore.delete(key);
    } catch (_) {
      try {
        await (await SharedPreferences.getInstance()).setBool(
          _revokedKey(key),
          true,
        );
      } catch (_) {}
    }
    return false;
  }
  final prefs = await SharedPreferences.getInstance();
  await prefs.remove(key);
  if (epoch != null && epoch != sessionEpoch) {
    // A logout ran between the write and the marker removal: keep its marker, drop the token.
    try {
      await tokenStore.delete(key);
    } catch (_) {}
    return false;
  }
  await prefs.remove(_revokedKey(key));
  return true;
}

/// Logs out. Never throws. The revoke marker is set BEFORE the keystore delete and removed only
/// after the delete succeeded, so a process kill at any point leaves either a marker or no
/// token, never a live unmarked token.
Future<void> deleteTokens() async {
  sessionEpoch++;
  SharedPreferences? prefs;
  try {
    prefs = await SharedPreferences.getInstance();
  } catch (_) {}
  // Phase 1: mark every token revoked before deleting any, so a kill between keys cannot
  // leave a later token live and unmarked.
  final marked = <String>{};
  if (prefs != null) {
    for (final key in tokenKeys) {
      try {
        await prefs.setBool(_revokedKey(key), true);
        marked.add(key);
      } catch (_) {}
    }
  }
  for (final key in tokenKeys) {
    try {
      await prefs?.remove(key);
    } catch (_) {}
    try {
      await tokenStore.delete(key);
      await prefs?.remove(_revokedKey(key));
    } catch (_) {
      // Delete failed (or the marker could not be cleared): the marker stays, so readToken
      // keeps returning null for this key until a new login writes a fresh token. If no marker
      // could be stored either, overwrite the token with a value the server rejects.
      if (!marked.contains(key)) {
        try {
          await tokenStore.write(key, 'revoked');
        } catch (_) {}
      }
    }
  }
}

/// Picks the API base URL. A release build never falls back to a localhost URL and never
/// talks plain http: it needs an https API_BASE_URL set at build time (--dart-define).
String resolveBaseUrl({
  required String configured,
  required bool isRelease,
  required bool isWeb,
  required bool isAndroid,
}) {
  if (configured.isNotEmpty) {
    if (isRelease && Uri.tryParse(configured)?.scheme != 'https') {
      throw StateError('Release builds need an https API_BASE_URL.');
    }
    return configured;
  }
  if (isRelease) {
    throw StateError(
      'Release builds need --dart-define=API_BASE_URL=https://...',
    );
  }
  if (isWeb || !isAndroid) return 'http://localhost:3000/api';
  return 'http://10.0.2.2:3000/api';
}

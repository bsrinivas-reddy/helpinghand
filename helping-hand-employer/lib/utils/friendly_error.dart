/// Turns a thrown error into a short user-facing message. Server messages
/// carried by StateError/Exception text are kept; transport and parse errors
/// become a plain connection message.
String friendlyError(Object error) {
  final raw = error.toString();
  final lower = raw.toLowerCase();
  if (lower.contains('clientexception') ||
      lower.contains('socketexception') ||
      lower.contains('failed to fetch') ||
      lower.contains('formatexception') ||
      lower.contains('timeoutexception')) {
    return 'Could not reach the server. Check your connection and try again.';
  }
  return raw
      .replaceFirst('Bad state: ', '')
      .replaceFirst('Exception: ', '')
      .replaceFirst('Invalid argument(s): ', '');
}

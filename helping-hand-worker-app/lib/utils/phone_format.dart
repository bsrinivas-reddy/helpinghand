/// Formats a stored phone number for display with a single +91 prefix.
/// Accepts 10-digit numbers or numbers already stored with +91 / 91.
String formatIndianPhone(String raw) {
  final digits = raw.replaceAll(RegExp(r'[^0-9]'), '');
  if (digits.isEmpty) return '';
  final national = (digits.length > 10 && digits.startsWith('91'))
      ? digits.substring(digits.length - 10)
      : digits;
  return '+91 $national';
}

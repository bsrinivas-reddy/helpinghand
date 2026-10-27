import 'package:flutter_test/flutter_test.dart';
import 'package:worker_app/utils/phone_format.dart';

void main() {
  test('single +91 prefix for every stored shape', () {
    expect(formatIndianPhone('9111111111'), '+91 9111111111');
    expect(formatIndianPhone('+919111111111'), '+91 9111111111');
    expect(formatIndianPhone('919111111111'), '+91 9111111111');
    expect(formatIndianPhone(''), '');
  });
}

import 'package:flutter_test/flutter_test.dart';
import 'package:pantry_mobile/stock_levels.dart';

void main() {
  group('parseQuantityAmount', () {
    test('reads the leading integer or decimal amount', () {
      expect(parseQuantityAmount('2 tubs'), 2);
      expect(parseQuantityAmount(' 0.5 kg'), 0.5);
    });

    test('returns null when quantity is not numeric', () {
      expect(parseQuantityAmount('a few'), isNull);
      expect(parseQuantityAmount(''), isNull);
      expect(parseQuantityAmount(null), isNull);
    });
  });

  group('isAtOrBelowMinimum', () {
    test('flags stock at or below its configured minimum', () {
      expect(
        isAtOrBelowMinimum({
          'quantity': '2 tubs',
          'minimumQuantity': 2,
          'status': 'ok',
        }),
        isTrue,
      );
      expect(
        isAtOrBelowMinimum({
          'quantity': '1.5 kg',
          'minimumQuantity': 2,
          'status': 'ok',
        }),
        isTrue,
      );
    });

    test('does not flag quantities above the minimum or unknown amounts', () {
      expect(
        isAtOrBelowMinimum({
          'quantity': '3 tubs',
          'minimumQuantity': 2,
          'status': 'ok',
        }),
        isFalse,
      );
      expect(
        isAtOrBelowMinimum({
          'quantity': 'a few',
          'minimumQuantity': 2,
          'status': 'ok',
        }),
        isFalse,
      );
    });

    test('retains manually marked low-stock items', () {
      expect(isAtOrBelowMinimum({'quantity': '10', 'status': 'low'}), isTrue);
    });
  });
}

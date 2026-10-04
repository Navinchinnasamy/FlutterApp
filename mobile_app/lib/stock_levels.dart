double? parseQuantityAmount(dynamic value) {
  final match = RegExp(r'^\s*(\d+(?:\.\d+)?)')
      .firstMatch(value?.toString() ?? '');
  return match == null ? null : double.tryParse(match.group(1)!);
}

bool isAtOrBelowMinimum(Map<String, dynamic> item) {
  if (item['status'] == 'low') return true;
  final rawMinimum = item['minimumQuantity'];
  final minimum = rawMinimum is num ? rawMinimum.toDouble() : null;
  final current = parseQuantityAmount(item['quantity']);
  return minimum != null && current != null && current <= minimum;
}

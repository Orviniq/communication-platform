import 'package:flutter/services.dart';

/// Keeps a text to [limit] Unicode scalar values, the unit the protocol counts
/// text in. A paste past the limit is cut to it.
final class AppScalarLimitFormatter extends TextInputFormatter {
  const AppScalarLimitFormatter(this.limit);

  final int limit;

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final runes = newValue.text.runes;
    if (runes.length <= limit) {
      return newValue;
    }
    final kept = String.fromCharCodes(runes.take(limit));
    return TextEditingValue(
      text: kept,
      selection: TextSelection.collapsed(offset: kept.length),
    );
  }
}

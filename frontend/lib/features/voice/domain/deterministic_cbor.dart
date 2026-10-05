import 'dart:convert';
import 'dart:typed_data';

/// One item of the deterministic CBOR subset a `CPVSV001` body is written in:
/// unsigned integers, byte and text strings, arrays, maps keyed by unsigned
/// integers, and the two booleans (`voice-signalling-v1.md`, "The common body
/// header").
///
/// Nothing else of RFC 8949 is representable, so nothing else can be encoded,
/// and nothing else is accepted when decoding.
sealed class CborValue {
  const CborValue();
}

final class CborUnsigned extends CborValue {
  CborUnsigned(this.value) {
    if (value < 0) {
      throw ArgumentError.value(value, 'value', 'must not be negative');
    }
  }

  final int value;
}

final class CborBytes extends CborValue {
  CborBytes(Uint8List value) : value = Uint8List.fromList(value);

  final Uint8List value;
}

final class CborText extends CborValue {
  const CborText(this.value);

  final String value;
}

final class CborBool extends CborValue {
  const CborBool(this.value);

  final bool value;
}

final class CborArray extends CborValue {
  CborArray(List<CborValue> items) : items = List.unmodifiable(items);

  final List<CborValue> items;
}

final class CborMap extends CborValue {
  CborMap(Map<int, CborValue> entries) : entries = Map.unmodifiable(entries) {
    if (entries.keys.any((key) => key < 0)) {
      throw ArgumentError.value(entries, 'entries', 'keys must be unsigned');
    }
  }

  final Map<int, CborValue> entries;
}

/// Bytes that are not a deterministic encoding of the subset above.
final class CborFormatException implements Exception {
  const CborFormatException();
}

/// RFC 8949 §4.2.1, for the subset [CborValue] can hold: definite lengths,
/// the shortest argument encoding, map keys in ascending order, no tags, no
/// floats and no simple values besides `false` and `true`.
abstract final class DeterministicCbor {
  /// The one encoding of [value]. Map keys are written in ascending order,
  /// which for unsigned keys is the bytewise order of their encodings.
  static Uint8List encode(CborValue value) {
    final output = BytesBuilder(copy: false);
    _write(output, value);
    return output.takeBytes();
  }

  /// Reads exactly one item that fills [bytes].
  ///
  /// [maximumNesting] bounds how many arrays and maps may enclose one another.
  /// Throws [CborFormatException] for anything outside the subset, for any
  /// encoding that is not the deterministic one, and for trailing bytes.
  static CborValue decode(Uint8List bytes, {required int maximumNesting}) {
    final reader = _CborReader(bytes, maximumNesting);
    final value = reader.read(0);
    if (!reader.atEnd) {
      throw const CborFormatException();
    }
    return value;
  }

  static void _write(BytesBuilder output, CborValue value) {
    switch (value) {
      case CborUnsigned(:final value):
        _writeHead(output, 0, value);
      case CborBytes(:final value):
        _writeHead(output, 2, value.length);
        output.add(value);
      case CborText(:final value):
        final encoded = utf8.encode(value);
        _writeHead(output, 3, encoded.length);
        output.add(encoded);
      case CborArray(:final items):
        _writeHead(output, 4, items.length);
        for (final item in items) {
          _write(output, item);
        }
      case CborMap(:final entries):
        final keys = entries.keys.toList()..sort();
        _writeHead(output, 5, keys.length);
        for (final key in keys) {
          _writeHead(output, 0, key);
          _write(output, entries[key]!);
        }
      case CborBool(:final value):
        output.addByte(value ? 0xf5 : 0xf4);
    }
  }

  static void _writeHead(BytesBuilder output, int major, int argument) {
    final type = major << 5;
    if (argument < 24) {
      output.addByte(type | argument);
    } else if (argument <= 0xff) {
      output
        ..addByte(type | 24)
        ..addByte(argument);
    } else if (argument <= 0xffff) {
      output
        ..addByte(type | 25)
        ..add([argument >> 8, argument & 0xff]);
    } else if (argument <= 0xffffffff) {
      output
        ..addByte(type | 26)
        ..add([
          (argument >> 24) & 0xff,
          (argument >> 16) & 0xff,
          (argument >> 8) & 0xff,
          argument & 0xff,
        ]);
    } else {
      final wide = ByteData(8)..setUint64(0, argument);
      output
        ..addByte(type | 27)
        ..add(wide.buffer.asUint8List());
    }
  }
}

final class _CborReader {
  _CborReader(this._bytes, this._maximumNesting);

  final Uint8List _bytes;
  final int _maximumNesting;
  int _offset = 0;

  bool get atEnd => _offset == _bytes.length;

  int get _remaining => _bytes.length - _offset;

  CborValue read(int nesting) {
    final initial = _byte();
    final major = initial >> 5;
    final information = initial & 0x1f;
    switch (major) {
      case 0:
        return CborUnsigned(_argument(information));
      case 2:
        return CborBytes(_take(_argument(information)));
      case 3:
        final encoded = _take(_argument(information));
        try {
          return CborText(utf8.decode(encoded));
        } on FormatException {
          throw const CborFormatException();
        }
      case 4:
        final count = _argument(information);
        if (nesting >= _maximumNesting || count > _remaining) {
          throw const CborFormatException();
        }
        return CborArray([
          for (var index = 0; index < count; index += 1) read(nesting + 1),
        ]);
      case 5:
        final count = _argument(information);
        if (nesting >= _maximumNesting || count > _remaining ~/ 2) {
          throw const CborFormatException();
        }
        final entries = <int, CborValue>{};
        int? previous;
        for (var index = 0; index < count; index += 1) {
          final key = _key();
          if (previous != null && key <= previous) {
            throw const CborFormatException();
          }
          previous = key;
          entries[key] = read(nesting + 1);
        }
        return CborMap(entries);
      case 7:
        return switch (information) {
          20 => const CborBool(false),
          21 => const CborBool(true),
          _ => throw const CborFormatException(),
        };
      default:
        // Negative integers and tags are outside the subset.
        throw const CborFormatException();
    }
  }

  int _key() {
    final initial = _byte();
    if (initial >> 5 != 0) {
      throw const CborFormatException();
    }
    return _argument(initial & 0x1f);
  }

  /// The argument in its shortest form, and nothing longer. Indefinite lengths
  /// and the reserved values are refused, as is anything wider than a Dart
  /// integer holds.
  int _argument(int information) {
    if (information < 24) {
      return information;
    }
    switch (information) {
      case 24:
        final value = _byte();
        if (value < 24) {
          throw const CborFormatException();
        }
        return value;
      case 25:
        final value = _unsigned(2);
        if (value <= 0xff) {
          throw const CborFormatException();
        }
        return value;
      case 26:
        final value = _unsigned(4);
        if (value <= 0xffff) {
          throw const CborFormatException();
        }
        return value;
      case 27:
        final high = _unsigned(4);
        final low = _unsigned(4);
        if (high == 0 || high > 0x7fffffff) {
          throw const CborFormatException();
        }
        return (high << 32) | low;
      default:
        throw const CborFormatException();
    }
  }

  int _unsigned(int width) {
    var value = 0;
    for (var index = 0; index < width; index += 1) {
      value = (value << 8) | _byte();
    }
    return value;
  }

  int _byte() {
    if (atEnd) {
      throw const CborFormatException();
    }
    return _bytes[_offset++];
  }

  Uint8List _take(int length) {
    if (length > _remaining) {
      throw const CborFormatException();
    }
    final taken = Uint8List.fromList(
      Uint8List.sublistView(_bytes, _offset, _offset + length),
    );
    _offset += length;
    return taken;
  }
}

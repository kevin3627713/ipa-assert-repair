import 'dart:convert';
import 'dart:typed_data';
import 'package:xml/xml.dart';
import 'macho.dart';

/// Read only: the original plist bytes are never serialized or changed.
Map<String, String> plistStrings(Uint8List bytes) {
  if (bytes.length >= 8 &&
      ascii.decode(bytes.sublist(0, 8), allowInvalid: true) == 'bplist00') {
    return _BinaryPlist(bytes).strings();
  }
  try {
    final root = XmlDocument.parse(
      utf8.decode(bytes),
    ).getElement('plist')?.getElement('dict');
    if (root == null) throw const RepairException('Info.plist 不是有效字典。');
    final children = root.childElements.toList();
    final values = <String, String>{};
    for (var i = 0; i + 1 < children.length; i += 2) {
      if (children[i].name.local == 'key' &&
          children[i + 1].name.local == 'string') {
        values[children[i].innerText] = children[i + 1].innerText;
      }
    }
    return values;
  } catch (error) {
    throw RepairException('无法读取 XML Info.plist：$error');
  }
}

class _BinaryPlist {
  _BinaryPlist(this.bytes) : view = ByteData.sublistView(bytes) {
    if (bytes.length < 40) throw const RepairException('二进制 plist 不完整。');
    final trailer = bytes.length - 32;
    offsetSize = bytes[trailer + 6];
    refSize = bytes[trailer + 7];
    count = integer(trailer + 8, 8);
    root = integer(trailer + 16, 8);
    table = integer(trailer + 24, 8);
    if (offsetSize < 1 ||
        offsetSize > 8 ||
        refSize < 1 ||
        refSize > 8 ||
        count < 1 ||
        count > 100000 ||
        root >= count ||
        table < 8 ||
        table + count * offsetSize > trailer) {
      throw const RepairException('二进制 plist 索引无效。');
    }
  }
  final Uint8List bytes;
  final ByteData view;
  late final int offsetSize, refSize, count, root, table;
  int integer(int at, int size) {
    if (at < 0 || size < 1 || size > 8 || at + size > bytes.length) {
      throw const RepairException('plist 字段越界。');
    }
    var value = 0;
    for (var i = 0; i < size; i++) {
      value = (value << 8) | bytes[at + i];
    }
    if (value < 0) throw const RepairException('plist 字段过大。');
    return value;
  }

  int object(int reference) {
    if (reference < 0 || reference >= count) {
      throw const RepairException('plist 引用无效。');
    }
    final at = integer(table + reference * offsetSize, offsetSize);
    if (at < 8 || at >= table) throw const RepairException('plist 对象偏移无效。');
    return at;
  }

  (int, int) length(int at) {
    final small = bytes[at] & 15;
    if (small < 15) return (small, at + 1);
    if (at + 1 >= table || bytes[at + 1] >> 4 != 1) {
      throw const RepairException('plist 长度编码无效。');
    }
    final size = 1 << (bytes[at + 1] & 15);
    return (integer(at + 2, size), at + 2 + size);
  }

  String? string(int reference) {
    final at = object(reference), type = bytes[at] >> 4;
    if (type != 5 && type != 6 && type != 7) return null;
    final (count, start) = length(at);
    if (count < 0 || start + count * (type == 6 ? 2 : 1) > table) {
      throw const RepairException('plist 字符串越界。');
    }
    if (type != 6) return utf8.decode(bytes.sublist(start, start + count));
    return String.fromCharCodes(
      List.generate(count, (i) => view.getUint16(start + i * 2, Endian.big)),
    );
  }

  Map<String, String> strings() {
    final at = object(root);
    if (bytes[at] >> 4 != 13) throw const RepairException('plist 根对象不是字典。');
    final (size, start) = length(at);
    if (start + size * refSize * 2 > table) {
      throw const RepairException('plist 字典越界。');
    }
    final result = <String, String>{};
    for (var i = 0; i < size; i++) {
      final key = string(integer(start + i * refSize, refSize));
      final value = string(integer(start + (size + i) * refSize, refSize));
      if (key != null && value != null) result[key] = value;
    }
    return result;
  }
}

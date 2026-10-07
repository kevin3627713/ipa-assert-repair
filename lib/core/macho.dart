import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

class RepairException implements Exception {
  const RepairException(this.message);
  final String message;
  @override
  String toString() => message;
}

class BinaryRepair {
  const BinaryRepair(this.bytes, this.slices, this.changed);
  final Uint8List bytes;
  final List<Map<String, Object?>> slices;
  final bool changed;
}

int _align(int value, int alignment) =>
    (value + alignment - 1) ~/ alignment * alignment;

class _Reader {
  _Reader(this.bytes, this.endian) : view = ByteData.sublistView(bytes);
  final Uint8List bytes;
  final Endian endian;
  final ByteData view;
  void range(int offset, int size) {
    if (offset < 0 || size < 0 || offset > bytes.length - size) {
      throw const RepairException('Mach-O 字段超出文件边界，无法安全修复。');
    }
  }

  int u32(int offset) {
    range(offset, 4);
    return view.getUint32(offset, endian);
  }

  int u64(int offset) {
    range(offset, 8);
    final value = view.getUint64(offset, endian);
    if (value < 0) throw const RepairException('不支持超过 2⁶³ 的文件偏移。');
    return value;
  }

  String name(int offset) {
    range(offset, 16);
    return ascii.decode(
      bytes
          .sublist(offset, offset + 16)
          .takeWhile((value) => value != 0)
          .toList(),
    );
  }
}

class _Slice {
  _Slice(this.bytes, {required this.inFat}) {
    final magic = ByteData.sublistView(bytes).getUint32(0, Endian.big);
    bits64 = magic == 0xcffaedfe || magic == 0xfeedfacf;
    endian = magic == 0xcffaedfe || magic == 0xcefaedfe
        ? Endian.little
        : Endian.big;
    r = _Reader(bytes, endian);
    headerSize = bits64 ? 32 : 28;
    r.range(0, headerSize);
    cpu = r.u32(4);
    fileType = r.u32(12);
    ncmds = r.u32(16);
    commandSize = r.u32(20);
    commandEnd = headerSize + commandSize;
    r.range(headerSize, commandSize);
    if (ncmds > commandSize ~/ 8) {
      throw const RepairException('Mach-O 加载命令数量无效。');
    }
    firstData = bytes.length;
    var cursor = headerSize;
    for (var index = 0; index < ncmds; index++) {
      r.range(cursor, 8);
      final cmd = r.u32(cursor);
      final size = r.u32(cursor + 4);
      if (size < 8 || size % 4 != 0 || cursor + size > commandEnd) {
        throw const RepairException('Mach-O 加载命令长度无效。');
      }
      if (cmd == 0x2) {
        if (size != 24 || symbolEnd != null) {
          throw const RepairException('符号表命令无效或重复。');
        }
        symbolEnd = r.u32(cursor + 16) + r.u32(cursor + 20);
        if (symbolEnd == 0) symbolEnd = null;
        _referenced(r.u32(cursor + 8), r.u32(cursor + 12) * (bits64 ? 16 : 12));
        _referenced(r.u32(cursor + 16), r.u32(cursor + 20));
      } else if (cmd == 0x1d) {
        if (size != 16 || signatureOffset != null) {
          throw const RepairException('签名命令无效或重复。');
        }
        signatureOffset = r.u32(cursor + 8);
        signatureSize = r.u32(cursor + 12);
        r.range(signatureOffset!, signatureSize!);
      } else if (cmd == 0x1 || cmd == 0x19) {
        final is64 = cmd == 0x19;
        final minimum = is64 ? 72 : 56;
        if (size < minimum) throw const RepairException('段命令不完整。');
        final segmentName = r.name(cursor + 8);
        final offset = is64 ? r.u64(cursor + 40) : r.u32(cursor + 32);
        final length = is64 ? r.u64(cursor + 48) : r.u32(cursor + 36);
        r.range(offset, length);
        if (segmentName == '__LINKEDIT') {
          if (linkedit != null) throw const RepairException('__LINKEDIT 重复。');
          linkedit = cursor;
          linkedit64 = is64;
          linkeditOffset = offset;
          linkeditSize = length;
        } else {
          _referenced(offset, length);
        }
        final prot = r.u32(cursor + (is64 ? 60 : 44));
        if (prot & 4 != 0 && length > 0) {
          executableStart = math.min(executableStart, offset);
          executableEnd = math.max(executableEnd, offset + length);
        }
        final sections = r.u32(cursor + (is64 ? 64 : 48));
        final sectionSize = is64 ? 80 : 68;
        if (sections > (size - minimum) ~/ sectionSize) {
          throw const RepairException('段内 section 数量无效。');
        }
        for (var s = 0; s < sections; s++) {
          final section = cursor + minimum + s * sectionSize;
          final sectionOffset = r.u32(section + (is64 ? 48 : 40));
          final sectionLength = is64
              ? r.u64(section + 40)
              : r.u32(section + 36);
          final type = r.u32(section + (is64 ? 64 : 56)) & 0xff;
          if (type != 1 && type != 0xc && type != 0x12 && sectionLength > 0) {
            _referenced(sectionOffset, sectionLength);
          }
        }
      } else if (cmd == 0x22 || cmd == 0x80000022) {
        if (size < 48) throw const RepairException('dyld 命令不完整。');
        for (var p = 8; p < 48; p += 8) {
          _referenced(r.u32(cursor + p), r.u32(cursor + p + 4));
        }
      } else if (const {
        0x1e,
        0x26,
        0x29,
        0x2b,
        0x2e,
        0x80000033,
        0x80000034,
        0x36,
        0x37,
        0x38,
      }.contains(cmd)) {
        if (size < 16) throw const RepairException('LINKEDIT 数据命令不完整。');
        _referenced(r.u32(cursor + 8), r.u32(cursor + 12));
      } else if (cmd == 0xb) {
        if (size < 80) throw const RepairException('动态符号表命令不完整。');
        for (final pair in <(int, int)>[
          (32, 8),
          (40, bits64 ? 56 : 52),
          (48, 4),
          (56, 4),
          (64, 8),
          (72, 8),
        ]) {
          _referenced(
            r.u32(cursor + pair.$1),
            r.u32(cursor + pair.$1 + 4) * pair.$2,
          );
        }
      } else if (cmd == 0x21 || cmd == 0x2c) {
        if (size < 20) throw const RepairException('加密信息命令不完整。');
        if (r.u32(cursor + 16) != 0) {
          throw const RepairException('检测到加密的 Mach-O；本工具不能解密 App Store 安装包。');
        }
      } else if (cmd == 0x31) {
        if (size < 40) throw const RepairException('LC_NOTE 不完整。');
        _referenced(r.u64(cursor + 24), r.u64(cursor + 32));
      }
      cursor += size;
    }
    if (cursor != commandEnd) {
      throw const RepairException('加载命令总长度与头部不一致。');
    }
  }

  final Uint8List bytes;
  final bool inFat;
  late final bool bits64;
  late final Endian endian;
  late final _Reader r;
  late final int headerSize, cpu, fileType, ncmds, commandSize, commandEnd;
  late int firstData;
  int referencedEnd = 0;
  int? symbolEnd, signatureOffset, signatureSize, linkedit;
  bool linkedit64 = false;
  int linkeditOffset = 0, linkeditSize = 0;
  int executableStart = 0x7fffffffffffffff, executableEnd = 0;

  void _referenced(int offset, int length) {
    if (length == 0) return;
    r.range(offset, length);
    if (offset > 0) firstData = math.min(firstData, offset);
    referencedEnd = math.max(referencedEnd, offset + length);
  }

  int get boundary =>
      signatureOffset ?? (bytes.length + (inFat ? 0 : 16 - bytes.length % 16));
  int? get gap => symbolEnd == null ? null : boundary - symbolEnd!;
  bool get passes => gap == null || (gap! >= 0 && gap! <= 16);

  Map<String, Object?> report({int? previousGap, bool changed = false}) => {
    'cpuType': cpu,
    'bits': bits64 ? 64 : 32,
    'inFat': inFat,
    'stringTableEnd': symbolEnd,
    'signingBoundary': boundary,
    'gapBytes': gap,
    'previousGapBytes': previousGap ?? gap,
    'hasSignature': signatureOffset != null,
    'passesLegacyAssert': passes,
    'changed': changed,
  };

  Uint8List sign(String identifier) {
    if (signatureOffset != null) {
      throw const RepairException('异常二进制已经有签名；为保留原权限，本版本不重写它。');
    }
    final end = symbolEnd;
    if (end == null ||
        linkedit == null ||
        end < commandEnd ||
        end > bytes.length ||
        end < referencedEnd ||
        linkeditOffset + linkeditSize != bytes.length) {
      throw const RepairException('尾部包含其他数据或布局不符合此类问题，无法安全修复。');
    }
    if (bytes.skip(end).any((value) => value != 0)) {
      throw const RepairException('字符串表后存在非零数据，无法安全修复。');
    }
    if (commandEnd + 16 > firstData ||
        commandEnd + 16 > end ||
        bytes.sublist(commandEnd, commandEnd + 16).any((value) => value != 0)) {
      throw const RepairException('Mach-O 头部没有足够空位添加签名命令。');
    }
    if (identifier.isEmpty || identifier.contains('\x00')) {
      throw const RepairException('框架标识符无效。');
    }
    final signatureAt = _align(end, 16);
    final slots = (signatureAt + 4095) ~/ 4096;
    final id = utf8.encode(identifier);
    final hashAt = 88 + id.length + 1;
    final cdLength = hashAt + slots * 32;
    final blobLength = 20 + cdLength;
    final allocated = _align(blobLength, 16);
    final output = Uint8List(signatureAt + allocated)..setRange(0, end, bytes);
    final view = ByteData.sublistView(output);
    void word(int offset, int value) => view.setUint32(offset, value, endian);
    word(16, ncmds + 1);
    word(20, commandSize + 16);
    word(commandEnd, 0x1d);
    word(commandEnd + 4, 16);
    word(commandEnd + 8, signatureAt);
    word(commandEnd + 12, allocated);
    final newLinkSize = output.length - linkeditOffset;
    final vmAlignment = cpu == 7 || cpu == 0x1000007 ? 4096 : 16384;
    if (linkedit64) {
      view.setUint64(linkedit! + 48, newLinkSize, endian);
      view.setUint64(linkedit! + 32, _align(newLinkSize, vmAlignment), endian);
    } else {
      word(linkedit! + 36, newLinkSize);
      word(linkedit! + 28, _align(newLinkSize, vmAlignment));
    }
    void big(int offset, int value) =>
        view.setUint32(offset, value, Endian.big);
    big(signatureAt, 0xfade0cc0);
    big(signatureAt + 4, blobLength);
    big(signatureAt + 8, 1);
    big(signatureAt + 12, 0);
    big(signatureAt + 16, 20);
    final cd = signatureAt + 20;
    big(cd, 0xfade0c02);
    big(cd + 4, cdLength);
    big(cd + 8, 0x20400);
    big(cd + 12, 2);
    big(cd + 16, hashAt);
    big(cd + 20, 88);
    big(cd + 24, 0);
    big(cd + 28, slots);
    big(cd + 32, signatureAt);
    output[cd + 36] = 32;
    output[cd + 37] = 2;
    output[cd + 39] = 12;
    if (executableEnd > 0) {
      view.setUint64(cd + 64, executableStart, Endian.big);
      view.setUint64(cd + 72, executableEnd - executableStart, Endian.big);
    }
    view.setUint64(cd + 80, fileType == 2 ? 1 : 0, Endian.big);
    output.setRange(cd + 88, cd + 88 + id.length, id);
    for (var slot = 0; slot < slots; slot++) {
      final start = slot * 4096;
      final digest = sha256
          .convert(
            Uint8List.sublistView(
              output,
              start,
              math.min(start + 4096, signatureAt),
            ),
          )
          .bytes;
      output.setRange(
        cd + hashAt + slot * 32,
        cd + hashAt + (slot + 1) * 32,
        digest,
      );
    }
    final checked = _Slice(output, inFat: inFat);
    if (!checked.passes || !_equal(bytes, output, commandEnd + 16, end)) {
      throw const RepairException('修复后的边界或代码一致性验证失败。');
    }
    return output;
  }
}

bool _equal(Uint8List left, Uint8List right, int start, int end) {
  for (var i = start; i < end; i++) {
    if (left[i] != right[i]) return false;
  }
  return true;
}

/// Returns null for non Mach-O files. FAT32 supports all declared slices;
/// FAT64 is rejected because the targeted legacy ldid cannot parse it.
BinaryRepair? repairMachO(
  Uint8List bytes,
  String identifier, {
  bool repair = true,
}) {
  if (bytes.length < 4) return null;
  final magic = ByteData.sublistView(bytes).getUint32(0, Endian.big);
  const thin = {0xcffaedfe, 0xcefaedfe, 0xfeedfacf, 0xfeedface};
  if (thin.contains(magic)) {
    final slice = _Slice(bytes, inFat: false);
    if (slice.passes) return BinaryRepair(bytes, [slice.report()], false);
    if (!repair) return BinaryRepair(bytes, [slice.report()], false);
    final output = slice.sign(identifier);
    return BinaryRepair(output, [
      _Slice(
        output,
        inFat: false,
      ).report(previousGap: slice.gap, changed: true),
    ], true);
  }
  if (magic == 0xcafebabf || magic == 0xbfbafeca) {
    throw const RepairException('FAT64 不受目标旧版 ldid 支持，本工具不导出此布局。');
  }
  if (magic != 0xcafebabe && magic != 0xbebafeca) return null;
  final r = _Reader(bytes, magic == 0xcafebabe ? Endian.big : Endian.little);
  final count = r.u32(4);
  if (count < 1 || count > 32) throw const RepairException('FAT 架构数量无效。');
  r.range(8, count * 20);
  final pieces = <Uint8List>[];
  final rows = <Map<String, Object?>>[];
  var changed = false;
  var priorEnd = 8 + count * 20;
  for (var i = 0; i < count; i++) {
    final at = 8 + i * 20;
    final offset = r.u32(at + 8),
        length = r.u32(at + 12),
        alignment = r.u32(at + 16);
    if (alignment > 24 || offset < priorEnd || offset % (1 << alignment) != 0) {
      throw const RepairException('FAT 切片重叠或对齐无效。');
    }
    r.range(offset, length);
    final part = Uint8List.sublistView(bytes, offset, offset + length);
    if (part.length < 4 ||
        !thin.contains(ByteData.sublistView(part).getUint32(0, Endian.big))) {
      throw const RepairException('FAT 内包含无效的 Mach-O 切片。');
    }
    final slice = _Slice(part, inFat: true);
    if (slice.cpu != r.u32(at) || slice.r.u32(8) != r.u32(at + 4)) {
      throw const RepairException('FAT 架构信息与切片头部不一致。');
    }
    final fixed = !slice.passes && repair ? slice.sign(identifier) : part;
    final didChange = !identical(fixed, part);
    pieces.add(fixed);
    changed |= didChange;
    rows.add(
      _Slice(
        fixed,
        inFat: true,
      ).report(previousGap: slice.gap, changed: didChange),
    );
    priorEnd = offset + length;
  }
  if (!changed) return BinaryRepair(bytes, rows, false);
  final offsets = <int>[];
  var total = 8 + count * 20;
  for (var i = 0; i < count; i++) {
    total = _align(total, 1 << r.u32(8 + i * 20 + 16));
    offsets.add(total);
    total += pieces[i].length;
  }
  final output = Uint8List(total)..setRange(0, 8 + count * 20, bytes);
  final view = ByteData.sublistView(output);
  for (var i = 0; i < count; i++) {
    view.setUint32(8 + i * 20 + 8, offsets[i], r.endian);
    view.setUint32(8 + i * 20 + 12, pieces[i].length, r.endian);
    output.setRange(offsets[i], offsets[i] + pieces[i].length, pieces[i]);
  }
  return BinaryRepair(output, rows, true);
}

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive_io.dart' hide ZLibEncoder;
import 'package:crypto/crypto.dart';

import 'macho.dart';
import 'plist.dart';

typedef RepairProgress = void Function(double fraction, String message);

/// No extracted paths, executable processes, network calls or certificates.
/// ZIP payloads are handled one entry at a time; unchanged compressed streams
/// are copied verbatim, including symlinks. Permissions and DOS times survive.
Map<String, Object?> repairIpa(
  String inputPath,
  String outputPath, {
  RepairProgress? progress,
}) {
  final source = File(inputPath), destination = File(outputPath);
  if (source.absolute.path == destination.absolute.path ||
      destination.existsSync()) {
    throw const RepairException('请选择新的输出文件，原包和已有文件不会被覆盖。');
  }
  if (source.lengthSync() > 512 * 1024 * 1024) {
    throw const RepairException('本版本支持最多 512 MB 的 IPA。');
  }
  final pending = File('$outputPath.partial');
  if (pending.existsSync()) throw const RepairException('输出位置已有临时文件。');
  destination.parent.createSync(recursive: true);
  final input = InputFileStream(inputPath);
  RandomAccessFile? writer;
  try {
    progress?.call(0, '读取 IPA 文件目录');
    final decoder = ZipDecoder();
    decoder.decodeStream(input);
    final entries = decoder.directory.fileHeaders;
    if (entries.isEmpty || entries.length > 50000) {
      throw const RepairException('IPA 的 ZIP 文件目录无效或文件过多。');
    }
    final byName = {for (final entry in entries) entry.filename: entry};
    if (byName.length != entries.length) {
      throw const RepairException('IPA 包含重复路径，无法保证修复后内容一致。');
    }
    var uncompressed = 0;
    for (final entry in entries) {
      final name = entry.filename;
      if (name.startsWith('/') ||
          name.contains('\\') ||
          name.contains('\x00') ||
          name.split('/').contains('..')) {
        throw const RepairException('IPA 中存在异常文件路径。');
      }
      if (entry.generalPurposeBitFlag & 1 != 0 ||
          (entry.compressionMethod != 0 && entry.compressionMethod != 8)) {
        throw const RepairException('不支持加密 ZIP 或非标准 IPA 压缩方式。');
      }
      uncompressed += entry.uncompressedSize;
      if (entry.uncompressedSize > 128 * 1024 * 1024 ||
          entry.compressedSize > 128 * 1024 * 1024 ||
          uncompressed > 2 * 1024 * 1024 * 1024) {
        throw const RepairException('文件过大：单个文件限 128 MB，解压总量限 2 GB。');
      }
    }
    final mainPlists = entries
        .where(
          (entry) => RegExp(
            r'^Payload/[^/]+\.app/Info\.plist$',
          ).hasMatch(entry.filename),
        )
        .toList();
    if (mainPlists.length != 1) {
      throw const RepairException('需要包含一个 Payload/*.app 的标准 IPA。');
    }
    final mainBytes = mainPlists.single.file!.getStream().toUint8List();
    final mainInfo = plistStrings(mainBytes);
    final bundleId = mainInfo['CFBundleIdentifier'];
    if (bundleId == null || bundleId.isEmpty) {
      throw const RepairException('主应用没有 Bundle ID。');
    }
    final expectedHashes = <String, String>{};
    final expectedModes = <String, int>{};
    final changed = <String>[];
    final binaries = <Map<String, Object?>>[];
    final central = <Uint8List>[];
    writer = pending.openSync(mode: FileMode.writeOnly);
    var position = 0;
    for (var index = 0; index < entries.length; index++) {
      final entry = entries[index];
      progress?.call(
        0.05 + index / entries.length * 0.7,
        '检查 ${index + 1}/${entries.length}：${entry.filename.split('/').last}',
      );
      final bytes = entry.file!.getStream().toUint8List();
      if (bytes.length != entry.uncompressedSize ||
          getCrc32(bytes) != entry.crc32) {
        throw RepairException('文件长度或 CRC 校验失败：${entry.filename}');
      }
      var outputBytes = bytes;
      if (bytes.length >= 4 &&
          (entry.externalFileAttributes >> 16 & 0xf000) != 0xa000) {
        var identifier = entry.filename.split('/').last;
        final parent = entry.filename.substring(
          0,
          entry.filename.lastIndexOf('/') + 1,
        );
        final infoEntry = byName['${parent}Info.plist'];
        if (infoEntry != null) {
          identifier =
              plistStrings(
                infoEntry.file!.getStream().toUint8List(),
              )['CFBundleIdentifier'] ??
              identifier;
        }
        BinaryRepair? result;
        try {
          result = repairMachO(bytes, identifier);
        } on RepairException catch (error) {
          throw RepairException('${entry.filename}\n${error.message}');
        }
        if (result != null) {
          outputBytes = result.bytes;
          binaries.add({
            'path': entry.filename,
            'slices': result.slices,
            'changed': result.changed,
          });
          if (result.changed) changed.add(entry.filename);
        }
      }
      expectedHashes[entry.filename] = sha256.convert(outputBytes).toString();
      expectedModes[entry.filename] = entry.externalFileAttributes;
      final compressed = identical(outputBytes, bytes)
          ? entry.file!.getStream(decompress: false).toUint8List()
          : Uint8List.fromList(
              ZLibEncoder(raw: true, level: 6).convert(outputBytes),
            );
      final method = identical(outputBytes, bytes)
          ? entry.compressionMethod
          : 8;
      final filename = utf8.encode(entry.filename);
      final comment = utf8.encode(entry.fileComment);
      final crc = getCrc32(outputBytes);
      final flags = (entry.generalPurposeBitFlag & ~9) | 0x800;
      final local = ByteData(30)
        ..setUint32(0, 0x04034b50, Endian.little)
        ..setUint16(4, 20, Endian.little)
        ..setUint16(6, flags, Endian.little)
        ..setUint16(8, method, Endian.little)
        ..setUint16(10, entry.lastModifiedFileTime, Endian.little)
        ..setUint16(12, entry.lastModifiedFileDate, Endian.little)
        ..setUint32(14, crc, Endian.little)
        ..setUint32(18, compressed.length, Endian.little)
        ..setUint32(22, outputBytes.length, Endian.little)
        ..setUint16(26, filename.length, Endian.little);
      final record = ByteData(46)
        ..setUint32(0, 0x02014b50, Endian.little)
        ..setUint16(4, entry.versionMadeBy, Endian.little)
        ..setUint16(6, 20, Endian.little)
        ..setUint16(8, flags, Endian.little)
        ..setUint16(10, method, Endian.little)
        ..setUint16(12, entry.lastModifiedFileTime, Endian.little)
        ..setUint16(14, entry.lastModifiedFileDate, Endian.little)
        ..setUint32(16, crc, Endian.little)
        ..setUint32(20, compressed.length, Endian.little)
        ..setUint32(24, outputBytes.length, Endian.little)
        ..setUint16(28, filename.length, Endian.little)
        ..setUint16(32, comment.length, Endian.little)
        ..setUint16(36, entry.internalFileAttributes, Endian.little)
        ..setUint32(38, entry.externalFileAttributes, Endian.little)
        ..setUint32(42, position, Endian.little);
      central.add(
        Uint8List.fromList([
          ...record.buffer.asUint8List(),
          ...filename,
          ...comment,
        ]),
      );
      writer.writeFromSync(local.buffer.asUint8List());
      writer.writeFromSync(filename);
      writer.writeFromSync(compressed);
      position += 30 + filename.length + compressed.length;
    }
    if (binaries.isEmpty) throw const RepairException('IPA 中未找到 Mach-O 可执行文件。');
    final centralAt = position;
    for (final record in central) {
      writer.writeFromSync(record);
      position += record.length;
    }
    final zipComment = utf8.encode(decoder.directory.zipFileComment);
    final footer = ByteData(22)
      ..setUint32(0, 0x06054b50, Endian.little)
      ..setUint16(8, entries.length, Endian.little)
      ..setUint16(10, entries.length, Endian.little)
      ..setUint32(12, position - centralAt, Endian.little)
      ..setUint32(16, centralAt, Endian.little)
      ..setUint16(20, zipComment.length, Endian.little);
    writer.writeFromSync(footer.buffer.asUint8List());
    writer.writeFromSync(zipComment);
    writer.flushSync();
    writer.closeSync();
    writer = null;
    input.closeSync();
    progress?.call(0.8, '重新读取输出包，核对所有文件');
    final verifiedInput = InputFileStream(pending.path);
    try {
      final verified = ZipDecoder();
      verified.decodeStream(verifiedInput);
      final checked = verified.directory.fileHeaders;
      if (checked.length != entries.length) {
        throw const RepairException('输出文件数量改变。');
      }
      for (var i = 0; i < checked.length; i++) {
        final entry = checked[i];
        final bytes = entry.file!.getStream().toUint8List();
        if (entry.filename != entries[i].filename ||
            getCrc32(bytes) != entry.crc32 ||
            sha256.convert(bytes).toString() !=
                expectedHashes[entry.filename] ||
            entry.externalFileAttributes != expectedModes[entry.filename] ||
            entry.versionMadeBy != entries[i].versionMadeBy ||
            entry.lastModifiedFileTime != entries[i].lastModifiedFileTime ||
            entry.lastModifiedFileDate != entries[i].lastModifiedFileDate) {
          throw RepairException('输出一致性校验失败：${entry.filename}');
        }
        final result = repairMachO(bytes, '', repair: false);
        if (result != null &&
            result.slices.any((slice) => slice['passesLegacyAssert'] != true)) {
          throw RepairException('输出仍未通过旧版边界检查：${entry.filename}');
        }
        progress?.call(
          0.8 + i / checked.length * 0.19,
          '验证 ${i + 1}/${checked.length}',
        );
      }
    } finally {
      verifiedInput.closeSync();
    }
    pending.renameSync(outputPath);
    final fileCount = entries
        .where((entry) => !entry.filename.endsWith('/'))
        .length;
    final report = <String, Object?>{
      'toolVersion': '1.0.0',
      'inputName': source.uri.pathSegments.last,
      'outputName': destination.uri.pathSegments.last,
      'outputPath': outputPath,
      'appName':
          mainInfo['CFBundleDisplayName'] ?? mainInfo['CFBundleName'] ?? 'App',
      'bundleIdentifier': bundleId,
      'entryCount': entries.length,
      'fileCount': fileCount,
      'machOCount': binaries.length,
      'changedFiles': changed,
      'unchangedFileCount': fileCount - changed.length,
      'allInfoPlistsUnchanged': true,
      'codeAndDataUnchanged': true,
      'allCrcsValid': true,
      'permissionsAndTimestampsPreserved': true,
      'allLegacyAssertionsPass': true,
      'maximumAllowedGapBytes': 16,
      'outputBytes': destination.lengthSync(),
      'binaries': binaries,
      'deviceInstallationTested': false,
    };
    final reportPath = '$outputPath.report.json';
    File(
      reportPath,
    ).writeAsStringSync(const JsonEncoder.withIndent('  ').convert(report));
    report['reportPath'] = reportPath;
    progress?.call(1, changed.isEmpty ? '检查通过，无需修复' : '修复和验证完成');
    return report;
  } finally {
    writer?.closeSync();
    input.closeSync();
    if (pending.existsSync()) pending.deleteSync();
  }
}

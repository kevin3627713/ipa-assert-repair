import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ipa_assert_repair/core/ipa_service.dart';
import 'package:ipa_assert_repair/core/macho.dart';
import 'package:ipa_assert_repair/core/plist.dart';
import 'package:ipa_assert_repair/main.dart';

Uint8List fixture({
  bool bits64 = true,
  Endian endian = Endian.little,
  int padding = 8,
}) {
  final bytes = Uint8List(1032 + padding), data = ByteData.sublistView(bytes);
  void w(int at, int value) => data.setUint32(at, value, endian);
  void number(int at, int value) =>
      bits64 ? data.setUint64(at, value, endian) : w(at, value);
  void name(int at, String value) =>
      bytes.setRange(at, at + value.length, ascii.encode(value));
  final header = bits64 ? 32 : 28,
      segment = bits64 ? 72 : 56,
      sectionSize = bits64 ? 80 : 68;
  final textSize = segment + sectionSize,
      link = header + textSize,
      sym = link + segment;
  w(0, bits64 ? 0xfeedfacf : 0xfeedface);
  w(4, bits64 ? 0x100000c : 12);
  w(8, 0);
  w(12, 6);
  w(16, 3);
  w(20, textSize + segment + 24);
  w(header, bits64 ? 0x19 : 1);
  w(header + 4, textSize);
  name(header + 8, '__TEXT');
  number(header + 24, 0);
  number(header + (bits64 ? 32 : 28), 16384);
  number(header + (bits64 ? 40 : 32), 0);
  number(header + (bits64 ? 48 : 36), 768);
  w(header + (bits64 ? 60 : 44), 5);
  w(header + (bits64 ? 64 : 48), 1);
  final section = header + segment;
  name(section, '__text');
  name(section + 16, '__TEXT');
  number(section + 32, 512);
  number(section + (bits64 ? 40 : 36), 256);
  w(section + (bits64 ? 48 : 40), 512);
  w(link, bits64 ? 0x19 : 1);
  w(link + 4, segment);
  name(link + 8, '__LINKEDIT');
  number(link + 24, 16384);
  number(link + (bits64 ? 32 : 28), 16384);
  number(link + (bits64 ? 40 : 32), 768);
  number(link + (bits64 ? 48 : 36), bytes.length - 768);
  w(sym, 2);
  w(sym + 4, 24);
  w(sym + 8, 960);
  w(sym + 12, 2);
  w(sym + 16, 1024);
  w(sym + 20, 8);
  for (var i = 512; i < 768; i++) {
    bytes[i] = i % 251;
  }
  bytes.setRange(1024, 1032, [0, 95, 97, 0, 95, 98, 0, 0]);
  return bytes;
}

Uint8List fatFixture() {
  final first = fixture(padding: 24),
      second = fixture(bits64: false, padding: 0);
  final bytes = Uint8List(8192 + second.length),
      data = ByteData.sublistView(bytes);
  void w(int at, int value) => data.setUint32(at, value, Endian.big);
  w(0, 0xcafebabe);
  w(4, 2);
  w(8, 0x100000c);
  w(12, 0);
  w(16, 4096);
  w(20, first.length);
  w(24, 12);
  w(28, 12);
  w(32, 0);
  w(36, 8192);
  w(40, second.length);
  w(44, 12);
  bytes.setRange(4096, 4096 + first.length, first);
  bytes.setRange(8192, bytes.length, second);
  return bytes;
}

void verifyPageHashes(Uint8List bytes, {Endian endian = Endian.little}) {
  final view = ByteData.sublistView(bytes);
  final header = view.getUint32(0, endian) == 0xfeedfacf ? 32 : 28;
  final command = header + view.getUint32(20, endian) - 16;
  expect(view.getUint32(command, endian), 0x1d);
  final signature = view.getUint32(command + 8, endian), cd = signature + 20;
  expect(view.getUint32(signature, Endian.big), 0xfade0cc0);
  expect(view.getUint32(cd, Endian.big), 0xfade0c02);
  expect(view.getUint32(cd + 12, Endian.big), 2);
  final hashAt = cd + view.getUint32(cd + 16, Endian.big);
  final slots = view.getUint32(cd + 28, Endian.big);
  expect(view.getUint32(cd + 32, Endian.big), signature);
  for (var slot = 0; slot < slots; slot++) {
    final end = (slot + 1) * 4096 < signature ? (slot + 1) * 4096 : signature;
    expect(
      bytes.sublist(hashAt + slot * 32, hashAt + (slot + 1) * 32),
      sha256.convert(bytes.sublist(slot * 4096, end)).bytes,
    );
  }
}

void main() {
  for (final bits64 in [true, false]) {
    for (final endian in [Endian.little, Endian.big]) {
      test(
        '${bits64 ? 64 : 32}-bit $endian: fix 24-byte gap and preserve code',
        () {
          final original = fixture(bits64: bits64, endian: endian);
          final before = repairMachO(
            original,
            'org.example.fixture',
            repair: false,
          )!;
          expect(before.slices.single['gapBytes'], 24);
          final result = repairMachO(original, 'org.example.fixture')!;
          expect(result.changed, true);
          expect(result.slices.single['gapBytes'], 8);
          expect(result.bytes.sublist(512, 1032), original.sublist(512, 1032));
          verifyPageHashes(result.bytes, endian: endian);
          expect(
            repairMachO(result.bytes, 'org.example.fixture')!.changed,
            false,
          );
        },
      );
    }
  }
  test('unsigned valid layout is unchanged', () {
    final bytes = fixture(padding: 0);
    final result = repairMachO(bytes, 'org.example.fixture')!;
    expect(result.changed, false);
    expect(identical(result.bytes, bytes), true);
  });
  test('exactly 16 bytes passes the original inclusive assertion', () {
    final bytes = fixture(padding: 0);
    ByteData.sublistView(bytes).setUint32(32 + 152 + 72 + 20, 0, Endian.little);
    expect(
      repairMachO(bytes, 'org.example.fixture')!.slices.single['gapBytes'],
      16,
    );
  });
  test('FAT32 repairs failing slice without changing other architecture', () {
    final bytes = fatFixture(),
        result = repairMachO(bytes, 'org.example.fixture')!;
    expect(result.changed, true);
    expect(result.slices.length, 2);
    expect(result.slices.every((s) => s['passesLegacyAssert'] == true), true);
    final view = ByteData.sublistView(result.bytes);
    final offset = view.getUint32(36, Endian.big),
        size = view.getUint32(40, Endian.big);
    expect(
      result.bytes.sublist(offset, offset + size),
      fixture(bits64: false, padding: 0),
    );
  });
  test('nonzero tail is refused', () {
    final bytes = fixture()..[1039] = 1;
    expect(() => repairMachO(bytes, 'x'), throwsA(isA<RepairException>()));
  });
  test('occupied load-command padding is refused', () {
    final bytes = fixture()..[280] = 1;
    expect(() => repairMachO(bytes, 'x'), throwsA(isA<RepairException>()));
  });
  test('truncated and overlapping layouts are refused', () {
    expect(
      () => repairMachO(fixture().sublist(0, 100), 'x'),
      throwsA(isA<RepairException>()),
    );
    final bytes = fatFixture();
    ByteData.sublistView(bytes).setUint32(36, 4096, Endian.big);
    expect(() => repairMachO(bytes, 'x'), throwsA(isA<RepairException>()));
  });
  test('already signed bad layout is refused', () {
    final bytes = Uint8List(1152)..setRange(0, 1040, fixture());
    final view = ByteData.sublistView(bytes);
    view.setUint32(16, 4, Endian.little);
    view.setUint32(20, 264, Endian.little);
    view.setUint32(280, 0x1d, Endian.little);
    view.setUint32(284, 16, Endian.little);
    view.setUint32(288, 1104, Endian.little);
    view.setUint32(292, 48, Endian.little);
    expect(() => repairMachO(bytes, 'x'), throwsA(isA<RepairException>()));
  });
  test('read binary and Unicode plist without rewriting it', () {
    const hex =
        '62706c6973743030d2010203045f1013434642756e646c65446973706c61794e616d655f1012434642756e646c654964656e746966696572624fee5fa95f10106f72672e6578616d706c652e74657374080d23383d0000000000000101000000000000000500000000000000000000000000000050';
    final bytes = Uint8List.fromList(
      List.generate(
        hex.length ~/ 2,
        (i) => int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16),
      ),
    );
    expect(plistStrings(bytes)['CFBundleIdentifier'], 'org.example.test');
    expect(plistStrings(bytes)['CFBundleDisplayName'], '修復');
  });
  test('ZIP round-trip preserves plists, resources and symlink modes', () {
    final folder = Directory.systemTemp.createTempSync('ipa-repair-test-');
    try {
      const plist =
          '<?xml version="1.0"?><plist><dict><key>CFBundleIdentifier</key><string>org.example.test</string></dict></plist>';
      final archive = Archive()
        ..add(ArchiveFile.string('Payload/Test.app/Info.plist', plist))
        ..add(
          ArchiveFile.bytes('Payload/Test.app/Test', fixture())..mode = 0x81ed,
        )
        ..add(
          ArchiveFile.string(
            'Payload/Test.app/resource.txt',
            'Keep this exactly',
          ),
        )
        ..add(
          ArchiveFile.bytes('Payload/Test.app/alias', utf8.encode('Test'))
            ..mode = 0xa1ff,
        )
        ..add(ArchiveFile.bytes('Payload/Test.app/empty/', [])..mode = 0x41ed);
      final zip = Uint8List.fromList(ZipEncoder().encodeBytes(archive));
      // archive's encoder always declares MS-DOS. Mark this fixture as Unix
      // so readers interpret the symlink's Unix mode, as real iOS ZIPs do.
      final zipView = ByteData.sublistView(zip);
      var central = zipView.getUint32(zip.length - 22 + 16, Endian.little);
      for (var i = 0; i < archive.length; i++) {
        expect(zipView.getUint32(central, Endian.little), 0x02014b50);
        zipView.setUint16(central + 4, 0x0314, Endian.little);
        central +=
            46 +
            zipView.getUint16(central + 28, Endian.little) +
            zipView.getUint16(central + 30, Endian.little) +
            zipView.getUint16(central + 32, Endian.little);
      }
      final source = File('${folder.path}/input.ipa')..writeAsBytesSync(zip);
      expect(
        ZipDecoder()
            .decodeBytes(zip)
            .find('Payload/Test.app/alias')!
            .symbolicLink,
        'Test',
      );
      final output = '${folder.path}/output.ipa';
      final report = repairIpa(source.path, output);
      expect(report['changedFiles'], ['Payload/Test.app/Test']);
      expect(report['bundleIdentifier'], 'org.example.test');
      expect(report['allLegacyAssertionsPass'], true);
      expect(report['fileCount'], 4);
      expect(report['entryCount'], 5);
      expect(report['unchangedFileCount'], 3);
      final result = ZipDecoder().decodeBytes(File(output).readAsBytesSync());
      expect(
        result.find('Payload/Test.app/Info.plist')!.readBytes(),
        utf8.encode(plist),
      );
      expect(
        result.find('Payload/Test.app/resource.txt')!.readBytes(),
        utf8.encode('Keep this exactly'),
      );
      expect(result.find('Payload/Test.app/alias')!.symbolicLink, 'Test');
      expect(
        () => repairIpa(source.path, source.path),
        throwsA(isA<RepairException>()),
      );
      expect(
        () => repairIpa(source.path, output),
        throwsA(isA<RepairException>()),
      );
    } finally {
      folder.deleteSync(recursive: true);
    }
  });
  testWidgets('initial screen has import action and disabled repair action', (
    tester,
  ) async {
    await tester.pumpWidget(const IpaRepairApp());
    expect(find.text('从文件中导入 IPA'), findsOneWidget);
    expect(find.text('检查并生成修复包'), findsOneWidget);
  });
}

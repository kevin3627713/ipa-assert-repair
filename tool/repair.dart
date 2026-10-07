import 'dart:convert';
import 'dart:io';
import 'package:ipa_assert_repair/core/ipa_service.dart';

void main(List<String> arguments) {
  if (arguments.length != 2) {
    stderr.writeln('Usage: dart run tool/repair.dart INPUT.ipa NEW_OUTPUT.ipa');
    exitCode = 2;
    return;
  }
  try {
    final report = repairIpa(arguments[0], arguments[1]);
    stdout.writeln(const JsonEncoder.withIndent('  ').convert(report));
  } catch (error) {
    stderr.writeln(error);
    exitCode = 1;
  }
}

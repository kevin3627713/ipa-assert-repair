import 'dart:async';
import 'dart:isolate';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'core/ipa_service.dart';

const _files = MethodChannel('ipa_assert_repair/files');
void main() => runApp(const IpaRepairApp());

void _repairWorker(List<Object?> arguments) {
  final send = arguments[2] as SendPort;
  var lastUpdate = DateTime.fromMillisecondsSinceEpoch(0);
  try {
    final report = repairIpa(
      arguments[0] as String,
      arguments[1] as String,
      progress: (fraction, message) {
        final now = DateTime.now();
        if (fraction == 1 || now.difference(lastUpdate).inMilliseconds > 150) {
          lastUpdate = now;
          send.send({
            'type': 'progress',
            'fraction': fraction,
            'message': message,
          });
        }
      },
    );
    send.send({'type': 'result', 'report': report});
  } catch (error) {
    send.send({'type': 'error', 'message': error.toString()});
  }
}

class IpaRepairApp extends StatelessWidget {
  const IpaRepairApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'IPA 修复',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xff087f75)),
      scaffoldBackgroundColor: const Color(0xfff5f7f7),
    ),
    home: const RepairPage(),
  );
}

class RepairPage extends StatefulWidget {
  const RepairPage({super.key});
  @override
  State<RepairPage> createState() => _RepairPageState();
}

class _RepairPageState extends State<RepairPage> {
  Map<String, dynamic>? _selected;
  Map<String, Object?>? _report;
  bool _busy = false;
  double _fraction = 0;
  String _message = '', _error = '';

  Future<void> _pick() async {
    setState(() {
      _busy = true;
      _error = '';
      _message = '';
    });
    try {
      final selected = await _files.invokeMapMethod<String, dynamic>('pickIpa');
      if (mounted && selected != null) {
        setState(() {
          _selected = selected;
          _report = null;
        });
      }
    } on PlatformException catch (error) {
      if (mounted) setState(() => _error = error.message ?? '无法读取文件');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _repair() async {
    if (_selected == null) return;
    setState(() {
      _busy = true;
      _fraction = 0;
      _error = '';
      _report = null;
      _message = '准备处理';
    });
    final receive = ReceivePort();
    Isolate? worker;
    final done = Completer<Map<String, Object?>>();
    final listener = receive.listen((event) {
      if (event is! Map) {
        if (!done.isCompleted) done.completeError(StateError(event.toString()));
        return;
      }
      if (event['type'] == 'progress' && mounted) {
        setState(() {
          _fraction = event['fraction'] as double;
          _message = event['message'] as String;
        });
      } else if (event['type'] == 'result' && !done.isCompleted) {
        done.complete(Map<String, Object?>.from(event['report'] as Map));
      } else if (event['type'] == 'error' && !done.isCompleted) {
        done.completeError(StateError(event['message'] as String));
      }
    });
    try {
      final folder = await _files.invokeMethod<String>('workspace');
      if (folder == null) throw StateError('无法创建输出目录');
      final name = (_selected!['name'] as String)
          .replaceFirst(RegExp(r'\.ipa$', caseSensitive: false), '')
          .replaceAll(RegExp(r'[/\\\x00]'), '_');
      final output =
          '$folder/$name-sidestore-fixed-${DateTime.now().millisecondsSinceEpoch}.ipa';
      worker = await Isolate.spawn(_repairWorker, [
        _selected!['path'],
        output,
        receive.sendPort,
      ], onError: receive.sendPort);
      final report = await done.future;
      if (mounted) setState(() => _report = report);
    } catch (error) {
      if (mounted) {
        setState(
          () => _error = error.toString().replaceFirst('Bad state: ', ''),
        );
      }
    } finally {
      worker?.kill(priority: Isolate.immediate);
      await listener.cancel();
      receive.close();
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _export(String key) async {
    setState(() {
      _busy = true;
      _error = '';
      _message = '';
    });
    try {
      await _files.invokeMethod<bool>('exportFile', {'path': _report![key]});
    } on PlatformException catch (error) {
      if (mounted) setState(() => _error = error.message ?? '导出失败');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _panel(Widget child) => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(22),
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(22),
      border: Border.all(color: const Color(0xffe2e8e7)),
    ),
    child: child,
  );

  @override
  Widget build(BuildContext context) {
    final changed = (_report?['changedFiles'] as List?) ?? [];
    return Scaffold(
      appBar: AppBar(
        title: const Text('IPA 修复'),
        backgroundColor: const Color(0xfff5f7f7),
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
              children: [
                const Icon(
                  Icons.build_circle_outlined,
                  size: 62,
                  color: Color(0xff087f75),
                ),
                const SizedBox(height: 16),
                const Text(
                  '让旧版 SideStore\n顺利签名',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 28,
                    fontWeight: FontWeight.w700,
                    height: 1.25,
                  ),
                ),
                const SizedBox(height: 12),
                const Text(
                  '修复 ldid 尾部边界报错，保留原 Bundle ID。\n文件只在本机处理。',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Color(0xff627570), height: 1.6),
                ),
                const SizedBox(height: 28),
                _panel(
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Text(
                        '1  选择安装包',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 14),
                      if (_selected != null) ...[
                        Text(
                          _selected!['name'] as String,
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          '${((_selected!['bytes'] as num) / 1048576).toStringAsFixed(1)} MB',
                          style: const TextStyle(color: Color(0xff627570)),
                        ),
                        const SizedBox(height: 14),
                      ],
                      OutlinedButton.icon(
                        onPressed: _busy ? null : _pick,
                        icon: const Icon(Icons.folder_open),
                        label: Text(
                          _selected == null ? '从文件中导入 IPA' : '选择其他 IPA',
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                _panel(
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Text(
                        '2  检查并修复',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 10),
                      const Text(
                        '仅处理能确认的同类二进制布局问题。保留应用代码、资源和配置，生成新的安装包。',
                        style: TextStyle(color: Color(0xff627570), height: 1.6),
                      ),
                      const SizedBox(height: 18),
                      FilledButton.icon(
                        onPressed: _busy || _selected == null ? null : _repair,
                        icon: const Icon(Icons.auto_fix_high),
                        label: const Text('检查并生成修复包'),
                      ),
                      if (_busy && _message.isNotEmpty) ...[
                        const SizedBox(height: 20),
                        LinearProgressIndicator(value: _fraction),
                        const SizedBox(height: 10),
                        Text(_message, style: const TextStyle(fontSize: 12)),
                      ],
                    ],
                  ),
                ),
                if (_error.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  _panel(
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          '未能完成',
                          style: TextStyle(
                            color: Color(0xffa33a32),
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 10),
                        SelectableText(_error),
                      ],
                    ),
                  ),
                ],
                if (_report != null) ...[
                  const SizedBox(height: 16),
                  _panel(
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            const Icon(
                              Icons.check_circle,
                              color: Color(0xff087f75),
                            ),
                            const SizedBox(width: 10),
                            Text(
                              changed.isEmpty ? '检查通过，无需修复' : '修复完成',
                              style: const TextStyle(
                                fontSize: 20,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 14),
                        Text(
                          '${_report!['appName']}',
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                        const SizedBox(height: 4),
                        SelectableText('${_report!['bundleIdentifier']}'),
                        const SizedBox(height: 14),
                        Text(
                          '修改 ${changed.length} 个二进制 · 保留 ${_report!['unchangedFileCount']} 个文件',
                        ),
                        const SizedBox(height: 6),
                        const Text(
                          '原 Bundle ID、Info.plist、代码和数据验证通过。',
                          style: TextStyle(color: Color(0xff627570)),
                        ),
                        const SizedBox(height: 18),
                        Wrap(
                          spacing: 10,
                          runSpacing: 10,
                          children: [
                            FilledButton.icon(
                              onPressed: _busy
                                  ? null
                                  : () => _export('outputPath'),
                              icon: const Icon(Icons.save_alt),
                              label: const Text('保存修复后的 IPA'),
                            ),
                            OutlinedButton(
                              onPressed: _busy
                                  ? null
                                  : () => _export('reportPath'),
                              child: const Text('导出检查报告'),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        const Text(
                          '导出后用 SideStore 安装。输出文件也保存在本应用的 Repairs 文件夹。',
                          style: TextStyle(
                            fontSize: 12,
                            color: Color(0xff627570),
                            height: 1.5,
                          ),
                        ),
                        if (changed.isNotEmpty)
                          ExpansionTile(
                            tilePadding: EdgeInsets.zero,
                            title: const Text('查看修复详情'),
                            children: [
                              for (final binary
                                  in (_report!['binaries'] as List).cast<Map>())
                                if (binary['changed'] == true)
                                  ListTile(
                                    contentPadding: EdgeInsets.zero,
                                    title: Text(
                                      (binary['path'] as String)
                                          .split('/')
                                          .last,
                                    ),
                                    subtitle: Text(
                                      (binary['slices'] as List)
                                          .cast<Map>()
                                          .map(
                                            (s) =>
                                                '${s['previousGapBytes']} → ${s['gapBytes']} 字节（允许 ≤ 16）',
                                          )
                                          .join('\n'),
                                    ),
                                  ),
                            ],
                          ),
                      ],
                    ),
                  ),
                ],
                const SizedBox(height: 24),
                const Text(
                  'IPA 修复 1.0.0 · 离线处理\n本工具不提供安装证书，也不解密加密安装包。',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 12,
                    color: Color(0xff627570),
                    height: 1.6,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

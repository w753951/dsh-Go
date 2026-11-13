import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../common/brief_notice.dart';
import '../theme/app_icons.dart';
import 'settings_widgets.dart';

/// SSH 到手机自己，给 AI 一条能执行命令的通道。
///
/// 越狱机的 sshd 默认就开着（root / alpine），所以这里默认值直接能用；
/// 用户改过密码或端口才需要动它。保存后立刻对下一次工具调用生效，
/// 不需要重启引擎。
class PhoneSshSettings extends StatefulWidget {
  const PhoneSshSettings({super.key});

  @override
  State<PhoneSshSettings> createState() => _PhoneSshSettingsState();
}

class _PhoneSshSettingsState extends State<PhoneSshSettings> {
  static const _defaults = <String, Object>{'host': '127.0.0.1', 'port': 22, 'username': 'root', 'password': 'alpine'};

  final _host = TextEditingController();
  final _port = TextEditingController();
  final _username = TextEditingController();
  final _password = TextEditingController();
  bool _loading = true;
  bool _saving = false;
  bool _obscure = true;
  String? _error;

  /// 引擎的 DSH_HOME：EngineChannel 把 guest 落在
  /// `<容器>/Library/Application Support/runtime/rootfs/root/.dsh`，
  /// runtime 里的 shell 工具读的是同一个目录，两边必须是同一个文件。
  static File get _file {
    final home = Platform.environment['HOME'] ?? '';
    final support = home.isEmpty ? Directory.systemTemp.path : '$home/Library/Application Support';
    return File('$support/runtime/rootfs/root/.dsh/dsh-app/phone-ssh.json');
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _host.dispose();
    _port.dispose();
    _username.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    var host = _defaults['host'] as String;
    var port = '${_defaults['port']}';
    var username = _defaults['username'] as String;
    var password = _defaults['password'] as String;
    try {
      final file = _file;
      if (await file.exists()) {
        final saved = jsonDecode(await file.readAsString());
        if (saved is Map) {
          if (saved['host'] is String && (saved['host'] as String).trim().isNotEmpty) host = saved['host'] as String;
          if (saved['port'] is int) port = '${saved['port']}';
          if (saved['username'] is String && (saved['username'] as String).trim().isNotEmpty) {
            username = saved['username'] as String;
          }
          if (saved['password'] is String && (saved['password'] as String).isNotEmpty) password = saved['password'] as String;
        }
      }
    } catch (_) {
      // 读不到就用默认值：越狱机默认这套是通的。
    }
    if (!mounted) return;
    _host.text = host;
    _port.text = port;
    _username.text = username;
    _password.text = password;
    setState(() => _loading = false);
  }

  Future<void> _save() async {
    final host = _host.text.trim();
    final port = int.tryParse(_port.text.trim());
    final username = _username.text.trim();
    final password = _password.text;
    if (host.isEmpty) {
      setState(() => _error = '主机不能为空。');
      return;
    }
    if (port == null || port < 1 || port > 65535) {
      setState(() => _error = '端口要在 1–65535 之间。');
      return;
    }
    if (username.isEmpty) {
      setState(() => _error = '用户名不能为空。');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final file = _file;
      await file.parent.create(recursive: true);
      await file.writeAsString(
        const JsonEncoder.withIndent('  ').convert({'host': host, 'port': port, 'username': username, 'password': password}),
        flush: true,
      );
      if (!mounted) return;
      HapticFeedback.selectionClick();
      showBriefNotice(context, '已保存，AI 下次执行命令就用这套设置。');
    } catch (error) {
      if (mounted) setState(() => _error = '保存失败：$error');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _reset() async {
    setState(() {
      _host.text = _defaults['host'] as String;
      _port.text = '${_defaults['port']}';
      _username.text = _defaults['username'] as String;
      _password.text = _defaults['password'] as String;
      _error = null;
    });
    await _save();
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return SettingsSection(
        title: 'SSH 通道',
        children: [const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator()))],
      );
    }
    return SettingsSection(
      title: 'SSH 通道',
      children: [
        SettingsTile(
          icon: AppIcons.terminal,
          title: '让 AI 执行命令',
          subtitle: '连手机自己的 sshd。开着的时候 AI 能查进程、看文件、装插件，不用点允许。',
          trailing: _saving
              ? const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2))
              : null,
          chevron: false,
        ),
        _field(controller: _host, label: '主机', hint: '127.0.0.1', keyboard: TextInputType.url),
        _field(controller: _port, label: '端口', hint: '22', keyboard: TextInputType.number),
        _field(controller: _username, label: '用户名', hint: 'root'),
        _passwordField(),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(SettingsMetrics.inset, 4, SettingsMetrics.inset, 8),
            child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error, fontSize: 13)),
          ),
        _actions(),
      ],
    );
  }

  Widget _field({
    required TextEditingController controller,
    required String label,
    required String hint,
    TextInputType? keyboard,
  }) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(SettingsMetrics.inset, 4, SettingsMetrics.inset, 4),
      child: TextField(
        controller: controller,
        keyboardType: keyboard,
        autocorrect: false,
        enableSuggestions: false,
        decoration: InputDecoration(labelText: label, hintText: hint, isDense: true),
      ),
    );
  }

  Widget _passwordField() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(SettingsMetrics.inset, 4, SettingsMetrics.inset, 4),
      child: TextField(
        controller: _password,
        obscureText: _obscure,
        autocorrect: false,
        enableSuggestions: false,
        decoration: InputDecoration(
          labelText: '密码',
          hintText: 'alpine',
          isDense: true,
          suffixIcon: IconButton(
            icon: Icon(_obscure ? AppIcons.showSecret : AppIcons.hideSecret, size: 20),
            onPressed: () => setState(() => _obscure = !_obscure),
          ),
        ),
      ),
    );
  }

  Widget _actions() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(SettingsMetrics.inset, 8, SettingsMetrics.inset, 12),
      child: Row(
        children: [
          FilledButton(
            onPressed: _saving ? null : _save,
            child: const Text('保存'),
          ),
          const SizedBox(width: 12),
          TextButton(
            onPressed: _saving ? null : _reset,
            child: const Text('恢复默认'),
          ),
        ],
      ),
    );
  }
}

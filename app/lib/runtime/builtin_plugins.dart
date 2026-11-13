// 把随 ipa 一起内置的 DSH 插件补进本机引擎的 profile。
//
// 手机端装插件要在引擎里走 npm/pnpm，联网和磁盘都容易失败；这里改成
// 构建期把插件包放进 app bundle，启动时复制进 profile 的 node_modules，
// 再把它加进 profile 包的 `dsh.profile.bundles`。
//
// 引擎的目录约定（见 app/ios/Runner/EngineChannel.swift）：
//   guestRoot = <App>/Library/.../runtime/rootfs
//   home      = guestRoot/root          ← LocalPaths.home 返回的就是这个
//   dshHome   = home/.dsh
//   profiles  = dshHome/profiles/<name>
//
// 边界：
//   - 只处理已经存在 node_modules 的 profile（引擎至少启动过一次）；
//   - 复制是幂等的，目标已在就跳过；
//   - 任何一步失败都只记录，不影响启动。

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'local_paths.dart';

class BuiltinPlugins {
  BuiltinPlugins._();

  /// 内置在 app bundle 里、需要补进 profile 的插件目录名。
  static const List<String> bundled = ['dsh-our-free-model'];

  /// app bundle 里存放内置插件的位置（由 CI 复制进去）。
  static const String bundleFolder = 'builtin-plugins';

  /// 最近一次执行的诊断结果，供设置页展示。
  static String lastResult = '尚未执行';
  static List<String> lastProfiles = const [];
  static List<String> lastSteps = const [];

  static String? get _appDirectory {
    final executable = Platform.resolvedExecutable;
    if (executable.isEmpty) return null;
    return File(executable).parent.path;
  }

  static Future<void> ensure() async {
    final steps = <String>[];
    try {
      await _ensure(steps);
    } catch (error) {
      steps.add('异常: $error');
    }
    lastSteps = steps;
    for (final step in steps) {
      debugPrint('builtin plugins: $step');
    }
    _writeLog(steps);
  }

  /// 把这一次的结果写到 `$DSH_HOME/dsh-app/builtin-plugins.log`。
  ///
  /// 手机上没法看 debugPrint，注入失败时只有这个文件能说明原因。
  static void _writeLog(List<String> steps) {
    try {
      final home = LocalPaths.home;
      if (home.isEmpty) return;
      final file = File('$home/.dsh/dsh-app/builtin-plugins.log');
      file.parent.createSync(recursive: true);
      final stamp = DateTime.now().toIso8601String();
      file.writeAsStringSync(
        '[$stamp] ${lastResult}\n${steps.map((s) => '  - $s').join('\n')}\n',
        mode: FileMode.append,
        flush: true,
      );
    } catch (_) {
      // 日志本身失败不影响注入。
    }
  }

  /// profile 目录由引擎创建；App 先启动时可能还没有，等一会儿再来。
  static bool _profileReady(Directory profiles) {
    if (!profiles.existsSync()) return false;
    for (final entity in profiles.listSync()) {
      if (entity is Directory) return true;
    }
    return false;
  }

  static Future<void> _ensure(List<String> steps) async {
    final app = _appDirectory;
    if (app == null) {
      lastResult = '没有 app 目录';
      steps.add('没有 app 目录');
      return;
    }
    steps.add('app=$app');

    final sourceRoot = Directory('$app/$bundleFolder');
    if (!sourceRoot.existsSync()) {
      lastResult = '包里没有 $bundleFolder';
      steps.add('缺 $bundleFolder');
      return;
    }
    final available = sourceRoot
        .listSync()
        .whereType<Directory>()
        .map((d) => d.path.split('/').last)
        .toList();
    steps.add('包内插件: ${available.join(',')}');

    final home = LocalPaths.home;
    steps.add('home=$home');
    if (home.isEmpty) {
      lastResult = '还没有 home 路径（guestRoot 未就绪）';
      return;
    }

    final profiles = Directory('$home/.dsh/profiles');
    // 引擎首次启动前 profile 还不存在；等它建好再注入，最多等 20 秒。
    // 调用方不 await 这个函数，所以等待不拖慢启动。
    for (var attempt = 0; attempt < 40 && !_profileReady(profiles); attempt++) {
      if (attempt == 0) steps.add('等引擎建 profile: ${profiles.path}');
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
    steps.add('profiles ready=${_profileReady(profiles)}');
    if (!_profileReady(profiles)) {
      lastResult = '引擎还没建 profile（等了 20 秒）';
      return;
    }

    final names = <String>[];
    final seeded = <String>[];
    for (final entity in profiles.listSync()) {
      if (entity is! Directory) continue;
      final name = entity.path.split('/').last;
      // 不要要求 node_modules 预先存在：全新 profile 里它就是没有的，
      // 而我们要做的正是把它建起来。
      names.add(name);
      final modules = Directory('${entity.path}/node_modules');
      if (!modules.existsSync()) {
        steps.add('创建 $name/node_modules');
        modules.createSync(recursive: true);
      }
      for (final plugin in bundled) {
        final source = Directory('${sourceRoot.path}/$plugin');
        if (!source.existsSync()) continue;
        final target = Directory('${modules.path}/$plugin');
        if (!target.existsSync()) {
          steps.add('复制 $plugin → $name');
          await _copy(source, target);
        } else {
          steps.add('$plugin 已在 $name');
        }
        await _register(entity.path, plugin, steps);
        if (!seeded.contains(plugin)) seeded.add(plugin);
      }
    }
    lastProfiles = names;
    if (names.isEmpty) {
      lastResult = 'profiles 下没有任何 profile 目录';
    } else if (seeded.isEmpty) {
      lastResult = '包内缺少插件源目录';
    } else {
      lastResult = '已写入 ${seeded.join(',')} → ${names.join(',')}；重启本机引擎后生效';
    }
  }

  static Future<void> _copy(Directory source, Directory target) async {
    target.createSync(recursive: true);
    for (final entity in source.listSync(recursive: true, followLinks: false)) {
      final relative = entity.path.substring(source.path.length + 1);
      final destination = '${target.path}/$relative';
      if (entity is Directory) {
        Directory(destination).createSync(recursive: true);
      } else if (entity is File) {
        File(destination).parent.createSync(recursive: true);
        entity.copySync(destination);
      }
    }
  }

  /// 在 profile 的 package.json 里登记 bundle。解析失败就原样不动。
  static Future<void> _register(String profile, String name, List<String> steps) async {
    final manifest = File('$profile/package.json');
    if (!manifest.existsSync()) {
      steps.add('$profile 没有 package.json');
      return;
    }
    final text = await manifest.readAsString();
    final Map<String, dynamic> root;
    try {
      final decoded = jsonDecode(text);
      if (decoded is! Map<String, dynamic>) {
        steps.add('package.json 不是对象');
        return;
      }
      root = decoded;
    } catch (error) {
      steps.add('package.json 解析失败: $error');
      return;
    }

    final dshRaw = root['dsh'];
    final Map<String, dynamic> dsh =
        dshRaw is Map<String, dynamic> ? dshRaw : <String, dynamic>{};
    root['dsh'] = dsh;
    final profileRaw = dsh['profile'];
    final Map<String, dynamic> profileSection =
        profileRaw is Map<String, dynamic> ? profileRaw : <String, dynamic>{};
    dsh['profile'] = profileSection;
    final bundlesRaw = profileSection['bundles'];
    final List<dynamic> bundles = bundlesRaw is List ? bundlesRaw : <dynamic>[];
    profileSection['bundles'] = bundles;

    if (bundles.contains(name)) {
      steps.add('$name 已登记在 bundle 列表');
      return;
    }
    bundles.add(name);
    try {
      await manifest.writeAsString(
        const JsonEncoder.withIndent('  ').convert(root),
        flush: true,
      );
      steps.add('已登记 $name 到 ${profile.split('/').last}');
    } catch (error) {
      steps.add('写 package.json 失败: $error');
    }
  }
}

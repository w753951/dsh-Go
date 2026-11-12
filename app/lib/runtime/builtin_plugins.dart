// 把随 ipa 一起内置的 DSH 插件补进本机引擎的 profile。
//
// 手机端装插件要在引擎里走 npm/pnpm，联网和磁盘都容易失败；这里改成
// 构建期把插件包放进 app bundle，启动时复制进 profile 的 node_modules，
// 再把它加进 profile 包的 `dsh.profile.bundles`。
//
// 边界：
//   - 只在 profile 已经存在时动手（引擎至少启动过一次），不替引擎创建 profile；
//   - 复制是幂等的，已存在且完整就跳过；
//   - 任何一步失败都只记录，不影响启动，也不写坏已有的 package.json。

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'local_paths.dart';

class BuiltinPlugins {
  BuiltinPlugins._();

  /// 内置在 app bundle 里、需要补进 profile 的插件目录名。
  static const List<String> bundled = ['dsh-our-free-model'];

  /// app bundle 里存放内置插件的位置（由构建脚本复制进去）。
  static const String bundleFolder = 'builtin-plugins';

  static String? get _appDirectory {
    if (!Platform.isIOS && !Platform.isMacOS) return null;
    final executable = Platform.resolvedExecutable;
    if (executable.isEmpty) return null;
    return File(executable).parent.path;
  }

  static Future<void> ensure() async {
    try {
      await _ensure();
    } catch (error) {
      debugPrint('builtin plugins: skipped ($error)');
    }
  }

  static Future<void> _ensure() async {
    final app = _appDirectory;
    if (app == null) return;
    final sourceRoot = Directory('$app/$bundleFolder');
    if (!sourceRoot.existsSync()) return;

    final home = LocalPaths.home;
    if (home.isEmpty) return;
    final profiles = Directory('$home/.dsh/profiles');
    if (!profiles.existsSync()) return;

    for (final entity in profiles.listSync()) {
      if (entity is! Directory) continue;
      // 只补正常 profile，安全模式用到的 profile 保持原样。
      if (entity.path.endsWith('/safe')) continue;
      final nodeModules = Directory('${entity.path}/node_modules');
      if (!nodeModules.existsSync()) continue;
      for (final name in bundled) {
        final source = Directory('${sourceRoot.path}/$name');
        if (!source.existsSync()) continue;
        final target = Directory('${nodeModules.path}/$name');
        if (!target.existsSync()) {
          await _copy(source, target);
        }
        await _register(entity.path, name);
      }
    }
  }

  static Future<void> _copy(Directory source, Directory target) async {
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
  static Future<void> _register(String profile, String name) async {
    final manifest = File('$profile/package.json');
    if (!manifest.existsSync()) return;
    final text = await manifest.readAsString();
    final Map<String, dynamic> root;
    try {
      final decoded = jsonDecode(text);
      if (decoded is! Map<String, dynamic>) return;
      root = decoded;
    } catch (_) {
      return;
    }
    final dsh = root['dsh'];
    if (dsh is! Map<String, dynamic>) return;
    final profileSection = dsh['profile'];
    if (profileSection is! Map<String, dynamic>) return;
    final bundles = profileSection['bundles'];
    if (bundles is! List) return;
    if (bundles.contains(name)) return;
    bundles.add(name);
    await manifest.writeAsString(const JsonEncoder.withIndent('  ').convert(root));
  }
}

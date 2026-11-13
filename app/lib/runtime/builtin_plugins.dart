// 把随 ipa 一起内置的 DSH 插件补进本机引擎的 profile。
//
// 手机端装插件要在引擎里走 npm/pnpm，联网和磁盘都容易失败；这里改成
// 构建期把插件包放进 app bundle，启动时复制进 profile 的 node_modules，
// 再把它加进 profile 包的 `dsh.profile.bundles`。
//
// 边界：
//   - 只处理已经存在 node_modules 的 profile（引擎至少启动过一次）；
//   - 复制是幂等的，目标已在就跳过；
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

  /// App 可执行文件所在目录，也就是 .app 包本身。
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

  /// 把这次注入看到的东西写成一行结果，供设置页或日志排查。
  /// 返回 null 表示一切正常进了 profile，否则是卡在哪一步。
  static String? lastResult;
  static List<String> lastProfiles = const [];

  static Future<void> _ensure() async {
    final app = _appDirectory;
    if (app == null) {
      lastResult = '没有 app 目录';
      return;
    }
    final sourceRoot = Directory('$app/$bundleFolder');
    if (!sourceRoot.existsSync()) {
      lastResult = '包里没有 $bundleFolder';
      return;
    }
    lastResult = '包内有 $bundleFolder';

    final home = LocalPaths.home;
    if (home.isEmpty) {
      lastResult = '还没有 home 路径';
      return;
    }
    final profiles = Directory('$home/.dsh/profiles');
    if (!profiles.existsSync()) {
      lastResult = '引擎还没建 profile：${profiles.path}';
      return;
    }

    final names = <String>[];
    final seeded = <String>[];
    for (final entity in profiles.listSync()) {
      if (entity is! Directory) continue;
      final nodeModules = Directory('${entity.path}/node_modules');
      if (!nodeModules.existsSync()) continue;
      names.add(entity.path.split('/').last);
      for (final name in bundled) {
        final source = Directory('${sourceRoot.path}/$name');
        if (!source.existsSync()) continue;
        final target = Directory('${nodeModules.path}/$name');
        if (!target.existsSync()) {
          debugPrint('builtin plugins: copying $name into ${entity.path}');
          await _copy(source, target);
        }
        // 每次启动都确保 package.json 里有这一项：用户可能之前自己删掉了。
        await _register(entity.path, name);
        if (!seeded.contains(name)) seeded.add(name);
      }
    }
    lastProfiles = names;
    if (names.isEmpty) {
      lastResult = 'profile 目录下没有带 node_modules 的条目';
    } else if (seeded.isEmpty) {
      lastResult = '已在 profile（${names.join(',')}），但包内没有插件目录';
    } else {
      lastResult = '已注入 ${seeded.join(',')} → ${names.join(',')}';
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
    if (!manifest.existsSync()) {
      debugPrint('builtin plugins: no package.json in $profile');
      return;
    }
    final text = await manifest.readAsString();
    final Map<String, dynamic> root;
    try {
      final decoded = jsonDecode(text);
      if (decoded is! Map<String, dynamic>) return;
      root = decoded;
    } catch (_) {
      return;
    }
    // 有些 profile 的 package.json 还没写 dsh 段，补出来再登记。
    final dsh = root['dsh'] is Map<String, dynamic>
        ? root['dsh'] as Map<String, dynamic>
        : (root['dsh'] = <String, dynamic>{}) as Map<String, dynamic>;
    final profileSection = dsh['profile'] is Map<String, dynamic>
        ? dsh['profile'] as Map<String, dynamic>
        : (dsh['profile'] = <String, dynamic>{}) as Map<String, dynamic>;
    final bundles = profileSection['bundles'] is List
        ? profileSection['bundles'] as List
        : (profileSection['bundles'] = <dynamic>[]) as List;
    if (bundles.contains(name)) return;
    bundles.add(name);
    debugPrint('builtin plugins: registering $name in $profile');
    await manifest.writeAsString(const JsonEncoder.withIndent('  ').convert(root));
  }
}

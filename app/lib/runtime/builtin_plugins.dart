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

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import 'local_paths.dart';

class BuiltinPlugins {
  BuiltinPlugins._();

  /// 内置在 app bundle 里、需要补进 profile 的插件目录名。
  ///
  /// 这些目录由 CI 在打包时放进 App 的 `builtin-plugins/`，首次启动时整份
  /// 复制进 profile 的 node_modules 并登记到 package.json。
  static const List<String> bundled = [
    'dsh-our-free-model',
    // 破甲（purge）：npm 包名是 dsh-purge-community，不是 dsh-purge。
    // CI 的 Bundle dsh-purge 步骤就是按这个目录名打包的
    // （见 .github/workflows/ios-compile.yml：dest=.../dsh-purge-community），
    // 上游 kingcharleslzy-ai/dsh-purge 的 package.json name 也是它。
    // 这里以前写成 'dsh-purge'，源目录永远 existsSync()=false，于是整条
    // 静默跳过：包里有目录、profile 里没有、bundle 也没登记，界面上就是
    // 「dsh-purge 没被加载」。名字必须和 CI 打包目录严格一致。
    // 注意 bin 里的 dsh-purge 只是可执行文件名，不能拿来当目录名。
    'dsh-purge-community',
    // 图像与视频：带 scope 的目录名，源码在 runtime/media/dsh-media，
    // 由 .github/workflows/ios-compile.yml 内置进 Runner.app/builtin-plugins。
    '@ccch1mneyyy/dsh-media',
    // 炒股：源码在 runtime/local-tickflow。首次运行自己建库（data/tickflow.db），
    // 包里只有代码和建表脚本。
    'local-tickflow',
  ];

  /// app bundle 里存放内置插件的位置（由 CI 复制进去）。
  static const String bundleFolder = 'builtin-plugins';

  /// 包内插件源根，`_ensure` 里确定后供改名清理复用。
  static String? _sourceRoot;

  /// 改过目录名的插件：旧名 → 现名。装机升级时要清掉 profile 里的旧残留。
  static const Map<String, String> _renamed = {
    'dsh-purge': 'dsh-purge-community',
  };

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
        '[$stamp] $lastResult\n${steps.map((s) => '  - $s').join('\n')}\n',
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
    _sourceRoot = sourceRoot.path;
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
    final missing = <String>[];
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
      _dropRenamed(entity.path, modules, name, steps);
      for (final plugin in bundled) {
        final source = Directory('${sourceRoot.path}/$plugin');
        // 源目录不在说明 CI 没把它打进包，或者 bundled 与打包目录名脱节。
        // 以前是 continue 静默跳过，结果插件永远装不上还看不出来。
        if (!source.existsSync()) {
          missing.add(plugin);
          steps.add('缺源目录 $bundleFolder/$plugin（CI 没打进包，或 bundled 名字写错）');
          continue;
        }
        final target = Directory('${modules.path}/$plugin');
        // 比内容，不比「目录在不在」：装上新 IPA 后包里的插件已经换版，
        // 只看目录存不存在会永远留着 profile 里第一次装进去的那份，改了什么
        // 都不生效。只覆盖代码文件，config.json / data/ 这些运行时产生的
        // 东西不动，否则用户的自选和 Key 会被每次启动清掉。
        if (!target.existsSync()) {
          steps.add('复制 $plugin → $name');
          await _copy(source, target);
        } else if (await _refresh(source, target, steps, name, plugin)) {
          // 已按包内新版覆盖。
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
      lastResult = '包内缺少插件源目录${missing.isEmpty ? '' : '：${missing.join(',')}'}';
    } else if (missing.isNotEmpty) {
      // 有装上也有缺的：主结果仍报成功，但把缺的写清楚，别让人以为都好了。
      lastResult =
          '已写入 ${seeded.join(',')} → ${names.join(',')}；缺 ${missing.join(',')}；重启本机引擎后生效';
    } else {
      lastResult = '已写入 ${seeded.join(',')} → ${names.join(',')}；重启本机引擎后生效';
    }
  }

  /// 插件改过目录名时，把 profile 里旧名字的残留清掉。
  ///
  /// 破甲从 `dsh-purge` 改成 `dsh-purge-community` 后，老用户 profile 的
  /// node_modules 里会留着一份旧目录，bundle 列表里也留着旧名字；不清掉的话
  /// 引擎可能按旧名去解析，表现为「装了新版还是旧的」。
  static void _dropRenamed(
    String profile,
    Directory modules,
    String name,
    List<String> steps,
  ) {
    for (final entry in _renamed.entries) {
      final legacy = entry.key;
      final current = entry.value;
      if (!bundled.contains(current)) continue;
      final stale = Directory('${modules.path}/$legacy');
      // 只删「旧名在、新名也已经由包里提供」的情况，免得把用户自己
      // 装的旧版删掉却补不回新版。
      if (!stale.existsSync()) continue;
      final source = Directory('${_sourceRoot ?? ''}/$current');
      if (!source.existsSync()) continue;
      try {
        stale.deleteSync(recursive: true);
        steps.add('清理旧目录 $legacy（已改名为 $current）');
      } catch (error) {
        steps.add('清理旧目录 $legacy 失败: $error');
        continue;
      }
      _unregister(profile, legacy, steps);
    }
  }

  /// 把旧名字从 profile 的 bundle 列表里去掉。
  static void _unregister(String profile, String name, List<String> steps) {
    try {
      final manifest = File('$profile/package.json');
      if (!manifest.existsSync()) return;
      final decoded = jsonDecode(manifest.readAsStringSync());
      if (decoded is! Map<String, dynamic>) return;
      final dsh = decoded['dsh'];
      if (dsh is! Map<String, dynamic>) return;
      final section = dsh['profile'];
      if (section is! Map<String, dynamic>) return;
      final bundles = section['bundles'];
      if (bundles is! List || !bundles.contains(name)) return;
      bundles.remove(name);
      section['bundles'] = bundles;
      manifest.writeAsStringSync(
        const JsonEncoder.withIndent('  ').convert(decoded),
        flush: true,
      );
      steps.add('从 bundle 列表移除旧名 $name');
    } catch (error) {
      steps.add('移除旧名 $name 失败: $error');
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

  /// 用包里的新版覆盖 profile 里已存在的那份，只动代码文件。
  ///
  /// 运行时会写进插件目录的东西必须留着：`config.json`（炒股开关、自选）、
  /// `data/`（行情库）、`.apikey`。指纹记在目标目录的 `.builtin-source`，
  /// 与包内源一致就整份跳过，换版则一次全部覆盖。
  ///
  /// 返回 true 表示确实覆盖了。
  static Future<bool> _refresh(
    Directory source,
    Directory target,
    List<String> steps,
    String profile,
    String plugin,
  ) async {
    // 先比整份清单的指纹（路径+长度+内容哈希）：一样就什么都不做。
    // 只比长度会漏掉等长改动，比 mtime 又永远不等（copySync 会刷新它）。
    final stampFile = File('${target.path}/.builtin-source');
    final stamp = _fingerprint(source);
    if (stampFile.existsSync()) {
      try {
        if (stampFile.readAsStringSync().trim() == stamp) return false;
      } catch (_) {
        // 读不了就当没有，走覆盖。
      }
    }
    for (final entity in source.listSync(recursive: true, followLinks: false)) {
      if (entity is! File) continue;
      final relative = entity.path.substring(source.path.length + 1);
      if (_runtimeOwned(relative)) continue;
      final destination = File('${target.path}/$relative');
      destination.parent.createSync(recursive: true);
      entity.copySync(destination.path);
    }
    try {
      stampFile.writeAsStringSync('$stamp\n', flush: true);
    } catch (_) {}
    steps.add('更新 $plugin → $profile');
    return true;
  }

  /// 插件源目录的指纹：每个文件的大小与内容摘要合起来再摘要一次。
  static String _fingerprint(Directory source) {
    final parts = <String>[];
    for (final entity in source.listSync(recursive: true, followLinks: false)) {
      if (entity is! File) continue;
      final relative = entity.path.substring(source.path.length + 1);
      if (_runtimeOwned(relative)) continue;
      final bytes = entity.readAsBytesSync();
      parts.add('$relative:${bytes.length}:${sha256.convert(bytes)}');
    }
    parts.sort();
    return sha256.convert(utf8.encode(parts.join('\n'))).toString();
  }

  /// 插件自己运行时生成的文件，覆盖时一律不动。
  static bool _runtimeOwned(String relative) {
    final name = relative.split('/').first;
    return name == 'data' || name == 'config.json' || name == '.apikey';
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

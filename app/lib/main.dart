import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app.dart';
import 'dev/frame_probe.dart';
import 'diagnostics/app_error_log.dart';
import 'launch/launch_state.dart';
import 'launch/startup_trace.dart';
import 'runtime/builtin_plugins.dart';
import 'runtime/local_paths.dart';
import 'state/locale_state.dart';
import 'ui/common/third_party_licenses.dart';
import 'ui/settings/font_licenses.dart';
import 'ui/theme/theme.dart';

Future<void> main() => runWithFrameProbe(_startApp);

Future<void> _startApp() async {
  if (!frameProbeEnabled) SteadyFrameBinding();
  WidgetsFlutterBinding.ensureInitialized();
  appErrorCapture.install();
  appErrorLog.onRecord = (record) => StartupTrace.error(record.message);
  StartupTrace.mark('main, ${kReleaseMode ? 'release' : (kProfileMode ? 'profile' : 'debug')}');
  // The first frame is already in the chosen language (设置 → 语言), and is the launch
  // window's own picture (启动画面, lib/launch/launch_state.dart).
  await Future.wait([
    StartupTrace.step('language', AppLanguageController.load),
    StartupTrace.step('launch screen', LaunchController.begin, onLate: LaunchController.giveUp),
    StartupTrace.step('paths', LocalPaths.load),
  ]);
  // 把随包内置的插件补进本机引擎 profile。只在 profile 已存在时动手，
  // 失败也不影响启动。
  await StartupTrace.step('builtin plugins', BuiltinPlugins.ensure);
  // MIT / OFL notices must ship with the APK, not just the sources.
  registerThirdPartyLicenses();
  registerFontLicenses();
  // Edge-to-edge with transparent system bars; pages refine the icon brightness
  // through AnnotatedRegion(dshSystemOverlay(...)).
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  SystemChrome.setSystemUIOverlayStyle(dshSystemOverlay(PlatformDispatcher.instance.platformBrightness));
  StartupTrace.mark('runApp');
  runApp(const ProviderScope(child: DshApp()));
  WidgetsBinding.instance.addPostFrameCallback((_) => StartupTrace.mark('first frame'));
}

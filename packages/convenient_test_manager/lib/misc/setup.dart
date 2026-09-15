import 'dart:async';

import 'package:convenient_test_manager/launcher/flutter_worker_process.dart';
import 'package:convenient_test_manager/launcher/launcher_controller.dart';
import 'package:convenient_test_manager/launcher/launcher_preferences.dart';
import 'package:convenient_test_manager/launcher/launcher_session_services.dart';
import 'package:convenient_test_manager/launcher/project_discovery.dart';
import 'package:convenient_test_manager/services/fs_service.dart';
import 'package:convenient_test_manager/services/misc_flutter_service.dart';
import 'package:convenient_test_manager/stores/golden_diff_page_store.dart';
import 'package:convenient_test_manager/stores/highlight_store.dart';
import 'package:convenient_test_manager/stores/home_page_store.dart';
import 'package:convenient_test_manager/stores/video_player_store.dart';
import 'package:convenient_test_manager_dart/misc/setup.dart'
    as convenient_test_manager_dart_setup;
import 'package:convenient_test_manager_dart/services/fs_service.dart';
import 'package:convenient_test_manager_dart/services/misc_dart_service.dart';
import 'package:convenient_test_manager_dart/stores/highlight_store.dart';
import 'package:convenient_test_manager_dart/stores/video_player_store.dart';
import 'package:flutter/widgets.dart';
import 'package:get_it/get_it.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart' as path_provider;

final getIt = GetIt.instance;

Future<void> setup({
  bool registerVmServiceWrapper = true,
  bool startManagerServer = false,
  bool autoConnectVm = false,
  bool initializeLauncher = true,
  bool parseConfigFile = true,
  bool initVLC = true,
}) async {
  if (initializeLauncher) WidgetsFlutterBinding.ensureInitialized();

  await convenient_test_manager_dart_setup.setup(
    registerMiscDartService: false,
    registerFsService: false,
    registerHighlightStoreBase: false,
    registerVideoPlayerStoreBase: false,
    registerVmServiceWrapper: registerVmServiceWrapper,
    startManagerServer: startManagerServer,
    autoConnectVm: autoConnectVm,
    parseConfigFile: parseConfigFile,
  );

  // if (initVLC) DartVLC.initialize(); // #303

  getIt.registerSingleton<VideoPlayerStore>(VideoPlayerStore());
  getIt.registerSingleton<HighlightStore>(HighlightStore());
  getIt.registerSingleton<HomePageStore>(HomePageStore());
  getIt.registerSingleton<GoldenDiffPageStore>(GoldenDiffPageStore());
  getIt.registerSingleton<FsService>(FsServiceFlutter());
  getIt.registerSingleton<MiscFlutterService>(MiscFlutterService());

  getIt.registerSingleton<HighlightStoreBase>(GetIt.I.get<HighlightStore>());
  getIt.registerSingleton<VideoPlayerStoreBase>(
    GetIt.I.get<VideoPlayerStore>(),
  );
  getIt.registerSingleton<MiscDartService>(GetIt.I.get<MiscFlutterService>());

  if (initializeLauncher) {
    final applicationSupportDirectory = await path_provider
        .getApplicationSupportDirectory();
    final launcherDirectory = p.join(
      applicationSupportDirectory.path,
      'launcher',
    );
    final sessionServices = GetItLauncherSessionServices();
    final controller = LauncherController(
      discovery: ProjectDiscovery(),
      preferences: LauncherPreferences(
        filePath: p.join(launcherDirectory, 'configuration.json'),
      ),
      process: FlutterLauncherWorkerProcess(FlutterWorkerProcess()),
      sessionServices: sessionServices,
      reportRootDirectory: p.join(launcherDirectory, 'sessions'),
    );
    getIt.registerSingleton<LauncherSessionServices>(sessionServices);
    getIt.registerSingleton<LauncherController>(controller);
    unawaited(controller.restore());
  }
}

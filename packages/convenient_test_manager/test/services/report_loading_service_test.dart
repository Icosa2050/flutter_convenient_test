import 'dart:async';
import 'dart:io';

import 'package:convenient_test_common_dart/convenient_test_common_dart.dart';
import 'package:convenient_test_manager/services/misc_flutter_service.dart';
import 'package:convenient_test_manager/stores/home_page_store.dart';
import 'package:convenient_test_manager_dart/services/fs_service.dart';
import 'package:convenient_test_manager_dart/services/misc_dart_service.dart';
import 'package:convenient_test_manager_dart/services/report_handler_service.dart';
import 'package:convenient_test_manager_dart/services/report_saver_service.dart';
import 'package:convenient_test_manager_dart/stores/log_store.dart';
import 'package:convenient_test_manager_dart/stores/raw_log_store.dart';
import 'package:convenient_test_manager_dart/stores/suite_info_store.dart';
import 'package:convenient_test_manager_dart/stores/video_recorder_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';

void main() {
  tearDown(() => GetIt.I.reset());

  test('report read cancellation leaves existing stores untouched', () async {
    final readStarted = Completer<void>();
    final readGate = Completer<List<int>>();
    final service = MiscDartService(
      readFileBytes: (_) {
        readStarted.complete();
        return readGate.future;
      },
    );
    _registerReportStores(service);
    final suiteStore = GetIt.I.get<SuiteInfoStore>();
    final existingSuite = SuiteInfo.fromProto(SuiteInfoProto());
    suiteStore.suiteInfo = existingSuite;
    var current = true;

    final read = service.readReportFromFileWithAuthority(
      '/reports/stalled.bin',
      isCurrent: () => current,
    );
    await readStarted.future;
    current = false;
    readGate.complete(
      ReportCollection(
        items: [ReportItem(suiteInfoProto: SuiteInfoProto())],
      ).writeToBuffer(),
    );

    expect(await read, isFalse);
    expect(suiteStore.suiteInfo, same(existingSuite));
  });

  test('report application checks authority after awaited clearing', () async {
    final service = MiscDartService();
    final saver = _BlockingReportSaverService();
    _registerReportStores(service, saver: saver);
    final suiteStore = GetIt.I.get<SuiteInfoStore>();
    suiteStore.suiteInfo = SuiteInfo.fromProto(SuiteInfoProto());
    var current = true;

    final apply = GetIt.I.get<ReportHandlerService>().handle(
      ReportCollection(items: [ReportItem(suiteInfoProto: SuiteInfoProto())]),
      offlineFile: true,
      isCurrent: () => current,
    );
    await saver.clearStarted.future;
    current = false;
    saver.clearGate.complete();
    await apply;

    expect(saver.mutated, isFalse);
    expect(suiteStore.suiteInfo, isNull);
  });

  test('report saver checks authority after awaiting its path', () async {
    final directory = await Directory.systemTemp.createTemp(
      'report-load-authority-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final report = File('${directory.path}/report.$kReportFileExtension')
      ..writeAsStringSync('existing');
    final fs = _BlockingFsService(directory.path);
    GetIt.I.registerSingleton<FsService>(fs);
    var current = true;

    final clear = ManagerReportSaverService().clear(isCurrent: () => current);
    await fs.pathRequested.future;
    current = false;
    fs.pathGate.complete();
    await clear;

    expect(report.existsSync(), isTrue);
  });

  test('report mode changes only after a successful load', () async {
    final homePageStore = HomePageStore();
    GetIt.I.registerSingleton<HomePageStore>(homePageStore);
    final service = _ControlledMiscFlutterService();

    final load = service.pickFileAndReadReportWithAuthority(
      pathOverride: '/reports/valid.bin',
      isCurrent: () => true,
    );
    await service.readStarted.future;
    expect(homePageStore.displayLoadedReportMode, isFalse);

    service.readGate.complete(true);
    expect(await load, isTrue);
    expect(homePageStore.displayLoadedReportMode, isTrue);
  });

  test('report load errors restore the previous report mode', () async {
    final homePageStore = HomePageStore()..displayLoadedReportMode = false;
    GetIt.I.registerSingleton<HomePageStore>(homePageStore);
    final service = _ControlledMiscFlutterService()
      ..readError = const FormatException('malformed report');

    await expectLater(
      service.pickFileAndReadReportWithAuthority(
        pathOverride: '/reports/malformed.bin',
        isCurrent: () => true,
      ),
      throwsFormatException,
    );

    expect(homePageStore.displayLoadedReportMode, isFalse);
  });
}

void _registerReportStores(
  MiscDartService miscService, {
  ManagerReportSaverService? saver,
}) {
  GetIt.I.registerSingleton<LogStore>(LogStore());
  GetIt.I.registerSingleton<SuiteInfoStore>(SuiteInfoStore());
  GetIt.I.registerSingleton<RawLogStore>(RawLogStore());
  GetIt.I.registerSingleton<VideoRecorderStore>(VideoRecorderStore());
  GetIt.I.registerSingleton<MiscDartService>(miscService);
  GetIt.I.registerSingleton<ManagerReportSaverService>(
    saver ?? ManagerReportSaverService(),
  );
  GetIt.I.registerSingleton<ReportHandlerService>(ReportHandlerService());
}

class _BlockingReportSaverService extends ManagerReportSaverService {
  final clearStarted = Completer<void>();
  final clearGate = Completer<void>();
  bool mutated = false;

  @override
  Future<void> clear({bool Function()? isCurrent}) async {
    clearStarted.complete();
    await clearGate.future;
    if (isCurrent?.call() == false) return;
    mutated = true;
  }
}

class _BlockingFsService extends FsService {
  _BlockingFsService(this.path);

  final String path;
  final pathRequested = Completer<void>();
  final pathGate = Completer<void>();

  @override
  Future<String> getActiveSuperRunDataSubDirectory({
    required String category,
  }) async {
    pathRequested.complete();
    await pathGate.future;
    return '$path/';
  }

  @override
  Future<String> getTemporaryDirectory() async => path;
}

class _ControlledMiscFlutterService extends MiscFlutterService {
  final readStarted = Completer<void>();
  final readGate = Completer<bool>();
  Object? readError;

  @override
  Future<bool> readReportFromFileWithAuthority(
    String path, {
    bool sync = false,
    bool doClear = true,
    required bool Function() isCurrent,
  }) {
    readStarted.complete();
    final error = readError;
    if (error != null) return Future<bool>.error(error);
    return readGate.future;
  }
}

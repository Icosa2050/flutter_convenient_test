import 'package:convenient_test_common/convenient_test_common.dart';
import 'package:convenient_test_manager_dart/services/vm_service_wrapper_service.dart';

class FakeVmServiceWrapper extends VmServiceWrapperService {
  bool _connected = true;
  Uri? lastConnectedUri;
  int connectCount = 0;
  int disconnectCount = 0;

  @override
  Future<void> connect({Uri? uri}) async {
    connectCount++;
    lastConnectedUri = uri;
    _connected = true;
  }

  @override
  Future<void> disconnect() async {
    disconnectCount++;
    _connected = false;
  }

  @override
  bool get connected => _connected;

  @override
  bool get hotRestartAvailable => false;

  @override
  Future<void> hotRestartRaw() async {
    Log.d(
      'FakeVMServiceWrapper',
      'user requested hotRestartRaw but doing nothing',
    );
  }

  @override
  void hotRestartThrottled() {
    Log.d(
      'FakeVMServiceWrapper',
      'user requested hotRestartThrottled but doing nothing',
    );
  }

  @override
  bool get hotRestartActing => false;
}

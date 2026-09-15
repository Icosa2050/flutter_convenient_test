abstract class VmServiceWrapperService {
  bool get connected;

  Future<void> connect({Uri? uri});
  Future<void> disconnect();
  bool get hotRestartActing;

  bool get hotRestartAvailable;
  Future<void> hotRestartRaw();

  void hotRestartThrottled();
}

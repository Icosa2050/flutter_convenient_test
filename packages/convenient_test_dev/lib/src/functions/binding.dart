import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

class MyIntegrationTestWidgetsFlutterBinding
    extends IntegrationTestWidgetsFlutterBinding {
  @override
  void handlePointerEvent(PointerEvent event) {
    // A desktop pointer packet can outlive its render view across a hot
    // restart. LiveTestWidgetsFlutterBinding assumes that every device event
    // still has a matching view and uses firstWhere, which throws before the
    // new application view is attached. Ignore only that stale-view packet;
    // current-view device events and all other binding errors remain visible.
    final isStaleDeviceEvent =
        pointerEventSource == TestBindingEventSource.device &&
        !shouldPropagateDevicePointerEvents &&
        deviceEventDispatcher != null &&
        !renderViews.any(
          (renderView) => renderView.flutterView.viewId == event.viewId,
        );
    if (isStaleDeviceEvent) {
      return;
    }

    super.handlePointerEvent(event);
  }
}

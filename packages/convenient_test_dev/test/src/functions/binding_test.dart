import 'package:convenient_test_dev/src/functions/binding.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final binding = MyIntegrationTestWidgetsFlutterBinding();

  test('ignores a device pointer event for a removed render view', () {
    binding.deviceEventDispatcher = _RecordingHitTestDispatcher();

    expect(
      () => binding.handlePointerEvent(
        const PointerHoverEvent(viewId: 0x7fffffff),
      ),
      returnsNormally,
    );
  });

  test('still dispatches a device pointer event for the current view', () {
    final dispatcher = _RecordingHitTestDispatcher();
    binding.deviceEventDispatcher = dispatcher;
    final renderView = RenderView(
      view: binding.platformDispatcher.views.single,
    );
    final owner = PipelineOwner()..rootNode = renderView;
    binding.rootPipelineOwner.adoptChild(owner);
    binding.addRenderView(renderView);
    addTearDown(() {
      binding.removeRenderView(renderView);
      binding.rootPipelineOwner.dropChild(owner);
      owner.rootNode = null;
    });
    renderView.prepareInitialFrame();

    binding.handlePointerEvent(
      PointerHoverEvent(viewId: renderView.flutterView.viewId),
    );

    expect(dispatcher.dispatchCount, 1);
  });
}

final class _RecordingHitTestDispatcher implements HitTestDispatcher {
  var dispatchCount = 0;

  @override
  void dispatchEvent(PointerEvent event, HitTestResult? hitTestResult) {
    dispatchCount += 1;
  }
}

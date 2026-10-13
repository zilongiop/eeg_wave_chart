import 'package:flutter_test/flutter_test.dart';

import 'package:eeg_wave_chart_example/demo_brain_page.dart';
import 'package:eeg_wave_chart_example/main.dart';

/// 推进一步路由转场动画。单次 pump 时新页面仍处在 offstage 状态，
/// 需要再补一帧才可见、可命中点击。
Future<void> _settleRoute(WidgetTester tester) async {
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  testWidgets('首页展示两个入口', (WidgetTester tester) async {
    await tester.pumpWidget(const MyApp());

    expect(find.text('EEG Wave Demo'), findsOneWidget);
    expect(find.text('EEG 时序波形'), findsOneWidget);
    expect(find.text('EEG 脑地形图'), findsOneWidget);
  });

  testWidgets('点击「EEG 时序波形」进入波形页', (WidgetTester tester) async {
    await tester.pumpWidget(const MyApp());

    await tester.tap(find.text('EEG 时序波形'));
    await _settleRoute(tester);

    expect(find.byType(DemoEegPage), findsOneWidget);
    expect(find.text('EEG波形｜10分钟模拟数据'), findsOneWidget);
  });

  testWidgets('点击「EEG 脑地形图」进入地形图页', (WidgetTester tester) async {
    await tester.pumpWidget(const MyApp());

    await tester.tap(find.text('EEG 脑地形图'));
    await _settleRoute(tester);

    expect(find.byType(DemoBrainPage), findsOneWidget);
    expect(find.text('EEG 时序波形 + 脑地形图 Demo'), findsOneWidget);
  });
}

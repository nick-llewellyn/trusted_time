import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:trusted_time/trusted_time.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('TrustedTime initialization test', (WidgetTester tester) async {
    await TrustedTime.initialize();

    final assessment = TrustedTime.getAssessment();
    expect(assessment.isTrusted, isTrue);
    expect(assessment.time, isNotNull);
    expect(assessment.time!.millisecondsSinceEpoch, greaterThan(0));
    expect(assessment.time!.toIso8601String(), contains('T'));
    expect(
      assessment.reason,
      anyOf(TrustStatusReason.synchronized, TrustStatusReason.degraded),
    );
  });
}

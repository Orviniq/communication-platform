import 'package:communication_platform/app/app.dart';
import 'package:communication_platform/app/config/app_environment.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('development app visibly renders production Chats List', (
    tester,
  ) async {
    await tester.pumpWidget(
      const CommunicationPlatformApp(
        environment: AppEnvironment.development,
        locale: Locale('en'),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Development configuration'), findsOneWidget);
    expect(find.text('No chats yet'), findsOneWidget);
    expect(find.text('Not built yet'), findsNothing);
    expect(find.text('Flutter foundation is ready'), findsNothing);
  });

  testWidgets('production shell shows no configuration banner at all', (
    tester,
  ) async {
    await tester.pumpWidget(
      const CommunicationPlatformApp(
        environment: AppEnvironment.production,
        locale: Locale('en'),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Development configuration'), findsNothing);
    // The owner declined an Experimental designation for production when it
    // became a build handed to people (ADR-076 D8).
    expect(find.textContaining('Experimental'), findsNothing);
  });

  testWidgets(
    'Persian localization establishes right-to-left shell direction',
    (tester) async {
      await tester.pumpWidget(
        const CommunicationPlatformApp(
          environment: AppEnvironment.production,
          locale: Locale('fa'),
        ),
      );
      await tester.pumpAndSettle();

      final directionality = tester.widget<Directionality>(
        find.byType(Directionality).first,
      );
      expect(directionality.textDirection, TextDirection.rtl);
      expect(find.text('گفت‌وگوها'), findsWidgets);
      expect(find.text('پیکربندی توسعه'), findsNothing);
      expect(find.textContaining('آزمایشی'), findsNothing);
    },
  );
}

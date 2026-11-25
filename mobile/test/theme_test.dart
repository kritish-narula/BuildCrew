import 'package:buildcrew/core/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('theme uses Mukta with roomy line heights (Devanagari matras)', () {
    final t = buildTheme();
    expect(t.textTheme.bodyLarge!.fontFamily, 'Mukta');
    for (final s in [t.textTheme.bodyLarge, t.textTheme.bodyMedium, t.textTheme.titleLarge, t.textTheme.headlineMedium, t.textTheme.labelLarge]) {
      expect(s!.height!, greaterThanOrEqualTo(1.35));
    }
  });

  test('button heights follow the design system', () {
    final t = buildTheme();
    expect(t.filledButtonTheme.style!.minimumSize!.resolve({})!.height, BC.btn);
    expect(t.outlinedButtonTheme.style!.minimumSize!.resolve({})!.height, BC.btnSm);
    expect(BC.btn, 52);
    expect(BC.btnSm, 48);
    expect(BC.btnXs, 40);
    expect(BC.tap, 56);
  });
}

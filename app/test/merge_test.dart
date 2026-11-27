import 'dart:convert';
import 'dart:io';

import 'package:chit/core/merge.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // the cases chit's internal/merge runs: the two must agree
  final cases = (jsonDecode(File('../internal/merge/testdata/cases.json').readAsStringSync()) as List)
      .cast<Map<String, Object?>>();
  for (final c in cases) {
    test(c['name']! as String, () {
      expect(merge3(c['base']! as String, c['current']! as String, c['mine']! as String), c['want']);
    });
  }
}

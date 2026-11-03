import 'package:flutter_test/flutter_test.dart';
import 'package:karaoke_battle/services/problem_report.dart';

void main() {
  test('pre-fills the bug report form', () {
    final u = problemReportUri(version: '0.6.0', os: 'Windows 11 (Build 22631)', backend: 'CUDA');
    expect(u.toString(), startsWith('https://github.com/Hikari-Tsai/karaoke-battle/issues/new?'));
    expect(u.queryParameters, {'template': 'bug_report.yml', 'version': '0.6.0', 'os': 'Windows 11 (Build 22631)', 'backend': 'CUDA'});
  });

  test('leaves unknown fields out', () {
    expect(problemReportUri(version: '', backend: null).queryParameters, {'template': 'bug_report.yml'});
  });
}

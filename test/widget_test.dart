import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ve_lai_cho_dep/main.dart';
import 'package:ve_lai_cho_dep/models/redraw_result.dart';
import 'package:ve_lai_cho_dep/services/export_service.dart';
import 'package:ve_lai_cho_dep/services/settings_service.dart';

void main() {
  testWidgets('Home screen shows app name and asks for an API key', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final settings = await SettingsService.load();
    await tester.pumpWidget(RedrawApp(settings: settings));
    await tester.pump();
    expect(find.text('Vẽ lại cho đẹp'), findsWidgets);
    expect(find.text('Chưa nhập Anthropic API key'), findsOneWidget);
  });

  test('RedrawResult parses table JSON and pads rows', () {
    final r = RedrawResult.fromJson({
      'kind': 'table',
      'title': 'Lịch học',
      'summary': 'Bảng',
      'svg': '',
      'table': {
        'headers': ['Thứ', 'Môn'],
        'rows': [
          ['2', 'Toán', 'Phòng 1'],
          ['3'],
        ],
      },
      'text': '',
    });
    expect(r.kind, RedrawKind.table);
    expect(r.paddedHeaders, ['Thứ', 'Môn', '']);
    expect(r.paddedRows[1], ['3', '', '']);
  });

  test('Markup parser recognises headings, bullets and numbers', () {
    final lines = parseMarkup('# Tiêu đề\n- ý một\n2. bước hai\n\nĐoạn văn');
    expect(lines.map((l) => l.type), [
      MarkupType.h1,
      MarkupType.bullet,
      MarkupType.numbered,
      MarkupType.blank,
      MarkupType.paragraph,
    ]);
    expect(lines[2].marker, '2.');
  });

  test('CSV export escapes commas and quotes', () {
    final r = RedrawResult(
      kind: RedrawKind.table,
      title: 't',
      summary: '',
      headers: ['a', 'b'],
      rows: [
        ['x,y', 'say "hi"'],
      ],
    );
    final csv = String.fromCharCodes(ExportService.buildCsv(r).skip(3));
    expect(csv, 'a,b\r\n"x,y","say ""hi"""');
  });
}

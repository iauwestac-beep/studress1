// pubspec.yaml:
//   excel: ^4.0.6
//   path_provider: ^2.1.4
//   share_plus: ^10.0.0
//   shamsi_date: ^1.1.1
import 'dart:io';
import 'package:excel/excel.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shamsi_date/shamsi_date.dart';

/// ───────── مدل‌ها ─────────
class Student {
  final String studentNo, nationalId, firstName, lastName, major;
  final int sourceRow; // شماره ردیف در فایل اکسل
  Student(this.studentNo, this.nationalId, this.firstName, this.lastName,
      this.major, this.sourceRow);
  String get key => '$studentNo|$major';
}

class ViolationRow {
  final Student student;
  final DateTime occurredAt; // UTC
  final List<String> checkedItems; // عنوان چک‌باکس‌های تیک‌خورده
  final String note, recordedBy;
  ViolationRow(this.student, this.occurredAt, this.checkedItems, this.note,
      this.recordedBy);
}

class ImportResult {
  final List<Student> toImport; // یکتا، آماده ذخیره در دیتابیس
  final File reportFile; // اکسل گزارش با شیت تکراری‌ها
  final int totalRows, duplicateRows;
  final List<List<String>> duplicates; // برای شیت «تکراری‌ها» روی گوگل‌شیت
  ImportResult(this.toImport, this.reportFile, this.totalRows,
      this.duplicateRows, this.duplicates);
}

/// ───────── ابزارهای کمکی ─────────
String normalize(String s) {
  const fa = '۰۱۲۳۴۵۶۷۸۹', ar = '٠١٢٣٤٥٦٧٨٩';
  var out = s.replaceAll('ي', 'ی').replaceAll('ك', 'ک').replaceAll('\u200c', ' ');
  for (var i = 0; i < 10; i++) {
    out = out.replaceAll(fa[i], '$i').replaceAll(ar[i], '$i');
  }
  return out.replaceAll(RegExp(r'\s+'), ' ').trim();
}

String _cell(List<Data?> row, int i) {
  if (i < 0 || i >= row.length || row[i] == null) return '';
  final v = row[i]!.value;
  if (v == null) return '';
  if (v is TextCellValue) return normalize(v.value.toString());
  if (v is IntCellValue) return v.value.toString();
  if (v is DoubleCellValue) {
    final d = v.value;
    return d == d.truncateToDouble() ? d.toInt().toString() : d.toString();
  }
  return normalize(v.toString());
}

String jalali(DateTime utc) {
  final l = utc.toLocal();
  final j = Jalali.fromDateTime(l);
  String p(int n) => n.toString().padLeft(2, '0');
  return '${j.year}/${p(j.month)}/${p(j.day)}  ${p(l.hour)}:${p(l.minute)}';
}

/// ───────── سرویس اکسل ─────────
class ExcelService {
  /// عنوان ستون‌های فایل اکسل شما (بعد از دیدن فایل واقعی اصلاح شود)
  static const _hStudentNo = ['شماره دانشجویی', 'کد دانشجویی'];
  static const _hNationalId = ['کد ملی', 'شماره ملی'];
  static const _hFirst = ['نام'];
  static const _hLast = ['نام خانوادگی'];
  static const _hMajor = ['رشته'];

  int _col(List<String> header, List<String> names) =>
      header.indexWhere((h) => names.contains(h));

  /// ۱) خواندن فایل آپلودشده، جداکردن تکراری‌ها، ساخت گزارش اکسل
  Future<ImportResult> importStudents(String path) async {
    final excel = Excel.decodeBytes(await File(path).readAsBytes());
    final sheet = excel.tables.values.first;
    final header = sheet.rows.first
        .map((c) => normalize(c?.value?.toString() ?? ''))
        .toList();

    final cNo = _col(header, _hStudentNo);
    final cNid = _col(header, _hNationalId);
    final cFn = _col(header, _hFirst);
    final cLn = _col(header, _hLast);
    final cMj = _col(header, _hMajor);
    if (cNo < 0) throw Exception('ستون شماره دانشجویی پیدا نشد');

    final all = <Student>[];
    for (var r = 1; r < sheet.rows.length; r++) {
      final row = sheet.rows[r];
      final no = _cell(row, cNo);
      if (no.isEmpty) continue;
      all.add(Student(no, _cell(row, cNid), _cell(row, cFn), _cell(row, cLn),
          _cell(row, cMj), r + 1));
    }

    // گروه‌بندی بر اساس شماره دانشجویی
    final byNo = <String, List<Student>>{};
    for (final s in all) {
      byNo.putIfAbsent(s.studentNo, () => []).add(s);
    }

    final unique = <String, Student>{}; // کلید: شماره + رشته
    final dupRows = <List<CellValue>>[];
    final dupText = <List<String>>[];

    byNo.forEach((no, group) {
      if (group.length == 1) {
        unique[group.first.key] = group.first;
        return;
      }
      final seenKeys = <String>{};
      for (final s in group) {
        final exact = !seenKeys.add(s.key);
        dupRows.add([
          TextCellValue(no),
          TextCellValue(s.nationalId),
          TextCellValue(s.firstName),
          TextCellValue(s.lastName),
          TextCellValue(s.major),
          IntCellValue(s.sourceRow),
          TextCellValue(exact ? 'ردیف کاملاً تکراری (وارد نشد)' : 'رشته متفاوت (وارد شد)'),
        ]);
        dupText.add([
          no, s.nationalId, s.firstName, s.lastName, s.major, '${s.sourceRow}',
          exact ? 'ردیف کاملاً تکراری (وارد نشد)' : 'رشته متفاوت (وارد شد)',
        ]);
        if (!exact) unique[s.key] = s;
      }
    });

    // ساخت فایل گزارش
    final rep = Excel.createExcel();
    final dup = rep['شماره دانشجویی تکراری'];
    dup.isRTL = true;
    dup.appendRow(['شماره دانشجویی', 'کد ملی', 'نام', 'نام خانوادگی', 'رشته',
        'ردیف در فایل', 'وضعیت'].map((e) => TextCellValue(e)).toList());
    for (final r in dupRows) {
      dup.appendRow(r);
    }
    final sum = rep['خلاصه'];
    sum.isRTL = true;
    sum.appendRow([TextCellValue('کل ردیف‌ها'), IntCellValue(all.length)]);
    sum.appendRow([TextCellValue('ردیف‌های وارد‌شده'), IntCellValue(unique.length)]);
    sum.appendRow([TextCellValue('ردیف‌های تکراری'), IntCellValue(dupRows.length)]);
    rep.delete('Sheet1');

    final file = await _save(rep, 'گزارش_آپلود');
    return ImportResult(
        unique.values.toList(), file, all.length, dupRows.length, dupText);
  }

  /// ۲) خروجی تخلف‌ها: شیت دانشجویان متخلف + شیت جزئیات
  Future<File> exportViolations(
      List<ViolationRow> rows, List<String> allCheckboxTitles) async {
    final ex = Excel.createExcel();

    // شیت ۱: دانشجویان دارای تخلف (هر دانشجو یک ردیف)
    final byStudent = <String, List<ViolationRow>>{};
    for (final v in rows) {
      byStudent.putIfAbsent(v.student.key, () => []).add(v);
    }
    final s1 = ex['دانشجویان دارای تخلف'];
    s1.isRTL = true;
    s1.appendRow(['شماره دانشجویی', 'کد ملی', 'نام', 'نام خانوادگی', 'رشته',
        'تعداد تخلف', 'آخرین تخلف'].map((e) => TextCellValue(e)).toList());
    byStudent.forEach((_, list) {
      list.sort((a, b) => b.occurredAt.compareTo(a.occurredAt));
      final st = list.first.student;
      s1.appendRow([
        TextCellValue(st.studentNo), TextCellValue(st.nationalId),
        TextCellValue(st.firstName), TextCellValue(st.lastName),
        TextCellValue(st.major), IntCellValue(list.length),
        TextCellValue(jalali(list.first.occurredAt)),
      ]);
    });

    // شیت ۲: جزئیات همه تخلف‌ها (هر تخلف یک ردیف، هر چک‌باکس یک ستون)
    final s2 = ex['جزئیات تخلف‌ها'];
    s2.isRTL = true;
    s2.appendRow([
      'شماره دانشجویی', 'نام و نام خانوادگی', 'رشته', 'تاریخ و ساعت',
      ...allCheckboxTitles, 'توضیحات', 'ثبت‌کننده'
    ].map((e) => TextCellValue(e)).toList());
    for (final v in rows) {
      s2.appendRow([
        TextCellValue(v.student.studentNo),
        TextCellValue('${v.student.firstName} ${v.student.lastName}'),
        TextCellValue(v.student.major),
        TextCellValue(jalali(v.occurredAt)),
        ...allCheckboxTitles.map(
            (t) => TextCellValue(v.checkedItems.contains(t) ? '✓' : '')),
        TextCellValue(v.note),
        TextCellValue(v.recordedBy),
      ]);
    }
    ex.delete('Sheet1');

    return _save(ex, 'گزارش_تخلف‌ها');
  }

  Future<File> _save(Excel ex, String name) async {
    final dir = await getApplicationDocumentsDirectory();
    final j = Jalali.now();
    final stamp = '${j.year}'
        '${j.month.toString().padLeft(2, '0')}'
        '${j.day.toString().padLeft(2, '0')}';
    final file = File('${dir.path}/${name}_$stamp.xlsx');
    await file.writeAsBytes(ex.encode()!);
    return file;
  }

  /// باز کردن منوی اشتراک‌گذاری (ذخیره، واتساپ، ایمیل و...)
  Future<void> share(File f) => Share.shareXFiles([XFile(f.path)]);
}

/* نحوه استفاده:

// ادمین بعد از انتخاب فایل:
final res = await ExcelService().importStudents(pickedPath);
await db.upsertStudents(res.toImport);      // ذخیره در SQLite/سرور
await ExcelService().share(res.reportFile); // شیت تکراری‌ها

// دکمه «خروجی اکسل» در صفحه گزارش:
final f = await ExcelService().exportViolations(violations, checkboxTitles);
await ExcelService().share(f);
*/

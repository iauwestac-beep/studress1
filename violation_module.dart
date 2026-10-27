// pubspec.yaml (علاوه بر پکیج‌های excel_service.dart):
//   sqflite_sqlcipher: ^3.1.0
//   path: ^1.9.0
//   uuid: ^4.5.0
//   flutter_secure_storage: ^9.2.2   # نگهداری کلید رمزنگاری دیتابیس
//
// در MaterialApp: locale: Locale('fa'), و Directionality راست‌به‌چپ
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_sqlcipher/sqflite.dart';
import 'package:uuid/uuid.dart';
import 'excel_service.dart';

/// ۶ مورد چک‌باکس: عنوان‌ها را با موارد واقعی عوض کنید
const kViolationItems = [
  'لباس کوتاه یا چسبان',
  'لباس نازک یا بدن‌نما',
  'شلوار پاره یا کوتاه',
  'نوشته یا تصویر نامناسب روی لباس',
  'دمپایی یا صندل',
  'آرایش یا اکسسوری نامتعارف',
];

/// ───────── دیتابیس محلی (رمزنگاری‌شده) ─────────
class LocalDb {
  static Database? _db;

  /// کلید را یک بار بسازید و در flutter_secure_storage نگه دارید
  static Future<Database> open(String key) async {
    if (_db != null) return _db!;
    final path = p.join(await getDatabasesPath(), 'dress.db');
    _db = await openDatabase(path, password: key, version: 1,
        onCreate: (d, _) async {
      await d.execute('''
        CREATE TABLE students(
          key TEXT PRIMARY KEY,          -- شماره دانشجویی|رشته
          student_no TEXT, national_id TEXT,
          first_name TEXT, last_name TEXT, major TEXT,
          search_text TEXT)''');
      await d.execute('CREATE INDEX idx_search ON students(search_text)');
      await d.execute('''
        CREATE TABLE violations(
          id TEXT PRIMARY KEY,           -- UUID
          student_key TEXT,
          occurred_at TEXT,              -- UTC ISO
          items TEXT,                    -- JSON آرایه عنوان‌ها
          note TEXT, recorded_by TEXT,
          synced INTEGER DEFAULT 0)''');
      await d.execute('CREATE INDEX idx_v_student ON violations(student_key)');
    });
    return _db!;
  }

  static Database get _d => _db!;

  /// ذخیره/به‌روزرسانی دانشجوها (سابقه تخلف دست نمی‌خورد)
  static Future<void> upsertStudents(List<Student> list) async {
    final b = _d.batch();
    for (final s in list) {
      b.insert(
        'students',
        {
          'key': s.key, 'student_no': s.studentNo, 'national_id': s.nationalId,
          'first_name': s.firstName, 'last_name': s.lastName, 'major': s.major,
          'search_text': normalize(
              '${s.studentNo} ${s.nationalId} ${s.firstName} ${s.lastName}'),
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
    await b.commit(noResult: true);
  }

  /// جستجو: هر کلمه باید در کد دانشجویی، کد ملی یا نام وجود داشته باشد
  static Future<List<Student>> search(String q) async {
    final tokens =
        normalize(q).split(' ').where((t) => t.isNotEmpty).toList();
    if (tokens.isEmpty) return [];
    final rows = await _d.query(
      'students',
      where: tokens.map((_) => 'search_text LIKE ?').join(' AND '),
      whereArgs: tokens.map((t) => '%$t%').toList(),
      orderBy: 'last_name, first_name',
      limit: 50,
    );
    return rows.map(_toStudent).toList();
  }

  static Student _toStudent(Map<String, Object?> r) => Student(
      r['student_no'] as String, r['national_id'] as String,
      r['first_name'] as String, r['last_name'] as String,
      r['major'] as String, 0);

  static Future<int> violationCount(String studentKey) async =>
      Sqflite.firstIntValue(await _d.rawQuery(
          'SELECT COUNT(*) FROM violations WHERE student_key=?',
          [studentKey])) ??
      0;

  static Future<void> addViolation(Student s, DateTime when,
      List<String> items, String note, String by) async {
    await _d.insert('violations', {
      'id': const Uuid().v4(),
      'student_key': s.key,
      'occurred_at': when.toUtc().toIso8601String(),
      'items': jsonEncode(items),
      'note': note,
      'recorded_by': by,
      'synced': 0, // در صف ارسال (مرحله بعد)
    });
  }

  /// برای خروجی اکسل
  static Future<List<ViolationRow>> allViolations() async {
    final rows = await _d.rawQuery('''
      SELECT v.*, s.student_no, s.national_id, s.first_name, s.last_name, s.major
      FROM violations v JOIN students s ON s.key = v.student_key
      ORDER BY v.occurred_at DESC''');
    return rows.map((r) {
      final st = Student(r['student_no'] as String, r['national_id'] as String,
          r['first_name'] as String, r['last_name'] as String,
          r['major'] as String, 0);
      return ViolationRow(
        st,
        DateTime.parse(r['occurred_at'] as String),
        List<String>.from(jsonDecode(r['items'] as String)),
        r['note'] as String? ?? '',
        r['recorded_by'] as String? ?? '',
      );
    }).toList();
  }

  static Future<int> studentCount() async =>
      Sqflite.firstIntValue(
          await _d.rawQuery('SELECT COUNT(*) FROM students')) ??
      0;

  static Future<int> violationTotal() async =>
      Sqflite.firstIntValue(
          await _d.rawQuery('SELECT COUNT(*) FROM violations')) ??
      0;

  /// پشتیبان‌گیری دستی (جایگزین سرور تا زمان داشتن سرور)
  static Future<List<Map<String, Object?>>> rawViolations() =>
      _d.query('violations');

  /// ادغام تخلف‌های گوشی دیگر؛ شناسه (UUID) تکراری نادیده گرفته می‌شود.
  /// synced=0 می‌ماند تا بعداً با داشتن سرور خودکار ارسال شوند.
  static Future<int> importViolations(List<dynamic> rows) async {
    final have = (await _d.query('violations', columns: ['id']))
        .map((r) => r['id'] as String)
        .toSet();
    final b = _d.batch();
    var added = 0;
    for (final x in rows) {
      final id = '${x['id']}';
      if (have.contains(id)) continue;
      have.add(id);
      added++;
      b.insert('violations', {
        'id': id,
        'student_key': '${x['student_key']}',
        'occurred_at': '${x['occurred_at']}',
        'items': '${x['items']}',
        'note': '${x['note'] ?? ''}',
        'recorded_by': '${x['recorded_by'] ?? ''}',
        'synced': 0,
      });
    }
    await b.commit(noResult: true);
    return added;
  }

  /// برای صف همگام‌سازی
  static Future<List<Map<String, Object?>>> unsynced() =>
      _d.query('violations', where: 'synced=0');
  static Future<void> markSynced(String id) =>
      _d.update('violations', {'synced': 1}, where: 'id=?', whereArgs: [id]);
}

/// ───────── صفحه جستجو ─────────
class SearchScreen extends StatefulWidget {
  final String currentUser;
  const SearchScreen({super.key, required this.currentUser});
  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  final _ctrl = TextEditingController();
  List<Student> _results = [];
  bool _searched = false;

  Future<void> _run(String q) async {
    final r = await LocalDb.search(q);
    if (mounted) setState(() { _results = r; _searched = q.trim().isNotEmpty; });
  }

  Future<void> _export() async {
    final svc = ExcelService();
    final f = await svc.exportViolations(
        await LocalDb.allViolations(), kViolationItems);
    await svc.share(f);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('جستجوی دانشجو'), actions: [
          IconButton(
              icon: const Icon(Icons.file_download),
              tooltip: 'خروجی اکسل',
              onPressed: _export),
        ]),
        body: Column(children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: TextField(
              controller: _ctrl,
              onChanged: _run,
              textInputAction: TextInputAction.search,
              decoration: const InputDecoration(
                hintText: 'کد دانشجویی، کد ملی یا نام و نام خانوادگی',
                prefixIcon: Icon(Icons.search),
                border: OutlineInputBorder(),
              ),
            ),
          ),
          Expanded(
            child: _results.isEmpty
                ? Center(child: Text(_searched ? 'نتیجه‌ای پیدا نشد' : ''))
                : ListView.separated(
                    itemCount: _results.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (_, i) {
                      final s = _results[i];
                      return ListTile(
                        title: Text('${s.firstName} ${s.lastName}'),
                        subtitle:
                            Text('${s.studentNo}  •  ${s.major}'),
                        trailing: const Icon(Icons.chevron_left),
                        onTap: () => Navigator.push(
                          context,
                          MaterialPageRoute(
                              builder: (_) => ViolationFormScreen(
                                  student: s, user: widget.currentUser)),
                        ),
                      );
                    },
                  ),
          ),
        ]),
      );
}

/// ───────── فرم ثبت تخلف ─────────
class ViolationFormScreen extends StatefulWidget {
  final Student student;
  final String user;
  const ViolationFormScreen(
      {super.key, required this.student, required this.user});
  @override
  State<ViolationFormScreen> createState() => _ViolationFormScreenState();
}

class _ViolationFormScreenState extends State<ViolationFormScreen> {
  final _checked = <String>{};
  final _note = TextEditingController();
  DateTime _when = DateTime.now();
  int _previous = 0;

  @override
  void initState() {
    super.initState();
    LocalDb.violationCount(widget.student.key)
        .then((c) => mounted ? setState(() => _previous = c) : null);
  }

  /// انتخاب تاریخ/ساعت. برای تقویم شمسی می‌توانید پکیج
  /// persian_datetime_picker را جایگزین showDatePicker کنید.
  Future<void> _pickWhen() async {
    final d = await showDatePicker(
        context: context,
        initialDate: _when,
        firstDate: DateTime(2020),
        lastDate: DateTime.now());
    if (d == null || !mounted) return;
    final t = await showTimePicker(
        context: context, initialTime: TimeOfDay.fromDateTime(_when));
    if (t == null) return;
    setState(() => _when = DateTime(d.year, d.month, d.day, t.hour, t.minute));
  }

  Future<void> _save() async {
    await LocalDb.addViolation(widget.student, _when,
        _checked.toList(), _note.text.trim(), widget.user);
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('تخلف ثبت شد')));
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.student;
    return Scaffold(
      appBar: AppBar(title: const Text('ثبت تخلف پوشش')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        Card(
          child: ListTile(
            title: Text('${s.firstName} ${s.lastName}'),
            subtitle: Text(
                'دانشجویی: ${s.studentNo}\nکد ملی: ${s.nationalId}\nرشته: ${s.major}'),
            isThreeLine: true,
            trailing: _previous > 0
                ? Chip(label: Text('$_previous سابقه'))
                : null,
          ),
        ),
        const SizedBox(height: 8),
        for (final item in kViolationItems)
          CheckboxListTile(
            title: Text(item),
            value: _checked.contains(item),
            onChanged: (v) => setState(
                () => v == true ? _checked.add(item) : _checked.remove(item)),
          ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          icon: const Icon(Icons.schedule),
          label: Text('تاریخ و ساعت: ${jalali(_when)}'),
          onPressed: _pickWhen,
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _note,
          maxLines: 2,
          decoration: const InputDecoration(
              labelText: 'توضیحات (اختیاری)', border: OutlineInputBorder()),
        ),
        const SizedBox(height: 16),
        FilledButton(
          onPressed: _checked.isEmpty ? null : _save,
          child: const Text('ثبت تخلف'),
        ),
      ]),
    );
  }
}

/* راه‌اندازی بعد از ورود:
await LocalDb.open(keyFromSecureStorage);
Navigator.push(context, MaterialPageRoute(
  builder: (_) => SearchScreen(currentUser: 'نام کاربر')));

بعد از آپلود اکسل توسط ادمین:
final res = await ExcelService().importStudents(path);
await LocalDb.upsertStudents(res.toImport);
*/

// نسخه بدون سرور — این فایل را به lib/main.dart تغییر نام دهید.
//
// ساختار پروژه:
//   lib/main.dart              ← همین فایل
//   lib/excel_service.dart
//   lib/violation_module.dart
//   server_later/              ← بیرون از lib (کامپایل نمی‌شود)
//       sync_auth.dart  (PocketBase)   sync_auth_sheets.dart  (گوگل‌شیت)   Code.gs
//
// pubspec.yaml:
//   excel: ^4.0.6, path_provider: ^2.1.4, share_plus: ^10.0.0,
//   shamsi_date: ^1.1.1, sqflite_sqlcipher: ^3.1.0, path: ^1.9.0, uuid: ^4.5.0,
//   flutter_secure_storage: ^9.2.2, shared_preferences: ^2.3.2,
//   file_picker: ^8.1.2, flutter_localizations: {sdk: flutter}
//
// وقتی سرور پیدا کردید: محتوای یکی از فایل‌های server_later را به lib برگردانید و
// main.dart را جایش بگذارید. تخلف‌های ثبت‌شده همگی UUID دارند و synced=0 هستند،
// پس بدون از دست رفتن چیزی با اولین اتصال ارسال می‌شوند.
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shamsi_date/shamsi_date.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'excel_service.dart';
import 'violation_module.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final prefs = await SharedPreferences.getInstance();
  const sec = FlutterSecureStorage();
  var key = await sec.read(key: 'db_key');
  if (key == null) {
    final r = Random.secure();
    key = base64Url.encode(List.generate(32, (_) => r.nextInt(256)));
    await sec.write(key: 'db_key', value: key);
  }
  await LocalDb.open(key);
  runApp(StandaloneApp(prefs: prefs));
}

class StandaloneApp extends StatelessWidget {
  final SharedPreferences prefs;
  const StandaloneApp({super.key, required this.prefs});
  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'ثبت تخلف پوشش',
        locale: const Locale('fa'),
        supportedLocales: const [Locale('fa')],
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        builder: (c, child) =>
            Directionality(textDirection: TextDirection.rtl, child: child!),
        theme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.teal),
        home: StandaloneHome(prefs: prefs),
      );
}

class StandaloneHome extends StatefulWidget {
  final SharedPreferences prefs;
  const StandaloneHome({super.key, required this.prefs});
  @override
  State<StandaloneHome> createState() => _StandaloneHomeState();
}

class _StandaloneHomeState extends State<StandaloneHome> {
  int _students = 0, _violations = 0;
  String _msg = '';
  bool _busy = false;

  String get _name => widget.prefs.getString('recorder') ?? '';

  @override
  void initState() {
    super.initState();
    _refresh();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_name.isEmpty) _askName();
    });
  }

  Future<void> _refresh() async {
    final s = await LocalDb.studentCount();
    final v = await LocalDb.violationTotal();
    if (mounted) setState(() { _students = s; _violations = v; });
  }

  /// نام ثبت‌کننده روی هر تخلف ذخیره می‌شود
  Future<void> _askName() async {
    final c = TextEditingController(text: _name);
    await showDialog(
      context: context,
      barrierDismissible: _name.isNotEmpty,
      builder: (_) => AlertDialog(
        title: const Text('نام ثبت‌کننده'),
        content: TextField(
            controller: c,
            decoration: const InputDecoration(hintText: 'نام و نام خانوادگی')),
        actions: [
          FilledButton(
            onPressed: () {
              if (c.text.trim().isEmpty) return;
              widget.prefs.setString('recorder', c.text.trim());
              Navigator.pop(context);
            },
            child: const Text('ذخیره'),
          ),
        ],
      ),
    );
    setState(() {});
  }

  Future<void> _run(Future<void> Function() job) async {
    setState(() { _busy = true; _msg = 'در حال انجام...'; });
    try {
      await job();
    } catch (e) {
      setState(() => _msg = 'خطا: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
      _refresh();
    }
  }

  /// آپلود اکسل دانشجویان (همه‌ی موارد قبلی و سابقه تخلف حفظ می‌شود)
  Future<void> _importExcel() async {
    final pick = await FilePicker.platform
        .pickFiles(type: FileType.custom, allowedExtensions: ['xlsx']);
    if (pick == null) return;
    await _run(() async {
      final svc = ExcelService();
      final res = await svc.importStudents(pick.files.single.path!);
      await LocalDb.upsertStudents(res.toImport);
      setState(() => _msg = 'کل ردیف‌ها: ${res.totalRows}\n'
          'دانشجوی وارد‌شده: ${res.toImport.length}\n'
          'ردیف‌های تکراری: ${res.duplicateRows}');
      await svc.share(res.reportFile); // اکسل گزارش با شیت تکراری‌ها
    });
  }

  Future<void> _exportExcel() => _run(() async {
        final rows = await LocalDb.allViolations();
        if (rows.isEmpty) {
          setState(() => _msg = 'هنوز تخلفی ثبت نشده است');
          return;
        }
        final svc = ExcelService();
        await svc.share(await svc.exportViolations(rows, kViolationItems));
        setState(() => _msg = 'خروجی اکسل آماده شد');
      });

  /// پشتیبان JSON برای جمع‌کردن داده چند گوشی (به‌جای سرور)
  Future<void> _exportBackup() => _run(() async {
        final data = jsonEncode(
            {'v': 1, 'violations': await LocalDb.rawViolations()});
        final dir = await getApplicationDocumentsDirectory();
        final j = Jalali.now();
        final stamp = '${j.year}'
            '${j.month.toString().padLeft(2, '0')}'
            '${j.day.toString().padLeft(2, '0')}';
        final f = File('${dir.path}/پشتیبان_تخلف_$stamp.json');
        await f.writeAsString(data);
        await Share.shareXFiles([XFile(f.path)]);
        setState(() => _msg = 'فایل پشتیبان ساخته شد');
      });

  Future<void> _importBackup() async {
    final pick = await FilePicker.platform
        .pickFiles(type: FileType.custom, allowedExtensions: ['json']);
    if (pick == null) return;
    await _run(() async {
      final m = jsonDecode(await File(pick.files.single.path!).readAsString());
      final added = await LocalDb.importViolations(m['violations'] as List);
      setState(() => _msg = '$added تخلف جدید اضافه شد '
          '(موارد تکراری نادیده گرفته شدند)');
    });
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text(_name.isEmpty ? 'ثبت تخلف پوشش' : 'سلام $_name'),
            actions: [
              IconButton(
                  icon: const Icon(Icons.edit),
                  tooltip: 'تغییر نام ثبت‌کننده',
                  onPressed: _askName),
            ]),
        body: ListView(padding: const EdgeInsets.all(16), children: [
          Card(
            child: ListTile(
              leading: const Icon(Icons.people),
              title: Text('$_students دانشجو  •  $_violations تخلف ثبت‌شده'),
              subtitle: _students == 0
                  ? const Text('ابتدا فایل اکسل دانشجویان را وارد کنید')
                  : null,
            ),
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            icon: const Icon(Icons.search),
            label: const Text('جستجو و ثبت تخلف'),
            onPressed: _students == 0 || _name.isEmpty
                ? null
                : () async {
                    await Navigator.push(
                        context,
                        MaterialPageRoute(
                            builder: (_) => SearchScreen(currentUser: _name)));
                    _refresh();
                  },
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
              icon: const Icon(Icons.upload_file),
              label: const Text('وارد کردن اکسل دانشجویان'),
              onPressed: _busy ? null : _importExcel),
          const SizedBox(height: 8),
          OutlinedButton.icon(
              icon: const Icon(Icons.file_download),
              label: const Text('خروجی اکسل تخلف‌ها'),
              onPressed: _busy ? null : _exportExcel),
          const Divider(height: 32),
          const Text('جمع‌کردن داده چند گوشی (بدون سرور)',
              style: TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(
                child: OutlinedButton(
                    onPressed: _busy ? null : _exportBackup,
                    child: const Text('ساخت پشتیبان'))),
            const SizedBox(width: 8),
            Expanded(
                child: OutlinedButton(
                    onPressed: _busy ? null : _importBackup,
                    child: const Text('دریافت پشتیبان'))),
          ]),
          const SizedBox(height: 16),
          if (_busy) const LinearProgressIndicator(),
          if (_msg.isNotEmpty)
            Padding(padding: const EdgeInsets.only(top: 8), child: Text(_msg)),
        ]),
      );
}

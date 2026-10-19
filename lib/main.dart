import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const KlencodProIdeApp());
}

/// ============================================================================
/// الألوان والسمة الاحترافية (Klencod Dark Theme)
/// ============================================================================
class AppColors {
  static const Color darkBg = Color(0xFF0B0F17);
  static const Color surface = Color(0xFF151B26);
  static const Color surfaceAlt = Color(0xFF1E2636);
  static const Color border = Color(0xFF2B3548);
  static const Color primary = Color(0xFF388BFD);
  static const Color primaryDark = Color(0xFF1F6FEB);
  static const Color orange = Color(0xFFFF9800);
  static const Color success = Color(0xFF2EA043);
  static const Color danger = Color(0xFFF85149);
  static const Color warning = Color(0xFFD29922);
  static const Color purple = Color(0xFFA371F7);
  static const Color cyan = Color(0xFF39C5CF);
  static const Color textPrimary = Color(0xFFE6EDF3);
  static const Color textMuted = Color(0xFF8B949E);
}

/// ============================================================================
/// مخزن آمن مزدوج (SharedPreferences + ملف احتياطي مباشر عبر dart:io)
/// ============================================================================
class SafeStorage {
  static final Map<String, String> _memoryCache = {};
  static File get _backupFile => File('${Directory.systemTemp.path}/klencod_pro_ide_v4.json');

  static Future<Map<String, String>> _readAll() async {
    if (_memoryCache.isNotEmpty) return _memoryCache;
    try {
      if (await _backupFile.exists()) {
        final raw = await _backupFile.readAsString();
        final map = jsonDecode(raw) as Map<String, dynamic>;
        map.forEach((k, v) => _memoryCache[k] = v.toString());
      }
    } catch (_) {}
    return _memoryCache;
  }

  static Future<String?> getString(String key) async {
    try {
      final prefs = await SharedPreferences.getInstance().timeout(const Duration(milliseconds: 1000));
      final val = prefs.getString(key);
      if (val != null) {
        _memoryCache[key] = val;
        return val;
      }
    } catch (_) {}
    final map = await _readAll();
    return map[key];
  }

  static Future<void> setString(String key, String value) async {
    _memoryCache[key] = value;
    try {
      await _backupFile.writeAsString(jsonEncode(_memoryCache));
    } catch (_) {}
    try {
      final prefs = await SharedPreferences.getInstance().timeout(const Duration(milliseconds: 1000));
      await prefs.setString(key, value);
    } catch (_) {}
  }

  static Future<void> remove(String key) async {
    _memoryCache.remove(key);
    try {
      await _backupFile.writeAsString(jsonEncode(_memoryCache));
    } catch (_) {}
    try {
      final prefs = await SharedPreferences.getInstance().timeout(const Duration(milliseconds: 1000));
      await prefs.remove(key);
    } catch (_) {}
  }
}

/// ============================================================================
/// النماذج الأساسية (Models: ProjectType, IdeNode, IdeProject, ApkBuildRecord)
/// ============================================================================
enum IdeProjectType {
  flutter,
  androidJava,
  androidKotlin,
  reactNative;

  String get title => switch (this) {
        IdeProjectType.flutter => 'Flutter',
        IdeProjectType.androidJava => 'Android (Java)',
        IdeProjectType.androidKotlin => 'Android (Kotlin)',
        IdeProjectType.reactNative => 'React Native',
      };

  String get subtitle => switch (this) {
        IdeProjectType.flutter => 'تطبيق Flutter متعدد المنصات (Dart)',
        IdeProjectType.androidJava => 'تطبيق Android أصلي بلغة Java',
        IdeProjectType.androidKotlin => 'تطبيق Android أصلي بلغة Kotlin',
        IdeProjectType.reactNative => 'تطبيق React Native CLI (TypeScript + Native Android)',
      };

  String get extTag => switch (this) {
        IdeProjectType.flutter => '.dart',
        IdeProjectType.androidJava => '.java',
        IdeProjectType.androidKotlin => '.kt',
        IdeProjectType.reactNative => '.tsx',
      };

  String get langTag => switch (this) {
        IdeProjectType.flutter => 'Dart',
        IdeProjectType.androidJava => 'Java',
        IdeProjectType.androidKotlin => 'Kotlin',
        IdeProjectType.reactNative => 'TypeScript',
      };

  Color get badgeColor => switch (this) {
        IdeProjectType.flutter => const Color(0xFF388BFD),
        IdeProjectType.androidJava => const Color(0xFFD29922),
        IdeProjectType.androidKotlin => const Color(0xFFA371F7),
        IdeProjectType.reactNative => const Color(0xFF39C5CF),
      };

  static IdeProjectType fromName(String? name) {
    for (final v in IdeProjectType.values) {
      if (v.name == name) return v;
    }
    return IdeProjectType.flutter;
  }
}

class IdeNode {
  String path;
  bool isFolder;
  String content;
  bool isDirty;

  IdeNode({
    required this.path,
    required this.isFolder,
    this.content = '',
    this.isDirty = false,
  });

  String get name => path.split('/').last;

  Map<String, dynamic> toJson() => {
        'path': path,
        'isFolder': isFolder,
        'content': content,
      };

  factory IdeNode.fromJson(Map<String, dynamic> json) => IdeNode(
        path: json['path'] as String,
        isFolder: json['isFolder'] as bool? ?? false,
        content: json['content'] as String? ?? '',
      );
}

class IdeProject {
  String id;
  String name; // Display app name
  String packageName; // e.g. com.klencod.myapp
  String versionName; // e.g. 1.0.0
  int versionCode; // e.g. 1
  IdeProjectType type;
  String buildMode; // 'release' or 'debug'
  bool publishReleaseTag; // Create GitHub Release with APK
  String? iconBase64; // Custom PNG icon bytes encoded in base64
  String? githubRepo; // e.g. username/my-repo
  DateTime updatedAt;
  List<IdeNode> nodes;

  IdeProject({
    required this.id,
    required this.name,
    required this.packageName,
    this.versionName = '1.0.0',
    this.versionCode = 1,
    this.type = IdeProjectType.flutter,
    this.buildMode = 'release',
    this.publishReleaseTag = true,
    this.iconBase64,
    this.githubRepo,
    required this.updatedAt,
    required this.nodes,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'packageName': packageName,
        'versionName': versionName,
        'versionCode': versionCode,
        'type': type.name,
        'buildMode': buildMode,
        'publishReleaseTag': publishReleaseTag,
        'iconBase64': iconBase64,
        'githubRepo': githubRepo,
        'updatedAt': updatedAt.toIso8601String(),
        'nodes': nodes.map((n) => n.toJson()).toList(),
      };

  factory IdeProject.fromJson(Map<String, dynamic> json) => IdeProject(
        id: json['id'] as String? ?? DateTime.now().millisecondsSinceEpoch.toString(),
        name: json['name'] as String? ?? 'My App',
        packageName: json['packageName'] as String? ?? 'com.klencod.app',
        versionName: json['versionName'] as String? ?? '1.0.0',
        versionCode: (json['versionCode'] as num?)?.toInt() ?? 1,
        type: IdeProjectType.fromName(json['type'] as String?),
        buildMode: json['buildMode'] as String? ?? 'release',
        publishReleaseTag: json['publishReleaseTag'] as bool? ?? true,
        iconBase64: json['iconBase64'] as String?,
        githubRepo: json['githubRepo'] as String?,
        updatedAt: DateTime.tryParse(json['updatedAt'] as String? ?? '') ?? DateTime.now(),
        nodes: ((json['nodes'] as List?) ?? [])
            .map((e) => IdeNode.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
}

class ApkBuildRecord {
  final String id;
  final String projectId;
  final String projectName;
  final String packageName;
  final String versionName;
  final String projectType;
  final String repoFullName;
  final String status; // 'success', 'running', 'failed'
  final String actionsUrl;
  final String? releaseApkUrl;
  final String? localSavedPath;
  final DateTime createdAt;
  final List<String> logs;

  const ApkBuildRecord({
    required this.id,
    required this.projectId,
    required this.projectName,
    required this.packageName,
    required this.versionName,
    required this.projectType,
    required this.repoFullName,
    required this.status,
    required this.actionsUrl,
    this.releaseApkUrl,
    this.localSavedPath,
    required this.createdAt,
    required this.logs,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'projectId': projectId,
        'projectName': projectName,
        'packageName': packageName,
        'versionName': versionName,
        'projectType': projectType,
        'repoFullName': repoFullName,
        'status': status,
        'actionsUrl': actionsUrl,
        'releaseApkUrl': releaseApkUrl,
        'localSavedPath': localSavedPath,
        'createdAt': createdAt.toIso8601String(),
        'logs': logs,
      };

  factory ApkBuildRecord.fromJson(Map<String, dynamic> json) => ApkBuildRecord(
        id: json['id'] as String? ?? '',
        projectId: json['projectId'] as String? ?? '',
        projectName: json['projectName'] as String? ?? '',
        packageName: json['packageName'] as String? ?? '',
        versionName: json['versionName'] as String? ?? '1.0.0',
        projectType: json['projectType'] as String? ?? 'Flutter',
        repoFullName: json['repoFullName'] as String? ?? '',
        status: json['status'] as String? ?? 'completed',
        actionsUrl: json['actionsUrl'] as String? ?? '',
        releaseApkUrl: json['releaseApkUrl'] as String?,
        localSavedPath: json['localSavedPath'] as String?,
        createdAt: DateTime.tryParse(json['createdAt'] as String? ?? '') ?? DateTime.now(),
        logs: ((json['logs'] as List?) ?? []).map((e) => e.toString()).toList(),
      );
}

/// ============================================================================
/// قوالب المشاريع والأكواد الجاهزة لكل اللغات (Templates Generator)
/// ============================================================================
class ProjectTemplates {
  static List<IdeNode> generateNodes({
    required IdeProjectType type,
    required String appName,
    required String packageName,
    required String versionName,
    required int versionCode,
    String templateKind = 'default',
  }) {
    final safeSlug = appName
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9_]'), '_')
        .replaceAll(RegExp(r'_+'), '_')
        .replaceAll(RegExp(r'^_|_$'), '');
    final dartPkgName = safeSlug.isEmpty ? 'klencod_app' : safeSlug;

    switch (type) {
      case IdeProjectType.flutter:
        return [
          IdeNode(
            path: 'pubspec.yaml',
            isFolder: false,
            content: 'name: $dartPkgName\n'
                'description: $appName - Built with Klencod IDE.\n'
                "publish_to: 'none'\n"
                'version: $versionName+$versionCode\n\n'
                'environment:\n'
                "  sdk: '>=3.0.0 <4.0.0'\n\n"
                'dependencies:\n'
                '  flutter:\n'
                '    sdk: flutter\n\n'
                'flutter:\n'
                '  uses-material-design: true\n',
          ),
          IdeNode(path: 'lib', isFolder: true),
          IdeNode(
            path: 'lib/main.dart',
            isFolder: false,
            content: _flutterStarterCode(appName, templateKind),
          ),
          IdeNode(path: '.github', isFolder: true),
          IdeNode(path: '.github/workflows', isFolder: true),
          IdeNode(
            path: '.github/workflows/main.yml',
            isFolder: false,
            content: workflowForType(
              IdeProjectType.flutter,
              appName: appName,
              packageName: packageName,
              versionName: versionName,
              versionCode: versionCode,
            ),
          ),
        ];

      case IdeProjectType.androidJava:
        final pkgPath = packageName.replaceAll('.', '/');
        return [
          IdeNode(path: 'app', isFolder: true),
          IdeNode(path: 'app/src', isFolder: true),
          IdeNode(path: 'app/src/main', isFolder: true),
          IdeNode(path: 'app/src/main/java', isFolder: true),
          IdeNode(
            path: 'app/src/main/java/$pkgPath/MainActivity.java',
            isFolder: false,
            content: 'package $packageName;\n\n'
                'import android.app.Activity;\n'
                'import android.os.Bundle;\n'
                'import android.widget.TextView;\n'
                'import android.view.Gravity;\n\n'
                'public class MainActivity extends Activity {\n'
                '    @Override\n'
                '    protected void onCreate(Bundle savedInstanceState) {\n'
                '        super.onCreate(savedInstanceState);\n'
                '        TextView tv = new TextView(this);\n'
                '        tv.setText("مرحباً بك في $appName (Android Java)");\n'
                '        tv.setTextSize(22f);\n'
                '        tv.setGravity(Gravity.CENTER);\n'
                '        setContentView(tv);\n'
                '    }\n'
                '}\n',
          ),
          IdeNode(
            path: 'app/src/main/AndroidManifest.xml',
            isFolder: false,
            content: '<?xml version="1.0" encoding="utf-8"?>\n'
                '<manifest xmlns:android="http://schemas.android.com/apk/res/android"\n'
                '    package="$packageName">\n'
                '    <uses-permission android:name="android.permission.INTERNET"/>\n'
                '    <application\n'
                '        android:label="$appName"\n'
                '        android:theme="@android:style/Theme.DeviceDefault.NoActionBar">\n'
                '        <activity android:name=".MainActivity" android:exported="true">\n'
                '            <intent-filter>\n'
                '                <action android:name="android.intent.action.MAIN"/>\n'
                '                <category android:name="android.intent.category.LAUNCHER"/>\n'
                '            </intent-filter>\n'
                '        </activity>\n'
                '    </application>\n'
                '</manifest>\n',
          ),
          IdeNode(path: '.github', isFolder: true),
          IdeNode(path: '.github/workflows', isFolder: true),
          IdeNode(
            path: '.github/workflows/main.yml',
            isFolder: false,
            content: workflowForType(
              IdeProjectType.androidJava,
              appName: appName,
              packageName: packageName,
              versionName: versionName,
              versionCode: versionCode,
            ),
          ),
        ];

      case IdeProjectType.androidKotlin:
        final pkgPath = packageName.replaceAll('.', '/');
        return [
          IdeNode(path: 'app', isFolder: true),
          IdeNode(path: 'app/src', isFolder: true),
          IdeNode(path: 'app/src/main', isFolder: true),
          IdeNode(path: 'app/src/main/kotlin', isFolder: true),
          IdeNode(
            path: 'app/src/main/kotlin/$pkgPath/MainActivity.kt',
            isFolder: false,
            content: 'package $packageName\n\n'
                'import android.app.Activity\n'
                'import android.os.Bundle\n'
                'import android.view.Gravity\n'
                'import android.widget.TextView\n\n'
                'class MainActivity : Activity() {\n'
                '    override fun onCreate(savedInstanceState: Bundle?) {\n'
                '        super.onCreate(savedInstanceState)\n'
                '        val tv = TextView(this).apply {\n'
                '            text = "مرحباً بك في $appName (Kotlin)"\n'
                '            textSize = 22f\n'
                '            gravity = Gravity.CENTER\n'
                '        }\n'
                '        setContentView(tv)\n'
                '    }\n'
                '}\n',
          ),
          IdeNode(
            path: 'app/src/main/AndroidManifest.xml',
            isFolder: false,
            content: '<?xml version="1.0" encoding="utf-8"?>\n'
                '<manifest xmlns:android="http://schemas.android.com/apk/res/android"\n'
                '    package="$packageName">\n'
                '    <uses-permission android:name="android.permission.INTERNET"/>\n'
                '    <application\n'
                '        android:label="$appName"\n'
                '        android:theme="@android:style/Theme.DeviceDefault.NoActionBar">\n'
                '        <activity android:name=".MainActivity" android:exported="true">\n'
                '            <intent-filter>\n'
                '                <action android:name="android.intent.action.MAIN"/>\n'
                '                <category android:name="android.intent.category.LAUNCHER"/>\n'
                '            </intent-filter>\n'
                '        </activity>\n'
                '    </application>\n'
                '</manifest>\n',
          ),
          IdeNode(path: '.github', isFolder: true),
          IdeNode(path: '.github/workflows', isFolder: true),
          IdeNode(
            path: '.github/workflows/main.yml',
            isFolder: false,
            content: workflowForType(
              IdeProjectType.androidKotlin,
              appName: appName,
              packageName: packageName,
              versionName: versionName,
              versionCode: versionCode,
            ),
          ),
        ];

      case IdeProjectType.reactNative:
        return [
          IdeNode(
            path: 'package.json',
            isFolder: false,
            content: '{\n'
                '  "name": "$dartPkgName",\n'
                '  "version": "$versionName",\n'
                '  "private": true,\n'
                '  "scripts": {\n'
                '    "android": "react-native run-android",\n'
                '    "start": "react-native start"\n'
                '  },\n'
                '  "dependencies": {\n'
                '    "react": "18.2.0",\n'
                '    "react-native": "0.73.6"\n'
                '  }\n'
                '}\n',
          ),
          IdeNode(
            path: 'App.tsx',
            isFolder: false,
            content: "import React, { useState } from 'react';\n"
                "import { SafeAreaView, StyleSheet, Text, TouchableOpacity, View } from 'react-native';\n\n"
                'export default function App() {\n'
                '  const [count, setCount] = useState(0);\n'
                '  return (\n'
                '    <SafeAreaView style={styles.container}>\n'
                '      <View style={styles.card}>\n'
                '        <Text style={styles.title}>$appName</Text>\n'
                '        <Text style={styles.subtitle}>العداد: {count}</Text>\n'
                '        <TouchableOpacity style={styles.btn} onPress={() => setCount(count + 1)}>\n'
                '          <Text style={styles.btnText}>زيادة +</Text>\n'
                '        </TouchableOpacity>\n'
                '      </View>\n'
                '    </SafeAreaView>\n'
                '  );\n'
                '}\n\n'
                'const styles = StyleSheet.create({\n'
                "  container: { flex: 1, backgroundColor: '#0D1117', justifyContent: 'center', padding: 20 },\n"
                "  card: { backgroundColor: '#161B22', padding: 24, borderRadius: 18, alignItems: 'center' },\n"
                "  title: { color: '#FFFFFF', fontSize: 22, fontWeight: 'bold', marginBottom: 10 },\n"
                "  subtitle: { color: '#58A6FF', fontSize: 18, marginBottom: 18 },\n"
                "  btn: { backgroundColor: '#2EA043', paddingHorizontal: 24, paddingVertical: 12, borderRadius: 12 },\n"
                "  btnText: { color: '#FFFFFF', fontWeight: 'bold', fontSize: 16 },\n"
                '});\n',
          ),
          IdeNode(path: '.github', isFolder: true),
          IdeNode(path: '.github/workflows', isFolder: true),
          IdeNode(
            path: '.github/workflows/main.yml',
            isFolder: false,
            content: workflowForType(
              IdeProjectType.reactNative,
              appName: appName,
              packageName: packageName,
              versionName: versionName,
              versionCode: versionCode,
            ),
          ),
        ];
    }
  }

  static String _flutterStarterCode(String appName, String templateKind) {
    if (templateKind == 'store') {
      return "import 'package:flutter/material.dart';\n\n"
          'void main() => runApp(const StoreApp());\n\n'
          'class StoreApp extends StatelessWidget {\n'
          '  const StoreApp({super.key});\n\n'
          '  @override\n'
          '  Widget build(BuildContext context) {\n'
          '    return MaterialApp(\n'
          '      debugShowCheckedModeBanner: false,\n'
          "      title: '$appName',\n"
          '      theme: ThemeData.dark(useMaterial3: true),\n'
          '      home: const StoreHomeScreen(),\n'
          '    );\n'
          '  }\n'
          '}\n\n'
          'class StoreHomeScreen extends StatelessWidget {\n'
          '  const StoreHomeScreen({super.key});\n\n'
          '  @override\n'
          '  Widget build(BuildContext context) {\n'
          '    final items = [\n'
          "      ('سماعة لاسلكية Pro', '450 ج.م', Icons.headphones),\n"
          "      ('ساعة ذكية Ultra', '1,200 ج.م', Icons.watch),\n"
          "      ('شاحن سريع 65W', '320 ج.م', Icons.bolt),\n"
          "      ('حقيبة لابتوب ذكية', '580 ج.م', Icons.backpack),\n"
          '    ];\n'
          '    return Scaffold(\n'
          "      appBar: AppBar(title: const Text('$appName')),\n"
          '      body: GridView.builder(\n'
          '        padding: const EdgeInsets.all(16),\n'
          '        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(\n'
          '          crossAxisCount: 2,\n'
          '          mainAxisSpacing: 12,\n'
          '          crossAxisSpacing: 12,\n'
          '          childAspectRatio: 0.85,\n'
          '        ),\n'
          '        itemCount: items.length,\n'
          '        itemBuilder: (ctx, i) => Card(\n'
          '          child: Padding(\n'
          '            padding: const EdgeInsets.all(12),\n'
          '            child: Column(\n'
          '              mainAxisAlignment: MainAxisAlignment.center,\n'
          '              children: [\n'
          '                Icon(items[i].\$3, size: 48, color: Colors.amber),\n'
          '                const SizedBox(height: 12),\n'
          '                Text(items[i].\$1, textAlign: TextAlign.center, style: const TextStyle(fontWeight: FontWeight.bold)),\n'
          '                const SizedBox(height: 6),\n'
          '                Text(items[i].\$2, style: const TextStyle(color: Colors.greenAccent)),\n'
          '              ],\n'
          '            ),\n'
          '          ),\n'
          '        ),\n'
          '      ),\n'
          '    );\n'
          '  }\n'
          '}\n';
    }

    if (templateKind == 'calculator') {
      return "import 'package:flutter/material.dart';\n\n"
          'void main() => runApp(const CalcApp());\n\n'
          'class CalcApp extends StatelessWidget {\n'
          '  const CalcApp({super.key});\n\n'
          '  @override\n'
          '  Widget build(BuildContext context) {\n'
          '    return MaterialApp(\n'
          '      debugShowCheckedModeBanner: false,\n'
          "      title: '$appName',\n"
          '      theme: ThemeData.dark(useMaterial3: true),\n'
          '      home: const CalcPage(),\n'
          '    );\n'
          '  }\n'
          '}\n\n'
          'class CalcPage extends StatefulWidget {\n'
          '  const CalcPage({super.key});\n\n'
          '  @override\n'
          '  State<CalcPage> createState() => _CalcPageState();\n'
          '}\n\n'
          'class _CalcPageState extends State<CalcPage> {\n'
          "  String _display = '0';\n\n"
          '  void _press(String k) {\n'
          '    setState(() {\n'
          "      if (k == 'C') {\n"
          "        _display = '0';\n"
          '      } else {\n'
          "        _display = _display == '0' ? k : _display + k;\n"
          '      }\n'
          '    });\n'
          '  }\n\n'
          '  @override\n'
          '  Widget build(BuildContext context) {\n'
          "    final keys = ['7','8','9','/','4','5','6','*','1','2','3','-','C','0','=','+'];\n"
          '    return Scaffold(\n'
          "      appBar: AppBar(title: const Text('$appName')),\n"
          '      body: Column(\n'
          '        children: [\n'
          '          Expanded(\n'
          '            child: Container(\n'
          '              alignment: Alignment.bottomRight,\n'
          '              padding: const EdgeInsets.all(24),\n'
          '              child: Text(_display, style: const TextStyle(fontSize: 42, fontWeight: FontWeight.bold)),\n'
          '            ),\n'
          '          ),\n'
          '          GridView.builder(\n'
          '            shrinkWrap: true,\n'
          '            padding: const EdgeInsets.all(12),\n'
          '            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 4, mainAxisSpacing: 8, crossAxisSpacing: 8),\n'
          '            itemCount: keys.length,\n'
          '            itemBuilder: (ctx, i) => ElevatedButton(\n'
          '              onPressed: () => _press(keys[i]),\n'
          '              child: Text(keys[i], style: const TextStyle(fontSize: 22)),\n'
          '            ),\n'
          '          ),\n'
          '        ],\n'
          '      ),\n'
          '    );\n'
          '  }\n'
          '}\n';
    }

    return "import 'package:flutter/material.dart';\n\n"
        'void main() {\n'
        '  runApp(const MyApp());\n'
        '}\n\n'
        'class MyApp extends StatelessWidget {\n'
        '  const MyApp({super.key});\n\n'
        '  @override\n'
        '  Widget build(BuildContext context) {\n'
        '    return MaterialApp(\n'
        '      debugShowCheckedModeBanner: false,\n'
        "      title: '$appName',\n"
        '      theme: ThemeData.dark(useMaterial3: true),\n'
        '      home: const HomePage(),\n'
        '    );\n'
        '  }\n'
        '}\n\n'
        'class HomePage extends StatefulWidget {\n'
        '  const HomePage({super.key});\n\n'
        '  @override\n'
        '  State<HomePage> createState() => _HomePageState();\n'
        '}\n\n'
        'class _HomePageState extends State<HomePage> {\n'
        '  int _counter = 0;\n\n'
        '  @override\n'
        '  Widget build(BuildContext context) {\n'
        '    return Scaffold(\n'
        "      appBar: AppBar(title: const Text('$appName')),\n"
        '      body: Center(\n'
        '        child: Column(\n'
        '          mainAxisAlignment: MainAxisAlignment.center,\n'
        '          children: [\n'
        "            const Text('تم إنشاء التطبيق وتخصيصه بنجاح:'),\n"
        '            const SizedBox(height: 12),\n'
        '            Text(\n'
        "              '\$_counter',\n"
        '              style: const TextStyle(fontSize: 36, fontWeight: FontWeight.bold),\n'
        '            ),\n'
        '          ],\n'
        '        ),\n'
        '      ),\n'
        '      floatingActionButton: FloatingActionButton(\n'
        '        onPressed: () => setState(() => _counter++),\n'
        '        child: const Icon(Icons.add),\n'
        '      ),\n'
        '    );\n'
        '  }\n'
        '}\n';
  }

  static String workflowForType(
    IdeProjectType type, {
    required String appName,
    required String packageName,
    required String versionName,
    required int versionCode,
    String buildMode = 'release',
    bool publishRelease = true,
  }) {
    final safeAppName = appName.replaceAll('"', '').replaceAll("'", '');
    final safePkg = packageName.trim().isEmpty ? 'com.klencod.app' : packageName.trim();
    final buildFlag = buildMode == 'debug' ? '--debug' : '--release';
    final apkFile = buildMode == 'debug' ? 'app-debug.apk' : 'app-release.apk';

    return 'name: Build Flutter APK\n\n'
        'on:\n'
        '  push:\n'
        '    branches: [ main, master ]\n'
        '  workflow_dispatch:\n'
        '    inputs:\n'
        '      flutter_version:\n'
        "        description: 'Flutter version'\n"
        '        required: false\n'
        "        default: '3.47.2'\n\n"
        'permissions:\n'
        '  contents: write\n\n'
        'jobs:\n'
        '  build:\n'
        '    runs-on: ubuntu-24.04\n'
        '    steps:\n'
        '      - name: Checkout\n'
        '        uses: actions/checkout@v4\n\n'
        '      - name: Setup Gradle Cache\n'
        '        uses: actions/cache@v4\n'
        '        with:\n'
        '          path: |\n'
        '            ~/.gradle/caches\n'
        '            ~/.gradle/wrapper\n'
        "          key: \${{ runner.os }}-gradle-\${{ hashFiles('**/*.gradle*', '**/gradle-wrapper.properties') }}\n"
        '          restore-keys: |\n'
        '            \${{ runner.os }}-gradle-\n\n'
        '      - name: Setup Java 17\n'
        '        uses: actions/setup-java@v4\n'
        '        with:\n'
        '          distribution: temurin\n'
        "          java-version: '17'\n\n"
        '      - name: Setup Flutter\n'
        '        uses: subosito/flutter-action@v2\n'
        '        with:\n'
        '          cache: true\n'
        '          channel: stable\n\n'
        '      - name: Prepare Android & Custom Branding\n'
        '        run: |\n'
        '          if [ ! -f "pubspec.yaml" ]; then\n'
        '            flutter create . --platforms=android --org ${safePkg.split(".").take(2).join(".")}\n'
        '          elif [ ! -d "android" ]; then\n'
        '            flutter create . --platforms=android\n'
        '          fi\n'
        '          if [ -f "android/app/src/main/AndroidManifest.xml" ]; then\n'
        '            sed -i \'s/android:label="[^"]*"/android:label="$safeAppName"/g\' android/app/src/main/AndroidManifest.xml || true\n'
        '          fi\n'
        '          if [ -f "android/app/build.gradle" ]; then\n'
        '            sed -i \'s/applicationId = "[^"]*"/applicationId = "$safePkg"/g\' android/app/build.gradle || true\n'
        '          fi\n'
        '          if [ -f "android/app/build.gradle.kts" ]; then\n'
        '            sed -i \'s/applicationId = "[^"]*"/applicationId = "$safePkg"/g\' android/app/build.gradle.kts || true\n'
        '          fi\n\n'
        '      - name: Get dependencies\n'
        '        run: flutter pub get\n\n'
        '      - name: Build APK\n'
        '        run: flutter build apk $buildFlag --build-name=$versionName --build-number=$versionCode\n\n'
        '      - name: Upload APK\n'
        '        uses: actions/upload-artifact@v4\n'
        '        with:\n'
        '          name: app-release\n'
        '          path: build/app/outputs/flutter-apk/$apkFile\n'
        '          if-no-files-found: error\n'
        '          retention-days: 14\n';
  }
}

/// ============================================================================
/// محرر الأكواد الملون (Syntax Highlighting Controller for Dart/Java/Kotlin/TSX)
/// ============================================================================
class CodeSyntaxController extends TextEditingController {
  CodeSyntaxController({super.text});

  static final RegExp _tokenRegex = RegExp(
    r"(//.*$)|(/\*[\s\S]*?\*/)|('(?:\\.|[^'\\])*')|"
    r'("(?:\\.|[^"\\])*")'
    r"|(@[a-zA-Z_]\w*)"
    r"|\b(abstract|as|assert|async|await|break|case|catch|class|const|continue|covariant|default|deferred|do|dynamic|else|enum|export|extends|extension|external|factory|false|final|finally|for|fun|function|Function|get|hide|if|implements|import|in|interface|is|late|let|library|mixin|new|null|object|on|operator|override|package|part|private|protected|public|required|rethrow|return|sealed|set|show|static|super|switch|sync|this|throw|true|try|typedef|val|var|void|when|while|with|yield)\b"
    r"|\b(Widget|StatelessWidget|StatefulWidget|State|BuildContext|Scaffold|AppBar|Container|Column|Row|Text|Center|ListView|Padding|Expanded|SizedBox|IconButton|ElevatedButton|TextField|MaterialApp|ThemeData|Color|Colors|EdgeInsets|Future|Stream|List|Map|Set|String|int|double|bool|num|Object|Key|Activity|Bundle|TextView|View)\b"
    r"|\b(\d+(?:\.\d+)?)\b",
    multiLine: true,
  );

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    final baseStyle = style ??
        const TextStyle(
          fontFamily: 'monospace',
          fontSize: 14,
          height: 1.5,
          color: AppColors.textPrimary,
        );

    final source = text;
    if (source.isEmpty) {
      return TextSpan(style: baseStyle, text: '');
    }

    try {
      final children = <TextSpan>[];
      var lastIndex = 0;

      for (final match in _tokenRegex.allMatches(source)) {
        if (match.start > lastIndex) {
          children.add(TextSpan(text: source.substring(lastIndex, match.start)));
        }

        Color tokenColor = AppColors.textPrimary;
        FontWeight? weight;
        FontStyle? fontStyle;

        if (match.group(1) != null || match.group(2) != null) {
          tokenColor = AppColors.textMuted;
          fontStyle = FontStyle.italic;
        } else if (match.group(3) != null || match.group(4) != null) {
          tokenColor = const Color(0xFFA5D6FF);
        } else if (match.group(5) != null) {
          tokenColor = const Color(0xFFD2A8FF);
        } else if (match.group(6) != null) {
          tokenColor = const Color(0xFFFF7B72);
          weight = FontWeight.w600;
        } else if (match.group(7) != null) {
          tokenColor = const Color(0xFFFFA657);
        } else if (match.group(8) != null) {
          tokenColor = const Color(0xFF79C0FF);
        }

        children.add(
          TextSpan(
            text: match.group(0),
            style: baseStyle.copyWith(
              color: tokenColor,
              fontWeight: weight,
              fontStyle: fontStyle,
            ),
          ),
        );
        lastIndex = match.end;
      }

      if (lastIndex < source.length) {
        children.add(TextSpan(text: source.substring(lastIndex)));
      }

      return TextSpan(style: baseStyle, children: children);
    } catch (_) {
      return TextSpan(style: baseStyle, text: source);
    }
  }
}

/// ============================================================================
/// خدمة ربط GitHub الرسمية عبر Device Flow بدون خادم وسيط + البناء السحابي
/// ============================================================================
class GithubOAuthDeviceService {
  // Client ID رسمي لتفويض Device Flow المباشر بدون خادم وسيط (قابل للتخصيص)
  static const String defaultClientId = '178c6fc778ccc68e1d6a';

  static Future<Map<String, dynamic>> startDeviceFlow({String? customClientId}) async {
    final clientId = (customClientId != null && customClientId.trim().isNotEmpty)
        ? customClientId.trim()
        : defaultClientId;

    final res = await http
        .post(
          Uri.parse('https://github.com/login/device/code'),
          headers: {
            'Accept': 'application/json',
            'Content-Type': 'application/x-www-form-urlencoded',
          },
          body: 'client_id=$clientId&scope=repo%20workflow',
        )
        .timeout(const Duration(seconds: 20));

    if (res.statusCode >= 400) {
      throw Exception('تعذر بدء طلب التفويض من GitHub (${res.statusCode}).');
    }
    final data = jsonDecode(res.body) as Map<String, dynamic>;
    if (data['user_code'] == null) {
      throw Exception(data['error_description']?.toString() ?? 'تعذر الحصول على رمز التحقق.');
    }
    return data;
  }

  static Future<Map<String, dynamic>> pollDeviceToken({
    required String deviceCode,
    String? customClientId,
  }) async {
    final clientId = (customClientId != null && customClientId.trim().isNotEmpty)
        ? customClientId.trim()
        : defaultClientId;

    final res = await http
        .post(
          Uri.parse('https://github.com/login/oauth/access_token'),
          headers: {
            'Accept': 'application/json',
            'Content-Type': 'application/x-www-form-urlencoded',
          },
          body: 'client_id=$clientId'
              '&device_code=$deviceCode'
              '&grant_type=urn:ietf:params:oauth:grant-type:device_code',
        )
        .timeout(const Duration(seconds: 20));

    final data = jsonDecode(res.body) as Map<String, dynamic>;
    return data;
  }

  static Future<Map<String, dynamic>> fetchUserProfile(String token) async {
    final res = await http.get(
      Uri.parse('https://api.github.com/user'),
      headers: {
        'Authorization': 'Bearer ${token.trim()}',
        'Accept': 'application/vnd.github+json',
      },
    ).timeout(const Duration(seconds: 20));

    if (res.statusCode >= 400) {
      throw Exception('التوكن غير صالح أو انتهت صلاحيته (${res.statusCode}).');
    }
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  /// ينشئ المستودع تلقائياً في حساب المستخدم إن لم يكن موجوداً ثم يرفع المشروع ويشغل GitHub Actions
  static Future<ApkBuildRecord> pushProjectAndBuildApk({
    required String token,
    required String githubLogin,
    required IdeProject project,
    required void Function(String stepLog) onLog,
  }) async {
    final cleanToken = token.trim();
    final headers = {
      'Authorization': 'Bearer $cleanToken',
      'Accept': 'application/vnd.github+json',
      'Content-Type': 'application/json',
      'X-GitHub-Api-Version': '2022-11-28',
    };

    final safeSlug = project.name
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9-]'), '-')
        .replaceAll(RegExp(r'-+'), '-')
        .replaceAll(RegExp(r'^-|-$'), '');
    final repoShortName = safeSlug.isEmpty ? 'klencod-app-${project.id.substring(project.id.length - 4)}' : safeSlug;
    final repoFullName = (project.githubRepo != null && project.githubRepo!.contains('/'))
        ? project.githubRepo!.trim()
        : '$githubLogin/$repoShortName';

    onLog('جاري التحقق من المستودع $repoFullName على GitHub...');
    var repoCheck = await http
        .get(Uri.parse('https://api.github.com/repos/$repoFullName'), headers: headers)
        .timeout(const Duration(seconds: 20));

    if (repoCheck.statusCode == 404) {
      onLog('جاري إنشاء مستودع جديد ($repoShortName) تلقائياً في حسابك...');
      final createRes = await http
          .post(
            Uri.parse('https://api.github.com/user/repos'),
            headers: headers,
            body: jsonEncode({
              'name': repoShortName,
              'description': '${project.name} - Built with Klencod Mobile IDE',
              'private': false,
              'auto_init': true,
            }),
          )
          .timeout(const Duration(seconds: 25));
      if (createRes.statusCode >= 400) {
        throw Exception('تعذر إنشاء المستودع تلقائياً: ${createRes.body}');
      }
      await Future<void>.delayed(const Duration(seconds: 2));
      repoCheck = await http
          .get(Uri.parse('https://api.github.com/repos/$repoFullName'), headers: headers)
          .timeout(const Duration(seconds: 20));
    }

    if (repoCheck.statusCode >= 400) {
      throw Exception('تعذر الوصول للمستودع $repoFullName (${repoCheck.statusCode}).');
    }

    final repoData = jsonDecode(repoCheck.body) as Map<String, dynamic>;
    final defaultBranch = (repoData['default_branch'] as String?) ?? 'main';

    onLog('جاري قراءة الفرع الأساسي ($defaultBranch)...');
    final refUri = Uri.parse('https://api.github.com/repos/$repoFullName/git/ref/heads/$defaultBranch');
    final refRes = await http.get(refUri, headers: headers).timeout(const Duration(seconds: 20));
    if (refRes.statusCode >= 400) {
      throw Exception('تعذر قراءة مرجع الفرع $defaultBranch (${refRes.statusCode}).');
    }
    final refData = jsonDecode(refRes.body) as Map<String, dynamic>;
    final latestCommitSha = (refData['object'] as Map<String, dynamic>)['sha'] as String;

    final commitRes = await http
        .get(
          Uri.parse('https://api.github.com/repos/$repoFullName/git/commits/$latestCommitSha'),
          headers: headers,
        )
        .timeout(const Duration(seconds: 20));
    final baseTreeSha = ((jsonDecode(commitRes.body) as Map<String, dynamic>)['tree']
        as Map<String, dynamic>)['sha'] as String;

    final files = project.nodes.where((n) => !n.isFolder).toList();
    final workflowYaml = ProjectTemplates.workflowForType(
      project.type,
      appName: project.name,
      packageName: project.packageName,
      versionName: project.versionName,
      versionCode: project.versionCode,
      buildMode: project.buildMode,
      publishRelease: project.publishReleaseTag,
    );

    final treeItems = <Map<String, dynamic>>[
      for (final file in files)
        if (file.path != '.github/workflows/main.yml')
          {
            'path': file.path,
            'mode': '100644',
            'type': 'blob',
            'content': file.content,
          },
      {
        'path': '.github/workflows/main.yml',
        'mode': '100644',
        'type': 'blob',
        'content': workflowYaml,
      },
    ];

    // إذا اختار المستخدم صورة أيقونة للتطبيق، نرفعها كـ Blob بصيغة base64
    if (project.iconBase64 != null && project.iconBase64!.isNotEmpty) {
      onLog('جاري رفع أيقونة التطبيق المخصصة...');
      final blobRes = await http
          .post(
            Uri.parse('https://api.github.com/repos/$repoFullName/git/blobs'),
            headers: headers,
            body: jsonEncode({
              'content': project.iconBase64,
              'encoding': 'base64',
            }),
          )
          .timeout(const Duration(seconds: 25));
      if (blobRes.statusCode < 300) {
        final iconSha = (jsonDecode(blobRes.body) as Map<String, dynamic>)['sha'] as String;
        treeItems.add({
          'path': 'android/app/src/main/res/drawable/ic_launcher.png',
          'mode': '100644',
          'type': 'blob',
          'sha': iconSha,
        });
      }
    }

    onLog('جاري رفع (${treeItems.length}/${treeItems.length} ملف) إلى GitHub...');
    final treeRes = await http
        .post(
          Uri.parse('https://api.github.com/repos/$repoFullName/git/trees'),
          headers: headers,
          body: jsonEncode({
            'base_tree': baseTreeSha,
            'tree': treeItems,
          }),
        )
        .timeout(const Duration(seconds: 35));
    if (treeRes.statusCode >= 400) {
      throw Exception('فشل رفع شجرة الملفات (${treeRes.statusCode}).');
    }
    final newTreeSha = (jsonDecode(treeRes.body) as Map<String, dynamic>)['sha'] as String;

    final newCommitRes = await http
        .post(
          Uri.parse('https://api.github.com/repos/$repoFullName/git/commits'),
          headers: headers,
          body: jsonEncode({
            'message': 'Build ${project.name} v${project.versionName} (${project.packageName})',
            'tree': newTreeSha,
            'parents': [latestCommitSha],
          }),
        )
        .timeout(const Duration(seconds: 25));
    final newCommitSha = (jsonDecode(newCommitRes.body) as Map<String, dynamic>)['sha'] as String;

    final updateRefRes = await http
        .patch(
          refUri,
          headers: headers,
          body: jsonEncode({'sha': newCommitSha, 'force': false}),
        )
        .timeout(const Duration(seconds: 25));
    if (updateRefRes.statusCode >= 400) {
      throw Exception('فشل تحديث الفرع وتشغيل البناء (${updateRefRes.statusCode}).');
    }

    // تشغيل workflow_dispatch أيضاً لضمان انطلاق البناء فوراً
    try {
      await http.post(
        Uri.parse('https://api.github.com/repos/$repoFullName/actions/workflows/main.yml/dispatches'),
        headers: headers,
        body: jsonEncode({'ref': defaultBranch}),
      );
    } catch (_) {}

    onLog('تم تشغيل GitHub Actions لبناء ملف الـ APK بنجاح ✓');

    return ApkBuildRecord(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      projectId: project.id,
      projectName: project.name,
      packageName: project.packageName,
      versionName: project.versionName,
      projectType: project.type.title,
      repoFullName: repoFullName,
      status: 'running',
      actionsUrl: 'https://github.com/$repoFullName/actions',
      releaseApkUrl: 'https://github.com/$repoFullName/releases',
      createdAt: DateTime.now(),
      logs: [
        'تم رفع (${treeItems.length}/${treeItems.length} ملف) إلى $repoFullName',
        'اسم التطبيق: ${project.name}',
        'اسم الحزمة: ${project.packageName}',
        'الإصدار: ${project.versionName}+${project.versionCode}',
        'نوع البناء: ${project.buildMode.toUpperCase()}',
        'انطلقت عملية البناء على GitHub Actions...',
      ],
    );
  }
}

/// ============================================================================
/// شاشة ربط GitHub الرسمية (مطابقة تماماً لصورة KLENCOD / CONNECT)
/// ============================================================================
class GithubConnectModalScreen extends StatefulWidget {
  const GithubConnectModalScreen({
    super.key,
    required this.onConnected,
  });

  final void Function(String token, String login) onConnected;

  @override
  State<GithubConnectModalScreen> createState() => _GithubConnectModalScreenState();
}

class _GithubConnectModalScreenState extends State<GithubConnectModalScreen> {
  String _statusText = 'لم يتم ربط حساب GitHub';
  String? _userCode;
  String? _verificationUri;
  bool _busy = false;
  bool _connected = false;
  String? _connectedLogin;
  Timer? _pollTimer;

  @override
  void initState() {
    super.initState();
    _checkExistingConnection();
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    super.dispose();
  }

  Future<void> _checkExistingConnection() async {
    final token = await SafeStorage.getString('gh_oauth_token');
    final login = await SafeStorage.getString('gh_oauth_login');
    if (token != null && token.isNotEmpty && mounted) {
      setState(() {
        _connected = true;
        _connectedLogin = login;
        _statusText = 'متصل بحساب GitHub${login != null ? " (@$login)" : ""} ✓';
      });
    }
  }

  Future<void> _startDeviceLogin() async {
    _pollTimer?.cancel();
    setState(() {
      _busy = true;
      _statusText = 'جاري طلب رمز مؤقت من GitHub...';
    });

    try {
      final customClientId = await SafeStorage.getString('gh_custom_client_id');
      final data = await GithubOAuthDeviceService.startDeviceFlow(customClientId: customClientId);
      final userCode = data['user_code'].toString();
      final deviceCode = data['device_code'].toString();
      final verifyUri = (data['verification_uri']?.toString() ?? 'https://github.com/login/device');
      final intervalSec = (data['interval'] as num?)?.toInt() ?? 5;

      // نسخ الرمز تلقائياً لتسهيل اللصق الفوري في صفحة التحقق
      await Clipboard.setData(ClipboardData(text: userCode));

      if (!mounted) return;
      setState(() {
        _userCode = userCode;
        _verificationUri = verifyUri;
        _busy = false;
        _statusText = 'تم نسخ الرمز تلقائياً! اضغط "فتح صفحة التحقق داخل التطبيق" ثم اضغط Continue.';
      });

      _startPolling(deviceCode, intervalSec, customClientId);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _statusText = e.toString().replaceFirst('Exception: ', '');
      });
    }
  }

  void _startPolling(String deviceCode, int intervalSec, String? customClientId) {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(Duration(seconds: intervalSec < 5 ? 5 : intervalSec), (timer) async {
      try {
        final res = await GithubOAuthDeviceService.pollDeviceToken(
          deviceCode: deviceCode,
          customClientId: customClientId,
        );
        if (res['access_token'] != null) {
          timer.cancel();
          final token = res['access_token'].toString();
          final profile = await GithubOAuthDeviceService.fetchUserProfile(token);
          final login = profile['login']?.toString() ?? 'user';

          await SafeStorage.setString('gh_oauth_token', token);
          await SafeStorage.setString('gh_oauth_login', login);

          if (!mounted) return;
          setState(() {
            _connected = true;
            _connectedLogin = login;
            _statusText = 'تم ربط حساب GitHub بنجاح (@$login) ✓';
          });
          widget.onConnected(token, login);
        } else if (res['error'] == 'expired_token' || res['error'] == 'access_denied') {
          timer.cancel();
          if (mounted) {
            setState(() {
              _statusText = 'انتهت صلاحية الرمز أو تم رفض الطلب. اضغط بدء تسجيل الدخول مجدداً.';
            });
          }
        }
      } catch (_) {}
    });
  }

  Future<void> _openVerificationInApp() async {
    final uriStr = _verificationUri ?? 'https://github.com/login/device';
    if (_userCode != null && _userCode!.isNotEmpty) {
      await Clipboard.setData(ClipboardData(text: _userCode!));
    }
    try {
      final uri = Uri.parse(uriStr);
      final launched = await launchUrl(
        uri,
        mode: LaunchMode.inAppBrowserView,
      );
      if (!launched) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      }
    } catch (_) {
      try {
        await launchUrl(Uri.parse(uriStr), mode: LaunchMode.externalApplication);
      } catch (_) {}
    }
  }

  Future<void> _showAdvancedTokenDialog() async {
    final patCtrl = TextEditingController();
    final clientCtrl = TextEditingController(
      text: (await SafeStorage.getString('gh_custom_client_id')) ?? '',
    );
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Text('إعدادات ربط متقدمة (اختياري)'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: patCtrl,
                obscureText: true,
                textDirection: TextDirection.ltr,
                decoration: const InputDecoration(
                  labelText: 'ربط فوري عبر Personal Access Token',
                  hintText: 'ghp_xxxxxxxxxxxxxxxxxxxx',
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: clientCtrl,
                textDirection: TextDirection.ltr,
                decoration: const InputDecoration(
                  labelText: 'OAuth Client ID مخصص (اختياري)',
                  hintText: 'اتركه فارغاً لاستخدام المعرّف الافتراضي',
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('إلغاء')),
          ElevatedButton(
            onPressed: () async {
              if (clientCtrl.text.trim().isNotEmpty) {
                await SafeStorage.setString('gh_custom_client_id', clientCtrl.text.trim());
              }
              if (patCtrl.text.trim().isNotEmpty) {
                try {
                  final profile = await GithubOAuthDeviceService.fetchUserProfile(patCtrl.text.trim());
                  final login = profile['login']?.toString() ?? 'user';
                  await SafeStorage.setString('gh_oauth_token', patCtrl.text.trim());
                  await SafeStorage.setString('gh_oauth_login', login);
                  if (mounted) {
                    setState(() {
                      _connected = true;
                      _connectedLogin = login;
                      _statusText = 'تم ربط حساب GitHub بنجاح (@$login) ✓';
                    });
                    widget.onConnected(patCtrl.text.trim(), login);
                  }
                } catch (e) {
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text(e.toString())),
                    );
                  }
                }
              }
              if (ctx.mounted) Navigator.pop(ctx);
            },
            child: const Text('حفظ'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        backgroundColor: const Color(0xFF0A0E14),
        body: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // الشريط العلوي KLENCOD / CONNECT
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    IconButton(
                      icon: const Icon(Icons.tune_rounded, color: AppColors.textMuted, size: 20),
                      tooltip: 'خيارات متقدمة',
                      onPressed: _showAdvancedTokenDialog,
                    ),
                    const Text(
                      'KLENCOD / CONNECT',
                      textDirection: TextDirection.ltr,
                      style: TextStyle(
                        color: Color(0xFF388BFD),
                        fontSize: 13,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 1.4,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                const Text(
                  'اربط مساحة العمل بـ GitHub',
                  textAlign: TextAlign.right,
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 28,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 6),
                const Text(
                  'تفويض رسمي من دون خادم وسيط',
                  textAlign: TextAlign.right,
                  style: TextStyle(
                    color: AppColors.textMuted,
                    fontSize: 14.5,
                  ),
                ),
                const SizedBox(height: 22),

                // بطاقة: كيف يعمل الربط؟
                Container(
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    color: const Color(0xFF131922),
                    borderRadius: BorderRadius.circular(22),
                    border: Border.all(color: const Color(0xFF263042)),
                  ),
                  child: const Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'كيف يعمل الربط؟',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      SizedBox(height: 10),
                      Text(
                        'يتم طلب رمز مؤقت من GitHub. سيتم ملء الرمز تلقائياً في صفحة التحقق. أنت فقط تضغط Continue ثم توافق. لا يتم حفظ كلمة المرور.',
                        style: TextStyle(
                          color: Color(0xFF9BA4B0),
                          fontSize: 14.5,
                          height: 1.65,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 22),

                // حالة الربط
                Text(
                  _statusText,
                  textAlign: TextAlign.right,
                  style: TextStyle(
                    color: _connected ? AppColors.success : const Color(0xFF9BA4B0),
                    fontSize: 14.5,
                    fontWeight: _connected ? FontWeight.bold : FontWeight.normal,
                  ),
                ),
                const SizedBox(height: 12),

                // صندوق رمز التحقق المؤقت
                Container(
                  height: 82,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: const Color(0xFF131922),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: const Color(0xFF263042)),
                  ),
                  child: _busy
                      ? const SizedBox(
                          width: 26,
                          height: 26,
                          child: CircularProgressIndicator(strokeWidth: 2.5, color: Color(0xFF388BFD)),
                        )
                      : SelectableText(
                          _userCode ?? (_connected ? '✓ @${_connectedLogin ?? ""}' : ''),
                          textDirection: TextDirection.ltr,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 28,
                            fontWeight: FontWeight.w900,
                            letterSpacing: 4,
                            fontFamily: 'monospace',
                          ),
                        ),
                ),
                const SizedBox(height: 14),

                // زر نسخ رمز التحقق
                SizedBox(
                  height: 54,
                  child: OutlinedButton(
                    style: OutlinedButton.styleFrom(
                      backgroundColor: const Color(0xFF131922),
                      foregroundColor: Colors.white,
                      side: const BorderSide(color: Color(0xFF263042)),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
                    ),
                    onPressed: _userCode == null
                        ? null
                        : () async {
                            await Clipboard.setData(ClipboardData(text: _userCode!));
                            if (context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(content: Text('تم نسخ رمز التحقق إلى الحافظة ✓')),
                              );
                            }
                          },
                    child: const Text(
                      'نسخ رمز التحقق',
                      style: TextStyle(fontSize: 15.5, fontWeight: FontWeight.w700),
                    ),
                  ),
                ),
                const SizedBox(height: 12),

                // زر فتح صفحة التحقق داخل التطبيق
                SizedBox(
                  height: 56,
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF4796FF),
                      foregroundColor: Colors.white,
                      elevation: 0,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
                    ),
                    onPressed: _openVerificationInApp,
                    child: const Text(
                      'فتح صفحة التحقق داخل التطبيق',
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                    ),
                  ),
                ),
                const SizedBox(height: 12),

                // زر بدء تسجيل الدخول
                SizedBox(
                  height: 56,
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF4796FF),
                      foregroundColor: Colors.white,
                      elevation: 0,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
                    ),
                    onPressed: _busy ? null : _startDeviceLogin,
                    child: Text(
                      _connected ? 'إعادة ربط حساب آخر' : 'بدء تسجيل الدخول',
                      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                    ),
                  ),
                ),
                const SizedBox(height: 22),

                // زر إغلاق
                Center(
                  child: TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text(
                      'إغلاق',
                      style: TextStyle(color: Color(0xFF9BA4B0), fontSize: 15.5),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// ============================================================================
/// خدمة الذكاء الاصطناعي للتعديل المباشر على الكود (Direct AI Code Mutator)
/// ============================================================================
class AiStudioService {
  static Future<String> sendCodePrompt({
    required String provider, // 'gemini', 'openai', 'deepseek'
    required String apiKey,
    required String model,
    required String prompt,
    required IdeProject project,
    required String activeFilePath,
    required String activeFileContent,
  }) async {
    if (apiKey.trim().isEmpty) {
      throw Exception('يرجى إدخال مفتاح الـ API أولاً من أيقونة المفتاح أعلى النافذة.');
    }

    final fileList = project.nodes.where((n) => !n.isFolder).map((n) => n.path).join(', ');
    final systemPrompt =
        'أنت مطور تطبيقات خبير داخل بيئة تطوير Klencod IDE.\n'
        'نوع المشروع الحالي: ${project.type.title} (${project.type.langTag})\n'
        'اسم التطبيق: ${project.name} | الحزمة: ${project.packageName}\n'
        'ملفات المشروع: $fileList\n'
        'الملف المفتوح حالياً للتعديل المباشر: $activeFilePath\n'
        'محتوى الملف الحالي:\n'
        '```\n$activeFileContent\n```\n'
        'المطلوب منك:\n'
        '1. قم بتنفيذ طلب المستخدم بدقة واحترافية.\n'
        '2. ضع الكود الكامل المحدّث للملف المفتوح داخل بلوك كود ``` ... ``` بحيث يتم تطبيقه وحفظه مباشرةً في الملف المفتوح دون أي نقص.\n'
        '3. اكتب ملخصاً قصيراً جداً (سطرين) لما قمت بتعديله.';

    if (provider == 'gemini') {
      final selectedModel = model.trim().isEmpty ? 'gemini-2.5-flash' : model.trim();
      final uri = Uri.parse(
        'https://generativelanguage.googleapis.com/v1beta/models/$selectedModel:generateContent?key=${apiKey.trim()}',
      );
      final response = await http
          .post(
            uri,
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'system_instruction': {
                'parts': [
                  {'text': systemPrompt}
                ]
              },
              'contents': [
                {
                  'role': 'user',
                  'parts': [
                    {'text': prompt}
                  ]
                }
              ],
              'generationConfig': {'temperature': 0.2},
            }),
          )
          .timeout(const Duration(seconds: 50));

      if (response.statusCode >= 400) {
        throw Exception('خطأ من Gemini API (${response.statusCode}): ${response.body}');
      }
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final candidates = data['candidates'] as List?;
      if (candidates == null || candidates.isEmpty) {
        throw Exception('لم يرجع النموذج أي استجابة.');
      }
      final parts = (candidates.first['content'] as Map<String, dynamic>)['parts'] as List;
      return parts.map((p) => (p as Map<String, dynamic>)['text'] ?? '').join('\n');
    } else {
      final isDeepSeek = provider == 'deepseek';
      final endpoint = isDeepSeek
          ? 'https://api.deepseek.com/chat/completions'
          : 'https://api.openai.com/v1/chat/completions';
      final selectedModel = model.trim().isEmpty
          ? (isDeepSeek ? 'deepseek-chat' : 'gpt-4o-mini')
          : model.trim();

      final response = await http
          .post(
            Uri.parse(endpoint),
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer ${apiKey.trim()}',
            },
            body: jsonEncode({
              'model': selectedModel,
              'temperature': 0.2,
              'messages': [
                {'role': 'system', 'content': systemPrompt},
                {'role': 'user', 'content': prompt},
              ],
            }),
          )
          .timeout(const Duration(seconds: 50));

      if (response.statusCode >= 400) {
        throw Exception('خطأ من API (${response.statusCode}): ${response.body}');
      }
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final choices = data['choices'] as List?;
      if (choices == null || choices.isEmpty) {
        throw Exception('لم يرجع النموذج أي استجابة.');
      }
      return ((choices.first as Map<String, dynamic>)['message'] as Map<String, dynamic>)['content']
              ?.toString() ??
          '';
    }
  }

  static String? extractFirstCodeBlock(String text) {
    final regex = RegExp(r'```(?:[a-zA-Z0-9_+-]+)?\s*\n([\s\S]*?)```');
    final match = regex.firstMatch(text);
    return match?.group(1)?.trimRight();
  }
}

/// ============================================================================
/// التطبيق الرئيسي ذو التبويبات الأربعة (مشاريع | المكتبة | AI | إعدادات)
/// ============================================================================
class KlencodProIdeApp extends StatelessWidget {
  const KlencodProIdeApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Klencod IDE Pro',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(useMaterial3: true).copyWith(
        scaffoldBackgroundColor: AppColors.darkBg,
        colorScheme: const ColorScheme.dark(
          primary: AppColors.primary,
          secondary: AppColors.orange,
          surface: AppColors.surface,
          error: AppColors.danger,
          onPrimary: Colors.white,
          onSurface: AppColors.textPrimary,
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: AppColors.darkBg,
          elevation: 0,
          scrolledUnderElevation: 0,
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: AppColors.surfaceAlt,
          contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: const BorderSide(color: AppColors.border),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: const BorderSide(color: AppColors.border),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: const BorderSide(color: AppColors.primary, width: 1.5),
          ),
        ),
      ),
      home: const MainHomeShell(),
    );
  }
}

class MainHomeShell extends StatefulWidget {
  const MainHomeShell({super.key});

  @override
  State<MainHomeShell> createState() => _MainHomeShellState();
}

class _MainHomeShellState extends State<MainHomeShell> {
  static const String _projectsStorageKey = 'klencod_pro_projects_v4';
  static const String _buildsStorageKey = 'klencod_pro_builds_v4';

  int _selectedTabIndex = 0; // 0: مشاريع, 1: المكتبة, 2: AI, 3: إعدادات
  List<IdeProject> _projects = [];
  List<ApkBuildRecord> _builds = [];
  String? _githubToken;
  String? _githubLogin;

  // إعدادات المساعد الذكي
  String _aiProvider = 'gemini';
  String _aiApiKey = '';
  String _aiModel = 'gemini-2.5-flash';
  bool _aiAutoApply = true; // تعديل مباشر تلقائي على الكود
  final List<Map<String, String>> _aiChatHistory = [];

  @override
  void initState() {
    super.initState();
    // إنشاء مشروع افتراضي فوراً حتى تفتح الواجهة في 0ms بدون أي تعليق
    final defaultProj = IdeProject(
      id: 'default_1',
      name: 'تطبيقي الأول',
      packageName: 'com.klencod.firstapp',
      type: IdeProjectType.flutter,
      updatedAt: DateTime.now(),
      nodes: ProjectTemplates.generateNodes(
        type: IdeProjectType.flutter,
        appName: 'تطبيقي الأول',
        packageName: 'com.klencod.firstapp',
        versionName: '1.0.0',
        versionCode: 1,
      ),
    );
    _projects = [defaultProj];
    _loadSavedStateInBackground();
  }

  Future<void> _loadSavedStateInBackground() async {
    try {
      final token = await SafeStorage.getString('gh_oauth_token');
      final login = await SafeStorage.getString('gh_oauth_login');
      final aiProv = await SafeStorage.getString('ide_ai_provider');
      final aiKey = await SafeStorage.getString('ide_ai_api_key');
      final aiMod = await SafeStorage.getString('ide_ai_model');
      final rawProjects = await SafeStorage.getString(_projectsStorageKey);
      final rawBuilds = await SafeStorage.getString(_buildsStorageKey);

      List<IdeProject>? loadedProjects;
      if (rawProjects != null && rawProjects.isNotEmpty) {
        final list = (jsonDecode(rawProjects) as List)
            .map((e) => IdeProject.fromJson(e as Map<String, dynamic>))
            .toList();
        if (list.isNotEmpty) loadedProjects = list;
      }

      List<ApkBuildRecord>? loadedBuilds;
      if (rawBuilds != null && rawBuilds.isNotEmpty) {
        loadedBuilds = (jsonDecode(rawBuilds) as List)
            .map((e) => ApkBuildRecord.fromJson(e as Map<String, dynamic>))
            .toList();
      }

      if (!mounted) return;
      setState(() {
        _githubToken = token;
        _githubLogin = login;
        if (aiProv != null) _aiProvider = aiProv;
        if (aiKey != null) _aiApiKey = aiKey;
        if (aiMod != null) _aiModel = aiMod;
        if (loadedProjects != null) _projects = loadedProjects;
        if (loadedBuilds != null) _builds = loadedBuilds;
      });
    } catch (_) {}
  }

  Future<void> _persistProjects() async {
    await SafeStorage.setString(
      _projectsStorageKey,
      jsonEncode(_projects.map((p) => p.toJson()).toList()),
    );
  }

  Future<void> _persistBuilds() async {
    await SafeStorage.setString(
      _buildsStorageKey,
      jsonEncode(_builds.map((b) => b.toJson()).toList()),
    );
  }

  /// فتح نافذة "نوع المشروع" المطابقة تماماً للصورة + إعدادات الاسم والحزمة والأيقونة
  Future<void> _showNewProjectTypeSelector() async {
    final chosenType = await showModalBottomSheet<IdeProjectType>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) {
        return Directionality(
          textDirection: TextDirection.rtl,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  'نوع المشروع',
                  style: TextStyle(fontSize: 22, fontWeight: FontWeight.w900, color: Colors.white),
                ),
                const SizedBox(height: 4),
                const Text(
                  'اختر نوع المشروع الذي تريد إنشاءه:',
                  style: TextStyle(fontSize: 13.5, color: AppColors.textMuted),
                ),
                const SizedBox(height: 16),
                for (final t in IdeProjectType.values)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(18),
                      onTap: () => Navigator.pop(ctx, t),
                      child: Container(
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: AppColors.darkBg,
                          borderRadius: BorderRadius.circular(18),
                          border: Border.all(color: AppColors.border),
                        ),
                        child: Row(
                          children: [
                            Container(
                              width: 52,
                              height: 52,
                              decoration: BoxDecoration(
                                color: t.badgeColor.withOpacity(0.15),
                                borderRadius: BorderRadius.circular(14),
                              ),
                              alignment: Alignment.center,
                              child: Icon(
                                switch (t) {
                                  IdeProjectType.flutter => Icons.flutter_dash_rounded,
                                  IdeProjectType.androidJava => Icons.coffee_rounded,
                                  IdeProjectType.androidKotlin => Icons.android_rounded,
                                  IdeProjectType.reactNative => Icons.hub_rounded,
                                },
                                color: t.badgeColor,
                                size: 30,
                              ),
                            ),
                            const SizedBox(width: 14),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    t.title,
                                    style: const TextStyle(
                                      fontSize: 17,
                                      fontWeight: FontWeight.w800,
                                      color: Colors.white,
                                    ),
                                  ),
                                  const SizedBox(height: 3),
                                  Text(
                                    t.subtitle,
                                    style: const TextStyle(fontSize: 12.5, color: AppColors.textMuted),
                                  ),
                                  const SizedBox(height: 8),
                                  Wrap(
                                    spacing: 6,
                                    children: [
                                      _miniBadge(t.langTag, t.badgeColor),
                                      _miniBadge(t.extTag, AppColors.textMuted),
                                      _miniBadge('GitHub Actions', AppColors.primary),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                            const Icon(Icons.chevron_right_rounded, color: AppColors.textMuted),
                          ],
                        ),
                      ),
                    ),
                  ),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton(
                    onPressed: () => Navigator.pop(ctx),
                    child: const Text('إلغاء'),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );

    if (chosenType == null || !mounted) return;
    await _showProjectConfigDialog(initialType: chosenType);
  }

  Widget _miniBadge(String text, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withOpacity(0.15),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withOpacity(0.45)),
      ),
      child: Text(
        text,
        textDirection: TextDirection.ltr,
        style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: color),
      ),
    );
  }

  /// نافذة إعدادات المشروع وتخصيص الاسم والحزمة والأيقونة وإعدادات النشر
  Future<void> _showProjectConfigDialog({
    IdeProject? existingProject,
    IdeProjectType initialType = IdeProjectType.flutter,
    String templateKind = 'default',
  }) async {
    final isEdit = existingProject != null;
    final nameCtrl = TextEditingController(text: existingProject?.name ?? 'تطبيقي الاحترافي');
    final pkgCtrl = TextEditingController(
      text: existingProject?.packageName ?? 'com.klencod.app${_projects.length + 1}',
    );
    final verNameCtrl = TextEditingController(text: existingProject?.versionName ?? '1.0.0');
    final verCodeCtrl = TextEditingController(text: '${existingProject?.versionCode ?? 1}');
    final repoCtrl = TextEditingController(text: existingProject?.githubRepo ?? '');

    var buildMode = existingProject?.buildMode ?? 'release';
    var publishRelease = existingProject?.publishReleaseTag ?? true;
    var iconBase64 = existingProject?.iconBase64;

    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setModalState) {
            Future<void> pickAppIcon() async {
              try {
                final res = await FilePicker.platform.pickFiles(
                  type: FileType.custom,
                  allowedExtensions: ['png', 'jpg', 'jpeg'],
                );
                final path = res?.files.single.path;
                if (path == null) return;
                final bytes = await File(path).readAsBytes();
                setModalState(() {
                  iconBase64 = base64Encode(bytes);
                });
              } catch (e) {
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('تعذر اختيار الصورة: $e')),
                  );
                }
              }
            }

            return Directionality(
              textDirection: TextDirection.rtl,
              child: Padding(
                padding: EdgeInsets.only(
                  left: 18,
                  right: 18,
                  top: 18,
                  bottom: MediaQuery.of(ctx).viewInsets.bottom + 18,
                ),
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        isEdit
                            ? 'إعدادات التطبيق والنشر (${existingProject.name})'
                            : 'تخصيص وإنشاء مشروع ${initialType.title}',
                        style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
                      ),
                      const SizedBox(height: 14),

                      // اختيار صورة / أيقونة التطبيق
                      Row(
                        children: [
                          GestureDetector(
                            onTap: pickAppIcon,
                            child: Container(
                              width: 64,
                              height: 64,
                              decoration: BoxDecoration(
                                color: AppColors.surfaceAlt,
                                borderRadius: BorderRadius.circular(16),
                                border: Border.all(color: AppColors.primary),
                              ),
                              clipBehavior: Clip.antiAlias,
                              child: iconBase64 != null && iconBase64!.isNotEmpty
                                  ? Image.memory(
                                      base64Decode(iconBase64!),
                                      fit: BoxFit.cover,
                                    )
                                  : const Icon(Icons.add_photo_alternate_outlined,
                                      color: AppColors.primary, size: 30),
                            ),
                          ),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text(
                                  'أيقونة التطبيق (App Icon)',
                                  style: TextStyle(fontWeight: FontWeight.bold),
                                ),
                                const SizedBox(height: 4),
                                const Text(
                                  'اختر صورة PNG أو JPG لتعيينها كأيقونة رسمية للـ APK عند البناء',
                                  style: TextStyle(fontSize: 12, color: AppColors.textMuted),
                                ),
                                TextButton.icon(
                                  onPressed: pickAppIcon,
                                  icon: const Icon(Icons.image_outlined, size: 16),
                                  label: Text(iconBase64 == null ? 'اختيار صورة التطبيق' : 'تغيير الصورة'),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),

                      TextField(
                        controller: nameCtrl,
                        decoration: const InputDecoration(
                          labelText: 'اسم التطبيق (App Name)',
                          prefixIcon: Icon(Icons.apps_rounded),
                        ),
                      ),
                      const SizedBox(height: 10),

                      TextField(
                        controller: pkgCtrl,
                        textDirection: TextDirection.ltr,
                        decoration: const InputDecoration(
                          labelText: 'اسم الحزمة (Package Name / Application ID)',
                          hintText: 'com.company.myapp',
                          prefixIcon: Icon(Icons.inventory_2_outlined),
                        ),
                      ),
                      const SizedBox(height: 10),

                      Row(
                        children: [
                          Expanded(
                            child: TextField(
                              controller: verNameCtrl,
                              textDirection: TextDirection.ltr,
                              decoration: const InputDecoration(
                                labelText: 'اسم الإصدار (Version)',
                                hintText: '1.0.0',
                              ),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: TextField(
                              controller: verCodeCtrl,
                              keyboardType: TextInputType.number,
                              textDirection: TextDirection.ltr,
                              decoration: const InputDecoration(
                                labelText: 'رقم البناء (Build Number)',
                                hintText: '1',
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),

                      TextField(
                        controller: repoCtrl,
                        textDirection: TextDirection.ltr,
                        decoration: const InputDecoration(
                          labelText: 'مستودع GitHub للنشر (اختياري: يُنشأ تلقائياً إن تُرك فارغاً)',
                          hintText: 'username/my-repo',
                          prefixIcon: Icon(Icons.cloud_outlined),
                        ),
                      ),
                      const SizedBox(height: 12),

                      const Text('نوع مخرجات البناء والنشر:', style: TextStyle(fontWeight: FontWeight.bold)),
                      const SizedBox(height: 6),
                      SegmentedButton<String>(
                        segments: const [
                          ButtonSegment(value: 'release', label: Text('Release APK (للنشر)')),
                          ButtonSegment(value: 'debug', label: Text('Debug APK (للتجربة)')),
                        ],
                        selected: {buildMode},
                        onSelectionChanged: (s) => setModalState(() => buildMode = s.first),
                      ),
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: const Text('تجهيز إصدار GitHub Release وملف APK قابل للتنزيل'),
                        value: publishRelease,
                        onChanged: (v) => setModalState(() => publishRelease = v),
                      ),
                      const SizedBox(height: 10),

                      ElevatedButton.icon(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppColors.primary,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                        ),
                        icon: Icon(isEdit ? Icons.save_outlined : Icons.rocket_launch_rounded),
                        label: Text(
                          isEdit ? 'حفظ إعدادات التطبيق' : 'إنشاء المشروع وفتح المحرر',
                          style: const TextStyle(fontSize: 15.5, fontWeight: FontWeight.bold),
                        ),
                        onPressed: () async {
                          final appName = nameCtrl.text.trim().isEmpty ? 'My App' : nameCtrl.text.trim();
                          final pkg = pkgCtrl.text.trim().isEmpty ? 'com.klencod.app' : pkgCtrl.text.trim();
                          final vName = verNameCtrl.text.trim().isEmpty ? '1.0.0' : verNameCtrl.text.trim();
                          final vCode = int.tryParse(verCodeCtrl.text.trim()) ?? 1;

                          if (isEdit) {
                            setState(() {
                              existingProject.name = appName;
                              existingProject.packageName = pkg;
                              existingProject.versionName = vName;
                              existingProject.versionCode = vCode;
                              existingProject.buildMode = buildMode;
                              existingProject.publishReleaseTag = publishRelease;
                              existingProject.iconBase64 = iconBase64;
                              existingProject.githubRepo =
                                  repoCtrl.text.trim().isEmpty ? null : repoCtrl.text.trim();
                              existingProject.updatedAt = DateTime.now();
                            });
                            await _persistProjects();
                            if (ctx.mounted) Navigator.pop(ctx);
                          } else {
                            final newProj = IdeProject(
                              id: DateTime.now().millisecondsSinceEpoch.toString(),
                              name: appName,
                              packageName: pkg,
                              versionName: vName,
                              versionCode: vCode,
                              type: initialType,
                              buildMode: buildMode,
                              publishReleaseTag: publishRelease,
                              iconBase64: iconBase64,
                              githubRepo: repoCtrl.text.trim().isEmpty ? null : repoCtrl.text.trim(),
                              updatedAt: DateTime.now(),
                              nodes: ProjectTemplates.generateNodes(
                                type: initialType,
                                appName: appName,
                                packageName: pkg,
                                versionName: vName,
                                versionCode: vCode,
                                templateKind: templateKind,
                              ),
                            );
                            setState(() {
                              _projects.insert(0, newProj);
                            });
                            await _persistProjects();
                            if (ctx.mounted) Navigator.pop(ctx);
                            if (mounted) _openProjectInEditor(newProj);
                          }
                        },
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  /// استيراد مشروع كامل من ملف ZIP وفتحه كمشروع جديد مع إمكانية تخصيص حزمته وأيقونته
  Future<void> _importProjectFromZip() async {
    try {
      final res = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['zip'],
      );
      final filePath = res?.files.single.path;
      if (filePath == null) return;

      final bytes = await File(filePath).readAsBytes();
      final archive = ZipDecoder().decodeBytes(bytes);
      final importedNodes = <IdeNode>[];
      final seenFolders = <String>{};

      for (final entry in archive) {
        var relPath = entry.name.replaceAll('\\', '/');
        relPath = relPath.replaceAll(RegExp(r'^/+|/+$'), '');
        if (relPath.isEmpty || relPath.startsWith('.git/')) continue;

        final parts = relPath.split('/');
        var currentFolder = '';
        for (var i = 0; i < parts.length - 1; i++) {
          currentFolder = currentFolder.isEmpty ? parts[i] : '$currentFolder/${parts[i]}';
          if (seenFolders.add(currentFolder)) {
            importedNodes.add(IdeNode(path: currentFolder, isFolder: true));
          }
        }

        if (entry.isFile) {
          final ext = relPath.split('.').last.toLowerCase();
          const textExts = {
            'dart', 'yaml', 'yml', 'json', 'xml', 'gradle', 'kts',
            'properties', 'md', 'txt', 'html', 'css', 'js', 'java', 'kt', 'tsx', 'ts', 'sh'
          };
          if (textExts.contains(ext) && entry.size < 1024 * 600) {
            final rawBytes = entry.content;
            final bytesList = rawBytes is List<int> ? rawBytes : <int>[];
            final content = utf8.decode(bytesList, allowMalformed: true);
            importedNodes.add(IdeNode(path: relPath, isFolder: false, content: content));
          }
        }
      }

      if (importedNodes.isEmpty) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('لم يتم العثور على ملفات برمجية داخل ملف الـ ZIP.')),
        );
        return;
      }

      // اكتشاف نوع المشروع تلقائياً
      var detectedType = IdeProjectType.flutter;
      if (importedNodes.any((n) => n.path.endsWith('.tsx') || n.path == 'package.json')) {
        detectedType = IdeProjectType.reactNative;
      } else if (importedNodes.any((n) => n.path.endsWith('.java')) &&
          !importedNodes.any((n) => n.path == 'pubspec.yaml')) {
        detectedType = IdeProjectType.androidJava;
      } else if (importedNodes.any((n) => n.path.endsWith('.kt')) &&
          !importedNodes.any((n) => n.path == 'pubspec.yaml')) {
        detectedType = IdeProjectType.androidKotlin;
      }

      final zipName = res!.files.single.name.replaceAll(RegExp(r'\.zip$', caseSensitive: false), '');
      final importedProj = IdeProject(
        id: DateTime.now().millisecondsSinceEpoch.toString(),
        name: zipName,
        packageName: 'com.klencod.${zipName.toLowerCase().replaceAll(RegExp(r"[^a-z0-9]"), "")}',
        type: detectedType,
        updatedAt: DateTime.now(),
        nodes: importedNodes,
      );

      setState(() {
        _projects.insert(0, importedProj);
      });
      await _persistProjects();
      if (!mounted) return;
      _openProjectInEditor(importedProj);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('خطأ أثناء استيراد ملف الـ ZIP: $e')),
      );
    }
  }

  /// تصدير وحفظ أي مشروع كملف ZIP في الهاتف
  Future<void> _exportProjectAsZip(IdeProject project) async {
    try {
      final archive = Archive();
      for (final node in project.nodes) {
        if (node.isFolder) continue;
        final bytes = utf8.encode(node.content);
        archive.addFile(ArchiveFile(node.path, bytes.length, bytes));
      }
      final zipBytes = ZipEncoder().encode(archive) ?? [];
      final outPath = '${Directory.systemTemp.path}/${project.name.replaceAll(" ", "_")}.zip';
      await File(outPath).writeAsBytes(zipBytes);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('تم حفظ نسخة ZIP للمشروع (${(zipBytes.length / 1024).toStringAsFixed(1)} KB) في: $outPath'),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('تعذر تصدير المشروع: $e')),
      );
    }
  }

  void _openProjectInEditor(IdeProject project) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ProjectEditorFullScreen(
          project: project,
          githubToken: _githubToken,
          githubLogin: _githubLogin,
          aiProvider: _aiProvider,
          aiApiKey: _aiApiKey,
          aiModel: _aiModel,
          onSaveProject: () async {
            project.updatedAt = DateTime.now();
            await _persistProjects();
            if (mounted) setState(() {});
          },
          onConfigureApp: () => _showProjectConfigDialog(existingProject: project),
          onOpenGithubConnect: _openGithubConnectScreen,
          onBuildRecorded: (record) async {
            setState(() {
              _builds.insert(0, record);
            });
            await _persistBuilds();
          },
        ),
      ),
    );
  }

  Future<void> _openGithubConnectScreen() async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => GithubConnectModalScreen(
          onConnected: (token, login) {
            setState(() {
              _githubToken = token;
              _githubLogin = login;
            });
          },
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(
          title: Row(
            children: [
              const Text(
                'KlencodIDE',
                style: TextStyle(
                  fontWeight: FontWeight.w900,
                  fontSize: 22,
                  letterSpacing: 0.5,
                  color: Colors.white,
                ),
              ),
              const Spacer(),
              InkWell(
                borderRadius: BorderRadius.circular(20),
                onTap: _openGithubConnectScreen,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                  decoration: BoxDecoration(
                    color: _githubToken != null
                        ? AppColors.success.withOpacity(0.16)
                        : AppColors.surfaceAlt,
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                      color: _githubToken != null ? AppColors.success : AppColors.border,
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.circle,
                        size: 9,
                        color: _githubToken != null ? AppColors.success : AppColors.warning,
                      ),
                      const SizedBox(width: 6),
                      Text(
                        _githubToken != null ? '@${_githubLogin ?? "GitHub"}' : 'ربط GitHub',
                        style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
        body: IndexedStack(
          index: _selectedTabIndex,
          children: [
            _buildProjectsTab(),
            _buildLibraryAndApksTab(),
            _buildGlobalAiStudioTab(),
            _buildSettingsTab(),
          ],
        ),
        bottomNavigationBar: Container(
          decoration: const BoxDecoration(
            border: Border(top: BorderSide(color: AppColors.border, width: 0.7)),
          ),
          child: BottomNavigationBar(
            currentIndex: _selectedTabIndex,
            onTap: (i) => setState(() => _selectedTabIndex = i),
            type: BottomNavigationBarType.fixed,
            backgroundColor: AppColors.darkBg,
            selectedItemColor: AppColors.primary,
            unselectedItemColor: AppColors.textMuted,
            items: const [
              BottomNavigationBarItem(icon: Icon(Icons.folder_copy_outlined), label: 'مشاريع'),
              BottomNavigationBarItem(icon: Icon(Icons.android_rounded), label: 'المكتبة (APK)'),
              BottomNavigationBarItem(icon: Icon(Icons.auto_awesome_rounded), label: 'AI'),
              BottomNavigationBarItem(icon: Icon(Icons.settings_outlined), label: 'إعدادات'),
            ],
          ),
        ),
      ),
    );
  }

  /// 1. تبويب المشاريع (مشابه لواجهة Klencod IDE مع أزرار + مشروع جديد، القوالب الجاهزة، واستيراد ZIP)
  Widget _buildProjectsTab() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Row(
          children: [
            Expanded(
              child: SizedBox(
                height: 48,
                child: ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF133268),
                    foregroundColor: const Color(0xFF68A6FF),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                      side: const BorderSide(color: Color(0xFF2352A0)),
                    ),
                  ),
                  onPressed: _showNewProjectTypeSelector,
                  icon: const Icon(Icons.add, size: 20),
                  label: const Text('مشروع جديد', style: TextStyle(fontWeight: FontWeight.bold)),
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: SizedBox(
                height: 48,
                child: OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    backgroundColor: AppColors.surface,
                    foregroundColor: AppColors.textPrimary,
                    side: const BorderSide(color: AppColors.border),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                  ),
                  onPressed: _showReadyTemplatesSheet,
                  icon: const Icon(Icons.dashboard_customize_outlined, size: 18),
                  label: const Text('القوالب الجاهزة', style: TextStyle(fontWeight: FontWeight.bold)),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        SizedBox(
          height: 46,
          child: OutlinedButton.icon(
            style: OutlinedButton.styleFrom(
              backgroundColor: AppColors.surface,
              foregroundColor: AppColors.orange,
              side: BorderSide(color: AppColors.orange.withOpacity(0.45)),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
            ),
            onPressed: _importProjectFromZip,
            icon: const Icon(Icons.folder_zip_outlined),
            label: const Text(
              'استيراد مشروع من الهاتف (ZIP) وتخصيص حزمته وأيقونته',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
            ),
          ),
        ),
        const SizedBox(height: 20),
        const Text(
          'مشاريعك الحالية',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 10),
        for (final proj in _projects)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: AppColors.surface,
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: AppColors.border),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      GestureDetector(
                        onTap: () => _showProjectConfigDialog(existingProject: proj),
                        child: Container(
                          width: 48,
                          height: 48,
                          decoration: BoxDecoration(
                            color: proj.type.badgeColor.withOpacity(0.15),
                            borderRadius: BorderRadius.circular(13),
                            border: Border.all(color: proj.type.badgeColor.withOpacity(0.4)),
                          ),
                          clipBehavior: Clip.antiAlias,
                          child: proj.iconBase64 != null && proj.iconBase64!.isNotEmpty
                              ? Image.memory(base64Decode(proj.iconBase64!), fit: BoxFit.cover)
                              : Icon(Icons.code_rounded, color: proj.type.badgeColor, size: 26),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              proj.name,
                              style: const TextStyle(fontSize: 16.5, fontWeight: FontWeight.w800),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              '${proj.packageName} • v${proj.versionName}+${proj.versionCode}',
                              textDirection: TextDirection.ltr,
                              style: const TextStyle(fontSize: 12, color: AppColors.textMuted),
                            ),
                          ],
                        ),
                      ),
                      _miniBadge(proj.type.title, proj.type.badgeColor),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      ElevatedButton.icon(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppColors.primary,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                        ),
                        onPressed: () => _openProjectInEditor(proj),
                        icon: const Icon(Icons.edit_note_rounded, size: 18),
                        label: const Text('فتح المحرر والكود'),
                      ),
                      OutlinedButton.icon(
                        onPressed: () => _showProjectConfigDialog(existingProject: proj),
                        icon: const Icon(Icons.tune_rounded, size: 17),
                        label: const Text('الأيقونة والحزمة والنشر'),
                      ),
                      OutlinedButton.icon(
                        onPressed: () => _exportProjectAsZip(proj),
                        icon: const Icon(Icons.download_outlined, size: 17),
                        label: const Text('حفظ ZIP'),
                      ),
                      if (_projects.length > 1)
                        IconButton(
                          icon: const Icon(Icons.delete_outline, color: AppColors.danger, size: 20),
                          onPressed: () async {
                            setState(() => _projects.removeWhere((p) => p.id == proj.id));
                            await _persistProjects();
                          },
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }

  Future<void> _showReadyTemplatesSheet() async {
    final templates = [
      ('متجر إلكتروني متكامل', 'store', IdeProjectType.flutter, Icons.shopping_bag_outlined),
      ('آلة حاسبة احترافية', 'calculator', IdeProjectType.flutter, Icons.calculate_outlined),
      ('تطبيق أندرويد Java أصلي', 'default', IdeProjectType.androidJava, Icons.coffee_outlined),
      ('تطبيق أندرويد Kotlin أصلي', 'default', IdeProjectType.androidKotlin, Icons.android_outlined),
      ('تطبيق React Native عداد', 'default', IdeProjectType.reactNative, Icons.hub_outlined),
    ];

    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => Directionality(
        textDirection: TextDirection.rtl,
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('القوالب الجاهزة للبدء السريع',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              const SizedBox(height: 12),
              for (final t in templates)
                ListTile(
                  leading: Icon(t.$4, color: AppColors.primary),
                  title: Text(t.$1),
                  subtitle: Text(t.$3.subtitle, style: const TextStyle(fontSize: 12)),
                  trailing: const Icon(Icons.add_circle_outline, color: AppColors.orange),
                  onTap: () {
                    Navigator.pop(ctx);
                    _showProjectConfigDialog(initialType: t.$3, templateKind: t.$2);
                  },
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// 2. تبويب المكتبة وحفظ ملفات الـ APK المبنية وسجلات البناء
  Widget _buildLibraryAndApksTab() {
    if (_builds.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.android_rounded, size: 64, color: AppColors.textMuted),
              const SizedBox(height: 12),
              const Text(
                'لا توجد ملفات APK محفوظة بعد',
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 6),
              const Text(
                'افتح أي مشروع واضغط "بناء APK" ليتم حفظ نسخ الـ APK وسجلات البناء وروابط التنزيل هنا.',
                textAlign: TextAlign.center,
                style: TextStyle(color: AppColors.textMuted, fontSize: 13),
              ),
            ],
          ),
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: _builds.length,
      itemBuilder: (ctx, i) {
        final b = _builds[i];
        return Card(
          color: AppColors.surface,
          margin: const EdgeInsets.only(bottom: 12),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(18),
            side: const BorderSide(color: AppColors.border),
          ),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.android_rounded, color: AppColors.success, size: 28),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '${b.projectName} (v${b.versionName})',
                            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                          ),
                          Text(
                            '${b.packageName} • ${b.repoFullName}',
                            textDirection: TextDirection.ltr,
                            style: const TextStyle(fontSize: 12, color: AppColors.textMuted),
                          ),
                        ],
                      ),
                    ),
                    _miniBadge(b.projectType, AppColors.primary),
                  ],
                ),
                const Divider(height: 20),
                for (final logLine in b.logs)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 3),
                    child: Row(
                      children: [
                        const Icon(Icons.check_circle, color: AppColors.success, size: 15),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(logLine, style: const TextStyle(fontSize: 12.5)),
                        ),
                      ],
                    ),
                  ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 8,
                  children: [
                    ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.primary,
                        foregroundColor: Colors.white,
                      ),
                      icon: const Icon(Icons.open_in_new, size: 17),
                      label: const Text('فتح GitHub Actions وتنزيل APK'),
                      onPressed: () => launchUrl(
                        Uri.parse(b.actionsUrl),
                        mode: LaunchMode.externalApplication,
                      ),
                    ),
                    if (b.releaseApkUrl != null)
                      OutlinedButton.icon(
                        icon: const Icon(Icons.new_releases_outlined, size: 17),
                        label: const Text('صفحة الإصدارات (Releases)'),
                        onPressed: () => launchUrl(
                          Uri.parse(b.releaseApkUrl!),
                          mode: LaunchMode.externalApplication,
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// 3. تبويب الذكاء الاصطناعي الشامل (يعدل مباشرة على الكود في المشروع النشط)
  Widget _buildGlobalAiStudioTab() {
    final activeProject = _projects.first;
    final mainNode = activeProject.nodes.where((n) => !n.isFolder).firstOrNull;
    final promptCtrl = TextEditingController();
    final apiKeyCtrl = TextEditingController(text: _aiApiKey);
    final modelCtrl = TextEditingController(text: _aiModel);
    bool busy = false;

    return StatefulBuilder(
      builder: (ctx, setTabState) {
        Future<void> runAiPrompt(String textPrompt) async {
          if (textPrompt.trim().isEmpty) return;
          setTabState(() {
            busy = true;
            _aiChatHistory.add({'role': 'user', 'text': textPrompt});
          });

          await SafeStorage.setString('ide_ai_provider', _aiProvider);
          await SafeStorage.setString('ide_ai_api_key', apiKeyCtrl.text.trim());
          await SafeStorage.setString('ide_ai_model', modelCtrl.text.trim());
          _aiApiKey = apiKeyCtrl.text.trim();
          _aiModel = modelCtrl.text.trim();

          try {
            final targetNode = activeProject.nodes
                    .where((n) => !n.isFolder && (n.path.endsWith('.dart') || n.path.endsWith('.java') || n.path.endsWith('.kt') || n.path.endsWith('.tsx')))
                    .firstOrNull ??
                mainNode;

            final reply = await AiStudioService.sendCodePrompt(
              provider: _aiProvider,
              apiKey: _aiApiKey,
              model: _aiModel,
              prompt: textPrompt,
              project: activeProject,
              activeFilePath: targetNode?.path ?? 'lib/main.dart',
              activeFileContent: targetNode?.content ?? '',
            );

            final extracted = AiStudioService.extractFirstCodeBlock(reply);
            var appliedNotice = '';
            if (_aiAutoApply && extracted != null && targetNode != null) {
              targetNode.content = extracted;
              targetNode.isDirty = false;
              await _persistProjects();
              appliedNotice = '\n\n✅ [تم تطبيق الكود الجديد مباشرة على الملف ${targetNode.path} وحفظه تلقائياً]';
            }

            setTabState(() {
              _aiChatHistory.add({'role': 'ai', 'text': '$reply$appliedNotice'});
            });
          } catch (e) {
            setTabState(() {
              _aiChatHistory.add({
                'role': 'error',
                'text': e.toString().replaceFirst('Exception: ', ''),
              });
            });
          } finally {
            setTabState(() => busy = false);
          }
        }

        return Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppColors.surface,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: AppColors.border),
                ),
                child: Column(
                  children: [
                    Row(
                      children: [
                        const Icon(Icons.auto_awesome, color: AppColors.orange),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'المساعد الذكي المباشر • يعدل على مشروع (${activeProject.name})',
                            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13.5),
                          ),
                        ),
                        Switch(
                          value: _aiAutoApply,
                          onChanged: (v) => setState(() => _aiAutoApply = v),
                        ),
                        const Text('تعديل مباشر', style: TextStyle(fontSize: 11.5)),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        DropdownButton<String>(
                          value: _aiProvider,
                          underline: const SizedBox(),
                          items: const [
                            DropdownMenuItem(value: 'gemini', child: Text('Google Gemini')),
                            DropdownMenuItem(value: 'openai', child: Text('OpenAI GPT')),
                            DropdownMenuItem(value: 'deepseek', child: Text('DeepSeek Coder')),
                          ],
                          onChanged: (v) {
                            if (v == null) return;
                            setState(() {
                              _aiProvider = v;
                              _aiModel = v == 'gemini'
                                  ? 'gemini-2.5-flash'
                                  : (v == 'deepseek' ? 'deepseek-chat' : 'gpt-4o-mini');
                              modelCtrl.text = _aiModel;
                            });
                          },
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: TextField(
                            controller: apiKeyCtrl,
                            obscureText: true,
                            textDirection: TextDirection.ltr,
                            decoration: const InputDecoration(
                              labelText: 'مفتاح الـ API',
                              isDense: true,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    for (final chip in [
                      'صمم واجهة احترافية عصرية للتطبيق',
                      'أضف شاشة تسجيل دخول وحساب مستخدم',
                      'أضف قاعدة بيانات وحفظ محلي للبيانات',
                      'أصلح أي أخطاء برمجية وحسّن الأداء',
                    ])
                      Padding(
                        padding: const EdgeInsets.only(left: 6),
                        child: ActionChip(
                          label: Text(chip, style: const TextStyle(fontSize: 11.5)),
                          onPressed: busy ? null : () => runAiPrompt(chip),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              Expanded(
                child: _aiChatHistory.isEmpty
                    ? const Center(
                        child: Text(
                          'اكتب أي وصف للتطبيق أو التعديل المطلوب، وسيقوم الذكاء الاصطناعي بكتابة الكود وتطبيقه مباشرةً داخل مشروعك!',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: AppColors.textMuted),
                        ),
                      )
                    : ListView.builder(
                        itemCount: _aiChatHistory.length,
                        itemBuilder: (ctx, i) {
                          final msg = _aiChatHistory[i];
                          final isUser = msg['role'] == 'user';
                          final isErr = msg['role'] == 'error';
                          return Container(
                            margin: const EdgeInsets.only(bottom: 10),
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: isUser
                                  ? AppColors.primary.withOpacity(0.18)
                                  : (isErr ? AppColors.danger.withOpacity(0.15) : AppColors.surface),
                              borderRadius: BorderRadius.circular(14),
                              border: Border.all(
                                color: isUser
                                    ? AppColors.primary
                                    : (isErr ? AppColors.danger : AppColors.border),
                              ),
                            ),
                            child: SelectableText(
                              msg['text'] ?? '',
                              style: const TextStyle(fontSize: 13, height: 1.5),
                            ),
                          );
                        },
                      ),
              ),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: promptCtrl,
                      decoration: const InputDecoration(
                        hintText: 'اطلب أي تعديل مباشر على الكود...',
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.orange,
                      foregroundColor: Colors.black,
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                    ),
                    onPressed: busy
                        ? null
                        : () {
                            final text = promptCtrl.text;
                            promptCtrl.clear();
                            runAiPrompt(text);
                          },
                    icon: busy
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2, color: Colors.black),
                          )
                        : const Icon(Icons.send_rounded),
                    label: const Text('تطبيق'),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }

  /// 4. تبويب الإعدادات الشاملة
  Widget _buildSettingsTab() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Card(
          color: AppColors.surface,
          child: ListTile(
            leading: const Icon(Icons.hub_rounded, color: AppColors.primary, size: 30),
            title: const Text('حساب GitHub والبناء السحابي',
                style: TextStyle(fontWeight: FontWeight.bold)),
            subtitle: Text(
              _githubToken != null
                  ? 'متصل بحساب @${_githubLogin ?? "GitHub"} (تفويض رسمي مباشر)'
                  : 'غير متصل - اضغط لربط مساحة العمل بـ GitHub',
            ),
            trailing: ElevatedButton(
              onPressed: _openGithubConnectScreen,
              child: Text(_githubToken != null ? 'إدارة الربط' : 'ربط الحساب'),
            ),
          ),
        ),
        const SizedBox(height: 12),
        if (_githubToken != null)
          Card(
            color: AppColors.surface,
            child: ListTile(
              leading: const Icon(Icons.link_off_rounded, color: AppColors.danger),
              title: const Text('تسجيل الخروج وفصل حساب GitHub'),
              onTap: () async {
                await SafeStorage.remove('gh_oauth_token');
                await SafeStorage.remove('gh_oauth_login');
                setState(() {
                  _githubToken = null;
                  _githubLogin = null;
                });
              },
            ),
          ),
        const SizedBox(height: 12),
        Card(
          color: AppColors.surface,
          child: SwitchListTile(
            title: const Text('التعديل المباشر التلقائي للذكاء الاصطناعي'),
            subtitle: const Text('تحديث وحفظ ملف الكود المفتوح تلقائياً فور توليد الكود'),
            value: _aiAutoApply,
            onChanged: (v) => setState(() => _aiAutoApply = v),
          ),
        ),
      ],
    );
  }
}

/// ============================================================================
/// شاشة محرر الأكواد الكاملة للمشروع المفتوح (Code Editor + File Tree + Live AI + Build)
/// ============================================================================
class ProjectEditorFullScreen extends StatefulWidget {
  const ProjectEditorFullScreen({
    super.key,
    required this.project,
    required this.githubToken,
    required this.githubLogin,
    required this.aiProvider,
    required this.aiApiKey,
    required this.aiModel,
    required this.onSaveProject,
    required this.onConfigureApp,
    required this.onOpenGithubConnect,
    required this.onBuildRecorded,
  });

  final IdeProject project;
  final String? githubToken;
  final String? githubLogin;
  final String aiProvider;
  final String aiApiKey;
  final String aiModel;
  final Future<void> Function() onSaveProject;
  final Future<void> Function() onConfigureApp;
  final Future<void> Function() onOpenGithubConnect;
  final Future<void> Function(ApkBuildRecord record) onBuildRecorded;

  @override
  State<ProjectEditorFullScreen> createState() => _ProjectEditorFullScreenState();
}

class _ProjectEditorFullScreenState extends State<ProjectEditorFullScreen> {
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  late final CodeSyntaxController _codeController;
  final ScrollController _editorScrollController = ScrollController();

  late List<String> _openTabs;
  String? _activeFilePath;
  String? _previousCodeSnapshot; // للتراجع السريع عن تعديل الذكاء الاصطناعي
  final Set<String> _expandedFolders = {'lib', 'app', 'app/src', 'app/src/main', '.github', '.github/workflows'};

  @override
  void initState() {
    super.initState();
    final firstFile = widget.project.nodes.where((n) => !n.isFolder && !n.path.startsWith('.github')).firstOrNull ??
        widget.project.nodes.where((n) => !n.isFolder).firstOrNull;

    if (firstFile != null) {
      _openTabs = [firstFile.path];
      _activeFilePath = firstFile.path;
      _codeController = CodeSyntaxController(text: firstFile.content);
    } else {
      _openTabs = [];
      _codeController = CodeSyntaxController();
    }
    _codeController.addListener(_onCodeChanged);
  }

  @override
  void dispose() {
    _codeController.removeListener(_onCodeChanged);
    _codeController.dispose();
    _editorScrollController.dispose();
    super.dispose();
  }

  void _onCodeChanged() {
    final activePath = _activeFilePath;
    if (activePath == null) return;
    final idx = widget.project.nodes.indexWhere((n) => !n.isFolder && n.path == activePath);
    if (idx == -1) return;
    if (widget.project.nodes[idx].content != _codeController.text) {
      setState(() {
        widget.project.nodes[idx].content = _codeController.text;
        widget.project.nodes[idx].isDirty = true;
      });
    }
  }

  void _selectFile(String path) {
    final node = widget.project.nodes.where((n) => !n.isFolder && n.path == path).firstOrNull;
    if (node == null) return;
    setState(() {
      if (!_openTabs.contains(path)) _openTabs.add(path);
      _activeFilePath = path;
      _codeController.value = TextEditingValue(
        text: node.content,
        selection: const TextSelection.collapsed(offset: 0),
      );
    });
  }

  void _closeTab(String path) {
    setState(() {
      _openTabs.remove(path);
      if (_activeFilePath == path) {
        _activeFilePath = _openTabs.isNotEmpty ? _openTabs.last : null;
        final next = widget.project.nodes.where((n) => !n.isFolder && n.path == _activeFilePath).firstOrNull;
        _codeController.text = next?.content ?? '';
      }
    });
  }

  void _insertSymbol(String sym) {
    final val = _codeController.value;
    final start = val.selection.start >= 0 ? val.selection.start : val.text.length;
    final end = val.selection.end >= 0 ? val.selection.end : val.text.length;
    final updated = val.text.replaceRange(start, end, sym);
    _codeController.value = TextEditingValue(
      text: updated,
      selection: TextSelection.collapsed(offset: start + sym.length),
    );
  }

  Future<void> _createNewNode({String? parentFolder, required bool isFolder}) async {
    final ctrl = TextEditingController(
      text: parentFolder != null && parentFolder.isNotEmpty ? '$parentFolder/' : 'lib/',
    );
    final res = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: Text(isFolder ? 'إنشاء مجلد جديد' : 'إنشاء ملف جديد'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          textDirection: TextDirection.ltr,
          decoration: InputDecoration(
            labelText: isFolder ? 'مسار المجلد' : 'مسار الملف (مثال: lib/screen.dart)',
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('إلغاء')),
          ElevatedButton(onPressed: () => Navigator.pop(ctx, ctrl.text.trim()), child: const Text('إنشاء')),
        ],
      ),
    );
    if (res == null || res.isEmpty) return;
    final clean = res.replaceAll('\\', '/').replaceAll(RegExp(r'^/+|/+$'), '');
    if (clean.isEmpty || widget.project.nodes.any((n) => n.path == clean)) return;

    setState(() {
      final parts = clean.split('/');
      var acc = '';
      for (var i = 0; i < parts.length - 1; i++) {
        acc = acc.isEmpty ? parts[i] : '$acc/${parts[i]}';
        if (!widget.project.nodes.any((n) => n.isFolder && n.path == acc)) {
          widget.project.nodes.add(IdeNode(path: acc, isFolder: true));
        }
        _expandedFolders.add(acc);
      }
      widget.project.nodes.add(
        IdeNode(
          path: clean,
          isFolder: isFolder,
          content: isFolder ? '' : '// $clean\n',
        ),
      );
      if (!isFolder) _selectFile(clean);
    });
    await widget.onSaveProject();
  }

  /// نافذة الذكاء الاصطناعي داخل المحرر للتعديل الفوري المباشر على الكود المفتوح
  Future<void> _openDirectAiEditorSheet() async {
    var provider = (await SafeStorage.getString('ide_ai_provider')) ?? widget.aiProvider;
    final savedKey = (await SafeStorage.getString('ide_ai_api_key')) ?? widget.aiApiKey;
    final savedModel = (await SafeStorage.getString('ide_ai_model')) ?? widget.aiModel;

    final keyCtrl = TextEditingController(text: savedKey);
    final modelCtrl = TextEditingController(text: savedModel);
    final promptCtrl = TextEditingController();
    bool autoApplyNow = true;
    bool showKeySettings = savedKey.isEmpty;
    bool busy = false;
    String? statusNote;
    String? errorMsg;

    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setModalState) {
            Future<void> executeDirectAiEdit() async {
              if (promptCtrl.text.trim().isEmpty) return;
              setModalState(() {
                busy = true;
                errorMsg = null;
                statusNote = null;
              });

              await SafeStorage.setString('ide_ai_provider', provider);
              await SafeStorage.setString('ide_ai_api_key', keyCtrl.text.trim());
              await SafeStorage.setString('ide_ai_model', modelCtrl.text.trim());

              try {
                final reply = await AiStudioService.sendCodePrompt(
                  provider: provider,
                  apiKey: keyCtrl.text.trim(),
                  model: modelCtrl.text.trim(),
                  prompt: promptCtrl.text.trim(),
                  project: widget.project,
                  activeFilePath: _activeFilePath ?? 'lib/main.dart',
                  activeFileContent: _codeController.text,
                );

                final newCode = AiStudioService.extractFirstCodeBlock(reply);
                if (newCode != null && autoApplyNow) {
                  _previousCodeSnapshot = _codeController.text;
                  _codeController.text = newCode;
                  for (final n in widget.project.nodes) {
                    n.isDirty = false;
                  }
                  await widget.onSaveProject();
                  if (ctx.mounted) Navigator.pop(ctx);
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: const Text('قام الذكاء الاصطناعي بتعديل الكود وحفظه مباشرةً ✓'),
                        action: SnackBarAction(
                          label: 'تراجع',
                          onPressed: () {
                            if (_previousCodeSnapshot != null) {
                              _codeController.text = _previousCodeSnapshot!;
                            }
                          },
                        ),
                      ),
                    );
                  }
                } else {
                  setModalState(() {
                    statusNote = reply;
                  });
                }
              } catch (e) {
                setModalState(() {
                  errorMsg = e.toString().replaceFirst('Exception: ', '');
                });
              } finally {
                setModalState(() => busy = false);
              }
            }

            return Directionality(
              textDirection: TextDirection.rtl,
              child: Padding(
                padding: EdgeInsets.only(
                  left: 16,
                  right: 16,
                  top: 16,
                  bottom: MediaQuery.of(ctx).viewInsets.bottom + 16,
                ),
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          const Icon(Icons.auto_awesome, color: AppColors.orange),
                          const SizedBox(width: 8),
                          const Expanded(
                            child: Text(
                              'تعديل الكود المباشر بالذكاء الاصطناعي',
                              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
                            ),
                          ),
                          IconButton(
                            icon: Icon(showKeySettings ? Icons.expand_less : Icons.vpn_key_outlined),
                            onPressed: () => setModalState(() => showKeySettings = !showKeySettings),
                          ),
                        ],
                      ),
                      if (showKeySettings) ...[
                        SegmentedButton<String>(
                          segments: const [
                            ButtonSegment(value: 'gemini', label: Text('Gemini')),
                            ButtonSegment(value: 'openai', label: Text('OpenAI')),
                            ButtonSegment(value: 'deepseek', label: Text('DeepSeek')),
                          ],
                          selected: {provider},
                          onSelectionChanged: (s) {
                            setModalState(() {
                              provider = s.first;
                              modelCtrl.text = provider == 'gemini'
                                  ? 'gemini-2.5-flash'
                                  : (provider == 'deepseek' ? 'deepseek-chat' : 'gpt-4o-mini');
                            });
                          },
                        ),
                        const SizedBox(height: 8),
                        TextField(
                          controller: keyCtrl,
                          obscureText: true,
                          textDirection: TextDirection.ltr,
                          decoration: const InputDecoration(labelText: 'مفتاح الـ API'),
                        ),
                        const SizedBox(height: 8),
                      ],
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: const Text('تطبيق التعديلات مباشرة على الملف المفتوح'),
                        value: autoApplyNow,
                        onChanged: (v) => setModalState(() => autoApplyNow = v),
                      ),
                      TextField(
                        controller: promptCtrl,
                        maxLines: 3,
                        decoration: const InputDecoration(
                          labelText: 'اكتب التعديل المطلوب تنفيذه على الكود',
                          hintText: 'مثال: حوّل هذه الشاشة إلى تطبيق متجر مع سلة مشتريات وألوان جذابة...',
                        ),
                      ),
                      const SizedBox(height: 12),
                      ElevatedButton.icon(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppColors.orange,
                          foregroundColor: Colors.black,
                          padding: const EdgeInsets.symmetric(vertical: 13),
                        ),
                        onPressed: busy ? null : executeDirectAiEdit,
                        icon: busy
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(strokeWidth: 2, color: Colors.black),
                              )
                            : const Icon(Icons.bolt_rounded),
                        label: Text(
                          busy ? 'جاري تعديل الكود مباشرة...' : 'تعديل الكود الآن',
                          style: const TextStyle(fontWeight: FontWeight.bold),
                        ),
                      ),
                      if (errorMsg != null) ...[
                        const SizedBox(height: 10),
                        Text(errorMsg!, style: const TextStyle(color: AppColors.danger)),
                      ],
                      if (statusNote != null) ...[
                        const SizedBox(height: 10),
                        SelectableText(statusNote!, style: const TextStyle(fontSize: 12.5)),
                      ],
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  /// شاشة البناء السحابي المباشر وعرض السجل الحي (مطابقة لشاشة البناء في Klencod IDE)
  Future<void> _startCloudBuildFlow() async {
    for (final n in widget.project.nodes) {
      n.isDirty = false;
    }
    await widget.onSaveProject();

    final token = await SafeStorage.getString('gh_oauth_token') ?? widget.githubToken;
    final login = await SafeStorage.getString('gh_oauth_login') ?? widget.githubLogin ?? 'user';

    if (token == null || token.isEmpty) {
      await widget.onOpenGithubConnect();
      return;
    }

    final liveLogs = <String>[];
    bool building = true;
    String? errorMsg;
    ApkBuildRecord? resultRecord;

    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.darkBg,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) {
        var started = false;
        return StatefulBuilder(
          builder: (ctx, setModalState) {
            if (!started) {
              started = true;
              Future<void>(() async {
                try {
                  final rec = await GithubOAuthDeviceService.pushProjectAndBuildApk(
                    token: token,
                    githubLogin: login,
                    project: widget.project,
                    onLog: (msg) {
                      if (ctx.mounted) {
                        setModalState(() => liveLogs.add(msg));
                      }
                    },
                  );
                  await widget.onBuildRecorded(rec);
                  if (ctx.mounted) {
                    setModalState(() {
                      building = false;
                      resultRecord = rec;
                    });
                  }
                } catch (e) {
                  if (ctx.mounted) {
                    setModalState(() {
                      building = false;
                      errorMsg = e.toString().replaceFirst('Exception: ', '');
                    });
                  }
                }
              });
            }

            return Directionality(
              textDirection: TextDirection.rtl,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(18, 18, 18, 28),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Icon(
                          errorMsg != null
                              ? Icons.cancel_rounded
                              : (building ? Icons.sync_rounded : Icons.check_circle_rounded),
                          color: errorMsg != null
                              ? AppColors.danger
                              : (building ? AppColors.primary : AppColors.success),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            'البناء السحابي (${widget.project.name} • ${widget.project.packageName})',
                            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
                          ),
                        ),
                      ],
                    ),
                    const Divider(height: 22),
                    for (final step in [
                      'Checkout',
                      'Setup Gradle Cache',
                      'Setup Java 17',
                      'Setup Flutter & Branding (${widget.project.packageName})',
                      'Get dependencies',
                      'Build APK (${widget.project.buildMode.toUpperCase()})',
                    ])
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 5),
                        child: Row(
                          children: [
                            const Icon(Icons.add_circle, color: AppColors.success, size: 20),
                            const SizedBox(width: 10),
                            Text(
                              step,
                              textDirection: TextDirection.ltr,
                              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                            ),
                          ],
                        ),
                      ),
                    const SizedBox(height: 12),
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: AppColors.surface,
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(color: AppColors.border),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          for (final l in liveLogs)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 4),
                              child: Text(l, style: const TextStyle(fontSize: 12.5, fontFamily: 'monospace')),
                            ),
                          if (errorMsg != null)
                            Text(errorMsg!, style: const TextStyle(color: AppColors.danger, fontSize: 13)),
                        ],
                      ),
                    ),
                    const SizedBox(height: 14),
                    if (resultRecord != null)
                      ElevatedButton.icon(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppColors.primary,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 13),
                        ),
                        icon: const Icon(Icons.open_in_new),
                        label: const Text('فتح GitHub Actions ومتابعة استخراج الـ APK'),
                        onPressed: () => launchUrl(
                          Uri.parse(resultRecord!.actionsUrl),
                          mode: LaunchMode.externalApplication,
                        ),
                      ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildExplorerDrawer() {
    final sorted = [...widget.project.nodes]..sort((a, b) {
        if (a.isFolder != b.isFolder) return a.isFolder ? -1 : 1;
        return a.path.compareTo(b.path);
      });

    final visible = sorted.where((node) {
      final parts = node.path.split('/');
      if (parts.length == 1) return true;
      var parent = '';
      for (var i = 0; i < parts.length - 1; i++) {
        parent = parent.isEmpty ? parts[i] : '$parent/${parts[i]}';
        if (!_expandedFolders.contains(parent)) return false;
      }
      return true;
    }).toList();

    return Drawer(
      backgroundColor: AppColors.surface,
      child: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  const Icon(Icons.folder_copy_outlined, color: AppColors.orange),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      widget.project.name,
                      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.note_add_outlined, size: 20),
                    onPressed: () => _createNewNode(isFolder: false),
                  ),
                  IconButton(
                    icon: const Icon(Icons.create_new_folder_outlined, size: 20),
                    onPressed: () => _createNewNode(isFolder: true),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: ListView.builder(
                itemCount: visible.length,
                itemBuilder: (ctx, i) {
                  final node = visible[i];
                  final depth = node.path.split('/').length - 1;
                  final isSelected = !node.isFolder && node.path == _activeFilePath;
                  final isExpanded = node.isFolder && _expandedFolders.contains(node.path);

                  return InkWell(
                    onTap: () {
                      if (node.isFolder) {
                        setState(() {
                          isExpanded
                              ? _expandedFolders.remove(node.path)
                              : _expandedFolders.add(node.path);
                        });
                      } else {
                        _selectFile(node.path);
                        Navigator.pop(context);
                      }
                    },
                    child: Container(
                      color: isSelected ? AppColors.primary.withOpacity(0.18) : null,
                      padding: EdgeInsets.only(
                        left: 12.0 + depth * 15.0,
                        right: 10,
                        top: 8,
                        bottom: 8,
                      ),
                      child: Row(
                        children: [
                          Icon(
                            node.isFolder
                                ? (isExpanded ? Icons.folder_open : Icons.folder)
                                : Icons.code_rounded,
                            size: 18,
                            color: node.isFolder ? AppColors.orange : AppColors.primary,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              node.name + (node.isDirty ? ' •' : ''),
                              textDirection: TextDirection.ltr,
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final lineCount = '\n'.allMatches(_codeController.text).length + 1;

    return Scaffold(
      key: _scaffoldKey,
      drawer: _buildExplorerDrawer(),
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.account_tree_outlined),
          tooltip: 'مستعرض الملفات',
          onPressed: () => _scaffoldKey.currentState?.openDrawer(),
        ),
        title: Text(
          _activeFilePath ?? widget.project.name,
          style: const TextStyle(fontSize: 13.5, fontFamily: 'monospace', fontWeight: FontWeight.bold),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.tune_rounded),
            tooltip: 'أيقونة التطبيق والحزمة والنشر',
            onPressed: widget.onConfigureApp,
          ),
          IconButton(
            icon: const Icon(Icons.auto_awesome, color: AppColors.orange),
            tooltip: 'تعديل مباشر بالذكاء الاصطناعي',
            onPressed: _openDirectAiEditorSheet,
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6),
            child: ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.primary,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(horizontal: 10),
              ),
              onPressed: _startCloudBuildFlow,
              icon: const Icon(Icons.play_arrow_rounded, size: 18),
              label: const Text('بناء APK', style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.bold)),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          if (_openTabs.isNotEmpty)
            Container(
              height: 36,
              color: AppColors.surface,
              child: ListView.builder(
                scrollDirection: Axis.horizontal,
                itemCount: _openTabs.length,
                itemBuilder: (ctx, idx) {
                  final tab = _openTabs[idx];
                  final active = tab == _activeFilePath;
                  return InkWell(
                    onTap: () => _selectFile(tab),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      decoration: BoxDecoration(
                        color: active ? AppColors.darkBg : AppColors.surface,
                        border: Border(
                          bottom: BorderSide(
                            color: active ? AppColors.primary : Colors.transparent,
                            width: 2.5,
                          ),
                        ),
                      ),
                      child: Row(
                        children: [
                          Text(
                            tab.split('/').last,
                            style: TextStyle(
                              fontSize: 12,
                              fontFamily: 'monospace',
                              color: active ? AppColors.primary : AppColors.textMuted,
                              fontWeight: active ? FontWeight.bold : FontWeight.normal,
                            ),
                          ),
                          const SizedBox(width: 6),
                          GestureDetector(
                            onTap: () => _closeTab(tab),
                            child: const Icon(Icons.close, size: 14, color: AppColors.textMuted),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
          Expanded(
            child: Directionality(
              textDirection: TextDirection.ltr,
              child: Container(
                color: AppColors.darkBg,
                child: SingleChildScrollView(
                  controller: _editorScrollController,
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        width: 44,
                        padding: const EdgeInsets.only(right: 8, left: 6),
                        decoration: const BoxDecoration(
                          border: Border(right: BorderSide(color: AppColors.border)),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: List.generate(
                            lineCount,
                            (i) => Text(
                              '${i + 1}',
                              style: const TextStyle(
                                fontFamily: 'monospace',
                                fontSize: 14,
                                height: 1.5,
                                color: AppColors.textMuted,
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: TextField(
                          controller: _codeController,
                          maxLines: null,
                          keyboardType: TextInputType.multiline,
                          style: const TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 14,
                            height: 1.5,
                            color: AppColors.textPrimary,
                          ),
                          decoration: const InputDecoration(
                            border: InputBorder.none,
                            enabledBorder: InputBorder.none,
                            focusedBorder: InputBorder.none,
                            filled: false,
                            isDense: true,
                            contentPadding: EdgeInsets.only(right: 14),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          Directionality(
            textDirection: TextDirection.ltr,
            child: Container(
              height: 42,
              decoration: const BoxDecoration(
                color: AppColors.surface,
                border: Border(top: BorderSide(color: AppColors.border)),
              ),
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                children: [
                  for (final sym in [
                    ('Tab', '  '),
                    ('{', '{'),
                    ('}', '}'),
                    ('(', '('),
                    (')', ')'),
                    ('[', '['),
                    (']', ']'),
                    (';', ';'),
                    ('=>', ' => '),
                    ('=', ' = '),
                    ("'", "'"),
                    ('"', '"'),
                    (r'$', r'$'),
                    ('//', '// '),
                  ])
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 3),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(8),
                        onTap: () => _insertSymbol(sym.$2),
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 4),
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: AppColors.surfaceAlt,
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: AppColors.border),
                          ),
                          child: Text(
                            sym.$1,
                            style: const TextStyle(
                              fontFamily: 'monospace',
                              fontWeight: FontWeight.bold,
                              fontSize: 13,
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
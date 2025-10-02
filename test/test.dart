import 'package:test/test.dart';
import 'dart:io';
import 'dart:convert';
import 'dart:math';
import 'package:args/args.dart';
import '../lib/main.dart'; // 需要将main.dart移到lib目录

void main() {
  group('Unit Tests', () {
    test('formatBytes returns correct format for various sizes', () {
      expect(formatBytes(0), equals('0.00 B'));
      expect(formatBytes(1023), equals('1023.00 B'));
      expect(formatBytes(1024), equals('1.00 KB'));
      expect(formatBytes(1048576), equals('1.00 MB'));
      expect(formatBytes(1073741824), equals('1.00 GB'));
    });
  });

  group('MyAppState Tests', () {
    late MyAppState MyApp;
    late Directory tempDir;

    setUp(() {
      MyApp = MyAppState();
      tempDir = Directory.systemTemp.createTempSync('test_dir');
    });

    tearDown(() {
      tempDir.deleteSync(recursive: true);
    });

    test('setWatchPath correctly sets path', () {
      MyApp.setWatchPath(tempDir.path);
      expect(MyApp.watchPath, equals(tempDir.path));
    });

    // 更多测试...
  });

  group('HTTP Tests', () {
    // HTTP相关测试
  });
}
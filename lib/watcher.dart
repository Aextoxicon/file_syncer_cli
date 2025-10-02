import 'dart:async';
import 'dart:io';
import 'package:watcher/watcher.dart';
import 'dart:convert';

class watcherd {
  void startWatch(String path) {
    watcher().startWatch(path);
  }
  void stopWatch() {
    watcher().stopWatch();
  }
  Stream<Map<String, String>> get onEvent => Stream.empty();
}

class watcher implements watcherd {
  DirectoryWatcher? _watcher;
  StreamSubscription? _sub;

  @override
  final _event = StreamController<Map<String, String>>.broadcast();
  Stream<Map<String, String>> get onEvent => _event.stream;

  Future<void> startWatch(String path) async {
    final dir = Directory(path);
    if (!dir.existsSync()) {
      final scanError = {
        'type': 'error',
        'message': 'Directory "$path" does not exist.',
        'timestamp': DateTime.now().toIso8601String()
      };
      _event.add({'event': jsonEncode(scanError)});
      return;
    }

    try {
      await for (final entity in dir.list(recursive: true)) {

        final eventData = {
          'type': '新增',
          'path': entity.path,
          'timestamp': DateTime.now().toIso8601String()
        };
        _event.add({'event': jsonEncode(eventData)});
      }
    } catch (e) {
      final scanError = {
        'type': 'error',
        'message': '初始扫描失败: $e',
        'timestamp': DateTime.now().toIso8601String()
      };
      _event.add({'event': jsonEncode(scanError)});
    }

    // 启动文件监视
    _sub?.cancel();
    _watcher = DirectoryWatcher(path);

    _sub = _watcher!.events.listen(
      (event) {

        String eventType;
        switch (event.type) {
          case ChangeType.ADD:
            eventType = "新增";
            break;
          case ChangeType.MODIFY:
            eventType = "修改";
            break;
          case ChangeType.REMOVE:
            eventType = "移除";
            break;
          default:
            eventType = "未知";
        }
        final eventData = {
          'type': eventType,
          'path': event.path,
          'timestamp': DateTime.now().toIso8601String()
        };
        _event.add({'event': jsonEncode(eventData)});
      },
      onError: (error) {
        final scanError = {
          'type': 'error',
          'message': error.toString(),
          'timestamp': DateTime.now().toIso8601String()
        };
        _event.add({'event': jsonEncode(scanError)});
      },
    );
  }

  void stopWatch() {
    _sub?.cancel();
    _watcher = null;
  }
}

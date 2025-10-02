import 'dart:io';
import 'dart:convert';
import 'dart:math';
import 'package:args/args.dart';
import 'watcher.dart'; // 假设 watcher.dart 在 lib 目录中

// 格式化字节数
String formatBytes(int bytes, {int decimalPlaces = 2}) {
  if (bytes == 0) return '0 B';

  const List<String> units = [
    'B',
    'KB',
    'MB',
    'GB',
    'TB',
    'PB',
    'EB',
    'ZB',
    'YB',
  ];
  const double base = 1024;

  int exponent = (log(bytes) / log(base)).floor();
  exponent = exponent.clamp(0, units.length - 1);

  double value = bytes / pow(base, exponent);
  return '${value.toStringAsFixed(decimalPlaces)} ${units[exponent]}';
}

class MyAppState {
  String watchPath = '';
  final watcherd _watcher = watcherd();
  bool isHTTPRunning = false;
  int httpPort = 8080;
  HttpServer? httpServer;
  String httpHost = 'localhost';
  int httpPortC = 8080;
  String httpUser = 'user';
  String httpPwd = 'pwd123';
  String localIPAddress = 'localhost';

  MyAppState() {
    _watcher.onEvent.listen((event) {
      if (event.containsKey('event')) {
        final jsonEvent = jsonDecode(event['event']!);
        String formattedEvent = '';

        if (jsonEvent['type'] == 'error') {
          formattedEvent =
              '[错误] ${jsonEvent['message']} (${jsonEvent['timestamp']})';
        } else {
          formattedEvent =
              '[${jsonEvent['type']}] ${jsonEvent['path']} (${jsonEvent['timestamp']})';
        }

        print(formattedEvent);
      }
    });
    getLocalIPAddress();
  }

  void setWatchPath(String path) {
    watchPath = path;
    _watcher.startWatch(path);
    print('监控路径已设置为: $path');
  }

  Future<void> getLocalIPAddress() async {
    try {
      final List<NetworkInterface> interfaces = await NetworkInterface.list(
        includeLoopback: false,
        includeLinkLocal: false,
        type: InternetAddressType.IPv4,
      );

      for (final interface in interfaces) {
        for (final address in interface.addresses) {
          if (address.type == InternetAddressType.IPv4 &&
              !address.isLoopback &&
              !address.isLinkLocal) {
            localIPAddress = address.address;
            return;
          }
        }
      }
    } catch (e) {
      print('获取本机IP地址失败: $e');
    }
  }

  void startHTTP() async {
    if (watchPath.isEmpty) {
      print('请先选择要同步的目录');
      return;
    }

    bool _checkAuth(HttpRequest request) {
      final authHeader = request.headers.value('authorization');
      if (authHeader == null || !authHeader.startsWith('Basic ')) {
        return false;
      }

      final encodedAuth = authHeader.substring(6);
      try {
        final decodedAuth = utf8.decode(base64Decode(encodedAuth));
        final parts = decodedAuth.split(':');
        if (parts.length != 2) {
          return false;
        }

        final user = parts[0];
        final pwd = parts[1];

        return user == httpUser && pwd == httpPwd;
      } catch (e) {
        print('认证解析失败: $e');
        return false;
      }
    }

    Future<void> _fileUpload(HttpRequest request, String path) async {
      IOSink? sink;
      try {
        print('开始处理文件上传请求，路径: $path');

        final normalizedPath = path.startsWith('/') ? path.substring(1) : path;
        print('标准化路径: $normalizedPath');

        final filePath = '$watchPath${Platform.pathSeparator}$normalizedPath'
            .replaceAll('/', Platform.pathSeparator)
            .replaceAll('\\', Platform.pathSeparator)
            .replaceAll(
              '${Platform.pathSeparator}${Platform.pathSeparator}',
              Platform.pathSeparator,
            );

        final file = File(filePath);
        print('准备接收上传文件: $filePath');
        print('监控路径: $watchPath');

        final parentDir = file.parent;
        print('父目录路径: ${parentDir.path}');

        try {
          if (!await parentDir.exists()) {
            print('父目录不存在，正在创建...');
            await parentDir.create(recursive: true);
            print('创建目录成功: ${parentDir.path}');
          } else {
            print('父目录已存在: ${parentDir.path}');
          }
        } catch (dirError) {
          print('创建目录失败: $dirError');
          request.response
            ..statusCode = HttpStatus.internalServerError
            ..write('Failed to create directory: $dirError')
            ..close();
          return;
        }

        try {
          print('开始流式写入文件...');
          sink = file.openWrite();
          int totalBytes = 0;
          await for (var data in request) {
            sink.add(data);
            totalBytes += data.length;
          }
          await sink.close();
          print('文件写入成功: $filePath, 总大小: $totalBytes 字节');
        } catch (writeError) {
          await sink?.close();
          if (await file.exists()) {
            await file.delete();
          }
          rethrow;
        }

        request.response
          ..statusCode = HttpStatus.ok
          ..headers.set('Content-Type', 'text/plain; charset=utf-8')
          ..write('File uploaded successfully')
          ..close();

        print('文件上传完成: $filePath');
      } catch (e, stackTrace) {
        await sink?.close();
        print('文件上传过程中发生未处理的异常: $e');
        print('详细堆栈信息: $stackTrace');
        try {
          request.response
            ..statusCode = HttpStatus.internalServerError
            ..headers.set('Content-Type', 'text/plain; charset=utf-8')
            ..write('File upload failed: $e')
            ..close();
        } catch (responseError) {
          print('发送错误响应失败: $responseError');
        }
      }
    }

    try {
      httpServer = await HttpServer.bind(InternetAddress.anyIPv4, httpPort);

      httpServer!.listen((HttpRequest request) async {
        bool isAuthenticated = true;
        if (httpUser.isNotEmpty && httpPwd.isNotEmpty) {
          isAuthenticated = _checkAuth(request);
        }

        if (!isAuthenticated) {
          request.response
            ..statusCode = HttpStatus.unauthorized
            ..headers.set('WWW-Authenticate', 'Basic realm="flutter-demo"')
            ..write('Unauthorized')
            ..close();
          return;
        }

        final path = request.uri.path;

        if (path.startsWith('/api/')) {
          // 处理API请求
          if (path == '/api/file-list') {
            try {
              final fileMap = await _scanDir(watchPath);
              final jsonResponse = jsonEncode(fileMap);

              request.response
                ..headers.contentType = ContentType.json
                ..write(jsonResponse)
                ..close();
            } catch (e) {
              print('生成文件列表失败: $e');
              request.response
                ..statusCode = HttpStatus.internalServerError
                ..write('{"error": "Internal server error"}')
                ..close();
            }
          } else {
            request.response
              ..statusCode = HttpStatus.notFound
              ..write('API未找到')
              ..close();
          }
          return;
        }

        if (path == '/.scan_result.json') {
          try {
            final fileMap = await _scanDir(watchPath);
            final jsonResponse = jsonEncode(fileMap);

            request.response
              ..headers.contentType = ContentType.json
              ..write(jsonResponse)
              ..close();
          } catch (e) {
            print('生成文件列表失败: $e');
            request.response
              ..statusCode = HttpStatus.internalServerError
              ..write('{"error": "Internal server error"}')
              ..close();
          }
          return;
        }

        if (request.method == 'PUT') {
          await _fileUpload(request, path);
          return;
        }

        if (path == '/' || path.isEmpty) {
          final dir = Directory(watchPath);
          final entities = await dir.list().toList();

          final StringBuffer buffer = StringBuffer();
          buffer.write('<html><head><title>文件列表</title></head><body>');
          buffer.write('<h1>目录内容</h1><ul>');

          for (final entity in entities) {
            final name = entity.uri.pathSegments.last;
            final isDir = entity is Directory ? '📁' : '📄';
            buffer.write('<li>$isDir <a href="$name">$name</a></li>');
          }

          buffer.write('</ul></body></html>');

          request.response
            ..headers.contentType = ContentType.html
            ..write(buffer.toString())
            ..close();
        } else {
          String normalizedPath = path;
          if (normalizedPath.startsWith('/')) {
            normalizedPath = normalizedPath.substring(1);
          }

          final filePath = '$watchPath${Platform.pathSeparator}$normalizedPath'
              .replaceAll('/', Platform.pathSeparator)
              .replaceAll('\\', Platform.pathSeparator)
              .replaceAll(
                '${Platform.pathSeparator}${Platform.pathSeparator}',
                Platform.pathSeparator,
              );

          final file = File(filePath);

          print('尝试提供文件: $filePath (原始请求路径: $path, 监控路径: $watchPath)');

          if (await file.exists()) {
            print('文件存在，开始传输: $filePath');
            request.response.headers.contentType = _getContentType(filePath);

            final length = await file.length();
            request.response.headers.set('Content-Length', length.toString());

            await request.response.addStream(file.openRead());
            await request.response.close();
            print('文件传输完成: $filePath');
          } else {
            print('文件不存在: $filePath');
            print('监控路径: $watchPath');
            print('请求路径: $path');
            print('标准化路径: $normalizedPath');
            request.response
              ..statusCode = HttpStatus.notFound
              ..headers.contentType = ContentType.html
              ..write(
                '<html><body><h1>404 - 文件未找到</h1><p>请求的文件 $path 不存在</p><p>完整路径: $filePath</p></body></html>',
              )
              ..close();
          }
        }
      });

      isHTTPRunning = true;
      print('HTTP服务器已启动，端口: $httpPort');
      await getLocalIPAddress();
      print('服务器地址: http://$localIPAddress:$httpPort');
    } catch (e) {
      print('启动HTTP服务器失败: $e');
    }
  }

  ContentType _getContentType(String filePath) {
    final lowerPath = filePath.toLowerCase();
    if (lowerPath.endsWith('.json')) {
      return ContentType('application', 'json');
    } else if (lowerPath.endsWith('.html') || lowerPath.endsWith('.htm')) {
      return ContentType('text', 'html');
    } else if (lowerPath.endsWith('.css')) {
      return ContentType('text', 'css');
    } else if (lowerPath.endsWith('.js')) {
      return ContentType('application', 'javascript');
    } else if (lowerPath.endsWith('.png')) {
      return ContentType('image', 'png');
    } else if (lowerPath.endsWith('.jpg') || lowerPath.endsWith('.jpeg')) {
      return ContentType('image', 'jpeg');
    } else if (lowerPath.endsWith('.gif')) {
      return ContentType('image', 'gif');
    } else {
      return ContentType('application', 'octet-stream');
    }
  }

  Future<Map<String, dynamic>> _scanDir(String rootPath) async {
    final fileMap = <String, dynamic>{};
    final dir = Directory(rootPath);

    if (!await dir.exists()) {
      return fileMap;
    }

    await _scanDirForApi(dir, rootPath, fileMap);
    return fileMap;
  }

  Future<void> _scanDirForApi(
    Directory dir,
    String rootPath,
    Map<String, dynamic> fileMap,
  ) async {
    try {
      await for (final FileSystemEntity entity in dir.list()) {
        final relativePath = entity.path
            .replaceFirst(rootPath, '')
            .replaceAll('\\', '/');
        if (relativePath.isEmpty) continue;

        final normalizedPath = relativePath.startsWith('/')
            ? relativePath
            : '/$relativePath';

        if (entity is Directory) {
          final dirInfo = {
            'type': 'directory',
            'path': normalizedPath,
            'children': <dynamic>[],
          };

          await _scanDirForApi(
            entity,
            rootPath,
            dirInfo as Map<String, dynamic>,
          );

          fileMap[normalizedPath] = dirInfo;
        } else if (entity is File) {
          final stat = await entity.stat();
          fileMap[normalizedPath] = {
            'type': 'file',
            'path': normalizedPath,
            'size': stat.size,
            'modified': stat.modified.toIso8601String(),
          };
        }
      }
    } catch (e) {
      print('扫描目录时出错: $e');
    }
  }

  void stopHTTP() {
    httpServer?.close();
    isHTTPRunning = false;
    httpServer = null;
    print('HTTP服务器已停止');
  }
}

void main(List<String> arguments) async {
  final ArgParser parser = ArgParser()
    ..addOption('mode', abbr: 'm', help: '运行模式: server 或 client', defaultsTo: 'server')
    ..addOption('path', abbr: 'p', help: '要监控/同步的目录路径')
    ..addOption('port', abbr: 'P', help: 'HTTP服务器端口', defaultsTo: '8080')
    ..addOption('host', abbr: 'H', help: '远程服务器地址', defaultsTo: 'localhost')
    ..addOption('user', help: 'HTTP认证用户名', defaultsTo: 'user')
    ..addOption('password', abbr: 'w', help: 'HTTP认证密码', defaultsTo: 'pwd123')
    ..addFlag('help', abbr: 'h', help: '显示帮助信息', negatable: false);

  try {
    final ArgResults results = parser.parse(arguments);

    if (results['help'] as bool) {
      print('Flutter Demo CLI 版本');
      print(parser.usage);
      return;
    }

    final String mode = results['mode'] as String;
    final String? path = results['path'] as String?;
    final int port = int.parse(results['port'] as String);
    final String host = results['host'] as String;
    final String user = results['user'] as String;
    final String password = results['password'] as String;

    if (path == null) {
      print('错误: 必须指定路径');
      print(parser.usage);
      exit(1);
    }

    // 检查路径是否存在
    final dir = Directory(path);
    if (!await dir.exists()) {
      print('错误: 指定的路径 "$path" 不存在');
      exit(1);
    }

    final MyApp = MyAppState();
    MyApp.setWatchPath(path);
    MyApp.httpPort = port;
    MyApp.httpHost = host;
    MyApp.httpUser = user;
    MyApp.httpPwd = password;

    if (mode == 'server') {
      print('启动服务器模式...');
      print('监控路径: $path');
      MyApp.startHTTP();
      
      // 保持程序运行
      print('按 Ctrl+C 停止服务器');
      ProcessSignal.sigint.watch().listen((signal) {
        print('\n正在停止服务器...');
        MyApp.stopHTTP();
        exit(0);
      });
      
      // 保持运行
      await Future<void>.delayed(Duration(days: 365));
    } else if (mode == 'client') {
      print('客户端模式功能需要进一步实现');
      // 这里可以添加客户端功能的实现
      print('当前仅支持服务器模式');
      exit(1);
    } else {
      print('错误: 无效的模式 "$mode"，支持的模式为 server 或 client');
      exit(1);
    }
  } on FormatException catch (e) {
    print('参数格式错误: $e');
    print(parser.usage);
    exit(1);
  } catch (e) {
    print('发生错误: $e');
    exit(1);
  }
}
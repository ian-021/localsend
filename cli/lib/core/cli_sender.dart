import 'dart:async';
import 'dart:io';
import 'package:common/model/stored_security_context.dart';
import 'package:uuid/uuid.dart';
import '../core/code_phrase.dart';
import '../discovery/cli_multicast.dart';
import '../transfer/file_scanner.dart';
import '../util/security_helper.dart';
import 'cli_server.dart';

const _uuid = Uuid();

/// Orchestrates the sending process for CLI mode.
class CliSender {
  final List<String> filePaths;
  final int? port;
  final Duration timeout;

  String? _codePhrase;
  String? _codeHash;
  String? _sessionId;
  StoredSecurityContext? _securityContext;
  CliMulticast? _multicast;
  CliServer? _server;
  Map<String, FileInfo>? _files;

  CliSender({
    required this.filePaths,
    this.port,
    this.timeout = const Duration(minutes: 5),
  });

  /// Starts the send process.
  /// Returns true if successful, false if timed out or failed.
  Future<bool> send() async {
    try {
      // 1. Scan files
      print('Scanning files...');
      _files = await FileScanner.scan(filePaths);

      if (_files!.isEmpty) {
        print('Error: No files found to send');
        return false;
      }

      print('Found ${_files!.length} file(s) to send');
      for (final file in _files!.values) {
        print('  - ${file.dto.fileName} (${file.dto.size} bytes)');
      }

      // 2. Generate code phrase and security context
      _codePhrase = await CodePhrase.generate();
      _codeHash = CodePhrase.hash(_codePhrase!);
      _sessionId = _uuid.v4();
      _securityContext = generateSecurityContext();

      print('\nCode phrase: $_codePhrase');
      print('\nOn the receiving device, run:');
      print('    localsend $_codePhrase');
      print('\nWaiting for receiver...');

      // 3. Start HTTPS server
      final serverPort = port ?? await _findAvailablePort();
      _server = CliServer(
        port: serverPort,
        fingerprint: _securityContext!.certificateHash,
        alias: 'CLI Sender',
        files: _files!,
        securityContext: _securityContext!,
      );
      await _server!.start();

      // 4. Start multicast broadcasting
      _multicast = CliMulticast();
      await _multicast!.startBroadcasting(
        codeHash: _codeHash!,
        sessionId: _sessionId!,
        alias: 'CLI Sender',
        port: serverPort,
        fingerprint: _securityContext!.certificateHash,
        useHttps: true,
      );

      // 5. Wait for receiver to connect (with timeout)
      final connected = await _server!.waitForReceiver().timeout(
        timeout,
        onTimeout: () {
          throw TimeoutException('No receiver connected within ${timeout.inSeconds} seconds');
        },
      );

      print('Receiver connected! Transfer complete.');
      return true;
    } on TimeoutException catch (e) {
      print('\nError: $e');
      print('\nMake sure:');
      print('  1. Receiver is on the same network');
      print('  2. Receiver ran: localsend $_codePhrase');
      print('  3. No firewall blocking port 53317');
      return false;
    } catch (e) {
      print('Error during send: $e');
      return false;
    } finally {
      await cleanup();
    }
  }

  /// Finds an available port starting from the default port.
  Future<int> _findAvailablePort() async {
    var testPort = 53317;
    while (testPort < 53417) {
      try {
        final server = await ServerSocket.bind(InternetAddress.anyIPv4, testPort);
        await server.close();
        return testPort;
      } catch (e) {
        testPort++;
      }
    }
    throw Exception('No available ports found in range 53317-53417');
  }


  /// Cleans up resources.
  Future<void> cleanup() async {
    _multicast?.stop();
    _multicast?.dispose();
    await _server?.stop();
  }
}

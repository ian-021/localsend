import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:common/model/device.dart';
import 'package:common/model/dto/file_dto.dart';
import 'package:common/model/dto/info_register_dto.dart';
import 'package:common/model/dto/prepare_upload_request_dto.dart';
import 'package:common/model/dto/prepare_upload_response_dto.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as path;
import 'package:uuid/uuid.dart';
import '../core/code_phrase.dart';
import '../discovery/cli_multicast.dart';
import '../ui/formatter.dart';
import '../ui/progress_bar.dart';

const _uuid = Uuid();

/// Orchestrates the receiving process for CLI mode.
class CliReceiver {
  final String codePhrase;
  final String? outputDirectory;
  final Duration timeout;
  final bool autoAccept;

  String? _codeHash;
  CliMulticast? _multicast;
  Device? _sender;

  CliReceiver({
    required this.codePhrase,
    this.outputDirectory,
    this.timeout = const Duration(minutes: 5),
    this.autoAccept = false,
  });

  /// Starts the receive process.
  /// Returns true if successful, false if failed.
  Future<bool> receive() async {
    try {
      // 1. Validate code phrase
      if (!CodePhrase.validate(codePhrase)) {
        print('Error: Invalid code phrase format');
        print('Expected format: adjective-noun-animal-number');
        print('Example: swift-ocean-tiger-7342');
        return false;
      }

      _codeHash = CodePhrase.hash(codePhrase);

      print('Searching for sender with code: $codePhrase');

      // 2. Start listening for sender on multicast
      final senderFound = Completer<Device>();

      _multicast = CliMulticast();
      await _multicast!.startListening(
        codeHash: _codeHash!,
        onDeviceFound: (device) {
          if (!senderFound.isCompleted) {
            senderFound.complete(device);
          }
        },
      );

      // 3. Wait for sender (with timeout)
      try {
        _sender = await senderFound.future.timeout(
          timeout,
          onTimeout: () {
            throw TimeoutException('No sender found within ${timeout.inSeconds} seconds');
          },
        );
      } on TimeoutException catch (e) {
        print('\nError: $e');
        print('\nMake sure:');
        print('  1. Sender is on the same network');
        print('  2. Code phrase is correct');
        print('  3. Sender is still waiting for receiver');
        return false;
      }

      print('Found sender at ${_sender!.ip}:${_sender!.port}');

      // 4. Connect to sender and initiate transfer
      await _initiateTransfer();

      return true;
    } catch (e) {
      print('Error during receive: $e');
      return false;
    } finally {
      await cleanup();
    }
  }

  /// Initiates the file transfer with the sender.
  Future<void> _initiateTransfer() async {
    try {
      // 1. Send prepare-upload request to announce ourselves
      final prepareUrl = Uri.parse(
        'http://${_sender!.ip}:${_sender!.port}/api/localsend/v2/prepare-upload',
      );

      final prepareRequest = PrepareUploadRequestDto(
        info: InfoRegisterDto(
          alias: 'CLI Receiver',
          version: '2.1',
          deviceModel: 'CLI',
          deviceType: DeviceType.headless,
          fingerprint: _uuid.v4(),
          port: null,
          protocol: null,
          download: null,
        ),
        files: {}, // Receiver doesn't know files yet
      );

      final response = await http.post(
        prepareUrl,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode(prepareRequest.toJson()),
      );

      if (response.statusCode != 200) {
        throw Exception('Failed to connect to sender: ${response.statusCode}');
      }

      final responseData = jsonDecode(response.body) as Map<String, dynamic>;
      final sessionId = responseData['sessionId'] as String;

      print('Connected! Session ID: $sessionId');

      // 2. Parse file list from response
      final filesData = responseData['files'] as Map<String, dynamic>;
      final files = <String, FileDto>{};
      const mapper = FileDtoMapper();

      for (final entry in filesData.entries) {
        files[entry.key] = mapper.decode(entry.value);
      }

      if (files.isEmpty) {
        print('No files to receive');
        return;
      }

      // 3. Display files
      print('\nFiles to receive:');
      int totalSize = 0;
      for (final file in files.values) {
        print('  - ${file.fileName} (${Formatter.formatBytes(file.size)})');
        totalSize += file.size;
      }
      print('\nTotal size: ${Formatter.formatBytes(totalSize)}');

      // 4. Confirm (if not auto-accept)
      if (!autoAccept) {
        stdout.write('\nAccept? [Y/n]: ');
        final input = stdin.readLineSync()?.toLowerCase() ?? 'y';
        if (input != 'y' && input != 'yes' && input != '') {
          print('Transfer cancelled');
          return;
        }
      }

      // 5. Download files
      final destDir = outputDirectory ?? Directory.current.path;
      await _downloadFiles(sessionId, files, destDir);

      print('\nTransfer complete!');
      print('Files saved to: $destDir');
    } catch (e) {
      print('Error during transfer: $e');
      rethrow;
    }
  }

  /// Downloads files from the sender.
  Future<void> _downloadFiles(
    String sessionId,
    Map<String, FileDto> files,
    String destDir,
  ) async {
    for (final entry in files.entries) {
      final fileId = entry.key;
      final fileDto = entry.value;

      await _downloadFile(sessionId, fileId, fileDto, destDir);
    }
  }

  /// Downloads a single file from the sender.
  Future<void> _downloadFile(
    String sessionId,
    String fileId,
    FileDto fileDto,
    String destDir,
  ) async {
    final downloadUrl = Uri.parse(
      'http://${_sender!.ip}:${_sender!.port}/api/localsend/v2/download?sessionId=$sessionId&fileId=$fileId',
    );

    // Ensure destination directory exists
    final destDirectory = Directory(destDir);
    if (!await destDirectory.exists()) {
      await destDirectory.create(recursive: true);
    }

    // Handle nested paths
    final filePath = path.join(destDir, fileDto.fileName);
    final fileDirectory = Directory(path.dirname(filePath));
    if (!await fileDirectory.exists()) {
      await fileDirectory.create(recursive: true);
    }

    final file = File(filePath);

    // Download with progress bar
    final progressBar = ProgressBar(
      label: fileDto.fileName,
      total: fileDto.size,
    );

    final request = await http.Client().send(http.Request('GET', downloadUrl));

    if (request.statusCode != 200) {
      throw Exception('Failed to download ${fileDto.fileName}: ${request.statusCode}');
    }

    final sink = file.openWrite();
    int received = 0;

    await for (final chunk in request.stream) {
      sink.add(chunk);
      received += chunk.length;
      progressBar.update(received);
    }

    await sink.close();
    progressBar.complete();
  }

  /// Cleans up resources.
  Future<void> cleanup() async {
    _multicast?.stop();
    _multicast?.dispose();
  }
}

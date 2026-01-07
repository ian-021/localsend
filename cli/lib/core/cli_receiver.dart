import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:common/model/device.dart';
import 'package:common/model/dto/file_dto.dart';
import 'package:common/model/dto/info_register_dto.dart';
import 'package:common/model/dto/prepare_upload_request_dto.dart';
import 'package:common/model/dto/prepare_upload_response_dto.dart';
import 'package:common/model/stored_security_context.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:path/path.dart' as path;
import 'package:uuid/uuid.dart';
import '../core/code_phrase.dart';
import '../discovery/cli_multicast.dart';
import '../ui/formatter.dart';
import '../ui/progress_bar.dart';
import '../util/security_helper.dart';

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
  StoredSecurityContext? _securityContext;
  http.Client? _httpClient;

  // Track directory renames to avoid asking multiple times for files in same directory
  final Map<String, String> _directoryRenames = {};

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
        print('Expected format: adjective-noun');
        print('Example: swift-ocean or clear-beach');
        return false;
      }

      _codeHash = CodePhrase.hash(codePhrase);

      // Generate our own security context
      _securityContext = generateSecurityContext();

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

      // Stop multicast immediately to avoid spam
      _multicast?.stop();

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
      // Create HTTP client with certificate validation
      final httpClient = HttpClient();

      // Accept self-signed certificates but validate fingerprint
      httpClient.badCertificateCallback = (cert, host, port) {
        // Extract certificate fingerprint and validate
        final certPem = cert.pem;
        final isValid = validateCertificateFingerprint(
          certPem,
          _sender!.fingerprint,
        );

        if (!isValid) {
          print('Warning: Certificate fingerprint mismatch!');
          print('Expected: ${_sender!.fingerprint}');
          print('Got: ${calculateHashOfCertificate(certPem)}');
        }

        return isValid;
      };

      _httpClient = IOClient(httpClient);

      // 1. Send prepare-upload request to announce ourselves
      final prepareUrl = Uri.parse(
        'https://${_sender!.ip}:${_sender!.port}/api/localsend/v2/prepare-upload',
      );

      final prepareRequest = PrepareUploadRequestDto(
        info: InfoRegisterDto(
          alias: 'CLI Receiver',
          version: '2.1',
          deviceModel: 'CLI',
          deviceType: DeviceType.headless,
          fingerprint: _securityContext!.certificateHash,
          port: null,
          protocol: null,
          download: null,
        ),
        files: {}, // Receiver doesn't know files yet
      );

      final response = await _httpClient!.post(
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
        stdout.write('\nAccept? [y/n]: ');
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
      'https://${_sender!.ip}:${_sender!.port}/api/localsend/v2/download?sessionId=$sessionId&fileId=$fileId',
    );

    // Ensure destination directory exists
    final destDirectory = Directory(destDir);
    if (!await destDirectory.exists()) {
      await destDirectory.create(recursive: true);
    }

    // SECURITY: Sanitize filename to prevent path traversal
    final sanitizedFileName = _sanitizeFileName(fileDto.fileName);
    if (sanitizedFileName.isEmpty) {
      throw Exception('SECURITY: Invalid file name: ${fileDto.fileName}');
    }

    // Handle nested paths
    final filePath = path.join(destDir, sanitizedFileName);

    // SECURITY: Validate path is within destination directory
    final canonicalDest = await destDirectory.resolveSymbolicLinks();
    final canonicalFile = File(filePath).absolute.path;

    if (!canonicalFile.startsWith(canonicalDest)) {
      throw Exception(
        'SECURITY: Path traversal detected: ${fileDto.fileName} -> $canonicalFile',
      );
    }

    // Apply any existing directory renames
    var workingFileName = sanitizedFileName;
    for (final entry in _directoryRenames.entries) {
      if (workingFileName.startsWith(entry.key + path.separator)) {
        workingFileName = workingFileName.replaceFirst(entry.key, entry.value);
      }
    }

    var workingFilePath = path.join(destDir, workingFileName);

    // Check for directory or file conflicts
    final fileDirectory = Directory(path.dirname(workingFilePath));
    if (!await fileDirectory.exists()) {
      await fileDirectory.create(recursive: true);
    }

    // Check if this file is in a subdirectory and if that directory exists
    final isNested = workingFileName.contains(path.separator);
    if (isNested) {
      final topLevelDir = workingFileName.split(path.separator).first;
      final topLevelDirPath = path.join(destDir, topLevelDir);

      // Check if we haven't already asked about this directory
      if (!_directoryRenames.containsKey(topLevelDir) && Directory(topLevelDirPath).existsSync()) {
        print('\n⚠️  Warning: Directory "$topLevelDir" already exists in $destDir');
        final newDirName = await _promptForNewDirectoryName(topLevelDir, destDir);
        _directoryRenames[topLevelDir] = newDirName;

        // Update the working filename with the new directory
        workingFileName = workingFileName.replaceFirst(topLevelDir, newDirName);
        workingFilePath = path.join(destDir, workingFileName);

        // Recreate the directory structure with new name
        final newFileDirectory = Directory(path.dirname(workingFilePath));
        if (!await newFileDirectory.exists()) {
          await newFileDirectory.create(recursive: true);
        }
      }
    } else if (File(workingFilePath).existsSync()) {
      // Single file conflict (no directory nesting)
      print('\n⚠️  Warning: File "${path.basename(workingFilePath)}" already exists in $destDir');
      workingFileName = await _promptForNewFileName(workingFileName, destDir);
      workingFilePath = path.join(destDir, workingFileName);
    }

    // Re-validate the final path for security
    final finalCanonicalFile = File(workingFilePath).absolute.path;
    if (!finalCanonicalFile.startsWith(canonicalDest)) {
      throw Exception(
        'SECURITY: Path traversal detected in new filename: $workingFileName',
      );
    }

    final file = File(workingFilePath);
    final finalFileName = workingFileName;

    // SECURITY: Check file size limit (10 GB max)
    const maxFileSize = 10 * 1024 * 1024 * 1024;
    if (fileDto.size > maxFileSize) {
      throw Exception(
        'File too large: ${fileDto.fileName} (${fileDto.size} bytes, max: $maxFileSize bytes)',
      );
    }

    // Download with progress bar
    final progressBar = ProgressBar(
      label: finalFileName,
      total: fileDto.size,
    );

    final request = await _httpClient!.send(http.Request('GET', downloadUrl));

    if (request.statusCode != 200) {
      throw Exception('Failed to download ${fileDto.fileName}: ${request.statusCode}');
    }

    final sink = file.openWrite();
    int received = 0;

    await for (final chunk in request.stream) {
      received += chunk.length;

      // SECURITY: Validate size while downloading (in case sender lies)
      if (received > maxFileSize) {
        await sink.close();
        await file.delete();
        throw Exception(
          'File exceeded size limit during transfer: ${fileDto.fileName}',
        );
      }

      sink.add(chunk);
      progressBar.update(received);
    }

    await sink.close();
    progressBar.complete();
  }

  /// Sanitizes a file name to prevent path traversal attacks.
  String _sanitizeFileName(String fileName) {
    // Split path into components
    final parts = path.split(fileName);

    // Filter out dangerous components
    final safeParts = parts.where((p) {
      // Remove parent directory references
      if (p == '..' || p == '.') return false;

      // Remove absolute path indicators
      if (path.isAbsolute(p)) return false;

      // Remove path separators within component
      if (p.contains('/') || p.contains('\\')) return false;

      // Keep valid components
      return p.isNotEmpty;
    }).toList();

    // Reconstruct safe path (preserves directory structure for nested files)
    return safeParts.isEmpty ? '' : path.joinAll(safeParts);
  }

  /// Prompts the user for a new directory name when a conflict is detected.
  Future<String> _promptForNewDirectoryName(String originalName, String destDir) async {
    while (true) {
      stdout.write('Enter a new name for the directory (or press Enter to skip): ');
      final input = stdin.readLineSync()?.trim() ?? '';

      if (input.isEmpty) {
        throw Exception('File transfer cancelled: Directory already exists and no new name provided');
      }

      // Sanitize the new directory name (no nested paths allowed for directories)
      if (input.contains('/') || input.contains('\\') || input.contains('..') || input == '.') {
        print('❌ Invalid directory name. Please use a simple name without path separators.');
        continue;
      }

      // Check if the new directory name also conflicts
      final newPath = path.join(destDir, input);
      if (Directory(newPath).existsSync()) {
        print('❌ Directory "$input" also already exists. Please choose a different name.');
        continue;
      }

      print('✓ Using new directory name: $input (all files in "$originalName" will go here)');
      return input;
    }
  }

  /// Prompts the user for a new filename when a conflict is detected.
  Future<String> _promptForNewFileName(String originalName, String destDir) async {
    while (true) {
      stdout.write('Enter a new name for the file (or press Enter to skip): ');
      final input = stdin.readLineSync()?.trim() ?? '';

      if (input.isEmpty) {
        throw Exception('File transfer cancelled: File already exists and no new name provided');
      }

      // Sanitize the new filename
      final sanitized = _sanitizeFileName(input);
      if (sanitized.isEmpty) {
        print('❌ Invalid filename. Please try again.');
        continue;
      }

      // Check if the new name also conflicts
      final newPath = path.join(destDir, sanitized);
      if (File(newPath).existsSync()) {
        print('❌ File "$sanitized" also already exists. Please choose a different name.');
        continue;
      }

      print('✓ Using new filename: $sanitized');
      return sanitized;
    }
  }

  /// Cleans up resources.
  Future<void> cleanup() async {
    _multicast?.stop();
    _multicast?.dispose();
    _httpClient?.close();
  }
}

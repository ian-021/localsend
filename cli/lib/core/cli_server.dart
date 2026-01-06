import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:common/api_route_builder.dart';
import 'package:common/model/dto/file_dto.dart';
import 'package:common/model/dto/info_dto.dart';
import 'package:common/model/dto/info_register_dto.dart';
import 'package:common/model/dto/prepare_upload_request_dto.dart';
import 'package:common/model/dto/prepare_upload_response_dto.dart';
import 'package:common/model/device.dart';
import 'package:common/model/stored_security_context.dart';
import 'package:crypto/crypto.dart';
import 'package:uuid/uuid.dart';
import '../transfer/file_scanner.dart';
import '../util/security_helper.dart';

const _uuid = Uuid();

/// HTTPS server for sender side (receives prepare-upload requests and serves files).
class CliServer {
  final int port;
  final String fingerprint;
  final String alias;
  final Map<String, FileInfo> files;
  final StoredSecurityContext securityContext;
  final String codePhrase;

  HttpServer? _server;
  String? _sessionId;
  final Completer<void> _receiverConnected = Completer<void>();
  final Completer<void> _transferComplete = Completer<void>();
  int _downloadedFiles = 0;

  // SECURITY: Rate limiting to prevent DoS attacks
  final Map<String, List<int>> _requestTimestamps = {};
  static const int _maxRequestsPerMinute = 60;
  static const int _rateLimitWindowMs = 60 * 1000;

  CliServer({
    required this.port,
    required this.fingerprint,
    required this.alias,
    required this.files,
    required this.securityContext,
    required this.codePhrase,
  });

  /// Starts the HTTPS server.
  Future<void> start() async {
    final context = createSecurityContext(securityContext);
    _server = await HttpServer.bindSecure(
      InternetAddress.anyIPv4,
      port,
      context,
    );
    print('Secure server started on port $port');

    _server!.listen(_handleRequest);
  }

  /// Waits for a receiver to connect.
  Future<void> waitForReceiver() {
    return _receiverConnected.future;
  }

  /// Waits for the transfer to complete (all files downloaded).
  Future<void> waitForTransferComplete() {
    return _transferComplete.future;
  }

  /// SECURITY: Checks if the request should be rate limited.
  /// Returns true if the request should be blocked.
  bool _shouldRateLimit(String ipAddress) {
    final now = DateTime.now().millisecondsSinceEpoch;

    // Get or create timestamp list for this IP
    _requestTimestamps.putIfAbsent(ipAddress, () => []);
    final timestamps = _requestTimestamps[ipAddress]!;

    // Remove old timestamps outside the window
    timestamps.removeWhere((ts) => now - ts > _rateLimitWindowMs);

    // Check if limit exceeded
    if (timestamps.length >= _maxRequestsPerMinute) {
      return true; // Rate limit exceeded
    }

    // Add current timestamp
    timestamps.add(now);
    return false;
  }

  /// Handles incoming HTTP requests.
  Future<void> _handleRequest(HttpRequest request) async {
    try {
      // SECURITY: Rate limiting check
      final clientIp = request.connectionInfo?.remoteAddress.address ?? 'unknown';
      if (_shouldRateLimit(clientIp)) {
        print('Warning: Rate limit exceeded for $clientIp');
        request.response.statusCode = 429; // Too Many Requests
        request.response.write('Rate limit exceeded');
        await request.response.close();
        return;
      }

      final uri = request.uri;

      // Handle /api/localsend/v2/info
      if (uri.path.endsWith('/info')) {
        await _handleInfo(request);
        return;
      }

      // Handle /api/localsend/v2/prepare-upload
      if (uri.path.endsWith('/prepare-upload')) {
        await _handlePrepareUpload(request);
        return;
      }

      // Handle /api/localsend/v2/upload
      if (uri.path.endsWith('/upload')) {
        // Note: In CLI mode, the receiver downloads files, not uploads
        // This endpoint is not used in our simplified flow
        request.response.statusCode = 404;
        await request.response.close();
        return;
      }

      // Handle /api/localsend/v2/download
      if (uri.path.contains('/download')) {
        await _handleDownload(request);
        return;
      }

      // Unknown endpoint
      request.response.statusCode = 404;
      await request.response.close();
    } catch (e) {
      print('Error handling request: $e');
      // Try to send error response, but don't fail if response is already closed
      try {
        request.response.statusCode = 500;
        await request.response.close();
      } catch (_) {
        // Response already closed, ignore
      }
    }
  }

  /// Handles /info endpoint.
  Future<void> _handleInfo(HttpRequest request) async {
    final info = InfoDto(
      alias: alias,
      version: '2.1',
      deviceModel: 'CLI',
      deviceType: DeviceType.headless,
      fingerprint: fingerprint,
      download: true, // Sender allows downloads
    );

    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode(info.toJson()));
    await request.response.close();
  }

  /// Handles /prepare-upload endpoint (receiver announces itself).
  Future<void> _handlePrepareUpload(HttpRequest request) async {
    final body = await utf8.decodeStream(request);
    final json = jsonDecode(body) as Map<String, dynamic>;

    // SECURITY: Verify receiver knows the code phrase (mutual authentication)
    if (!json.containsKey('cliAuth')) {
      print('Warning: Rejected connection without authentication');
      request.response.statusCode = 401;
      request.response.write('Authentication required');
      await request.response.close();
      return;
    }

    final cliAuth = json['cliAuth'] as Map<String, dynamic>;
    final timestamp = cliAuth['timestamp'] as String;
    final receivedProof = cliAuth['proof'] as String;

    // Verify timestamp is recent (within 5 minutes to prevent replay attacks)
    final requestTime = int.parse(timestamp);
    final now = DateTime.now().millisecondsSinceEpoch;
    if ((now - requestTime).abs() > 5 * 60 * 1000) {
      print('Warning: Rejected connection with expired timestamp');
      request.response.statusCode = 401;
      request.response.write('Authentication expired');
      await request.response.close();
      return;
    }

    // Verify HMAC proof
    final authData = '$timestamp:$fingerprint';
    final authKey = utf8.encode(codePhrase.toLowerCase());
    final authHmac = Hmac(sha256, authKey);
    final expectedProof = authHmac.convert(utf8.encode(authData)).toString();

    if (receivedProof != expectedProof) {
      print('Warning: Rejected connection with invalid authentication (wrong code phrase?)');
      request.response.statusCode = 403;
      request.response.write('Invalid authentication');
      await request.response.close();
      return;
    }

    final prepareRequest = PrepareUploadRequestDto.fromJson(json);

    print('\nReceiver connected: ${prepareRequest.info.alias}');

    // Generate session ID
    _sessionId = _uuid.v4();

    // Create response with file list and session info
    // We'll send a custom response that includes the file metadata
    const mapper = FileDtoMapper();
    final responseData = {
      'sessionId': _sessionId!,
      'files': files.map((key, value) => MapEntry(key, mapper.encode(value.dto))),
    };

    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode(responseData));
    await request.response.close();

    // Signal that receiver has connected
    if (!_receiverConnected.isCompleted) {
      _receiverConnected.complete();
    }
  }

  /// Handles /download endpoint (serves file content).
  Future<void> _handleDownload(HttpRequest request) async {
    final params = request.uri.queryParameters;
    final fileId = params['fileId'];
    final sessionId = params['sessionId'];

    if (sessionId != _sessionId) {
      request.response.statusCode = 403;
      await request.response.close();
      return;
    }

    if (fileId == null || !files.containsKey(fileId)) {
      request.response.statusCode = 404;
      await request.response.close();
      return;
    }

    final fileInfo = files[fileId]!;
    final file = fileInfo.file;

    request.response.headers.contentType = ContentType.binary;
    request.response.headers.set('Content-Disposition', 'attachment; filename="${fileInfo.dto.fileName}"');
    request.response.headers.contentLength = fileInfo.dto.size;

    // Stream the file (pipe() handles closing the response)
    await file.openRead().pipe(request.response);

    // Track download completion
    _downloadedFiles++;
    print('Downloaded: ${fileInfo.dto.fileName} ($_downloadedFiles/${files.length})');

    // Complete transfer after all downloads finish + grace period for network buffers
    if (_downloadedFiles >= files.length && !_transferComplete.isCompleted) {
      // Give network stack time to flush buffers before shutting down
      Future.delayed(const Duration(milliseconds: 500), () {
        if (!_transferComplete.isCompleted) {
          _transferComplete.complete();
        }
      });
    }
  }

  /// Gets the session ID (available after receiver connects).
  String? get sessionId => _sessionId;

  /// Stops the server.
  Future<void> stop() async {
    await _server?.close();
    _server = null;
  }
}

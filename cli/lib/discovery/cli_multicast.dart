import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:common/constants.dart';
import 'package:common/model/dto/multicast_dto.dart';
import 'package:common/model/device.dart';

/// Handles multicast broadcasting and listening for CLI mode.
class CliMulticast {
  static const String multicastAddress = defaultMulticastGroup;
  static const int multicastPort = defaultPort;

  RawDatagramSocket? _socket;
  Timer? _broadcastTimer;
  final StreamController<Device> _deviceController = StreamController<Device>.broadcast();

  /// Stream of discovered devices.
  Stream<Device> get devices => _deviceController.stream;

  /// Starts broadcasting the sender's information with code phrase hash.
  Future<void> startBroadcasting({
    required String codeHash,
    required String sessionId,
    required String alias,
    required int port,
    required String fingerprint,
    bool useHttps = false,
  }) async {
    // Bind to any available port for sending
    _socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    _socket!.broadcastEnabled = true;

    final dto = MulticastDto(
      alias: alias,
      version: protocolVersion,
      deviceModel: 'CLI',
      deviceType: DeviceType.headless,
      fingerprint: fingerprint,
      port: port,
      protocol: useHttps ? ProtocolType.https : ProtocolType.http,
      download: false,
      announcement: false,
      announce: true,
      codeHash: codeHash,
      cliSessionId: sessionId,
      cliMode: true,
    );

    final message = jsonEncode(dto.toJson());
    final bytes = utf8.encode(message);

    // Broadcast every 500ms
    _broadcastTimer = Timer.periodic(const Duration(milliseconds: 500), (timer) {
      try {
        _socket!.send(
          bytes,
          InternetAddress(multicastAddress),
          multicastPort,
        );
      } catch (e) {
        print('Error broadcasting: $e');
      }
    });

    print('Broadcasting on $multicastAddress:$multicastPort');
  }

  /// Starts listening for multicast announcements with matching code phrase hash.
  Future<void> startListening({
    required String codeHash,
    required Function(Device) onDeviceFound,
  }) async {
    _socket = await RawDatagramSocket.bind(
      InternetAddress.anyIPv4,
      multicastPort,
      reuseAddress: true,
      reusePort: true,
    );

    _socket!.joinMulticast(InternetAddress(multicastAddress));

    print('Listening for sender on $multicastAddress:$multicastPort');
    print('Looking for code hash: $codeHash');

    _socket!.listen((event) {
      if (event == RawSocketEvent.read) {
        final datagram = _socket!.receive();
        if (datagram == null) return;

        try {
          final message = utf8.decode(datagram.data);
          final json = jsonDecode(message) as Map<String, dynamic>;
          final dto = MulticastDto.fromJson(json);

          // Check if this is a CLI mode announcement with matching code hash
          if (dto.cliMode == true && dto.codeHash == codeHash) {
            print('Found matching sender!');

            final device = dto.toDevice(
              datagram.address.address,
              dto.port ?? defaultPort,
              dto.protocol == ProtocolType.https,
            );

            onDeviceFound(device);
            _deviceController.add(device);
          }
        } catch (e) {
          // Ignore malformed messages
          // print('Error parsing multicast message: $e');
        }
      }
    });
  }

  /// Stops broadcasting or listening and cleans up resources.
  void stop() {
    _broadcastTimer?.cancel();
    _broadcastTimer = null;
    _socket?.close();
    _socket = null;
  }

  /// Closes all resources.
  void dispose() {
    stop();
    _deviceController.close();
  }
}

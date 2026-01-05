import 'dart:io';
import 'package:args/args.dart';
import '../core/cli_sender.dart';

/// Handles the 'send' command.
class SendCommand {
  static const String commandName = 'send';

  static void addOptions(ArgParser parser) {
    parser.addOption(
      'port',
      abbr: 'p',
      help: 'Port to use for the server (default: auto)',
      valueHelp: 'PORT',
    );
    parser.addOption(
      'timeout',
      abbr: 't',
      help: 'Timeout in seconds waiting for receiver (default: 300)',
      valueHelp: 'SECONDS',
      defaultsTo: '300',
    );
  }

  static Future<int> execute(ArgResults results, List<String> filePaths) async {
    if (filePaths.isEmpty) {
      print('Error: No files specified');
      print('Usage: localsend send <file1> [file2] ... [options]');
      return 1;
    }

    // Validate all paths exist
    for (final filePath in filePaths) {
      final file = File(filePath);
      final dir = Directory(filePath);
      if (!await file.exists() && !await dir.exists()) {
        print('Error: File or directory not found: $filePath');
        return 1;
      }
    }

    final port = results['port'] != null ? int.tryParse(results['port']) : null;
    final timeoutSeconds = int.tryParse(results['timeout'] ?? '300') ?? 300;

    final sender = CliSender(
      filePaths: filePaths,
      port: port,
      timeout: Duration(seconds: timeoutSeconds),
    );

    final success = await sender.send();
    return success ? 0 : 1;
  }
}

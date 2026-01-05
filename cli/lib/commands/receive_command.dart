import 'package:args/args.dart';
import '../core/cli_receiver.dart';

/// Handles the receive command (when user provides a code phrase).
class ReceiveCommand {
  static void addOptions(ArgParser parser) {
    parser.addOption(
      'output',
      abbr: 'o',
      help: 'Output directory (default: current directory)',
      valueHelp: 'DIR',
    );
    parser.addFlag(
      'yes',
      abbr: 'y',
      help: 'Auto-accept transfer without confirmation',
      negatable: false,
    );
    parser.addOption(
      'timeout',
      abbr: 't',
      help: 'Timeout in seconds waiting for sender (default: 300)',
      valueHelp: 'SECONDS',
      defaultsTo: '300',
    );
  }

  static Future<int> execute(ArgResults results, String codePhrase) async {
    final outputDir = results['output'] as String?;
    final autoAccept = results['yes'] as bool? ?? false;
    final timeoutSeconds = int.tryParse(results['timeout'] ?? '300') ?? 300;

    final receiver = CliReceiver(
      codePhrase: codePhrase,
      outputDirectory: outputDir,
      autoAccept: autoAccept,
      timeout: Duration(seconds: timeoutSeconds),
    );

    final success = await receiver.receive();
    return success ? 0 : 1;
  }
}

import 'dart:io';
import 'package:args/args.dart';
import 'package:common/model/dto/file_dto.dart';
import 'package:common/model/dto/prepare_upload_request_dto.dart';
import 'package:dart_mappable/dart_mappable.dart';
import 'commands/send_command.dart';
import 'commands/receive_command.dart';
import 'core/code_phrase.dart';

const version = '1.0.0';

Future<void> main(List<String> arguments) async {
  // Initialize mappers
  MapperContainer.globals.use(const FileDtoMapper());
  PrepareUploadRequestDtoMapper.ensureInitialized();
  // Handle no arguments
  if (arguments.isEmpty) {
    _printUsage();
    exit(1);
  }

  // Handle global flags first
  if (arguments.contains('--help') || arguments.contains('-h')) {
    _printUsage();
    exit(0);
  }

  if (arguments.contains('--version') || arguments.contains('-v')) {
    print('LocalSend CLI v$version');
    exit(0);
  }

  try {
    // Check if first argument is 'send'
    if (arguments[0] == 'send') {
      if (arguments.length < 2) {
        print('Error: No files specified');
        print('Usage: localsend send <file1> [file2] ... [options]');
        exit(1);
      }

      // Parse send command with its options
      final parser = ArgParser();
      SendCommand.addOptions(parser);

      final results = parser.parse(arguments.sublist(1));
      final filePaths = results.rest;

      if (filePaths.isEmpty) {
        print('Error: No files specified');
        print('Usage: localsend send <file1> [file2] ... [options]');
        exit(1);
      }

      final exitCode = await SendCommand.execute(results, filePaths);
      exit(exitCode);
    }

    // Otherwise, assume it's a code phrase (receive mode)
    final codePhrase = arguments[0];

    // Validate code phrase format
    if (!CodePhrase.validate(codePhrase)) {
      print('Error: Invalid code phrase format');
      print('Expected format: adjective-noun');
      print('Example: swift-ocean or clear-beach');
      print('');
      print('Or use: localsend send <files> to send files');
      exit(1);
    }

    // Parse receive command with its options
    final parser = ArgParser();
    ReceiveCommand.addOptions(parser);

    final results = parser.parse(arguments.sublist(1));
    final exitCode = await ReceiveCommand.execute(results, codePhrase);
    exit(exitCode);
  } on FormatException catch (e) {
    print('Error: ${e.message}');
    print('');
    _printUsage();
    exit(1);
  }
}

void _printUsage() {
  print('LocalSend CLI - Send and receive files with code phrases');
  print('');
  print('Usage:');
  print('  localsend send <file1> [file2] ... [options]  Send files');
  print('  localsend <code-phrase> [options]              Receive files');
  print('  localsend --help                                Show this help');
  print('  localsend --version                             Show version');
  print('');
  print('Examples:');
  print('  localsend send document.pdf               # Send a file');
  print('  localsend send *.jpg report.pdf           # Send multiple files');
  print('  localsend send ./my-folder                # Send a directory');
  print('  localsend swift-ocean                     # Receive with code');
  print('  localsend swift-ocean -o ~/Downloads      # Receive to directory');
  print('');
  print('Send Options:');
  print('  -p, --port <PORT>        Port to use (default: auto)');
  print('  -t, --timeout <SECONDS>  Timeout waiting for receiver (default: 300)');
  print('');
  print('Receive Options:');
  print('  -o, --output <DIR>       Output directory (default: current)');
  print('  -y, --yes                Auto-accept without confirmation');
  print('  -t, --timeout <SECONDS>  Timeout waiting for sender (default: 300)');
  print('');
  print('Global Options:');
  print('  -h, --help               Show this help message');
  print('  -v, --version            Show version information');
  print('  --verbose                Enable verbose logging');
}

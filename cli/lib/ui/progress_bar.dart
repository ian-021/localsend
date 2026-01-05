import 'dart:io';
import 'formatter.dart';

/// A simple progress bar for displaying file transfer progress in the CLI.
class ProgressBar {
  final String label;
  final int total;
  final int barWidth;

  int _current = 0;
  DateTime _startTime = DateTime.now();
  DateTime _lastUpdate = DateTime.now();

  ProgressBar({
    required this.label,
    required this.total,
    this.barWidth = 40,
  }) {
    _startTime = DateTime.now();
    _lastUpdate = DateTime.now();
  }

  /// Updates the progress bar with the current value.
  void update(int current) {
    _current = current;
    _lastUpdate = DateTime.now();
    _render();
  }

  /// Completes the progress bar and moves to the next line.
  void complete() {
    _current = total;
    _render();
    stdout.write('\n');
  }

  /// Renders the progress bar to stdout.
  void _render() {
    final percent = total > 0 ? (_current / total * 100) : 0;
    final filled = total > 0 ? (_current / total * barWidth).round() : 0;
    final bar = '${'=' * filled}${' ' * (barWidth - filled)}';

    final currentStr = Formatter.formatBytes(_current);
    final totalStr = Formatter.formatBytes(total);

    // Calculate speed
    final elapsed = _lastUpdate.difference(_startTime).inMilliseconds;
    final speed = elapsed > 0 ? (_current / elapsed * 1000) : 0.0;
    final speedStr = Formatter.formatSpeed(speed);

    // Clear the line and render
    stdout.write('\r\x1B[K'); // Clear line
    stdout.write('$label: [$bar] ${percent.toStringAsFixed(1)}% ($currentStr/$totalStr) $speedStr');
  }

  /// Creates a simple indeterminate spinner (for when total size is unknown).
  static void spinner(String message) {
    const frames = ['⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏'];
    var index = 0;
    stdout.write('\r${frames[index]} $message');
    index = (index + 1) % frames.length;
  }

  /// Clears the current line in the terminal.
  static void clearLine() {
    stdout.write('\r\x1B[K');
  }
}

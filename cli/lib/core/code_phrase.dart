import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as path;

/// Handles code phrase generation and validation for CLI pairing.
class CodePhrase {
  static final Random _random = Random.secure();

  static List<String>? _adjectives;
  static List<String>? _nouns;
  static List<String>? _animals;

  /// Loads word lists from assets directory.
  static Future<void> _loadWordLists() async {
    if (_adjectives != null && _nouns != null && _animals != null) {
      return; // Already loaded
    }

    // Get the directory where the executable is located
    final executable = Platform.script.toFilePath();
    final binDir = path.dirname(executable);
    final projectRoot = path.dirname(binDir);
    final assetsDir = path.join(projectRoot, 'assets', 'wordlists');

    try {
      _adjectives = await _loadWordList(path.join(assetsDir, 'adjectives.txt'));
      _nouns = await _loadWordList(path.join(assetsDir, 'nouns.txt'));
      _animals = await _loadWordList(path.join(assetsDir, 'animals.txt'));
    } catch (e) {
      // Fallback to embedded word lists if files not found
      _adjectives = _fallbackAdjectives;
      _nouns = _fallbackNouns;
      _animals = _fallbackAnimals;
    }
  }

  static Future<List<String>> _loadWordList(String filePath) async {
    final file = File(filePath);
    if (!await file.exists()) {
      throw FileSystemException('Word list not found', filePath);
    }
    final content = await file.readAsString();
    return content
        .split('\n')
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .toList();
  }

  /// Generates a random code phrase in format: adjective-noun
  /// Example: swift-ocean or clear-beach
  static Future<String> generate() async {
    await _loadWordLists();

    final adjective = _adjectives![_random.nextInt(_adjectives!.length)];
    final noun = _nouns![_random.nextInt(_nouns!.length)];

    return '$adjective-$noun';
  }

  /// Validates the format of a code phrase.
  /// Returns true if the phrase matches the expected format.
  static bool validate(String phrase) {
    if (phrase.isEmpty) return false;

    final parts = phrase.split('-');
    if (parts.length != 2) return false;

    // Check that both parts are non-empty strings
    if (parts[0].isEmpty || parts[1].isEmpty) {
      return false;
    }

    return true;
  }

  /// Computes SHA-256 hash of the code phrase for matching.
  /// Both sender and receiver compute the same hash to find each other.
  static String hash(String phrase) {
    final bytes = utf8.encode(phrase.toLowerCase());
    final digest = sha256.convert(bytes);
    return digest.toString();
  }

  /// Normalizes a code phrase by trimming whitespace and converting to lowercase.
  static String normalize(String phrase) {
    return phrase.trim().toLowerCase();
  }

  // Fallback word lists (subset) in case files aren't found
  static final List<String> _fallbackAdjectives = [
    'swift', 'bright', 'calm', 'brave', 'quiet', 'bold', 'gentle', 'quick',
    'wise', 'warm', 'cool', 'fresh', 'clear', 'wild', 'free', 'soft',
    'dark', 'light', 'pure', 'strong', 'smooth', 'sharp', 'kind', 'noble',
    'grand', 'royal', 'proud', 'silent', 'steady', 'tiny', 'giant', 'happy',
  ];

  static final List<String> _fallbackNouns = [
    'ocean', 'river', 'mountain', 'forest', 'desert', 'valley', 'island', 'canyon',
    'meadow', 'stream', 'lake', 'sea', 'bay', 'gulf', 'coast', 'shore',
    'beach', 'cliff', 'hill', 'peak', 'summit', 'ridge', 'slope', 'plain',
    'field', 'garden', 'grove', 'marsh', 'swamp', 'pond', 'spring', 'waterfall',
  ];

  static final List<String> _fallbackAnimals = [
    'tiger', 'eagle', 'dolphin', 'wolf', 'lion', 'bear', 'fox', 'owl',
    'hawk', 'deer', 'elk', 'moose', 'bison', 'buffalo', 'zebra', 'giraffe',
    'elephant', 'rhino', 'hippo', 'whale', 'shark', 'orca', 'seal', 'otter',
    'beaver', 'rabbit', 'hare', 'squirrel', 'chipmunk', 'raccoon', 'badger', 'weasel',
  ];
}

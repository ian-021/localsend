import 'dart:io';
import 'package:path/path.dart' as path;
import 'package:common/model/dto/file_dto.dart';
import 'package:common/model/file_type.dart';
import 'package:uuid/uuid.dart';

const _uuid = Uuid();

/// Scans files and directories to prepare them for sending.
class FileScanner {
  /// Scans the given paths (files or directories) and returns a map of FileDto objects.
  static Future<Map<String, FileInfo>> scan(List<String> paths) async {
    final result = <String, FileInfo>{};

    for (final filePath in paths) {
      final file = File(filePath);
      final dir = Directory(filePath);

      if (await file.exists()) {
        // It's a file
        final info = await _scanFile(file, null);
        result[info.dto.id] = info;
      } else if (await dir.exists()) {
        // It's a directory - scan recursively
        final files = await _scanDirectory(dir);
        result.addAll(files);
      } else {
        throw FileSystemException('File or directory not found', filePath);
      }
    }

    return result;
  }

  /// Scans a single file and creates a FileInfo.
  static Future<FileInfo> _scanFile(File file, String? relativePath) async {
    final stat = await file.stat();
    final fileName = relativePath ?? path.basename(file.path);

    final dto = FileDto(
      id: _uuid.v4(),
      fileName: fileName,
      size: stat.size,
      fileType: _detectFileType(fileName),
      hash: null, // Could compute SHA-256 here if needed
      preview: null,
      metadata: FileMetadata(
        lastModified: stat.modified,
        lastAccessed: stat.accessed,
      ),
      legacy: false,
    );

    return FileInfo(
      dto: dto,
      file: file,
    );
  }

  /// Scans a directory recursively and returns all files.
  static Future<Map<String, FileInfo>> _scanDirectory(Directory dir) async {
    final result = <String, FileInfo>{};
    final basePath = dir.path;

    await for (final entity in dir.list(recursive: true, followLinks: false)) {
      if (entity is File) {
        // Calculate relative path from base directory
        final relativePath = path.relative(entity.path, from: basePath);
        final info = await _scanFile(entity, relativePath);
        result[info.dto.id] = info;
      }
    }

    return result;
  }

  /// Detects file type based on file extension.
  static FileType _detectFileType(String fileName) {
    final ext = path.extension(fileName).toLowerCase();

    // Images
    if (['.jpg', '.jpeg', '.png', '.gif', '.bmp', '.webp', '.svg', '.heic', '.heif'].contains(ext)) {
      return FileType.image;
    }

    // Videos
    if (['.mp4', '.avi', '.mkv', '.mov', '.wmv', '.flv', '.webm', '.m4v', '.3gp'].contains(ext)) {
      return FileType.video;
    }

    // PDFs
    if (ext == '.pdf') {
      return FileType.pdf;
    }

    // Text
    if (['.txt', '.md', '.log', '.json', '.xml', '.csv', '.yaml', '.yml', '.toml'].contains(ext)) {
      return FileType.text;
    }

    // APK
    if (ext == '.apk') {
      return FileType.apk;
    }

    return FileType.other;
  }
}

/// Contains file information including the DTO and actual file reference.
class FileInfo {
  final FileDto dto;
  final File file;

  FileInfo({
    required this.dto,
    required this.file,
  });
}

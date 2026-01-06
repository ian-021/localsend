# LocalSend CLI

A command-line interface for LocalSend with croc-like code phrase pairing. Send and receive files securely over your local network using simple, memorable code phrases.

## Features

- **Simple Code Phrases**: Use memorable codes like `swift-ocean` for pairing
- **Local Network Only**: Direct peer-to-peer transfers without internet or relay servers
- **Secure**: HTTPS encryption for all transfers
- **Fast**: Direct connections for maximum speed
- **Cross-Platform**: Works on Linux, macOS, and Windows
- **Progress Tracking**: Real-time progress bars for file transfers
- **Directory Support**: Send entire folders recursively
- **Multiple Files**: Send multiple files in one transfer

## Installation

### From Source

1. Ensure you have Flutter/Dart installed (see [.fvmrc](../.fvmrc) for required version)
2. Clone the repository
3. Navigate to the `cli` directory:
   ```bash
   cd localsend/cli
   ```
4. Install dependencies:
   ```bash
   dart pub get
   # or if using fvm:
   fvm dart pub get
   ```
5. Run the CLI:
   ```bash
   dart run bin/cli.dart --help
   ```

### Build Executable

To build a standalone executable:

```bash
dart compile exe bin/cli.dart -o localsend
```

Then move the `localsend` executable to your PATH.

## Usage

### Sending Files

```bash
# Send a single file
localsend send document.pdf

# Send multiple files
localsend send photo1.jpg photo2.jpg document.pdf

# Send a directory
localsend send ./my-folder

# Send with custom port
localsend send file.txt --port 8080

# Send with custom timeout (in seconds)
localsend send file.txt --timeout 600
```

When you run the send command, you'll get a code phrase:

```
Scanning files...
Found 1 file(s) to send
  - document.pdf (2485760 bytes)

Code phrase: swift-ocean

On the receiving device, run:
    localsend swift-ocean

Waiting for receiver...
```

### Receiving Files

On the receiving device, use the code phrase from the sender:

```bash
# Receive files to current directory
localsend swift-ocean

# Receive to specific directory
localsend swift-ocean --output ~/Downloads

# Auto-accept without confirmation
localsend swift-ocean --yes

# Custom timeout
localsend swift-ocean --timeout 600
```

When you run the receive command:

```
Searching for sender with code: swift-ocean
Found sender at 192.168.1.42:53318

Files to receive:
  - document.pdf (2.4 MB)

Total size: 2.4 MB

Accept? [y/n]: y
Receiving: document.pdf [====================] 100% (2.4 MB/2.4 MB) 15.2 MB/s

Transfer complete!
Files saved to: /current/directory
```

## Command Reference

### Global Options

- `-h, --help` - Show help message
- `-v, --version` - Show version information
- `--verbose` - Enable verbose logging

### Send Command

```bash
localsend send <file1> [file2] ... [options]
```

**Options:**
- `-p, --port <PORT>` - Port to use for the server (default: auto-assigned)
- `-t, --timeout <SECONDS>` - Timeout waiting for receiver in seconds (default: 300)

**Examples:**

```bash
# Send single file
localsend send document.pdf

# Send multiple files
localsend send *.jpg report.pdf

# Send directory
localsend send ./photos

# Custom port
localsend send file.txt -p 8080

# 10 minute timeout
localsend send large-file.zip -t 600
```

### Receive Command

```bash
localsend <code-phrase> [options]
```

**Options:**
- `-o, --output <DIR>` - Output directory (default: current directory)
- `-y, --yes` - Auto-accept transfer without confirmation
- `-t, --timeout <SECONDS>` - Timeout waiting for sender in seconds (default: 300)

**Examples:**

```bash
# Receive to current directory
localsend swift-ocean

# Receive to Downloads
localsend swift-ocean -o ~/Downloads

# Auto-accept
localsend swift-ocean -y

# Custom timeout
localsend swift-ocean -t 600
```

## How It Works

### Code Phrase Generation

Code phrases are generated in the format: `<adjective>-<noun>`

- **Adjectives**: 100+ words (e.g., swift, bright, calm)
- **Nouns**: 100+ words (e.g., ocean, river, mountain)

This provides sufficient entropy for local network pairing with short time windows.

### Discovery Process

1. **Sender**:
   - Generates a random code phrase
   - Computes SHA-256 hash of the code phrase
   - Starts HTTP server on an available port
   - Broadcasts multicast announcements with the code hash
   - Waits for receiver to connect

2. **Receiver**:
   - User provides the code phrase
   - Computes SHA-256 hash of the code phrase
   - Listens on multicast for announcements with matching hash
   - Connects to sender when found
   - Downloads files with progress tracking

### Security

- **HTTPS**: All transfers use HTTPS with self-signed certificates (planned)
- **Certificate Pinning**: Receiver validates the sender's certificate fingerprint
- **Code Phrase Matching**: Only devices with the correct code phrase can pair
- **Local Network Only**: No internet connection or relay servers involved
- **Short Time Window**: Transfers timeout after 5 minutes by default

## Troubleshooting

### Receiver Can't Find Sender

**Problem**: Receiver times out searching for sender

**Solutions**:
1. Verify both devices are on the same network
2. Check the code phrase was entered correctly
3. Ensure firewall allows UDP port 53317 (multicast)
4. Try disabling AP isolation on your router
5. Increase timeout: `localsend <code> -t 600`

### Sender Can't Find Receiver

**Problem**: Sender times out waiting for receiver

**Solutions**:
1. Make sure receiver ran the command with the correct code phrase
2. Check both devices are on the same network
3. Ensure firewall allows incoming connections on the server port
4. Increase timeout: `localsend send <files> -t 600`

### Transfer Interrupted

**Problem**: Transfer fails midway

**Solutions**:
1. Check network stability
2. Ensure sufficient disk space on receiver
3. Try sending files individually instead of all at once
4. Check file permissions

### Permission Denied

**Problem**: Can't save files to output directory

**Solutions**:
1. Check write permissions for the output directory
2. Use `-o` to specify a different directory
3. Run with appropriate permissions

## Architecture

The CLI is organized into several modules:

```
cli/
├── lib/
│   ├── commands/          # Command handlers
│   │   ├── send_command.dart
│   │   └── receive_command.dart
│   ├── core/              # Core functionality
│   │   ├── code_phrase.dart      # Code generation/validation
│   │   ├── cli_sender.dart       # Send orchestration
│   │   ├── cli_receiver.dart     # Receive orchestration
│   │   └── cli_server.dart       # HTTP server
│   ├── discovery/         # Network discovery
│   │   └── cli_multicast.dart    # Multicast broadcasting/listening
│   ├── transfer/          # File operations
│   │   └── file_scanner.dart     # File/directory scanning
│   └── ui/                # User interface
│       ├── progress_bar.dart     # Progress display
│       └── formatter.dart        # Output formatting
└── assets/wordlists/      # Word lists for code phrases
```

## Comparison with LocalSend GUI

| Feature | CLI | GUI App |
|---------|-----|---------|
| Discovery | Code phrases | Device discovery |
| Platform | Standalone | Cross-compatible |
| Interface | Terminal | Graphical |
| Use Case | Scripting, headless | Interactive |
| Pairing | Manual code entry | Auto-discovery |

## Comparison with Croc

| Feature | LocalSend CLI | Croc |
|---------|--------------|------|
| Network | Local only | Internet via relay |
| Code Phrases | ✓ | ✓ |
| PAKE Encryption | - (uses HTTPS) | ✓ |
| Relay Server | - | ✓ |
| Cross-Network | - | ✓ |
| Speed | Fast (direct) | Depends on relay |

## Contributing

Contributions are welcome! Please see [CONTRIBUTING.md](../CONTRIBUTING.md) for guidelines.

## License

Same license as LocalSend. See [LICENSE](../LICENSE) for details.

## Related Projects

- [LocalSend](https://localsend.org) - The main LocalSend project with GUI
- [croc](https://github.com/schollz/croc) - Inspiration for code phrase pairing

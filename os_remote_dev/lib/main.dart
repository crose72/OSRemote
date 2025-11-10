import 'package:permission_handler/permission_handler.dart';
import 'dart:io';
import 'dart:convert';
import 'package:path_provider/path_provider.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter/material.dart';
import 'package:dartssh2/dartssh2.dart';

void main() {
  runApp(const MaterialApp(home: JetsonConfigPage()));
}

class JetsonConfigPage extends StatefulWidget {
  const JetsonConfigPage({super.key});
  @override
  State<JetsonConfigPage> createState() => _JetsonConfigPageState();
}

class _JetsonConfigPageState extends State<JetsonConfigPage> {
  final _controller = TextEditingController();
  String _log = "";
  bool _busy = false;

  // --- Connection parameters ---
  final _secureStorage = const FlutterSecureStorage();
  String _host = "10.42.0.1";
  int _port = 22;
  String _username = "";
  String _password = "";
  bool _isSignedIn = false;
  String get _remoteJson =>
    "/home/$_username/workspaces/os-dev/OperationSquirrel/SquirrelDefender/params.json";
  String get _rebuildScript => "/home/$_username/rebuild_container.sh";

// --------------------------------------------------------------------------
// Ask to log in to jetson
// --------------------------------------------------------------------------
Future<void> _showLoginDialog({bool firstTime = false}) async {
  final hostController = TextEditingController(text: _host);
  final usernameController = TextEditingController(text: _username);
  final passwordController = TextEditingController(text: _password);

  await showDialog(
    context: context,
    barrierDismissible: !firstTime,
    builder: (context) {
      return AlertDialog(
        title: Text(firstTime ? "🔐 First-time setup" : "Sign in to Jetson"),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: hostController,
              decoration: const InputDecoration(labelText: "Host (Jetson IP)"),
            ),
            TextField(
              controller: usernameController,
              decoration: const InputDecoration(labelText: "Username"),
            ),
            TextField(
              controller: passwordController,
              decoration: const InputDecoration(labelText: "Password"),
              obscureText: true,
            ),
          ],
        ),
        actions: [
          if (!firstTime)
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text("Cancel"),
            ),
          ElevatedButton(
            onPressed: () async {
              setState(() {
                _host = hostController.text.trim();
                _username = usernameController.text.trim();
                _password = passwordController.text;
                _isSignedIn = true;
              });
              await _saveCredentials();
              Navigator.pop(context);
            },
            child: const Text("Sign In"),
          ),
        ],
      );
    },
  );
}

@override
void initState() {
  super.initState();
  _loadCredentials();
}

Future<void> _loadCredentials() async {
  final savedHost = await _secureStorage.read(key: 'host');
  final savedUser = await _secureStorage.read(key: 'username');
  final savedPass = await _secureStorage.read(key: 'password');

  if (savedHost != null && savedUser != null && savedPass != null) {
    setState(() {
      _host = savedHost;
      _username = savedUser;
      _password = savedPass;
      _isSignedIn = true;
      _log = "🔒 Auto-signed in as $_username @ $_host";
    });
  } else {
    // prompt first-time login
    await _showLoginDialog(firstTime: true);
  }
}

Future<void> _saveCredentials() async {
  await _secureStorage.write(key: 'host', value: _host);
  await _secureStorage.write(key: 'username', value: _username);
  await _secureStorage.write(key: 'password', value: _password);
}

Future<void> _clearCredentials() async {
  await _secureStorage.deleteAll();
  setState(() {
    _isSignedIn = false;
    _password = "";
    _log = "Signed out.";
  });
}

// --------------------------------------------------------------------------
// Fetch existing params.json from Jetson
// --------------------------------------------------------------------------
Future<void> _fetchConfig() async {

    if (!_isSignedIn) {
    await _showLoginDialog();
    if (!_isSignedIn) {
        setState(() => _log = "❌ Sign-in required before connecting.");
        return;
    }
    }

  setState(() => _log = "Connecting to Jetson...");

  try {
    // --- Create SSH socket and client ---
    final socket = await SSHSocket.connect(_host, _port);
    final client = SSHClient(
      socket,
      username: _username,
      onPasswordRequest: () => _password,
    );

    setState(() => _log = "📡 Connected — fetching params.json...");

    // --- Download remote file ---
    final sftp = await client.sftp();
    final file = await sftp.open(_remoteJson);
    final bytes = await file.readBytes();
    final content = utf8.decode(bytes);

    await file.close();
    sftp.close();
    client.close();

    // --- Save locally (optional) ---
    final dir = await getTemporaryDirectory();
    final localFile = File("${dir.path}/params.json");
    await localFile.writeAsString(content);

    setState(() {
      _controller.text = content;
      _log = "✅ params.json loaded successfully!";
    });
  } catch (e, st) {
    debugPrint("Fetch failed: $e\n$st");
    setState(() => _log = "❌ Fetch failed: $e");
  }
}

// --------------------------------------------------------------------------
// Upload updated JSON and rebuild Docker container
// --------------------------------------------------------------------------
Future<void> _uploadConfig() async {

    if (!_isSignedIn) {
        await _showLoginDialog();
        if (!_isSignedIn) {
            setState(() => _log = "❌ Sign-in required before connecting.");
            return;
        }
    }

  setState(() => _log = "Connecting to Jetson...");

  try {
    // Validate JSON
    try {
      jsonDecode(_controller.text);
    } catch (e) {
      setState(() => _log = "❌ Invalid JSON: $e");
      return;
    }

    // --- Create SSH socket and client ---
    final socket = await SSHSocket.connect(_host, _port);
    final client = SSHClient(
      socket,
      username: _username,
      onPasswordRequest: () => _password,
    );

    setState(() => _log = "📡 Connected — uploading params.json...");

    // --- Open SFTP and upload file directly from memory ---
    final sftp = await client.sftp();
    final file = await sftp.open(
      _remoteJson,
      mode: SftpFileOpenMode.create |
            SftpFileOpenMode.truncate |
            SftpFileOpenMode.write,
    );

    final bytes = utf8.encode(_controller.text);
    await file.writeBytes(bytes);
    await file.close();

    setState(() => _log = "✅ Upload successful! Verifying...");

    // --- Verify upload on Jetson ---
    final result = await client.run('ls -lh $_remoteJson || echo "Missing file"');
    setState(() => _log = "✅ Done!\n\n$result");

    // --- Clean up ---
    sftp.close();
    client.close();
  } catch (e, st) {
    debugPrint("Upload failed: $e\n$st");
    setState(() => _log = "❌ Upload failed: $e");
  }
}

  // --------------------------------------------------------------------------
  // UI
  // --------------------------------------------------------------------------
    @override
    Widget build(BuildContext context) {
    return Scaffold(
        appBar: AppBar(title: const Text("Jetson Config Editor")),
        body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
            children: [
            ElevatedButton(
                onPressed: _clearCredentials,
                child: const Text("Sign Out"),
            ),
            Row(
                children: [
                Expanded(
                    child: ElevatedButton(
                    onPressed: _busy ? null : _fetchConfig,
                    child: const Text("Fetch Config"),
                    ),
                ),
                const SizedBox(width: 8),
                Expanded(
                    child: ElevatedButton(
                    onPressed: _busy ? null : _uploadConfig,
                    child: Text(_busy ? "Working..." : "Upload"),
                    ),
                ),
                ],
            ),
            const SizedBox(height: 12),
            const Text("Edit params.json:"),
            Expanded(
                child: TextField(
                controller: _controller,
                maxLines: null,
                expands: true,
                textAlignVertical: TextAlignVertical.top,
                decoration: const InputDecoration(
                    border: OutlineInputBorder(),
                    hintText: '{\n  "Kp": 0.5,\n  "Ki": 0.1\n}',
                ),
                style: const TextStyle(fontFamily: "monospace"),
                ),
            ),
            const SizedBox(height: 12),
            Expanded(
                child: SingleChildScrollView(
                child: Text(
                    _log,
                    style: const TextStyle(fontFamily: "monospace"),
                ),
                ),
            ),
            ],
        ),
        ),
    );
    }
}
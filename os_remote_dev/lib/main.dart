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
  String get _squirrelDefenderParams =>
      "/home/$_username/workspaces/os-dev/OperationSquirrel/SquirrelDefender/params.json";
  String get _operationSquirrelPath =>
      "/home/$_username/workspaces/os-dev/OperationSquirrel/scripts/";
  final _pathController = TextEditingController(
    text: "/workspace/OperationSquirrel/SquirrelDefender/build",
  );
  final ScrollController _logScrollController = ScrollController();

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
                decoration: const InputDecoration(
                  labelText: "Host (Jetson IP)",
                ),
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
  Future<void> _downloadConfig() async {
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
      final file = await sftp.open(_squirrelDefenderParams);
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
        _squirrelDefenderParams,
        mode:
            SftpFileOpenMode.create |
            SftpFileOpenMode.truncate |
            SftpFileOpenMode.write,
      );

      final bytes = utf8.encode(_controller.text);
      await file.writeBytes(bytes);
      await file.close();

      setState(() => _log = "✅ Upload successful! Verifying...");

      // --- Verify upload on Jetson ---
      final result = await client.run(
        'ls -lh $_squirrelDefenderParams || echo "Missing file"',
      );
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
  // Execute a command over SSH (e.g. to start container or run program)
  // --------------------------------------------------------------------------
  Future<void> _execCommand(String cmd, {String? description}) async {
    if (!_isSignedIn) {
      await _showLoginDialog();
      if (!_isSignedIn) {
        setState(() => _log = "❌ Sign-in required before connecting.");
        return;
      }
    }

    setState(() => _log = "⚙️ ${description ?? 'Running command'}...");

    try {
      // --- Connect ---
      final socket = await SSHSocket.connect(_host, _port);
      final client = SSHClient(
        socket,
        username: _username,
        onPasswordRequest: () => _password,
      );

      // --- Run command and decode UTF-8 output ---
      final result = await client.run(cmd);
      final decoded = utf8.decode(result);

      // --- Cleanup ---
      client.close();
      socket.close();

      setState(() => _log = "✅ ${description ?? 'Done'}:\n\n$decoded");
    } catch (e, st) {
      debugPrint("Command failed: $e\n$st");
      setState(() => _log = "❌ Command failed: $e");
    }
  }

  Widget _buildJsonConfigTab() {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: ElevatedButton(
                  onPressed: _busy ? null : _downloadConfig,
                  // style: ElevatedButton.styleFrom(
                  //   textStyle: const TextStyle(fontSize: 12),
                  // ),
                  child: const Text("Download"),
                ),
              ),
              const SizedBox(width: 9),
              Expanded(
                child: ElevatedButton(
                  onPressed: _busy ? null : _uploadConfig,
                  child: Text(_busy ? "Working..." : "Upload"),
                ),
              ),
              const SizedBox(width: 9),
              ElevatedButton(
                onPressed: _clearCredentials,
                child: const Text("Sign Out"),
              ),
            ],
          ),
          const SizedBox(height: 16),
          const Text(
            "✏️ Edit params.json",
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
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
        ],
      ),
    );
  }

  Widget _buildDevContainerTab() {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: ElevatedButton(
                  onPressed: () => _execCommand(
                    "bash -c '$_operationSquirrelPath/run.sh dev orin osremote'",
                    description: "Starting Dev Container",
                  ),
                  child: const Text("Start Dev"),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: ElevatedButton(
                  onPressed: () => _execCommand(
                    "docker stop squirreldefender-dev",
                    description: "Stopping Dev Container",
                  ),
                  child: const Text("Stop Dev"),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: ElevatedButton(
                  onPressed: () => _execCommand(
                    "docker rm -f squirreldefender-dev || true && docker system prune -f",
                    description: "Deleting Dev Container",
                  ),
                  child: const Text("Del Dev"),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: ElevatedButton(
                  onPressed: () => _execCommand(
                    "docker exec -i squirreldefender-dev bash -c 'cd /workspace/OperationSquirrel/SquirrelDefender/build && ./squirreldefender'",
                    description: "Run SquirrelDefender",
                  ),
                  child: const Text("Run EXE"),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: ElevatedButton(
                  onPressed: () => _execCommand(
                    "docker exec squirreldefender-dev pkill -2 -f squirreldefender",
                    description: "Stop SquirrelDefender",
                  ),
                  child: const Text("Stop EXE"),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          const Text(
            "🖥️ Output / Terminal",
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                color: Colors.black,
                borderRadius: BorderRadius.circular(8),
              ),
              padding: const EdgeInsets.all(8),
              child: Scrollbar(
                thumbVisibility: true,
                child: SingleChildScrollView(
                  controller: _logScrollController,
                  child: Text(
                    _log,
                    style: const TextStyle(
                      color: Colors.greenAccent,
                      fontFamily: "monospace",
                      fontSize: 13,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // --------------------------------------------------------------------------
  // UI
  // --------------------------------------------------------------------------
  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text("Operation Squirrel Jetson Control"),
          bottom: const TabBar(
            tabs: [
              Tab(icon: Icon(Icons.developer_board), text: "Dev Container"),
              Tab(icon: Icon(Icons.settings), text: "Params Config"),
            ],
          ),
        ),
        body: TabBarView(
          children: [_buildDevContainerTab(), _buildJsonConfigTab()],
        ),
      ),
    );
  }
}

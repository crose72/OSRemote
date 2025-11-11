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

  final ButtonStyle _buttonStyle = ElevatedButton.styleFrom(
    minimumSize: const Size(0, 46),
    textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
    padding: const EdgeInsets.symmetric(horizontal: 12),
  );

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
  // Ask to log in to Jetson
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
  // Download params.json from Jetson
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
      final socket = await SSHSocket.connect(_host, _port);
      final client =
          SSHClient(socket, username: _username, onPasswordRequest: () => _password);

      setState(() => _log = "📡 Connected — fetching params.json...");

      final sftp = await client.sftp();
      final file = await sftp.open(_squirrelDefenderParams);
      final bytes = await file.readBytes();
      final content = utf8.decode(bytes);

      await file.close();
      sftp.close();
      client.close();

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
  // Upload updated JSON to Jetson
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
    // Pretty-print JSON before upload
    final parsed = jsonDecode(_controller.text);
    final prettyJson = const JsonEncoder.withIndent('  ').convert(parsed);
    _controller.text = prettyJson;

    final socket = await SSHSocket.connect(_host, _port);
    final client = SSHClient(socket, username: _username, onPasswordRequest: () => _password);

    setState(() => _log = "📡 Connected — uploading params.json...");

    final sftp = await client.sftp();
    final file = await sftp.open(
      _squirrelDefenderParams,
      mode: SftpFileOpenMode.create |
          SftpFileOpenMode.truncate |
          SftpFileOpenMode.write,
    );

    final bytes = utf8.encode(prettyJson);
    await file.writeBytes(bytes);
    await file.close();

    setState(() => _log = "✅ Upload successful! Verifying...");

    final result = await client.run('ls -lh $_squirrelDefenderParams || echo "Missing file"');
    final decoded = utf8.decode(result);
    setState(() => _log = "✅ Done!\n\n$decoded");

    sftp.close();
    client.close();
  } catch (e, st) {
    debugPrint("Upload failed: $e\n$st");
    setState(() => _log = "❌ Upload failed: $e");
  }
}

  // --------------------------------------------------------------------------
  // Execute command on Jetson
  // --------------------------------------------------------------------------
Future<void> _execCommand(String cmd, {String? description}) async {
  if (!_isSignedIn) {
    await _showLoginDialog();
    if (!_isSignedIn) {
      setState(() => _log = "❌ Sign-in required before connecting.");
      return;
    }
  }

  setState(() => _log = "⚙️ ${description ?? 'Running command'}...\n");

  try {
    final socket = await SSHSocket.connect(_host, _port);
    final client = SSHClient(
      socket,
      username: _username,
      onPasswordRequest: () => _password,
    );

    // --- Execute command and stream stdout/stderr ---
    final session = await client.execute(cmd);

    session.stdout
        .cast<List<int>>()
        .transform(utf8.decoder)
        .listen((data) {
      setState(() {
        _log += data;
      });
      // Auto-scroll down
      if (_logScrollController.hasClients) {
        _logScrollController.jumpTo(
          _logScrollController.position.maxScrollExtent,
        );
      }
    });

    session.stderr
        .cast<List<int>>()
        .transform(utf8.decoder)
        .listen((data) {
      setState(() {
        _log += "\n❗ $data";
      });
    });

    // Wait until process completes (no exit code available)
    await session.done;

    setState(() {
      _log += "\n\n✅ Process finished.\n";
    });

    client.close();
    socket.close();
  } catch (e, st) {
    debugPrint("Command failed: $e\n$st");
    setState(() => _log = "❌ Command failed: $e");
  }
}

  // --------------------------------------------------------------------------
  // Dynamic JSON → Form widget
  // --------------------------------------------------------------------------
Widget _jsonFormView() {
  Map<String, dynamic> data = {};
  try {
    data = jsonDecode(_controller.text);
  } catch (_) {}

  Widget buildForm(Map<String, dynamic> obj) {
    return Column(
      children: obj.entries.map((entry) {
        final key = entry.key;
        final value = entry.value;

        if (value is Map<String, dynamic>) {
          return ExpansionTile(
            title: Text(key, style: const TextStyle(fontWeight: FontWeight.bold)),
            children: [Padding(
              padding: const EdgeInsets.only(left: 16),
              child: buildForm(value),
            )],
          );
        } else if (value is bool) {
          return SwitchListTile(
            title: Text(key),
            value: value,
            onChanged: (v) {
              obj[key] = v;
              _controller.text = const JsonEncoder.withIndent('  ').convert(data);
              setState(() {});
            },
          );
        } else {
          return ListTile(
            title: Text(key),
            subtitle: TextField(
              controller: TextEditingController(text: value.toString()),
              onChanged: (v) {
                final parsed = num.tryParse(v);
                obj[key] = parsed ?? v;
                _controller.text = const JsonEncoder.withIndent('  ').convert(data);
              },
            ),
          );
        }
      }).toList(),
    );
  }

  return SingleChildScrollView(
    child: buildForm(data),
  );
}

  // --------------------------------------------------------------------------
  // Tabs
  // --------------------------------------------------------------------------
Widget _buildJsonConfigTab() {
  final hasParams = _controller.text.trim().isNotEmpty;

  return Padding(
    padding: const EdgeInsets.all(16),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // --- Buttons Row ---
        Row(
          children: [
            Expanded(
              child: ElevatedButton(
                onPressed: _busy ? null : _downloadConfig,
                style: _buttonStyle,
                child: const Text("Download", textAlign: TextAlign.center),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: ElevatedButton(
                onPressed: _busy ? null : _uploadConfig,
                style: _buttonStyle,
                child: Text(_busy ? "Working..." : "Upload",
                    textAlign: TextAlign.center),
              ),
            ),
            const SizedBox(width: 8),
            ElevatedButton(
              onPressed: _clearCredentials,
              style: _buttonStyle,
              child: const Text("Sign Out", textAlign: TextAlign.center),
            ),
          ],
        ),

        const SizedBox(height: 16),
        const Text(
          "⚙️ Parameters",
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 8),

        // --- Scrollable Form or Placeholder ---
        Expanded(
          child: Padding(
            padding: const EdgeInsets.only(bottom: 30), // 🔼 lifted a bit higher
            child: hasParams
                ? Container(
                    decoration: BoxDecoration(
                      color: Colors.grey.shade100,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: Colors.grey.shade400),
                    ),
                    child: Scrollbar(
                      thumbVisibility: true,
                      child: SingleChildScrollView(
                        padding: const EdgeInsets.all(8),
                        child: _jsonFormView(),
                      ),
                    ),
                  )
                : Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: const [
                        Icon(Icons.download_rounded,
                            size: 48, color: Colors.grey),
                        SizedBox(height: 8),
                        Text(
                          "No parameters loaded.\nTap “Download” to fetch params.json.",
                          textAlign: TextAlign.center,
                          style: TextStyle(color: Colors.grey),
                        ),
                      ],
                    ),
                  ),
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
        // --- Top Buttons ---
        Row(
          children: [
            Expanded(
              child: ElevatedButton(
                onPressed: () => _execCommand(
                  "bash -c '$_operationSquirrelPath/run.sh dev orin osremote'",
                  description: "Starting Dev Container",
                ),
                style: _buttonStyle,
                child: const Text("Start Dev", textAlign: TextAlign.center),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: ElevatedButton(
                onPressed: () => _execCommand(
                  "docker stop squirreldefender-dev",
                  description: "Stopping Dev Container",
                ),
                style: _buttonStyle,
                child: const Text("Stop Dev", textAlign: TextAlign.center),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: ElevatedButton(
                onPressed: () => _execCommand(
                  "docker rm -f squirreldefender-dev || true && docker system prune -f",
                  description: "Deleting Dev Container",
                ),
                style: _buttonStyle,
                child: const Text("Del Dev", textAlign: TextAlign.center),
              ),
            ),
          ],
        ),

        const SizedBox(height: 12),

        // --- Run / Stop EXE Buttons ---
        Row(
          children: [
            Expanded(
              child: ElevatedButton(
                onPressed: () => _execCommand(
                  "docker exec -i squirreldefender-dev bash -c 'cd /workspace/OperationSquirrel/SquirrelDefender/build && ./squirreldefender'",
                  description: "Run SquirrelDefender",
                ),
                style: _buttonStyle,
                child: const Text("Run EXE", textAlign: TextAlign.center),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: ElevatedButton(
                onPressed: () => _execCommand(
                  "docker exec squirreldefender-dev pkill -2 -f squirreldefender",
                  description: "Stop SquirrelDefender",
                ),
                style: _buttonStyle,
                child: const Text("Stop EXE", textAlign: TextAlign.center),
              ),
            ),
          ],
        ),

        const SizedBox(height: 16),
        const Text("🖥️ Output / Terminal",
            style: TextStyle(fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),

        // --- Stable Full-Width Terminal ---
        Expanded(
          child: Padding(
            padding: const EdgeInsets.only(bottom: 40),
            child: Container(
              width: double.infinity, // ✅ prevent narrowing
              constraints: const BoxConstraints(
                minHeight: 300, // ✅ keeps it tall even when log is short
              ),
              decoration: BoxDecoration(
                color: Colors.black,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.grey.shade700),
              ),
              padding: const EdgeInsets.all(8),
              child: Scrollbar(
                thumbVisibility: true,
                child: SingleChildScrollView(
                  controller: _logScrollController,
                  child: Text(
                    _log.isEmpty
                        ? "No output yet.\nTap “Run EXE” to begin..."
                        : _log,
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
          title: const Text("OS Remote"),
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

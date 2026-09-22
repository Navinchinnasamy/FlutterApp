import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:http/http.dart' as http;
import 'package:multicast_dns/multicast_dns.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';

void main() => runApp(const MyApp());

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Stockd',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xff628c6d)),
        scaffoldBackgroundColor: const Color(0xfff7f8f4),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xfff7f8f4),
          surfaceTintColor: Colors.transparent,
          elevation: 0,
        ),
        cardTheme: CardThemeData(
          elevation: 1,
          margin: EdgeInsets.symmetric(vertical: 6),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(18)),
          ),
        ),
        useMaterial3: true,
      ),
      home: const PantryHomePage(),
    );
  }
}

class PantryHomePage extends StatefulWidget {
  const PantryHomePage({super.key});

  @override
  State<PantryHomePage> createState() => _PantryHomePageState();
}

class _PantryHomePageState extends State<PantryHomePage>
    with WidgetsBindingObserver {
  static const _defaultServerUrl = 'http://192.168.1.24:3000';
  final LocalStore _store = LocalStore();
  List<Map<String, dynamic>> _items = [];
  List<Map<String, dynamic>> _shopping = [];
  bool _loading = true;
  bool _syncing = false;
  String? _error;
  String _serverUrl = _defaultServerUrl;
  String? _lastSyncedAt;
  String _connectionStatus = 'Checking connection';
  String _memberName = 'Navin';
  Timer? _retryTimer;
  int _selectedSection = 0;
  String _searchQuery = '';
  String _selectedCategory = 'All';
  String _selectedStatus = 'All';
  String _shoppingFilter = 'To buy';
  String _inventorySort = 'Recently updated';
  bool _syncPending = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _retryTimer = Timer.periodic(
      const Duration(seconds: 30),
      (_) => _retryPendingSync(),
    );
    _load(retryPending: true);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _retryTimer?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && !_loading && !_syncing) {
      _autoSync();
    }
  }

  Future<void> _load({bool retryPending = false}) async {
    try {
      _serverUrl = await _store.serverUrl();
      _lastSyncedAt = await _store.lastSyncedAt();
      _memberName = await _store.memberName();
      _syncPending = await _store.hasPendingSync();
      final data = await _store.read();
      if (!mounted) return;
      setState(() {
        _items = data.items.where((item) => item['deletedAt'] == null).toList();
        _shopping = data.shopping
            .where((item) => item['deletedAt'] == null)
            .toList();
        _loading = false;
      });
      if (!await _store.hasConfiguredMember() && mounted) {
        await _configureMember(initial: true);
      }
      await _checkConnection();
      if (retryPending && await _store.hasPendingSync()) {
        await _autoSync();
      }
    } catch (error) {
      if (mounted)
        setState(() {
          _loading = false;
          _error = error.toString();
        });
    }
  }

  Future<bool> _sync() async {
    setState(() {
      _syncing = true;
      _connectionStatus = 'Syncing';
      _error = null;
    });
    try {
      final data = await _store.sync(_serverUrl);
      await _store.setLastSyncedAt(DateTime.now().toLocal().toString());
      await _store.clearPendingSync();
      if (mounted) setState(() => _syncPending = false);
      if (!mounted) return true;
      setState(() {
        _items = data.items.where((item) => item['deletedAt'] == null).toList();
        _shopping = data.shopping
            .where((item) => item['deletedAt'] == null)
            .toList();
        _syncing = false;
        _connectionStatus = 'Connected';
      });
      _message('Synced with Stockd laptop');
      return true;
    } catch (error) {
      await _store.markSyncPending();
      if (mounted)
        setState(() {
          _syncing = false;
          _syncPending = true;
          _connectionStatus = 'Offline';
          _error = 'Laptop not reachable. Connect to home Wi-Fi and try again.';
        });
      return false;
    }
  }

  Future<void> _retryPendingSync() async {
    if (!mounted || _loading || _syncing || !await _store.hasPendingSync())
      return;
    await _sync();
  }

  Future<void> _checkConnection() async {
    try {
      final response = await http
          .get(Uri.parse('$_serverUrl/api/health'))
          .timeout(const Duration(seconds: 3));
      if (mounted)
        setState(
          () => _connectionStatus = response.statusCode == 200
              ? 'Connected'
              : 'Offline',
        );
    } catch (_) {
      if (mounted) setState(() => _connectionStatus = 'Offline');
    }
  }

  Future<void> _autoSync() async {
    final host = Uri.tryParse(_serverUrl)?.host;
    if (!await _sync() &&
        host != null &&
        host != 'localhost' &&
        host != '127.0.0.1') {
      await _discoverLaptop(silent: true);
    }
  }

  Future<void> _configureLaptop() async {
    final controller = TextEditingController(text: _serverUrl);
    final value = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Laptop connection'),
        content: TextField(
          controller: controller,
          keyboardType: TextInputType.url,
          autocorrect: false,
          decoration: const InputDecoration(
            labelText: 'Stockd laptop address',
            hintText: 'http://192.168.1.25:3000',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (value == null || value.isEmpty) return;
    final normalized = value.endsWith('/')
        ? value.substring(0, value.length - 1)
        : value;
    final uri = Uri.tryParse(normalized);
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
      _message('Enter a valid address such as http://192.168.1.25:3000');
      return;
    }

    await _store.setServerUrl(normalized);
    if (mounted)
      setState(() {
        _serverUrl = normalized;
        _error = null;
      });
    _message('Laptop address saved');
  }

  Future<void> _configureMember({bool initial = false}) async {
    final selected = await showDialog<String>(
      context: context,
      barrierDismissible: !initial,
      builder: (context) => SimpleDialog(
        title: Text(
          initial ? 'Welcome to Stockd' : 'Who is using this iPhone?',
        ),
        children: [
          if (initial)
            const Padding(
              padding: EdgeInsets.fromLTRB(24, 0, 24, 12),
              child: Text('Choose the family member using this device.'),
            ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, 'Navin'),
            child: const Text('Navin'),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, 'Vani'),
            child: const Text('Vani'),
          ),
        ],
      ),
    );
    if (selected == null) return;
    await _store.setMemberName(selected);
    await _store.setMemberConfigured();
    if (mounted) {
      setState(() => _memberName = selected);
      _message('New items will be added by $selected');
    }
  }

  Future<void> _showSettings() async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            const ListTile(
              title: Text('Stockd settings'),
              subtitle: Text('Connection and household preferences'),
            ),
            ListTile(
              leading: const Icon(Icons.laptop_mac_outlined),
              title: const Text('Laptop address'),
              subtitle: Text(_serverUrl),
              onTap: () {
                Navigator.pop(context);
                _configureLaptop();
              },
            ),
            ListTile(
              leading: const Icon(Icons.person_outline),
              title: const Text('Family member'),
              subtitle: Text(_memberName),
              onTap: () {
                Navigator.pop(context);
                _configureMember();
              },
            ),
            ListTile(
              leading: const Icon(Icons.wifi_find),
              title: const Text('Find laptop on Wi-Fi'),
              subtitle: const Text('Discover the Stockd laptop automatically'),
              onTap: () {
                Navigator.pop(context);
                _discoverLaptop();
              },
            ),
            ListTile(
              leading: const Icon(Icons.sync),
              title: const Text('Sync now'),
              subtitle: Text(
                _syncPending
                    ? 'Changes waiting to sync'
                    : 'Keep data up to date',
              ),
              onTap: () {
                Navigator.pop(context);
                _sync();
              },
            ),
            ListTile(
              leading: const Icon(Icons.download_outlined),
              title: const Text('Export local backup'),
              subtitle: const Text('Share a JSON copy of this iPhone data'),
              onTap: () {
                Navigator.pop(context);
                _exportBackup();
              },
            ),
            ListTile(
              leading: const Icon(Icons.upload_file_outlined),
              title: const Text('Import local backup'),
              subtitle: const Text(
                'Replace this iPhone data from a JSON backup',
              ),
              onTap: () {
                Navigator.pop(context);
                _importBackup();
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _exportBackup() async {
    try {
      final data = await _store.read();
      final payload = {
        'format': 'pantry-state-v1',
        'exportedAt': DateTime.now().toUtc().toIso8601String(),
        'items': data.items,
        'shopping': data.shopping,
      };
      final directory = await getTemporaryDirectory();
      final file = File(path.join(directory.path, 'pantry-mobile-backup.json'));
      await file.writeAsString(jsonEncode(payload));
      await SharePlus.instance.share(
        ShareParams(files: [XFile(file.path)], subject: 'Stockd mobile backup'),
      );
    } catch (error) {
      if (mounted) {
        _message('Backup export failed: $error');
      }
    }
  }

  Future<void> _importBackup() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['json'],
        withData: true,
      );
      if (result == null) return;
      final selected = result.files.single;
      final bytes = selected.bytes;
      final filePath = selected.path;
      final content = bytes != null
          ? utf8.decode(bytes)
          : filePath == null
          ? null
          : await File(filePath).readAsString();
      if (content == null) {
        throw const FormatException('Could not read backup file');
      }
      final payload = jsonDecode(content);
      if (payload is! Map<String, dynamic> ||
          payload['format'] != 'pantry-state-v1' ||
          payload['items'] is! List ||
          payload['shopping'] is! List) {
        throw const FormatException('Unsupported Stockd backup format');
      }
      if (!mounted) return;
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Import backup?'),
          content: const Text('This replaces the data stored on this iPhone.'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Import'),
            ),
          ],
        ),
      );
      if (confirmed != true) return;
      final items = List<Map<String, dynamic>>.from(
        (payload['items'] as List).map(
          (item) => Map<String, dynamic>.from(item),
        ),
      );
      final shopping = List<Map<String, dynamic>>.from(
        (payload['shopping'] as List).map(
          (item) => Map<String, dynamic>.from(item),
        ),
      );
      await _store.write(items, shopping);
      await _store.markSyncPending();
      await _load();
      if (mounted) {
        setState(() => _syncPending = true);
        _message('Backup imported. Sync to update the laptop.');
      }
    } catch (error) {
      if (mounted) _message('Backup import failed: $error');
    }
  }

  Future<void> _discoverLaptop({bool silent = false}) async {
    setState(() {
      _syncing = true;
      _error = null;
    });
    final client = MDnsClient();
    try {
      await client.start();
      await for (final PtrResourceRecord pointer
          in client.lookup<PtrResourceRecord>(
            ResourceRecordQuery.serverPointer('_pantry._tcp.local'),
          )) {
        await for (final SrvResourceRecord service
            in client.lookup<SrvResourceRecord>(
              ResourceRecordQuery.service(pointer.domainName),
            )) {
          final host = service.target;
          await for (final IPAddressResourceRecord address
              in client.lookup<IPAddressResourceRecord>(
                ResourceRecordQuery.addressIPv4(host),
              )) {
            final discovered =
                'http://${address.address.address}:${service.port}';
            await _store.setServerUrl(discovered);
            if (!mounted) return;
            setState(() {
              _serverUrl = discovered;
              _syncing = false;
            });
            await _sync();
            if (!silent) _message('Found and synced with Stockd laptop');
            return;
          }
        }
      }
      throw Exception('Stockd laptop was not found');
    } catch (error) {
      if (mounted)
        setState(() {
          _syncing = false;
          if (!silent)
            _error = 'Stockd laptop was not found on this Wi-Fi network.';
        });
    } finally {
      client.stop();
    }
  }

  Future<void> _addShoppingItem() async {
    final draft = await _askForShoppingItem();
    if (draft == null || draft['name']!.isEmpty) return;
    final stamp = DateTime.now().toUtc().toIso8601String();
    _shopping = [
      {
        'id': DateTime.now().millisecondsSinceEpoch,
        'name': draft['name'],
        'note': draft['quantity'],
        'category': draft['category'],
        'date': draft['date'],
        'icon': '🛒',
        'done': 0,
        'who': draft['who'],
        'createdAt': stamp,
        'updatedAt': stamp,
      },
      ..._shopping,
    ];
    await _store.write(_items, _shopping);
    await _store.markSyncPending();
    if (mounted) setState(() => _syncPending = true);
    setState(() {});
    await _sync();
  }

  Future<void> _editShoppingItem(Map<String, dynamic> item) async {
    final nameController = TextEditingController(
      text: item['name'] as String? ?? '',
    );
    final quantityController = TextEditingController(
      text: item['note'] as String? ?? '',
    );
    String category = item['category'] as String? ?? 'Pantry';
    String who = item['who'] as String? ?? _memberName;
    DateTime bestBefore =
        DateTime.tryParse(item['date'] as String? ?? '') ??
        DateTime.now().add(const Duration(days: 7));

    final updated = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Edit shopping item'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: nameController,
                  decoration: const InputDecoration(labelText: 'Item name'),
                ),
                TextField(
                  controller: quantityController,
                  decoration: const InputDecoration(labelText: 'Quantity'),
                ),
                DropdownButtonFormField<String>(
                  initialValue: category,
                  decoration: const InputDecoration(labelText: 'Category'),
                  items:
                      const ['Produce', 'Dairy', 'Pantry', 'Freezer', 'Drinks']
                          .map(
                            (value) => DropdownMenuItem(
                              value: value,
                              child: Text(value),
                            ),
                          )
                          .toList(),
                  onChanged: (value) =>
                      setDialogState(() => category = value ?? 'Pantry'),
                ),
                DropdownButtonFormField<String>(
                  initialValue: who,
                  decoration: const InputDecoration(labelText: 'Added by'),
                  items: const ['Navin', 'Vani']
                      .map(
                        (value) =>
                            DropdownMenuItem(value: value, child: Text(value)),
                      )
                      .toList(),
                  onChanged: (value) =>
                      setDialogState(() => who = value ?? _memberName),
                ),
                TextButton.icon(
                  onPressed: () async {
                    final picked = await showDatePicker(
                      context: context,
                      initialDate: bestBefore,
                      firstDate: DateTime.now(),
                      lastDate: DateTime.now().add(const Duration(days: 3650)),
                    );
                    if (picked != null) {
                      setDialogState(() => bestBefore = picked);
                    }
                  },
                  icon: const Icon(Icons.calendar_today_outlined, size: 17),
                  label: Text(
                    'Best before: ${bestBefore.year}-${bestBefore.month.toString().padLeft(2, '0')}-${bestBefore.day.toString().padLeft(2, '0')}',
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
    if (updated != true || nameController.text.trim().isEmpty) return;
    final stamp = DateTime.now().toUtc().toIso8601String();
    item
      ..['name'] = nameController.text.trim()
      ..['note'] = quantityController.text.trim()
      ..['category'] = category
      ..['who'] = who
      ..['date'] =
          '${bestBefore.year}-${bestBefore.month.toString().padLeft(2, '0')}-${bestBefore.day.toString().padLeft(2, '0')}'
      ..['updatedAt'] = stamp;
    await _store.write(_items, _shopping);
    await _store.markSyncPending();
    if (mounted) setState(() => _syncPending = true);
    if (mounted) setState(() {});
    await _sync();
  }

  Future<void> _markPicked(Map<String, dynamic> shoppingItem) async {
    if (shoppingItem['done'] == 1 || shoppingItem['done'] == true) return;
    final stamp = DateTime.now().toUtc().toIso8601String();
    final id = DateTime.now().millisecondsSinceEpoch;
    _items = [
      {
        'id': id,
        'shoppingId': shoppingItem['id'],
        'name': shoppingItem['name'],
        'category': shoppingItem['category'] ?? 'Pantry',
        'quantity': shoppingItem['note'] ?? '',
        'date': shoppingItem['date'] ?? '2026-09-30',
        'icon': shoppingItem['icon'] ?? '🛒',
        'status': 'ok',
        'createdAt': stamp,
        'updatedAt': stamp,
      },
      ..._items,
    ];
    shoppingItem['done'] = 1;
    shoppingItem['updatedAt'] = stamp;
    await _store.write(_items, _shopping);
    await _store.markSyncPending();
    if (mounted) setState(() => _syncPending = true);
    setState(() {});
    await _sync();
  }

  Future<void> _addInventoryItem() async {
    final draft = await _askForInventoryItem();
    if (draft == null || draft['name']!.isEmpty) return;
    final stamp = DateTime.now().toUtc().toIso8601String();
    _items = [
      {
        'id': DateTime.now().millisecondsSinceEpoch,
        'name': draft['name'],
        'quantity': draft['quantity'],
        'category': draft['category'],
        'date': draft['date'],
        'icon': '🛒',
        'status': draft['status'],
        'createdAt': stamp,
        'updatedAt': stamp,
      },
      ..._items,
    ];
    await _store.write(_items, _shopping);
    await _store.markSyncPending();
    if (mounted) setState(() => _syncPending = true);
    await _sync();
  }

  Future<void> _deleteInventoryItem(Map<String, dynamic> item) async {
    if (!await _confirmDelete(item['name'] as String? ?? 'this item')) return;
    await _store.softDelete('items', item['id']);
    await _store.markSyncPending();
    if (mounted) setState(() => _syncPending = true);
    await _load();
    await _sync();
  }

  Future<void> _deleteShoppingItem(Map<String, dynamic> item) async {
    if (!await _confirmDelete(item['name'] as String? ?? 'this item')) return;
    await _store.softDelete('shopping', item['id']);
    await _store.markSyncPending();
    if (mounted) setState(() => _syncPending = true);
    await _load();
    await _sync();
  }

  Future<bool> _confirmDelete(String name) async {
    return await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Remove item?'),
            content: Text('Remove $name from Stockd?'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Remove'),
              ),
            ],
          ),
        ) ??
        false;
  }

  Future<void> _editInventoryItem(Map<String, dynamic> item) async {
    final nameController = TextEditingController(
      text: item['name'] as String? ?? '',
    );
    final quantityController = TextEditingController(
      text: item['quantity'] as String? ?? '',
    );
    String category = item['category'] as String? ?? 'Pantry';
    String status = item['status'] as String? ?? 'ok';
    DateTime bestBefore =
        DateTime.tryParse(item['date'] as String? ?? '') ??
        DateTime.now().add(const Duration(days: 7));
    final updated = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Edit inventory item'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: nameController,
                  decoration: const InputDecoration(labelText: 'Item name'),
                ),
                TextField(
                  controller: quantityController,
                  decoration: const InputDecoration(labelText: 'Quantity'),
                ),
                DropdownButtonFormField<String>(
                  initialValue: category,
                  decoration: const InputDecoration(labelText: 'Category'),
                  items:
                      const ['Produce', 'Dairy', 'Pantry', 'Freezer', 'Drinks']
                          .map(
                            (value) => DropdownMenuItem(
                              value: value,
                              child: Text(value),
                            ),
                          )
                          .toList(),
                  onChanged: (value) =>
                      setDialogState(() => category = value ?? 'Pantry'),
                ),
                DropdownButtonFormField<String>(
                  initialValue: status,
                  decoration: const InputDecoration(labelText: 'Status'),
                  items: const [
                    DropdownMenuItem(value: 'ok', child: Text('In stock')),
                    DropdownMenuItem(value: 'low', child: Text('Running low')),
                    DropdownMenuItem(value: 'soon', child: Text('Use soon')),
                  ],
                  onChanged: (value) =>
                      setDialogState(() => status = value ?? 'ok'),
                ),
                TextButton.icon(
                  onPressed: () async {
                    final picked = await showDatePicker(
                      context: context,
                      initialDate: bestBefore,
                      firstDate: DateTime.now().subtract(
                        const Duration(days: 3650),
                      ),
                      lastDate: DateTime.now().add(const Duration(days: 3650)),
                    );
                    if (picked != null)
                      setDialogState(() => bestBefore = picked);
                  },
                  icon: const Icon(Icons.calendar_today_outlined, size: 17),
                  label: Text(
                    'Best before: ${bestBefore.year}-${bestBefore.month.toString().padLeft(2, '0')}-${bestBefore.day.toString().padLeft(2, '0')}',
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
    if (updated != true || nameController.text.trim().isEmpty) return;
    item
      ..['name'] = nameController.text.trim()
      ..['quantity'] = quantityController.text.trim()
      ..['category'] = category
      ..['status'] = status
      ..['date'] =
          '${bestBefore.year}-${bestBefore.month.toString().padLeft(2, '0')}-${bestBefore.day.toString().padLeft(2, '0')}'
      ..['updatedAt'] = DateTime.now().toUtc().toIso8601String();
    await _store.write(_items, _shopping);
    await _store.markSyncPending();
    if (mounted) setState(() => _syncPending = true);
    if (mounted) setState(() {});
    await _sync();
  }

  Future<Map<String, String>?> _askForShoppingItem() async {
    final nameController = TextEditingController();
    final quantityController = TextEditingController();
    String category = 'Pantry';
    String who = _memberName;
    DateTime bestBefore = DateTime.now().add(const Duration(days: 7));

    return showDialog<Map<String, String>>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Add to shopping list'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: nameController,
                  autofocus: true,
                  decoration: const InputDecoration(
                    labelText: 'Item name',
                    hintText: 'e.g. Milk',
                  ),
                ),
                TextField(
                  controller: quantityController,
                  decoration: const InputDecoration(
                    labelText: 'Quantity',
                    hintText: 'e.g. 2 bottles',
                  ),
                ),
                DropdownButtonFormField<String>(
                  initialValue: category,
                  decoration: const InputDecoration(labelText: 'Category'),
                  items:
                      const ['Produce', 'Dairy', 'Pantry', 'Freezer', 'Drinks']
                          .map(
                            (value) => DropdownMenuItem(
                              value: value,
                              child: Text(value),
                            ),
                          )
                          .toList(),
                  onChanged: (value) =>
                      setDialogState(() => category = value ?? 'Pantry'),
                ),
                DropdownButtonFormField<String>(
                  initialValue: who,
                  decoration: const InputDecoration(labelText: 'Added by'),
                  items: const ['Navin', 'Vani']
                      .map(
                        (value) =>
                            DropdownMenuItem(value: value, child: Text(value)),
                      )
                      .toList(),
                  onChanged: (value) =>
                      setDialogState(() => who = value ?? 'Navin'),
                ),
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    onPressed: () async {
                      final picked = await showDatePicker(
                        context: context,
                        initialDate: bestBefore,
                        firstDate: DateTime.now(),
                        lastDate: DateTime.now().add(
                          const Duration(days: 3650),
                        ),
                      );
                      if (picked != null)
                        setDialogState(() => bestBefore = picked);
                    },
                    icon: const Icon(Icons.calendar_today_outlined, size: 17),
                    label: Text(
                      'Best before: ${bestBefore.year}-${bestBefore.month.toString().padLeft(2, '0')}-${bestBefore.day.toString().padLeft(2, '0')}',
                    ),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, {
                'name': nameController.text.trim(),
                'quantity': quantityController.text.trim(),
                'category': category,
                'who': who,
                'date':
                    '${bestBefore.year}-${bestBefore.month.toString().padLeft(2, '0')}-${bestBefore.day.toString().padLeft(2, '0')}',
              }),
              child: const Text('Add'),
            ),
          ],
        ),
      ),
    );
  }

  Future<Map<String, String>?> _askForInventoryItem() async {
    final nameController = TextEditingController();
    final quantityController = TextEditingController();
    String category = 'Pantry';
    String status = 'ok';
    DateTime bestBefore = DateTime.now().add(const Duration(days: 7));

    return showDialog<Map<String, String>>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Add inventory item'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: nameController,
                  autofocus: true,
                  decoration: const InputDecoration(
                    labelText: 'Item name',
                    hintText: 'e.g. Rice',
                  ),
                ),
                TextField(
                  controller: quantityController,
                  decoration: const InputDecoration(
                    labelText: 'Quantity',
                    hintText: 'e.g. 2 kg',
                  ),
                ),
                DropdownButtonFormField<String>(
                  initialValue: category,
                  decoration: const InputDecoration(labelText: 'Category'),
                  items:
                      const ['Produce', 'Dairy', 'Pantry', 'Freezer', 'Drinks']
                          .map(
                            (value) => DropdownMenuItem(
                              value: value,
                              child: Text(value),
                            ),
                          )
                          .toList(),
                  onChanged: (value) =>
                      setDialogState(() => category = value ?? 'Pantry'),
                ),
                DropdownButtonFormField<String>(
                  initialValue: status,
                  decoration: const InputDecoration(labelText: 'Status'),
                  items: const [
                    DropdownMenuItem(value: 'ok', child: Text('In stock')),
                    DropdownMenuItem(value: 'low', child: Text('Running low')),
                    DropdownMenuItem(value: 'soon', child: Text('Use soon')),
                  ],
                  onChanged: (value) =>
                      setDialogState(() => status = value ?? 'ok'),
                ),
                TextButton.icon(
                  onPressed: () async {
                    final picked = await showDatePicker(
                      context: context,
                      initialDate: bestBefore,
                      firstDate: DateTime.now().subtract(
                        const Duration(days: 3650),
                      ),
                      lastDate: DateTime.now().add(const Duration(days: 3650)),
                    );
                    if (picked != null) {
                      setDialogState(() => bestBefore = picked);
                    }
                  },
                  icon: const Icon(Icons.calendar_today_outlined, size: 17),
                  label: Text(
                    'Best before: ${bestBefore.year}-${bestBefore.month.toString().padLeft(2, '0')}-${bestBefore.day.toString().padLeft(2, '0')}',
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, {
                'name': nameController.text.trim(),
                'quantity': quantityController.text.trim(),
                'category': category,
                'status': status,
                'date':
                    '${bestBefore.year}-${bestBefore.month.toString().padLeft(2, '0')}-${bestBefore.day.toString().padLeft(2, '0')}',
              }),
              child: const Text('Add'),
            ),
          ],
        ),
      ),
    );
  }

  void _message(String value) =>
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(value)));

  String _greeting() {
    final hour = DateTime.now().hour;
    if (hour < 12) return 'Good morning';
    if (hour < 18) return 'Good afternoon';
    return 'Good evening';
  }

  String _formatTimestamp(String? value) {
    if (value == null || value.isEmpty) return 'Not synced';
    final parsed = DateTime.tryParse(value);
    if (parsed == null) return value;
    final local = parsed.toLocal();
    final date =
        '${local.year}-${local.month.toString().padLeft(2, '0')}-${local.day.toString().padLeft(2, '0')}';
    final time =
        '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
    return '$date at $time';
  }

  String _inventorySubtitle(Map<String, dynamic> item) {
    final details = <String>[
      if ((item['quantity'] as String? ?? '').trim().isNotEmpty)
        (item['quantity'] as String).trim(),
      item['category'] as String? ?? 'Pantry',
      if ((item['date'] as String? ?? '').trim().isNotEmpty)
        item['date'] as String,
    ];
    return details.join(' · ');
  }

  String _shoppingSubtitle(Map<String, dynamic> item) {
    final details = <String>[
      if ((item['note'] as String? ?? '').trim().isNotEmpty)
        (item['note'] as String).trim(),
      item['category'] as String? ?? 'Pantry',
      if ((item['date'] as String? ?? '').trim().isNotEmpty)
        'Best before ${item['date']}',
      'Added by ${item['who'] ?? 'Unknown'}',
    ];
    return details.join(' · ');
  }

  String _statusLabel(String? status) {
    switch (status) {
      case 'low':
        return 'Running low';
      case 'soon':
        return 'Use soon';
      default:
        return 'In stock';
    }
  }

  String? _expiryLabel(String? value) {
    if (value == null || value.isEmpty) return null;
    final date = DateTime.tryParse(value);
    if (date == null) return null;
    final today = DateTime.now();
    final due = DateTime(date.year, date.month, date.day);
    final current = DateTime(today.year, today.month, today.day);
    final days = due.difference(current).inDays;
    if (days < 0) return 'Expired';
    if (days == 0) return 'Best before today';
    if (days <= 3) return 'Best before in $days days';
    return null;
  }

  Color _expiryColor(String? value) {
    final label = _expiryLabel(value);
    if (label == 'Expired') return Colors.red.shade700;
    if (label != null) return Colors.orange.shade800;
    return Colors.grey.shade700;
  }

  List<Map<String, dynamic>> _attentionItems() {
    return _items.where((item) {
      final status = item['status'] as String?;
      return status == 'low' ||
          status == 'soon' ||
          _expiryLabel(item['date'] as String?) != null;
    }).toList();
  }

  List<Map<String, dynamic>> _recentActivity() {
    final records = <Map<String, dynamic>>[
      ..._items.map((item) => {...item, '_type': 'Inventory'}),
      ..._shopping.map((item) => {...item, '_type': 'Shopping'}),
    ];
    records.sort((a, b) {
      final left =
          DateTime.tryParse(a['updatedAt'] as String? ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0);
      final right =
          DateTime.tryParse(b['updatedAt'] as String? ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0);
      return right.compareTo(left);
    });
    return records.take(5).toList();
  }

  bool _matchesSearch(Map<String, dynamic> item) {
    final query = _searchQuery.trim().toLowerCase();
    final categoryMatches =
        _selectedCategory == 'All' || item['category'] == _selectedCategory;
    if (!categoryMatches) return false;
    final statusMatches =
        _selectedSection != 0 ||
        _selectedStatus == 'All' ||
        item['status'] == _selectedStatus;
    if (!statusMatches) return false;
    if (query.isEmpty) return true;
    return [
      item['name'],
      item['category'],
      item['quantity'],
      item['note'],
      item['who'],
    ].whereType<String>().any((value) => value.toLowerCase().contains(query));
  }

  bool _matchesShoppingFilter(Map<String, dynamic> item) {
    final done = item['done'] == 1 || item['done'] == true;
    return _shoppingFilter == 'All' ||
        (_shoppingFilter == 'To buy' && !done) ||
        (_shoppingFilter == 'Completed' && done);
  }

  List<Map<String, dynamic>> _sortedInventory(
    List<Map<String, dynamic>> items,
  ) {
    final sorted = [...items];
    int compareText(dynamic left, dynamic right) => (left?.toString() ?? '')
        .toLowerCase()
        .compareTo((right?.toString() ?? '').toLowerCase());
    DateTime dateValue(dynamic value) =>
        DateTime.tryParse(value?.toString() ?? '') ??
        DateTime.fromMillisecondsSinceEpoch(0);
    sorted.sort((left, right) {
      switch (_inventorySort) {
        case 'Name':
          return compareText(left['name'], right['name']);
        case 'Best before':
          return dateValue(left['date']).compareTo(dateValue(right['date']));
        case 'Stock urgency':
          const rank = {'soon': 0, 'low': 1, 'ok': 2};
          return (rank[left['status']] ?? 3).compareTo(
            rank[right['status']] ?? 3,
          );
        default:
          return dateValue(right['updatedAt'])
              .compareTo(dateValue(left['updatedAt']));
      }
    });
    return sorted;
  }

  @override
  Widget build(BuildContext context) {
    final visibleItems = _sortedInventory(
      _items.where(_matchesSearch).toList(),
    );
    final visibleShopping = _shopping
        .where((item) => _matchesSearch(item) && _matchesShoppingFilter(item))
        .toList();
    final categories = <String>{
      'All',
      ..._items.map((item) => item['category']).whereType<String>(),
      ..._shopping.map((item) => item['category']).whereType<String>(),
    }.toList();
    return Scaffold(
      appBar: AppBar(
        title: const Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Stockd'),
            Text(
              'Family stock',
              style: TextStyle(fontSize: 11, color: Colors.grey),
            ),
          ],
        ),
        actions: [
          IconButton(
            onPressed: _syncing ? null : _discoverLaptop,
            tooltip: 'Find laptop',
            icon: const Icon(Icons.wifi_find),
          ),
          IconButton(
            onPressed: _configureLaptop,
            tooltip: 'Configure laptop',
            icon: const Icon(Icons.laptop_mac_outlined),
          ),
          IconButton(
            onPressed: _configureMember,
            tooltip: 'Choose family member',
            icon: const Icon(Icons.person_outline),
          ),
          IconButton(
            onPressed: _syncing ? null : _sync,
            tooltip: 'Sync with laptop',
            icon: _syncing
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.sync),
          ),
          IconButton(
            onPressed: _showSettings,
            tooltip: 'Settings',
            icon: const Icon(Icons.settings_outlined),
          ),
        ],
      ),
      body: _loading
          ? const _PantrySplash()
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.fromLTRB(18, 18, 18, 36),
                children: [
                  if (_error != null)
                    Card(
                      color: Colors.orange.shade50,
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Text(_error!),
                      ),
                    ),
                  Text(
                    _greeting(),
                    style: Theme.of(context).textTheme.headlineMedium
                        ?.copyWith(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${_items.length} items at home',
                    style: const TextStyle(color: Colors.grey),
                  ),
                  _ConnectionBanner(
                    status: _connectionStatus,
                    serverUrl: _serverUrl,
                    pending: _syncPending,
                    onRetry: _sync,
                  ),
                  if (_lastSyncedAt != null)
                    Text(
                      'Last synced ${_formatTimestamp(_lastSyncedAt)}',
                      style: const TextStyle(color: Colors.grey, fontSize: 11),
                    ),
                  const SizedBox(height: 18),
                  Row(
                    children: [
                      _StatCard(
                        label: 'Inventory',
                        value: '${_items.length}',
                        icon: Icons.inventory_2_outlined,
                        onTap: () => setState(() {
                          _selectedSection = 0;
                          _shoppingFilter = 'To buy';
                        }),
                      ),
                      const SizedBox(width: 10),
                      _StatCard(
                        label: 'To buy',
                        value:
                            '${_shopping.where((item) => item['done'] != 1 && item['done'] != true).length}',
                        icon: Icons.shopping_cart_outlined,
                        onTap: () => setState(() {
                          _selectedSection = 1;
                          _shoppingFilter = 'To buy';
                        }),
                      ),
                    ],
                  ),
                  if (_attentionItems().isNotEmpty) ...[
                    const SizedBox(height: 18),
                    Card(
                      color: Colors.orange.shade50,
                      child: Padding(
                        padding: const EdgeInsets.all(14),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Icon(
                                  Icons.warning_amber_rounded,
                                  color: Colors.orange.shade800,
                                ),
                                const SizedBox(width: 8),
                                Text(
                                  'Needs attention',
                                  style: Theme.of(context).textTheme.titleMedium
                                      ?.copyWith(fontWeight: FontWeight.bold),
                                ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            ..._attentionItems()
                                .take(3)
                                .map(
                                  (item) => Padding(
                                    padding: const EdgeInsets.only(top: 4),
                                    child: Text(
                                      '• ${item['name']} · ${_statusLabel(item['status'] as String?)}${_expiryLabel(item['date'] as String?) == null ? '' : ' · ${_expiryLabel(item['date'] as String?)}'}',
                                    ),
                                  ),
                                ),
                            if (_attentionItems().length > 3)
                              Padding(
                                padding: const EdgeInsets.only(top: 4),
                                child: Text(
                                  '+ ${_attentionItems().length - 3} more',
                                  style: const TextStyle(color: Colors.grey),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ],
                  if (_recentActivity().isNotEmpty) ...[
                    const SizedBox(height: 18),
                    Text(
                      'Recent activity',
                      style: Theme.of(context).textTheme.titleLarge
                          ?.copyWith(fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 8),
                    Card(
                      child: Column(
                        children: _recentActivity()
                            .map(
                              (item) => ListTile(
                                dense: true,
                                leading: Icon(
                                  item['_type'] == 'Inventory'
                                      ? Icons.inventory_2_outlined
                                      : Icons.shopping_cart_outlined,
                                ),
                                title: Text(item['name'] as String? ?? ''),
                                subtitle: Text(
                                  '${item['_type']} · Updated ${_formatTimestamp(item['updatedAt'] as String?)}',
                                ),
                              ),
                            )
                            .toList(),
                      ),
                    ),
                  ],
                  const SizedBox(height: 22),
                  TextField(
                    onChanged: (value) => setState(() => _searchQuery = value),
                    decoration: InputDecoration(
                      hintText: _selectedSection == 0
                          ? 'Search inventory'
                          : 'Search shopping list',
                      prefixIcon: const Icon(Icons.search),
                      suffixIcon: _searchQuery.isEmpty
                          ? null
                          : IconButton(
                              onPressed: () =>
                                  setState(() => _searchQuery = ''),
                              icon: const Icon(Icons.clear),
                            ),
                      filled: true,
                      fillColor: Colors.white,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                        borderSide: BorderSide.none,
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  DropdownButtonFormField<String>(
                    initialValue: categories.contains(_selectedCategory)
                        ? _selectedCategory
                        : 'All',
                    decoration: InputDecoration(
                      labelText: 'Category',
                      prefixIcon: const Icon(Icons.category_outlined),
                      filled: true,
                      fillColor: Colors.white,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                        borderSide: BorderSide.none,
                      ),
                    ),
                    items: categories
                        .map(
                          (category) => DropdownMenuItem(
                            value: category,
                            child: Text(category),
                          ),
                        )
                        .toList(),
                    onChanged: (value) =>
                        setState(() => _selectedCategory = value ?? 'All'),
                  ),
                  const SizedBox(height: 16),
                  if (_selectedSection == 0) ...[
                    DropdownButtonFormField<String>(
                      initialValue: _selectedStatus,
                      decoration: InputDecoration(
                        labelText: 'Stock status',
                        prefixIcon: const Icon(Icons.flag_outlined),
                        filled: true,
                        fillColor: Colors.white,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(14),
                          borderSide: BorderSide.none,
                        ),
                      ),
                      items: const [
                        DropdownMenuItem(value: 'All', child: Text('All')),
                        DropdownMenuItem(value: 'ok', child: Text('In stock')),
                        DropdownMenuItem(
                          value: 'low',
                          child: Text('Running low'),
                        ),
                        DropdownMenuItem(
                          value: 'soon',
                          child: Text('Use soon'),
                        ),
                      ],
                      onChanged: (value) =>
                          setState(() => _selectedStatus = value ?? 'All'),
                    ),
                    const SizedBox(height: 16),
                  ],
                  if (_selectedSection == 0) ...[
                    DropdownButtonFormField<String>(
                      initialValue: _inventorySort,
                      decoration: InputDecoration(
                        labelText: 'Sort inventory',
                        prefixIcon: const Icon(Icons.sort),
                        filled: true,
                        fillColor: Colors.white,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(14),
                          borderSide: BorderSide.none,
                        ),
                      ),
                      items: const [
                        DropdownMenuItem(
                          value: 'Recently updated',
                          child: Text('Recently updated'),
                        ),
                        DropdownMenuItem(value: 'Name', child: Text('Name')),
                        DropdownMenuItem(
                          value: 'Best before',
                          child: Text('Best before'),
                        ),
                        DropdownMenuItem(
                          value: 'Stock urgency',
                          child: Text('Stock urgency'),
                        ),
                      ],
                      onChanged: (value) => setState(
                        () => _inventorySort = value ?? 'Recently updated',
                      ),
                    ),
                    const SizedBox(height: 16),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          'Inventory',
                          style: Theme.of(context).textTheme.titleLarge
                              ?.copyWith(fontWeight: FontWeight.bold),
                        ),
                        Text(
                          '${visibleItems.length} items',
                          style: const TextStyle(
                            color: Colors.grey,
                            fontSize: 12,
                          ),
                        ),
                        FilledButton.icon(
                          onPressed: _addInventoryItem,
                          icon: const Icon(Icons.add),
                          label: const Text('Add'),
                        ),
                      ],
                    ),
                    if (visibleItems.isEmpty)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 20),
                        child: Text(
                          'Your inventory is empty.',
                          style: TextStyle(color: Colors.grey),
                        ),
                      )
                    else
                      ...visibleItems.map(
                        (item) => Card(
                          child: ListTile(
                            leading: CircleAvatar(
                              backgroundColor: const Color(0xffe5f0e7),
                              child: Text(item['icon'] as String? ?? '🛒'),
                            ),
                            title: Text(item['name'] as String? ?? ''),
                            subtitle: Text(
                              '${_inventorySubtitle(item)} · ${_statusLabel(item['status'] as String?)}',
                            ),
                            isThreeLine: true,
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                if (_expiryLabel(item['date'] as String?) !=
                                    null)
                                  Padding(
                                    padding: const EdgeInsets.only(right: 4),
                                    child: Icon(
                                      Icons.warning_amber_rounded,
                                      color: _expiryColor(
                                        item['date'] as String?,
                                      ),
                                    ),
                                  ),
                                IconButton(
                                  onPressed: () => _editInventoryItem(item),
                                  icon: const Icon(Icons.edit_outlined),
                                ),
                                IconButton(
                                  onPressed: () => _deleteInventoryItem(item),
                                  icon: const Icon(Icons.delete_outline),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                  ] else ...[
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          'Shopping list',
                          style: Theme.of(context).textTheme.titleLarge
                              ?.copyWith(fontWeight: FontWeight.bold),
                        ),
                        Row(
                          children: [
                            Text(
                              _memberName,
                              style: const TextStyle(
                                color: Colors.grey,
                                fontSize: 12,
                              ),
                            ),
                            TextButton.icon(
                              onPressed: _addShoppingItem,
                              icon: const Icon(Icons.add),
                              label: const Text('Add'),
                            ),
                          ],
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    SegmentedButton<String>(
                      segments: const [
                        ButtonSegment(
                          value: 'To buy',
                          label: Text('To buy'),
                          icon: Icon(Icons.shopping_cart_outlined),
                        ),
                        ButtonSegment(
                          value: 'Completed',
                          label: Text('Completed'),
                          icon: Icon(Icons.check_circle_outline),
                        ),
                        ButtonSegment(value: 'All', label: Text('All')),
                      ],
                      selected: {_shoppingFilter},
                      onSelectionChanged: (selection) =>
                          setState(() => _shoppingFilter = selection.first),
                    ),
                    if (visibleShopping.isEmpty)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 20),
                        child: Text(
                          'Your shopping list is empty.',
                          style: TextStyle(color: Colors.grey),
                        ),
                      ),
                    ...visibleShopping.map((item) {
                      final done = item['done'] == 1 || item['done'] == true;
                      return Card(
                        color: done ? Colors.grey.shade100 : null,
                        child: ListTile(
                          leading: Checkbox(
                            value: done,
                            onChanged: done ? null : (_) => _markPicked(item),
                          ),
                          title: Text(
                            item['name'] as String,
                            style: TextStyle(
                              decoration: done
                                  ? TextDecoration.lineThrough
                                  : null,
                              color: done ? Colors.grey : null,
                            ),
                          ),
                          subtitle: Text(_shoppingSubtitle(item)),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(
                                onPressed: () => _editShoppingItem(item),
                                icon: const Icon(Icons.edit_outlined),
                              ),
                              IconButton(
                                onPressed: () => _deleteShoppingItem(item),
                                icon: const Icon(Icons.delete_outline),
                              ),
                            ],
                          ),
                        ),
                      );
                    }),
                  ],
                ],
              ),
            ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _selectedSection,
        onDestinationSelected: (index) => setState(() {
          _selectedSection = index;
          _searchQuery = '';
          _selectedCategory = 'All';
          _selectedStatus = 'All';
          _shoppingFilter = 'To buy';
          _inventorySort = 'Recently updated';
        }),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.inventory_2_outlined),
            selectedIcon: Icon(Icons.inventory_2),
            label: 'Inventory',
          ),
          NavigationDestination(
            icon: Icon(Icons.shopping_cart_outlined),
            selectedIcon: Icon(Icons.shopping_cart),
            label: 'Shopping List',
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _selectedSection == 0 ? _addInventoryItem : _addShoppingItem,
        icon: const Icon(Icons.add),
        label: Text(_selectedSection == 0 ? 'Inventory' : 'Shopping'),
      ),
    );
  }
}

class _StatCard extends StatelessWidget {
  const _StatCard({
    required this.label,
    required this.value,
    required this.icon,
    required this.onTap,
  });
  final String label;
  final String value;
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Expanded(
    child: Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              CircleAvatar(
                backgroundColor: const Color(0xffe5f0e7),
                child: Icon(icon, color: const Color(0xff628c6d)),
              ),
              const SizedBox(width: 10),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: const TextStyle(color: Colors.grey, fontSize: 12),
                  ),
                  Text(
                    value,
                    style: const TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

class _PantrySplash extends StatelessWidget {
  const _PantrySplash();

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: const Color(0xfff7f8f4),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 88,
              height: 88,
              decoration: BoxDecoration(
                color: const Color(0xffe5f0e7),
                borderRadius: BorderRadius.circular(24),
              ),
              child: const Icon(
                Icons.inventory_2_outlined,
                size: 48,
                color: Color(0xff628c6d),
              ),
            ),
            const SizedBox(height: 20),
            Text(
              'Stockd',
              style: Theme.of(context).textTheme.headlineMedium
                  ?.copyWith(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 6),
            const Text(
              'Family stock, together',
              style: TextStyle(color: Colors.grey),
            ),
            const SizedBox(height: 28),
            const SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ],
        ),
      ),
    );
  }
}

class _ConnectionBanner extends StatelessWidget {
  const _ConnectionBanner({
    required this.status,
    required this.serverUrl,
    required this.pending,
    required this.onRetry,
  });
  final String status;
  final String serverUrl;
  final bool pending;
  final Future<bool> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    final connected = status == 'Connected';
    final syncing = status == 'Syncing';
    final color = connected
        ? const Color(0xff628c6d)
        : syncing
        ? Colors.orange
        : Colors.grey;
    return Container(
      margin: const EdgeInsets.only(top: 12),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: color.withValues(alpha: .1),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Icon(
            syncing
                ? Icons.sync
                : connected
                ? Icons.cloud_done_outlined
                : Icons.cloud_off_outlined,
            size: 17,
            color: color,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              pending
                  ? '$status · Changes waiting to sync'
                  : '$status · $serverUrl',
              style: TextStyle(color: color, fontSize: 11),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (!connected && !syncing)
            TextButton(onPressed: onRetry, child: const Text('Sync')),
        ],
      ),
    );
  }
}

class PantryData {
  const PantryData(this.items, this.shopping);
  final List<Map<String, dynamic>> items;
  final List<Map<String, dynamic>> shopping;
}

class LocalStore {
  Database? _database;

  Future<String> serverUrl() async {
    final preferences = await SharedPreferences.getInstance();
    final saved = preferences.getString('server_url');
    if (saved == null || saved == 'http://localhost:3000') {
      const defaultUrl = 'http://192.168.1.24:3000';
      await preferences.setString('server_url', defaultUrl);
      return defaultUrl;
    }
    return saved;
  }

  Future<void> setServerUrl(String value) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString('server_url', value);
  }

  Future<String?> lastSyncedAt() async {
    final preferences = await SharedPreferences.getInstance();
    return preferences.getString('last_synced_at');
  }

  Future<void> setLastSyncedAt(String value) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString('last_synced_at', value);
  }

  Future<String> memberName() async {
    final preferences = await SharedPreferences.getInstance();
    return preferences.getString('member_name') ?? 'Navin';
  }

  Future<void> setMemberName(String value) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString('member_name', value);
  }

  Future<bool> hasConfiguredMember() async {
    final preferences = await SharedPreferences.getInstance();
    return preferences.getBool('member_configured') ?? false;
  }

  Future<void> setMemberConfigured() async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setBool('member_configured', true);
  }

  Future<bool> hasPendingSync() async {
    final preferences = await SharedPreferences.getInstance();
    return preferences.getBool('sync_pending') ?? false;
  }

  Future<void> markSyncPending() async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setBool('sync_pending', true);
  }

  Future<void> clearPendingSync() async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setBool('sync_pending', false);
  }

  Future<void> softDelete(String table, dynamic id) async {
    if (table != 'items' && table != 'shopping') {
      throw ArgumentError.value(table, 'table', 'Unsupported Pantry table');
    }
    final db = await database;
    final timestamp = DateTime.now().toUtc().toIso8601String();
    await db.update(
      table,
      {'deletedAt': timestamp, 'updatedAt': timestamp},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<Database> get database async {
    if (_database != null) return _database!;
    final directory = await getApplicationDocumentsDirectory();
    _database = await openDatabase(
      path.join(directory.path, 'pantry_mobile.db'),
      version: 2,
      onCreate: (db, version) async {
        await db.execute(
          'CREATE TABLE items (id INTEGER PRIMARY KEY, shoppingId INTEGER, createdAt TEXT, updatedAt TEXT, deletedAt TEXT, name TEXT, category TEXT, quantity TEXT, date TEXT, icon TEXT, status TEXT)',
        );
        await db.execute(
          'CREATE TABLE shopping (id INTEGER PRIMARY KEY, createdAt TEXT, updatedAt TEXT, deletedAt TEXT, name TEXT, note TEXT, category TEXT, date TEXT, icon TEXT, done INTEGER, who TEXT)',
        );
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          await db.execute('ALTER TABLE items ADD COLUMN deletedAt TEXT');
          await db.execute('ALTER TABLE shopping ADD COLUMN deletedAt TEXT');
        }
      },
    );
    return _database!;
  }

  Future<PantryData> read() async {
    final db = await database;
    return PantryData(
      await db.query('items', orderBy: 'id DESC'),
      await db.query('shopping', orderBy: 'id DESC'),
    );
  }

  Future<void> write(
    List<Map<String, dynamic>> items,
    List<Map<String, dynamic>> shopping,
  ) async {
    final db = await database;
    await db.transaction((txn) async {
      await txn.delete('items');
      await txn.delete('shopping');
      for (final source in items) {
        final item = Map<String, dynamic>.from(source)
          ..removeWhere((key, value) => value == null);
        await txn.insert('items', item);
      }
      for (final source in shopping) {
        final item = Map<String, dynamic>.from(source)
          ..removeWhere((key, value) => value == null)
          ..['done'] = source['done'] == true || source['done'] == 1 ? 1 : 0;
        await txn.insert('shopping', item);
      }
    });
  }

  Future<PantryData> sync(String baseUrl) async {
    final local = await read();
    final response = await http
        .put(
          Uri.parse('$baseUrl/api/sync'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'items': local.items, 'shopping': local.shopping}),
        )
        .timeout(const Duration(seconds: 5));
    if (response.statusCode != 200) throw Exception('Sync failed');
    final payload = jsonDecode(response.body) as Map<String, dynamic>;
    final data = PantryData(
      List<Map<String, dynamic>>.from(
        (payload['items'] as List).map(
          (item) => Map<String, dynamic>.from(item),
        ),
      ),
      List<Map<String, dynamic>>.from(
        (payload['shopping'] as List).map(
          (item) => Map<String, dynamic>.from(item),
        ),
      ),
    );
    await write(data.items, data.shopping);
    return data;
  }
}

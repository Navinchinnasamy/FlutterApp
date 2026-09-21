import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:multicast_dns/multicast_dns.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';

void main() => runApp(const MyApp());

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Pantry',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xff628c6d)),
        scaffoldBackgroundColor: const Color(0xfff7f8f4),
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

class _PantryHomePageState extends State<PantryHomePage> with WidgetsBindingObserver {
  final LocalStore _store = LocalStore();
  List<Map<String, dynamic>> _items = [];
  List<Map<String, dynamic>> _shopping = [];
  bool _loading = true;
  bool _syncing = false;
  String? _error;
  String _serverUrl = 'http://localhost:3000';
  String? _lastSyncedAt;
  String _connectionStatus = 'Checking connection';
  String _memberName = 'Navin';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && !_loading && !_syncing) {
      _autoSync();
    }
  }

  Future<void> _load() async {
    try {
      _serverUrl = await _store.serverUrl();
      _lastSyncedAt = await _store.lastSyncedAt();
      _memberName = await _store.memberName();
      final data = await _store.read();
      if (!mounted) return;
      setState(() {
        _items = data.items.where((item) => item['deletedAt'] == null).toList();
        _shopping = data.shopping.where((item) => item['deletedAt'] == null).toList();
        _loading = false;
      });
      await _checkConnection();
    } catch (error) {
      if (mounted) setState(() { _loading = false; _error = error.toString(); });
    }
  }

  Future<bool> _sync() async {
    setState(() { _syncing = true; _connectionStatus = 'Syncing'; _error = null; });
    try {
      final data = await _store.sync(_serverUrl);
      if (!mounted) return true;
      setState(() {
        _items = data.items.where((item) => item['deletedAt'] == null).toList();
        _shopping = data.shopping.where((item) => item['deletedAt'] == null).toList();
        _syncing = false;
        _connectionStatus = 'Connected';
      });
      await _store.setLastSyncedAt(DateTime.now().toLocal().toString());
      if (mounted) setState(() {});
      _message('Synced with Pantry laptop');
      return true;
    } catch (error) {
      if (mounted) setState(() { _syncing = false; _connectionStatus = 'Offline'; _error = 'Laptop not reachable. Connect to home Wi-Fi and try again.'; });
      return false;
    }
  }

  Future<void> _checkConnection() async {
    try {
      final response = await http.get(Uri.parse('$_serverUrl/api/health')).timeout(const Duration(seconds: 3));
      if (mounted) setState(() => _connectionStatus = response.statusCode == 200 ? 'Connected' : 'Offline');
    } catch (_) {
      if (mounted) setState(() => _connectionStatus = 'Offline');
    }
  }

  Future<void> _autoSync() async {
    if (!await _sync()) {
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
              labelText: 'Pantry laptop address',
              hintText: 'http://192.168.1.25:3000',
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(context, controller.text.trim()), child: const Text('Save')),
          ],
        ),
      );
      if (value == null || value.isEmpty) return;
      final normalized = value.endsWith('/') ? value.substring(0, value.length - 1) : value;
      final uri = Uri.tryParse(normalized);
      if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
        _message('Enter a valid address such as http://192.168.1.25:3000');
        return;
      }

      await _store.setServerUrl(normalized);
      if (mounted) setState(() { _serverUrl = normalized; _error = null; });
      _message('Laptop address saved');
  }

  Future<void> _configureMember() async {
    final selected = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Who is using this iPhone?'),
        children: [
          SimpleDialogOption(onPressed: () => Navigator.pop(context, 'Navin'), child: const Text('Navin')),
          SimpleDialogOption(onPressed: () => Navigator.pop(context, 'Vani'), child: const Text('Vani')),
        ],
      ),
    );
    if (selected == null) return;
    await _store.setMemberName(selected);
    if (mounted) {
      setState(() => _memberName = selected);
      _message('New items will be added by $selected');
    }
  }

  Future<void> _discoverLaptop({bool silent = false}) async {
    setState(() { _syncing = true; _error = null; });
    final client = MDnsClient();
    try {
      await client.start();
      await for (final PtrResourceRecord pointer in client.lookup<PtrResourceRecord>(
        ResourceRecordQuery.serverPointer('_pantry._tcp.local'),
      )) {
        await for (final SrvResourceRecord service in client.lookup<SrvResourceRecord>(
          ResourceRecordQuery.service(pointer.domainName),
        )) {
          final host = service.target;
          await for (final IPAddressResourceRecord address in client.lookup<IPAddressResourceRecord>(
            ResourceRecordQuery.addressIPv4(host),
          )) {
            final discovered = 'http://${address.address.address}:${service.port}';
            await _store.setServerUrl(discovered);
            if (!mounted) return;
            setState(() { _serverUrl = discovered; _syncing = false; });
            await _sync();
            if (!silent) _message('Found and synced with Pantry laptop');
            return;
          }
        }
      }
      throw Exception('Pantry laptop was not found');
    } catch (_) {
      if (mounted) setState(() { _syncing = false; if (!silent) _error = 'Pantry laptop was not found on this Wi-Fi network.'; });
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
    setState(() {});
  }

  Future<void> _markPicked(Map<String, dynamic> shoppingItem) async {
    if (shoppingItem['done'] == 1 || shoppingItem['done'] == true) return;
    final stamp = DateTime.now().toUtc().toIso8601String();
    final id = DateTime.now().millisecondsSinceEpoch;
    _items = [
      {'id': id, 'shoppingId': shoppingItem['id'], 'name': shoppingItem['name'], 'category': shoppingItem['category'] ?? 'Pantry', 'quantity': shoppingItem['note'] ?? '', 'date': shoppingItem['date'] ?? '2026-09-30', 'icon': shoppingItem['icon'] ?? '🛒', 'status': 'ok', 'createdAt': stamp, 'updatedAt': stamp},
      ..._items,
    ];
    shoppingItem['done'] = 1;
    shoppingItem['updatedAt'] = stamp;
    await _store.write(_items, _shopping);
    setState(() {});
  }

  Future<void> _editInventoryItem(Map<String, dynamic> item) async {
    final nameController = TextEditingController(text: item['name'] as String? ?? '');
    final quantityController = TextEditingController(text: item['quantity'] as String? ?? '');
    String category = item['category'] as String? ?? 'Pantry';
    String status = item['status'] as String? ?? 'ok';
    DateTime bestBefore = DateTime.tryParse(item['date'] as String? ?? '') ?? DateTime.now().add(const Duration(days: 7));
    final updated = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Edit inventory item'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(controller: nameController, decoration: const InputDecoration(labelText: 'Item name')),
                TextField(controller: quantityController, decoration: const InputDecoration(labelText: 'Quantity')),
                DropdownButtonFormField<String>(
                  initialValue: category,
                  decoration: const InputDecoration(labelText: 'Category'),
                  items: const ['Produce', 'Dairy', 'Pantry', 'Freezer', 'Drinks']
                      .map((value) => DropdownMenuItem(value: value, child: Text(value)))
                      .toList(),
                  onChanged: (value) => setDialogState(() => category = value ?? 'Pantry'),
                ),
                DropdownButtonFormField<String>(
                  initialValue: status,
                  decoration: const InputDecoration(labelText: 'Status'),
                  items: const [
                    DropdownMenuItem(value: 'ok', child: Text('In stock')),
                    DropdownMenuItem(value: 'low', child: Text('Running low')),
                    DropdownMenuItem(value: 'soon', child: Text('Use soon')),
                  ],
                  onChanged: (value) => setDialogState(() => status = value ?? 'ok'),
                ),
                TextButton.icon(
                  onPressed: () async {
                    final picked = await showDatePicker(
                      context: context,
                      initialDate: bestBefore,
                      firstDate: DateTime.now().subtract(const Duration(days: 3650)),
                      lastDate: DateTime.now().add(const Duration(days: 3650)),
                    );
                    if (picked != null) setDialogState(() => bestBefore = picked);
                  },
                  icon: const Icon(Icons.calendar_today_outlined, size: 17),
                  label: Text('Best before: ${bestBefore.year}-${bestBefore.month.toString().padLeft(2, '0')}-${bestBefore.day.toString().padLeft(2, '0')}'),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Save')),
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
      ..['date'] = '${bestBefore.year}-${bestBefore.month.toString().padLeft(2, '0')}-${bestBefore.day.toString().padLeft(2, '0')}'
      ..['updatedAt'] = DateTime.now().toUtc().toIso8601String();
    await _store.write(_items, _shopping);
    if (mounted) setState(() {});
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
                  decoration: const InputDecoration(labelText: 'Item name', hintText: 'e.g. Milk'),
                ),
                TextField(
                  controller: quantityController,
                  decoration: const InputDecoration(labelText: 'Quantity', hintText: 'e.g. 2 bottles'),
                ),
                DropdownButtonFormField<String>(
                  initialValue: category,
                  decoration: const InputDecoration(labelText: 'Category'),
                  items: const ['Produce', 'Dairy', 'Pantry', 'Freezer', 'Drinks']
                      .map((value) => DropdownMenuItem(value: value, child: Text(value)))
                      .toList(),
                  onChanged: (value) => setDialogState(() => category = value ?? 'Pantry'),
                ),
                DropdownButtonFormField<String>(
                  initialValue: who,
                  decoration: const InputDecoration(labelText: 'Added by'),
                  items: const ['Navin', 'Vani']
                      .map((value) => DropdownMenuItem(value: value, child: Text(value)))
                      .toList(),
                  onChanged: (value) => setDialogState(() => who = value ?? 'Navin'),
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
                        lastDate: DateTime.now().add(const Duration(days: 3650)),
                      );
                      if (picked != null) setDialogState(() => bestBefore = picked);
                    },
                    icon: const Icon(Icons.calendar_today_outlined, size: 17),
                    label: Text('Best before: ${bestBefore.year}-${bestBefore.month.toString().padLeft(2, '0')}-${bestBefore.day.toString().padLeft(2, '0')}'),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
            FilledButton(
              onPressed: () => Navigator.pop(context, {
                'name': nameController.text.trim(),
                'quantity': quantityController.text.trim(),
                'category': category,
                'who': who,
                'date': '${bestBefore.year}-${bestBefore.month.toString().padLeft(2, '0')}-${bestBefore.day.toString().padLeft(2, '0')}',
              }),
              child: const Text('Add'),
            ),
          ],
        ),
      ),
    );
  }

  void _message(String value) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(value)));

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text('Pantry'), Text('Family stock', style: TextStyle(fontSize: 11, color: Colors.grey))]),
        actions: [
          IconButton(onPressed: _syncing ? null : _discoverLaptop, tooltip: 'Find laptop', icon: const Icon(Icons.wifi_find)),
          IconButton(onPressed: _configureLaptop, tooltip: 'Configure laptop', icon: const Icon(Icons.laptop_mac_outlined)),
          IconButton(onPressed: _configureMember, tooltip: 'Choose family member', icon: const Icon(Icons.person_outline)),
          IconButton(onPressed: _syncing ? null : _sync, tooltip: 'Sync with laptop', icon: _syncing ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.sync)),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(onRefresh: _load, child: ListView(padding: const EdgeInsets.all(18), children: [
              if (_error != null) Card(color: Colors.orange.shade50, child: Padding(padding: const EdgeInsets.all(12), child: Text(_error!))),
              Text('Good evening', style: Theme.of(context).textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.bold)),
              const SizedBox(height: 4),
              Text('${_items.length} items at home', style: const TextStyle(color: Colors.grey)),
              _ConnectionBanner(status: _connectionStatus, serverUrl: _serverUrl, onRetry: _sync),
              if (_lastSyncedAt != null) Text('Last synced $_lastSyncedAt', style: const TextStyle(color: Colors.grey, fontSize: 11)),
              const SizedBox(height: 18),
              Row(children: [
                _StatCard(label: 'Inventory', value: '${_items.length}', icon: Icons.inventory_2_outlined),
                const SizedBox(width: 10),
                _StatCard(label: 'To buy', value: '${_shopping.where((item) => item['done'] != 1 && item['done'] != true).length}', icon: Icons.shopping_cart_outlined),
              ]),
              const SizedBox(height: 22),
              Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                Text('Inventory', style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold)),
                Text('${_items.length} items', style: const TextStyle(color: Colors.grey, fontSize: 12)),
              ]),
              if (_items.isEmpty)
                const Padding(padding: EdgeInsets.symmetric(vertical: 20), child: Text('Your inventory is empty.', style: TextStyle(color: Colors.grey)))
              else
                ..._items.map((item) => Card(
                  child: ListTile(
                    leading: CircleAvatar(
                      backgroundColor: const Color(0xffe5f0e7),
                      child: Text(item['icon'] as String? ?? '🛒'),
                    ),
                    title: Text(item['name'] as String? ?? ''),
                    subtitle: Text('${item['quantity'] ?? ''} · ${item['category'] ?? 'Pantry'} · ${item['date'] ?? 'No date'}'),
                    trailing: IconButton(onPressed: () => _editInventoryItem(item), icon: const Icon(Icons.edit_outlined)),
                  ),
                )),
              const SizedBox(height: 22),
              Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                Text('Shopping list', style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold)),
                Row(children: [
                  Text(_memberName, style: const TextStyle(color: Colors.grey, fontSize: 12)),
                  TextButton.icon(onPressed: _addShoppingItem, icon: const Icon(Icons.add), label: const Text('Add')),
                ]),
              ]),
              if (_shopping.isEmpty) const Padding(padding: EdgeInsets.symmetric(vertical: 20), child: Text('Your shopping list is empty.', style: TextStyle(color: Colors.grey))),
              ..._shopping.map((item) => Card(
                child: ListTile(
                  leading: Checkbox(value: item['done'] == 1 || item['done'] == true, onChanged: (_) => _markPicked(item)),
                  title: Text(item['name'] as String, style: TextStyle(decoration: item['done'] == 1 || item['done'] == true ? TextDecoration.lineThrough : null)),
                  subtitle: Text('${item['category'] ?? 'Pantry'} · Added by ${item['who'] ?? 'Unknown'} · ${item['updatedAt'] ?? 'Not synced'}'),
                ),
              )),
            ])),
    );
  }
}

class _StatCard extends StatelessWidget {
  const _StatCard({required this.label, required this.value, required this.icon});
  final String label;
  final String value;
  final IconData icon;

  @override
  Widget build(BuildContext context) => Expanded(child: Card(child: Padding(padding: const EdgeInsets.all(14), child: Row(children: [Icon(icon, color: const Color(0xff628c6d)), const SizedBox(width: 10), Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(label, style: const TextStyle(color: Colors.grey, fontSize: 12)), Text(value, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold))])]))));
}

class _ConnectionBanner extends StatelessWidget {
  const _ConnectionBanner({required this.status, required this.serverUrl, required this.onRetry});
  final String status;
  final String serverUrl;
  final Future<bool> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    final connected = status == 'Connected';
    final syncing = status == 'Syncing';
    final color = connected ? const Color(0xff628c6d) : syncing ? Colors.orange : Colors.grey;
    return Container(
      margin: const EdgeInsets.only(top: 12),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(color: color.withValues(alpha: .1), borderRadius: BorderRadius.circular(10)),
      child: Row(children: [
        Icon(syncing ? Icons.sync : connected ? Icons.cloud_done_outlined : Icons.cloud_off_outlined, size: 17, color: color),
        const SizedBox(width: 8),
        Expanded(child: Text('$status · $serverUrl', style: TextStyle(color: color, fontSize: 11), overflow: TextOverflow.ellipsis)),
        if (!connected && !syncing) TextButton(onPressed: onRetry, child: const Text('Sync')),
      ]),
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
    return preferences.getString('server_url') ?? 'http://localhost:3000';
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

  Future<Database> get database async {
    if (_database != null) return _database!;
    final directory = await getApplicationDocumentsDirectory();
    _database = await openDatabase(path.join(directory.path, 'pantry_mobile.db'), version: 2, onCreate: (db, version) async {
      await db.execute('CREATE TABLE items (id INTEGER PRIMARY KEY, shoppingId INTEGER, createdAt TEXT, updatedAt TEXT, deletedAt TEXT, name TEXT, category TEXT, quantity TEXT, date TEXT, icon TEXT, status TEXT)');
      await db.execute('CREATE TABLE shopping (id INTEGER PRIMARY KEY, createdAt TEXT, updatedAt TEXT, deletedAt TEXT, name TEXT, note TEXT, category TEXT, date TEXT, icon TEXT, done INTEGER, who TEXT)');
    }, onUpgrade: (db, oldVersion, newVersion) async {
      if (oldVersion < 2) {
        await db.execute('ALTER TABLE items ADD COLUMN deletedAt TEXT');
        await db.execute('ALTER TABLE shopping ADD COLUMN deletedAt TEXT');
      }
    });
    return _database!;
  }

  Future<PantryData> read() async {
    final db = await database;
    return PantryData(await db.query('items', orderBy: 'id DESC'), await db.query('shopping', orderBy: 'id DESC'));
  }

  Future<void> write(List<Map<String, dynamic>> items, List<Map<String, dynamic>> shopping) async {
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
    final response = await http.put(
      Uri.parse('$baseUrl/api/sync'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'items': local.items, 'shopping': local.shopping}),
    ).timeout(const Duration(seconds: 5));
    if (response.statusCode != 200) throw Exception('Sync failed');
    final payload = jsonDecode(response.body) as Map<String, dynamic>;
    final data = PantryData(List<Map<String, dynamic>>.from((payload['items'] as List).map((item) => Map<String, dynamic>.from(item))), List<Map<String, dynamic>>.from((payload['shopping'] as List).map((item) => Map<String, dynamic>.from(item))));
    await write(data.items, data.shopping);
    return data;
  }
}

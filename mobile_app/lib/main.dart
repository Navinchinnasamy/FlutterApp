import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:http/http.dart' as http;
import 'package:multicast_dns/multicast_dns.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:timezone/data/latest_all.dart' as timezone_data;
import 'package:timezone/timezone.dart' as timezone;

import 'stock_levels.dart';

void main() => runApp(const MyApp());

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  bool _darkMode = false;

  @override
  void initState() {
    super.initState();
    SharedPreferences.getInstance().then((preferences) {
      if (mounted) {
        setState(() => _darkMode = preferences.getBool('dark_mode') ?? false);
      }
    });
  }

  Future<void> _setDarkMode(bool enabled) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setBool('dark_mode', enabled);
    if (mounted) setState(() => _darkMode = enabled);
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Stockd',
      debugShowCheckedModeBanner: false,
      theme: _buildTheme(Brightness.light),
      darkTheme: _buildTheme(Brightness.dark),
      themeMode: _darkMode ? ThemeMode.dark : ThemeMode.light,
      home: PantryHomePage(
        darkMode: _darkMode,
        onDarkModeChanged: _setDarkMode,
      ),
    );
  }

  ThemeData _buildTheme(Brightness brightness) {
    final dark = brightness == Brightness.dark;
    const seedColor = Color(0xff628c6d);
    final colorScheme = ColorScheme.fromSeed(
      seedColor: seedColor,
      brightness: brightness,
    );
    return ThemeData(
      colorScheme: colorScheme,
      scaffoldBackgroundColor: dark
          ? const Color(0xff101612)
          : const Color(0xfff7f8f4),
      fontFamily: 'Avenir',
      appBarTheme: AppBarTheme(
        backgroundColor: dark
            ? const Color(0xff101612)
            : const Color(0xfff7f8f4),
        surfaceTintColor: Colors.transparent,
        elevation: 0,
      ),
      cardTheme: CardThemeData(
        elevation: 1,
        color: dark ? const Color(0xff1b241e) : null,
        margin: const EdgeInsets.symmetric(vertical: 6),
        shape: RoundedRectangleBorder(
          borderRadius: const BorderRadius.all(Radius.circular(18)),
        ),
      ),
      useMaterial3: true,
    );
  }
}

class PantryHomePage extends StatefulWidget {
  const PantryHomePage({
    super.key,
    required this.darkMode,
    required this.onDarkModeChanged,
  });

  final bool darkMode;
  final Future<void> Function(bool) onDarkModeChanged;

  @override
  State<PantryHomePage> createState() => _PantryHomePageState();
}

class _PantryHomePageState extends State<PantryHomePage>
    with WidgetsBindingObserver {
  static const _defaultServerUrl = 'http://192.168.1.24:3000';
  final LocalStore _store = LocalStore();
  final LocalReminderService _reminderService = LocalReminderService();
  late final Future<void> _notificationReady;
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
  bool _expiryRemindersEnabled = false;
  bool _shoppingRemindersEnabled = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _retryTimer = Timer.periodic(
      const Duration(minutes: 5),
      (_) => _retryPendingSync(),
    );
    _notificationReady = _reminderService.initialize();
    _initializeReminderPreferences();
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
      await _refreshReminders();
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
      await _refreshReminders();
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
      await _refreshReminders();
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

  Future<void> _initializeReminderPreferences() async {
    try {
      await _notificationReady;
      final settings = await _store.reminderSettings();
      if (!mounted) return;
      setState(() {
        _expiryRemindersEnabled = settings.expiry;
        _shoppingRemindersEnabled = settings.shopping;
      });
      await _refreshReminders();
    } catch (error) {
      if (mounted) {
        setState(() => _error = 'Could not initialize reminders: $error');
      }
    }
  }

  Future<void> _setReminder(String type, bool enabled) async {
    try {
      await _notificationReady;
      if (enabled && !await _reminderService.requestPermission()) {
        if (mounted) {
          setState(() {
            if (type == 'expiry') {
              _expiryRemindersEnabled = false;
            } else {
              _shoppingRemindersEnabled = false;
            }
          });
          _message(
            'Allow notifications in iPhone Settings to enable reminders.',
          );
        }
        return;
      }
      await _store.setReminderEnabled(type, enabled);
      if (!mounted) return;
      setState(() {
        if (type == 'expiry') {
          _expiryRemindersEnabled = enabled;
        } else {
          _shoppingRemindersEnabled = enabled;
        }
      });
      await _refreshReminders();
      _message(enabled ? 'Reminder enabled' : 'Reminder disabled');
    } catch (error) {
      if (mounted) {
        _message('Could not update reminder: $error');
      }
    }
  }

  Future<void> _refreshReminders() async {
    try {
      await _notificationReady;
      await _reminderService.schedule(
        items: _items,
        shopping: _shopping,
        expiryEnabled: _expiryRemindersEnabled,
        shoppingEnabled: _shoppingRemindersEnabled,
      );
    } catch (error) {
      if (mounted) {
        setState(() => _error = 'Could not refresh reminders: $error');
      }
    }
  }

  Future<void> _changeDarkMode(bool enabled) async {
    try {
      await widget.onDarkModeChanged(enabled);
    } catch (error) {
      _message('Could not update appearance: $error');
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
            SwitchListTile(
              secondary: const Icon(Icons.dark_mode_outlined),
              title: const Text('Dark theme'),
              value: widget.darkMode,
              onChanged: _changeDarkMode,
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
    if (!mounted || _syncing) return;
    setState(() {
      _syncing = true;
      _error = null;
    });
    final client = MDnsClient();
    try {
      await client.start();
      final pointers = <PtrResourceRecord>[];
      final pointerSubscription = client
          .lookup<PtrResourceRecord>(
            ResourceRecordQuery.serverPointer('_pantry._tcp.local'),
          )
          .listen(pointers.add);
      await Future<void>.delayed(const Duration(milliseconds: 700));
      await pointerSubscription.cancel();
      if (pointers.isEmpty) {
        throw TimeoutException('No Stockd Bonjour service was found.');
      }

      String? reachableServer;
      for (final pointer in pointers.take(10)) {
        try {
          final service = await client
              .lookup<SrvResourceRecord>(
                ResourceRecordQuery.service(pointer.domainName),
              )
              .first
              .timeout(const Duration(seconds: 2));
          final addresses = <InternetAddress>{};
          final addressSubscription = client
              .lookup<IPAddressResourceRecord>(
                ResourceRecordQuery.addressIPv4(service.target),
              )
              .listen((record) => addresses.add(record.address));
          await Future<void>.delayed(const Duration(milliseconds: 500));
          await addressSubscription.cancel();

          final candidates =
              addresses.where((address) {
                return _lanAddressPriority(address.address) < 99;
              }).toList()..sort((a, b) {
                return _lanAddressPriority(a.address)
                    .compareTo(_lanAddressPriority(b.address));
              });
          for (final address in candidates) {
            final candidate = 'http://${address.address}:${service.port}';
            try {
              final response = await http
                  .get(Uri.parse('$candidate/api/state'))
                  .timeout(const Duration(seconds: 2));
              if (response.statusCode != 200) continue;
              final payload = jsonDecode(response.body);
              if (payload is Map &&
                  payload['items'] is List &&
                  payload['shopping'] is List) {
                reachableServer = candidate;
                break;
              }
            } on TimeoutException {
              continue;
            } on SocketException {
              continue;
            } on FormatException {
              continue;
            }
          }
        } on TimeoutException {
          continue;
        } on SocketException {
          continue;
        } on FormatException {
          continue;
        }
        if (reachableServer != null) break;
      }

      if (reachableServer == null) {
        throw const SocketException(
          'No Stockd laptop responded at its advertised home-network address.',
        );
      }
      await _store.setServerUrl(reachableServer);
      if (!mounted) return;
      setState(() => _serverUrl = reachableServer!);
      final synced = await _sync();
      if (!silent && synced) _message('Found and synced with Stockd laptop');
      if (!silent && !synced) {
        _message('Found the laptop, but sync failed. Try again.');
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _syncing = false;
          _error = 'Could not find Stockd on this Wi-Fi network: $error';
        });
        if (!silent) _message('Could not find Stockd on this Wi-Fi network.');
      }
    } finally {
      client.stop();
    }
  }

  int _lanAddressPriority(String value) {
    final octets = value.split('.').map(int.tryParse).toList();
    if (octets.length != 4 || octets.any((octet) => octet == null)) return 99;
    final a = octets[0]!;
    final b = octets[1]!;
    final c = octets[2]!;
    if (a == 192 && b == 168) return c == 1 ? 0 : 1;
    if (a == 10) return 2;
    if (a == 172 && b >= 16 && b <= 31) return 3;
    return 99;
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
    if (mounted) _offerAddAnother('shopping');
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
    if (mounted) setState(() {});
    await _store.write(_items, _shopping);
    await _store.markSyncPending();
    if (mounted) setState(() => _syncPending = true);
    await _sync();
    _showUndo(
      '${shoppingItem['name']} added to inventory',
      () => _undoPicked(shoppingItem, id),
    );
  }

  Future<void> _undoPicked(
    Map<String, dynamic> shoppingItem,
    int inventoryId,
  ) async {
    try {
      final data = await _store.read();
      final items = data.items
          .map((item) => Map<String, dynamic>.from(item))
          .toList();
      final shopping = data.shopping
          .map((item) => Map<String, dynamic>.from(item))
          .toList();
      final stamp = DateTime.now().toUtc().toIso8601String();
      final inventoryItem = items.cast<Map<String, dynamic>?>().firstWhere(
        (item) => item?['id'].toString() == inventoryId.toString(),
        orElse: () => null,
      );
      final savedShoppingItem = shopping
          .cast<Map<String, dynamic>?>()
          .firstWhere(
            (item) => item?['id'].toString() == shoppingItem['id'].toString(),
            orElse: () => null,
          );
      if (inventoryItem == null || savedShoppingItem == null) {
        _message('Could not undo purchase because the item has changed.');
        return;
      }
      inventoryItem
        ..['deletedAt'] = stamp
        ..['updatedAt'] = stamp;
      savedShoppingItem
        ..['done'] = 0
        ..['updatedAt'] = stamp;
      await _store.write(items, shopping);
      await _store.markSyncPending();
      if (mounted) {
        setState(() {
          _items = items.where((item) => item['deletedAt'] == null).toList();
          _shopping = shopping
              .where((item) => item['deletedAt'] == null)
              .toList();
          _syncPending = true;
        });
      }
      await _sync();
    } catch (error) {
      _message('Could not undo purchase: $error');
    }
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
        'minimumQuantity': double.tryParse(draft['minimumQuantity'] ?? ''),
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
    if (mounted) _offerAddAnother('inventory');
  }

  void _offerAddAnother(String type) {
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          content: Text(
            type == 'inventory'
                ? 'Item added to inventory'
                : 'Added to shopping list',
          ),
          action: SnackBarAction(
            label: 'Add another',
            onPressed: type == 'inventory'
                ? _addInventoryItem
                : _addShoppingItem,
          ),
        ),
      );
  }

  Future<void> _deleteInventoryItem(Map<String, dynamic> item) async {
    if (!await _confirmDelete(item['name'] as String? ?? 'this item')) return;
    await _softDeleteItem('items', item);
  }

  Future<void> _deleteShoppingItem(Map<String, dynamic> item) async {
    if (!await _confirmDelete(item['name'] as String? ?? 'this item')) return;
    await _softDeleteItem('shopping', item);
  }

  Future<void> _swipeDeleteInventory(Map<String, dynamic> item) async {
    await _softDeleteItem('items', item);
  }

  Future<void> _swipeDeleteShopping(Map<String, dynamic> item) async {
    await _softDeleteItem('shopping', item);
  }

  Future<void> _softDeleteItem(String table, Map<String, dynamic> item) async {
    if (mounted) {
      setState(() {
        if (table == 'items') {
          _items.removeWhere(
            (entry) => entry['id'].toString() == item['id'].toString(),
          );
        } else {
          _shopping.removeWhere(
            (entry) => entry['id'].toString() == item['id'].toString(),
          );
        }
      });
    }
    try {
      await _store.softDelete(table, item['id']);
      await _store.markSyncPending();
      if (mounted) {
        setState(() => _syncPending = true);
      }
      await _sync();
      _showUndo(
        '${item['name']} removed',
        () => _undoDelete(table, item['id']),
      );
    } catch (error) {
      await _load();
      _message('Could not remove item: $error');
    }
  }

  Future<void> _undoDelete(String table, dynamic id) async {
    try {
      final data = await _store.read();
      final items = data.items
          .map((item) => Map<String, dynamic>.from(item))
          .toList();
      final shopping = data.shopping
          .map((item) => Map<String, dynamic>.from(item))
          .toList();
      final rows = table == 'items' ? items : shopping;
      final item = rows.cast<Map<String, dynamic>?>().firstWhere(
        (entry) => entry?['id'].toString() == id.toString(),
        orElse: () => null,
      );
      if (item == null) {
        _message('Could not undo because the item is no longer available.');
        return;
      }
      item
        ..['deletedAt'] = null
        ..['updatedAt'] = DateTime.now().toUtc().toIso8601String();
      await _store.write(items, shopping);
      await _store.markSyncPending();
      if (mounted) {
        setState(() {
          _items = items.where((entry) => entry['deletedAt'] == null).toList();
          _shopping = shopping
              .where((entry) => entry['deletedAt'] == null)
              .toList();
          _syncPending = true;
        });
      }
      await _sync();
    } catch (error) {
      _message('Could not undo removal: $error');
    }
  }

  void _showUndo(String message, VoidCallback onUndo) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          duration: const Duration(seconds: 6),
          action: SnackBarAction(label: 'Undo', onPressed: onUndo),
        ),
      );
  }

  Widget _swipeBackground({
    required Color color,
    required IconData icon,
    required Alignment alignment,
  }) {
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 6),
      padding: const EdgeInsets.symmetric(horizontal: 22),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(18),
      ),
      alignment: alignment,
      child: Icon(icon, color: Colors.white),
    );
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
    final minimumController = TextEditingController(
      text: item['minimumQuantity']?.toString() ?? '',
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
                TextField(
                  controller: minimumController,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  inputFormatters: [
                    FilteringTextInputFormatter.allow(RegExp(r'^\d*\.?\d*')),
                  ],
                  decoration: const InputDecoration(
                    labelText: 'Restock when at or below (optional)',
                    helperText: 'Use the same unit as the quantity',
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
      ..['minimumQuantity'] = double.tryParse(minimumController.text)
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

    return showModalBottomSheet<Map<String, String>>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => SafeArea(
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              24,
              8,
              24,
              MediaQuery.viewInsetsOf(context).bottom + 20,
            ),
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'Add to shopping list',
                    style: Theme.of(context).textTheme.headlineSmall
                        ?.copyWith(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 18),
                  TextField(
                    controller: nameController,
                    autofocus: true,
                    decoration: const InputDecoration(
                      labelText: 'Item name',
                      hintText: 'e.g. Milk',
                      prefixIcon: Icon(Icons.shopping_basket_outlined),
                    ),
                  ),
                  TextField(
                    controller: quantityController,
                    decoration: const InputDecoration(
                      labelText: 'Quantity (optional)',
                      hintText: 'e.g. 2 bottles',
                      prefixIcon: Icon(Icons.scale_outlined),
                    ),
                  ),
                  DropdownButtonFormField<String>(
                    initialValue: category,
                    decoration: const InputDecoration(labelText: 'Category'),
                    items:
                        const [
                              'Produce',
                              'Dairy',
                              'Pantry',
                              'Freezer',
                              'Drinks',
                            ]
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
                          (value) => DropdownMenuItem(
                            value: value,
                            child: Text(value),
                          ),
                        )
                        .toList(),
                    onChanged: (value) =>
                        setDialogState(() => who = value ?? _memberName),
                  ),
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
                        if (picked != null) {
                          setDialogState(() => bestBefore = picked);
                        }
                      },
                      icon: const Icon(Icons.calendar_today_outlined, size: 17),
                      label: Text(
                        'Best before: ${bestBefore.year}-${bestBefore.month.toString().padLeft(2, '0')}-${bestBefore.day.toString().padLeft(2, '0')}',
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  FilledButton.icon(
                    onPressed: () => Navigator.pop(context, {
                      'name': nameController.text.trim(),
                      'quantity': quantityController.text.trim(),
                      'category': category,
                      'who': who,
                      'date':
                          '${bestBefore.year}-${bestBefore.month.toString().padLeft(2, '0')}-${bestBefore.day.toString().padLeft(2, '0')}',
                    }),
                    icon: const Icon(Icons.add),
                    label: const Text('Add to list'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<Map<String, String>?> _askForInventoryItem() async {
    final nameController = TextEditingController();
    final quantityController = TextEditingController();
    final minimumController = TextEditingController();
    String category = 'Pantry';
    String status = 'ok';
    DateTime bestBefore = DateTime.now().add(const Duration(days: 7));

    return showModalBottomSheet<Map<String, String>>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => SafeArea(
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              24,
              8,
              24,
              MediaQuery.viewInsetsOf(context).bottom + 20,
            ),
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'Add inventory item',
                    style: Theme.of(context).textTheme.headlineSmall
                        ?.copyWith(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 18),
                  TextField(
                    controller: nameController,
                    autofocus: true,
                    decoration: const InputDecoration(
                      labelText: 'Item name',
                      hintText: 'e.g. Rice',
                      prefixIcon: Icon(Icons.inventory_2_outlined),
                    ),
                  ),
                  TextField(
                    controller: quantityController,
                    decoration: const InputDecoration(
                      labelText: 'Quantity (optional)',
                      hintText: 'e.g. 2 kg',
                      prefixIcon: Icon(Icons.scale_outlined),
                    ),
                  ),
                  TextField(
                    controller: minimumController,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    inputFormatters: [
                      FilteringTextInputFormatter.allow(RegExp(r'^\d*\.?\d*')),
                    ],
                    decoration: const InputDecoration(
                      labelText: 'Restock threshold (optional)',
                      hintText: 'e.g. 2',
                      helperText: 'Same unit as quantity. Flag low at or below this level.',
                      prefixIcon: Icon(Icons.low_priority),
                    ),
                  ),
                  DropdownButtonFormField<String>(
                    initialValue: category,
                    decoration: const InputDecoration(labelText: 'Category'),
                    items:
                        const [
                              'Produce',
                              'Dairy',
                              'Pantry',
                              'Freezer',
                              'Drinks',
                            ]
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
                    decoration: const InputDecoration(
                      labelText: 'Stock status',
                    ),
                    items: const [
                      DropdownMenuItem(value: 'ok', child: Text('In stock')),
                      DropdownMenuItem(
                        value: 'low',
                        child: Text('Running low'),
                      ),
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
                        lastDate: DateTime.now().add(
                          const Duration(days: 3650),
                        ),
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
                  const SizedBox(height: 12),
                  FilledButton.icon(
                    onPressed: () => Navigator.pop(context, {
                      'name': nameController.text.trim(),
                      'quantity': quantityController.text.trim(),
                      'minimumQuantity': minimumController.text.trim(),
                      'category': category,
                      'status': status,
                      'date':
                          '${bestBefore.year}-${bestBefore.month.toString().padLeft(2, '0')}-${bestBefore.day.toString().padLeft(2, '0')}',
                    }),
                    icon: const Icon(Icons.add),
                    label: const Text('Add to inventory'),
                  ),
                ],
              ),
            ),
          ),
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
      if (item['minimumQuantity'] is num)
        'Restock at or below ${item['minimumQuantity']}',
      if ((item['date'] as String? ?? '').trim().isNotEmpty)
        'Best before ${item['date']}',
    ];
    return details.isEmpty
        ? 'No quantity or best-before date'
        : details.join(' · ');
  }

  bool _isLowStock(Map<String, dynamic> item) {
    return isAtOrBelowMinimum(item);
  }

  Future<void> _addRestockToShopping(Map<String, dynamic> item) async {
    final name = item['name'] as String? ?? 'Item';
    final existing = _shopping.where(
      (entry) =>
          entry['deletedAt'] == null &&
          entry['done'] != 1 &&
          entry['done'] != true &&
          (entry['name'] as String? ?? '').toLowerCase() == name.toLowerCase(),
    );
    if (existing.isNotEmpty) {
      _message('$name is already on the shopping list');
      if (mounted) setState(() => _selectedSection = 2);
      return;
    }
    final stamp = DateTime.now().toUtc().toIso8601String();
    final minimum = item['minimumQuantity'];
    final restockItem = {
      'id': DateTime.now().millisecondsSinceEpoch,
      'name': name,
      'note': minimum == null ? 'Restock' : 'Restock to $minimum',
      'category': item['category'] ?? 'Pantry',
      'date': item['date'] ?? '',
      'icon': item['icon'] ?? '🛒',
      'done': 0,
      'who': _memberName,
      'createdAt': stamp,
      'updatedAt': stamp,
    };
    _shopping = [restockItem, ..._shopping];
    try {
      await _store.write(_items, _shopping);
      await _store.markSyncPending();
      if (mounted) {
        setState(() {
          _selectedSection = 2;
          _syncPending = true;
        });
      }
      final synced = await _sync();
      if (!synced && mounted) {
        _message(
          '$name added locally; it will sync when the laptop is reachable',
        );
      }
    } catch (error) {
      _shopping.removeWhere(
        (entry) => entry['id'].toString() == restockItem['id'].toString(),
      );
      if (mounted) {
        _message('Could not add $name to shopping list: $error');
      }
    }
  }

  String _shoppingSubtitle(Map<String, dynamic> item) {
    final details = <String>[
      if ((item['note'] as String? ?? '').trim().isNotEmpty)
        (item['note'] as String).trim(),
      if ((item['date'] as String? ?? '').trim().isNotEmpty)
        'Best before ${item['date']}',
    ];
    return details.isEmpty
        ? 'No quantity or best-before date'
        : details.join(' · ');
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

  IconData _categoryIcon(String? category) {
    switch (category) {
      case 'Produce':
        return Icons.eco_outlined;
      case 'Dairy':
        return Icons.water_drop_outlined;
      case 'Freezer':
        return Icons.ac_unit;
      case 'Drinks':
        return Icons.local_drink_outlined;
      case 'Pantry':
        return Icons.inventory_2_outlined;
      default:
        return Icons.kitchen_outlined;
    }
  }

  Widget _itemBadge(String label, {Color? foreground, Color? background}) {
    final color = foreground ?? const Color(0xff628c6d);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(
        color: background ?? color.withValues(alpha: .11),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 11,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
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
      return _isLowStock(item) ||
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
        _selectedSection != 1 ||
        _selectedStatus == 'All' ||
        (_selectedStatus == 'low'
            ? _isLowStock(item)
            : item['status'] == _selectedStatus);
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
          final leftRank = _isLowStock(left) ? 0 : (rank[left['status']] ?? 3);
          final rightRank = _isLowStock(right)
              ? 0
              : (rank[right['status']] ?? 3);
          return leftRank.compareTo(rightRank);
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
          ? _StockdSkeleton(section: _selectedSection)
          : AnimatedSwitcher(
              duration: const Duration(milliseconds: 260),
              switchInCurve: Curves.easeOutCubic,
              switchOutCurve: Curves.easeInCubic,
              child: RefreshIndicator(
                key: ValueKey(_selectedSection),
                onRefresh: _load,
                child: ListView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.fromLTRB(18, 18, 18, 36),
                  children: [
                    if (_error != null)
                      Card(
                        color: Theme.of(context).colorScheme.tertiaryContainer,
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Text(_error!),
                        ),
                      ),
                    if (_selectedSection == 0) ...[
                      Text(
                        '${_greeting()}, $_memberName',
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
                          style: const TextStyle(
                            color: Colors.grey,
                            fontSize: 11,
                          ),
                        ),
                      const SizedBox(height: 18),
                      Row(
                        children: [
                          _StatCard(
                            label: 'Inventory',
                            value: '${_items.length}',
                            icon: Icons.inventory_2_outlined,
                            onTap: () => setState(() {
                              _selectedSection = 1;
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
                              _selectedSection = 2;
                              _shoppingFilter = 'To buy';
                            }),
                          ),
                        ],
                      ),
                      if (_attentionItems().isNotEmpty) ...[
                        const SizedBox(height: 18),
                        Card(
                          color: Theme.of(context)
                              .colorScheme
                              .tertiaryContainer,
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
                                      style: Theme.of(context)
                                          .textTheme
                                          .titleMedium
                                          ?.copyWith(
                                            fontWeight: FontWeight.bold,
                                          ),
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
                                      style: const TextStyle(
                                        color: Colors.grey,
                                      ),
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
                    ],
                    if (_selectedSection == 1 || _selectedSection == 2) ...[
                      const SizedBox(height: 22),
                      TextField(
                        onChanged: (value) =>
                            setState(() => _searchQuery = value),
                        decoration: InputDecoration(
                          hintText: _selectedSection == 1
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
                          fillColor: Theme.of(context)
                              .colorScheme
                              .surfaceContainerLow,
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(14),
                            borderSide: BorderSide.none,
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),
                      SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: Row(
                          children: categories.map((category) {
                            final selected = _selectedCategory == category;
                            return Padding(
                              padding: const EdgeInsets.only(right: 8),
                              child: FilterChip(
                                label: Text(category),
                                avatar: Icon(
                                  category == 'All'
                                      ? Icons.apps
                                      : _categoryIcon(category),
                                  size: 17,
                                ),
                                selected: selected,
                                onSelected: (_) => setState(
                                  () => _selectedCategory = category,
                                ),
                              ),
                            );
                          }).toList(),
                        ),
                      ),
                      const SizedBox(height: 16),
                    ],
                    if (_selectedSection == 1) ...[
                      SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: Row(
                          children:
                              const [
                                ('All', 'All'),
                                ('ok', 'In stock'),
                                ('low', 'Running low'),
                                ('soon', 'Use soon'),
                              ].map((entry) {
                                final (value, label) = entry;
                                final selected = _selectedStatus == value;
                                final color = switch (value) {
                                  'low' => Colors.deepOrange,
                                  'soon' => Colors.deepPurple,
                                  'ok' => Colors.green,
                                  _ => Colors.blueGrey,
                                };
                                return Padding(
                                  padding: const EdgeInsets.only(right: 8),
                                  child: FilterChip(
                                    label: Text(label),
                                    selected: selected,
                                    onSelected: (_) =>
                                        setState(() => _selectedStatus = value),
                                    selectedColor: color.withValues(alpha: .16),
                                  ),
                                );
                              }).toList(),
                        ),
                      ),
                      const SizedBox(height: 16),
                    ],
                    if (_selectedSection == 1) ...[
                      DropdownButtonFormField<String>(
                        initialValue: _inventorySort,
                        decoration: InputDecoration(
                          labelText: 'Sort inventory',
                          prefixIcon: const Icon(Icons.sort),
                          filled: true,
                          fillColor: Theme.of(context)
                              .colorScheme
                              .surfaceContainerLow,
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
                        _EmptyState(
                          icon: _items.isEmpty
                              ? Icons.kitchen_outlined
                              : Icons.search_off_outlined,
                          title: _items.isEmpty
                              ? 'Your pantry starts here'
                              : 'No matching groceries',
                          message: _items.isEmpty
                              ? 'Add the groceries you have at home to keep your family in sync.'
                              : 'Try another search or clear your filters to see all inventory.',
                          actionLabel: _items.isEmpty
                              ? 'Add first item'
                              : 'Clear filters',
                          onAction: _items.isEmpty
                              ? _addInventoryItem
                              : () => setState(() {
                                  _searchQuery = '';
                                  _selectedCategory = 'All';
                                  _selectedStatus = 'All';
                                }),
                        )
                      else
                        ...visibleItems.map(
                          (item) => Dismissible(
                            key: ValueKey('inventory-${item['id']}'),
                            direction: DismissDirection.endToStart,
                            confirmDismiss: (_) => _confirmDelete(
                              item['name'] as String? ?? 'this item',
                            ),
                            onDismissed: (_) => _swipeDeleteInventory(item),
                            background: _swipeBackground(
                              color: Colors.red.shade600,
                              icon: Icons.delete_outline,
                              alignment: Alignment.centerRight,
                            ),
                            child: Card(
                              child: ListTile(
                                leading: CircleAvatar(
                                  backgroundColor: Theme.of(context)
                                      .colorScheme
                                      .primaryContainer,
                                  child: Icon(
                                    _categoryIcon(item['category'] as String?),
                                    color: Theme.of(context)
                                        .colorScheme
                                        .primary,
                                  ),
                                ),
                                title: Text(item['name'] as String? ?? ''),
                                subtitle: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(_inventorySubtitle(item)),
                                    const SizedBox(height: 7),
                                    Wrap(
                                      spacing: 6,
                                      runSpacing: 5,
                                      children: [
                                        _itemBadge(
                                          item['category'] as String? ??
                                              'Pantry',
                                        ),
                                        _itemBadge(
                                          _statusLabel(
                                            _isLowStock(item)
                                                ? 'low'
                                                : item['status'] as String?,
                                          ),
                                          foreground: _isLowStock(item)
                                              ? Colors.deepOrange
                                              : item['status'] == 'soon'
                                              ? Colors.deepPurple
                                              : const Color(0xff628c6d),
                                        ),
                                        if (_expiryLabel(
                                              item['date'] as String?,
                                            ) !=
                                            null)
                                          _itemBadge(
                                            _expiryLabel(
                                              item['date'] as String?,
                                            )!,
                                            foreground: _expiryColor(
                                              item['date'] as String?,
                                            ),
                                          ),
                                      ],
                                    ),
                                    if (_isLowStock(item)) ...[
                                      const SizedBox(height: 4),
                                      Align(
                                        alignment: Alignment.centerLeft,
                                        child: TextButton.icon(
                                          onPressed: () =>
                                              _addRestockToShopping(item),
                                          icon: const Icon(
                                            Icons.add_shopping_cart,
                                            size: 17,
                                          ),
                                          label: const Text(
                                            'Add to shopping list',
                                          ),
                                        ),
                                      ),
                                    ],
                                  ],
                                ),
                                trailing: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    IconButton(
                                      onPressed: () => _editInventoryItem(item),
                                      icon: const Icon(Icons.edit_outlined),
                                    ),
                                    IconButton(
                                      onPressed: () =>
                                          _deleteInventoryItem(item),
                                      icon: const Icon(Icons.delete_outline),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                    ] else if (_selectedSection == 2) ...[
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
                        _EmptyState(
                          icon: _shopping.isEmpty
                              ? Icons.shopping_basket_outlined
                              : _searchQuery.isNotEmpty ||
                                    _selectedCategory != 'All'
                              ? Icons.search_off_outlined
                              : Icons.check_circle_outline,
                          title: _shopping.isEmpty
                              ? 'Your list is ready'
                              : _searchQuery.isNotEmpty ||
                                    _selectedCategory != 'All'
                              ? 'No matching items'
                              : _shoppingFilter == 'Completed'
                              ? 'Nothing completed yet'
                              : 'All caught up',
                          message: _shopping.isEmpty
                              ? 'Add groceries your family needs, then check them off as you shop.'
                              : _searchQuery.isNotEmpty ||
                                    _selectedCategory != 'All'
                              ? 'Try a different search or clear your filters.'
                              : _shoppingFilter == 'Completed'
                              ? 'Items you pick up will appear here.'
                              : 'There are no items left to buy. Nice work!',
                          actionLabel: _shopping.isEmpty
                              ? 'Add to shopping list'
                              : _searchQuery.isNotEmpty ||
                                    _selectedCategory != 'All'
                              ? 'Clear filters'
                              : _shoppingFilter == 'Completed'
                              ? 'View items to buy'
                              : 'View completed',
                          onAction: _shopping.isEmpty
                              ? _addShoppingItem
                              : _searchQuery.isNotEmpty ||
                                    _selectedCategory != 'All'
                              ? () => setState(() {
                                  _searchQuery = '';
                                  _selectedCategory = 'All';
                                  _shoppingFilter = 'To buy';
                                })
                              : () => setState(
                                  () => _shoppingFilter =
                                      _shoppingFilter == 'Completed'
                                      ? 'To buy'
                                      : 'Completed',
                                ),
                        ),
                      ...visibleShopping.map((item) {
                        final done = item['done'] == 1 || item['done'] == true;
                        return Dismissible(
                          key: ValueKey('shopping-${item['id']}'),
                          direction: done
                              ? DismissDirection.endToStart
                              : DismissDirection.horizontal,
                          confirmDismiss: (direction) async {
                            if (direction == DismissDirection.startToEnd &&
                                !done) {
                              return true;
                            }
                            return _confirmDelete(
                              item['name'] as String? ?? 'this item',
                            );
                          },
                          onDismissed: (direction) {
                            if (direction == DismissDirection.startToEnd &&
                                !done) {
                              _markPicked(item);
                            } else {
                              _swipeDeleteShopping(item);
                            }
                          },
                          background: _swipeBackground(
                            color: const Color(0xff628c6d),
                            icon: Icons.check,
                            alignment: Alignment.centerLeft,
                          ),
                          secondaryBackground: _swipeBackground(
                            color: Colors.red.shade600,
                            icon: Icons.delete_outline,
                            alignment: Alignment.centerRight,
                          ),
                          child: Card(
                            color: done
                                ? Theme.of(context)
                                      .colorScheme
                                      .surfaceContainerHighest
                                : null,
                            child: ListTile(
                              leading: Checkbox(
                                value: done,
                                onChanged: done
                                    ? null
                                    : (_) => _markPicked(item),
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
                              subtitle: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(_shoppingSubtitle(item)),
                                  const SizedBox(height: 7),
                                  Wrap(
                                    spacing: 6,
                                    runSpacing: 5,
                                    children: [
                                      _itemBadge(
                                        item['category'] as String? ?? 'Pantry',
                                      ),
                                      _itemBadge(
                                        'By ${item['who'] ?? 'Unknown'}',
                                        foreground: Colors.blueGrey,
                                      ),
                                      if (done)
                                        _itemBadge(
                                          'Picked up',
                                          foreground: const Color(0xff628c6d),
                                        ),
                                    ],
                                  ),
                                ],
                              ),
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
                          ),
                        );
                      }),
                    ],
                    if (_selectedSection == 3) ...[
                      Text(
                        'Settings',
                        style: Theme.of(context).textTheme.headlineSmall
                            ?.copyWith(fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        'Manage Stockd on this device.',
                        style: TextStyle(color: Colors.grey),
                      ),
                      const SizedBox(height: 12),
                      Card(
                        child: Column(
                          children: [
                            ListTile(
                              leading: const Icon(Icons.laptop_mac_outlined),
                              title: const Text('Laptop connection'),
                              subtitle: Text(_serverUrl),
                              onTap: _configureLaptop,
                            ),
                            ListTile(
                              leading: const Icon(Icons.wifi_find),
                              title: const Text('Find laptop on Wi-Fi'),
                              onTap: _syncing ? null : _discoverLaptop,
                            ),
                            ListTile(
                              leading: const Icon(Icons.person_outline),
                              title: const Text('Family member'),
                              subtitle: Text(_memberName),
                              onTap: _configureMember,
                            ),
                            SwitchListTile(
                              secondary: const Icon(Icons.dark_mode_outlined),
                              title: const Text('Dark theme'),
                              subtitle: const Text(
                                'Use a darker appearance on this device',
                              ),
                              value: widget.darkMode,
                              onChanged: _changeDarkMode,
                            ),
                            SwitchListTile(
                              secondary: const Icon(Icons.event_busy_outlined),
                              title: const Text('Expiry reminders'),
                              subtitle: const Text(
                                'A reminder the day before an item expires',
                              ),
                              value: _expiryRemindersEnabled,
                              onChanged: (value) =>
                                  _setReminder('expiry', value),
                            ),
                            SwitchListTile(
                              secondary: const Icon(
                                Icons.shopping_basket_outlined,
                              ),
                              title: const Text('Shopping reminder'),
                              subtitle: const Text(
                                'A daily reminder when items are still to buy',
                              ),
                              value: _shoppingRemindersEnabled,
                              onChanged: (value) =>
                                  _setReminder('shopping', value),
                            ),
                            ListTile(
                              leading: const Icon(Icons.sync),
                              title: const Text('Sync now'),
                              subtitle: Text(
                                _syncPending
                                    ? 'Changes waiting to sync'
                                    : 'Last synced ${_formatTimestamp(_lastSyncedAt)}',
                              ),
                              onTap: _syncing ? null : _sync,
                            ),
                            ListTile(
                              leading: const Icon(Icons.download_outlined),
                              title: const Text('Export local backup'),
                              onTap: _exportBackup,
                            ),
                            ListTile(
                              leading: const Icon(Icons.upload_file_outlined),
                              title: const Text('Import local backup'),
                              onTap: _importBackup,
                            ),
                          ],
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _selectedSection,
        onDestinationSelected: (index) {
          HapticFeedback.selectionClick();
          setState(() {
            _selectedSection = index;
            _searchQuery = '';
            _selectedCategory = 'All';
            _selectedStatus = 'All';
            _shoppingFilter = 'To buy';
            _inventorySort = 'Recently updated';
          });
        },
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.dashboard_outlined),
            selectedIcon: Icon(Icons.dashboard),
            label: 'Home',
          ),
          NavigationDestination(
            icon: Icon(Icons.inventory_2_outlined),
            selectedIcon: Icon(Icons.inventory_2),
            label: 'Inventory',
          ),
          NavigationDestination(
            icon: Icon(Icons.shopping_cart_outlined),
            selectedIcon: Icon(Icons.shopping_cart),
            label: 'Shopping',
          ),
          NavigationDestination(
            icon: Icon(Icons.settings_outlined),
            selectedIcon: Icon(Icons.settings),
            label: 'Settings',
          ),
        ],
      ),
      floatingActionButton: _selectedSection == 1 || _selectedSection == 2
          ? FloatingActionButton.extended(
              onPressed: _selectedSection == 1
                  ? _addInventoryItem
                  : _addShoppingItem,
              icon: const Icon(Icons.add),
              label: Text(_selectedSection == 1 ? 'Add item' : 'Add to list'),
            )
          : null,
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
        onTap: () {
          HapticFeedback.selectionClick();
          onTap();
        },
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              CircleAvatar(
                backgroundColor: Theme.of(context).colorScheme.primaryContainer,
                child: Icon(icon, color: Theme.of(context).colorScheme.primary),
              ),
              const SizedBox(width: 10),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                      fontSize: 12,
                    ),
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

class _EmptyState extends StatelessWidget {
  const _EmptyState({
    required this.icon,
    required this.title,
    required this.message,
    required this.actionLabel,
    required this.onAction,
  });

  final IconData icon;
  final String title;
  final String message;
  final String actionLabel;
  final VoidCallback onAction;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 30),
        child: Column(
          children: [
            CircleAvatar(
              radius: 30,
              backgroundColor: colors.primaryContainer,
              child: Icon(icon, size: 29, color: colors.primary),
            ),
            const SizedBox(height: 14),
            Text(
              title,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleMedium
                  ?.copyWith(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 6),
            Text(
              message,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium
                  ?.copyWith(color: colors.onSurfaceVariant),
            ),
            const SizedBox(height: 16),
            FilledButton.tonal(onPressed: onAction, child: Text(actionLabel)),
          ],
        ),
      ),
    );
  }
}

class _StockdSkeleton extends StatefulWidget {
  const _StockdSkeleton({required this.section});

  final int section;

  @override
  State<_StockdSkeleton> createState() => _StockdSkeletonState();
}

class _StockdSkeletonState extends State<_StockdSkeleton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _animation = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _animation.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return AnimatedBuilder(
      animation: _animation,
      builder: (context, child) {
        final skeletonColor = Color.lerp(
          colorScheme.surfaceContainerHighest,
          colorScheme.surfaceContainerLow,
          _animation.value,
        )!;
        return ListView(
          physics: const NeverScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(18, 16, 18, 36),
          children: [
            Row(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: Image.asset(
                    'lib/assets/Stockd-logo.png',
                    width: 44,
                    height: 44,
                    fit: BoxFit.cover,
                  ),
                ),
                const SizedBox(width: 12),
                Text(
                  'Stockd',
                  style: Theme.of(context).textTheme.titleLarge
                      ?.copyWith(fontWeight: FontWeight.bold),
                ),
              ],
            ),
            const SizedBox(height: 24),
            if (widget.section == 0) ...[
              _SkeletonBar(color: skeletonColor, width: 210, height: 30),
              const SizedBox(height: 10),
              _SkeletonBar(color: skeletonColor, width: 150, height: 16),
              const SizedBox(height: 18),
              _SkeletonBar(color: skeletonColor, height: 38),
              const SizedBox(height: 18),
              Row(
                children: [
                  Expanded(
                    child: _SkeletonCard(color: skeletonColor, height: 90),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _SkeletonCard(color: skeletonColor, height: 90),
                  ),
                ],
              ),
              const SizedBox(height: 22),
              _SkeletonBar(color: skeletonColor, width: 165, height: 22),
              const SizedBox(height: 10),
              ...List.generate(
                3,
                (_) => _SkeletonCard(color: skeletonColor, height: 76),
              ),
            ] else if (widget.section == 1 || widget.section == 2) ...[
              _SkeletonBar(color: skeletonColor, height: 50),
              const SizedBox(height: 16),
              Row(
                children: List.generate(
                  3,
                  (index) => Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: _SkeletonBar(
                      color: skeletonColor,
                      width: index == 0 ? 62 : 82,
                      height: 34,
                      radius: 20,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 18),
              ...List.generate(
                5,
                (_) => _SkeletonCard(color: skeletonColor, height: 94),
              ),
            ] else ...[
              _SkeletonBar(color: skeletonColor, width: 135, height: 28),
              const SizedBox(height: 14),
              _SkeletonCard(color: skeletonColor, height: 310),
            ],
          ],
        );
      },
    );
  }
}

class _SkeletonCard extends StatelessWidget {
  const _SkeletonCard({required this.color, required this.height});

  final Color color;
  final double height;

  @override
  Widget build(BuildContext context) => Card(
    child: SizedBox(
      height: height,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          children: [
            _SkeletonBar(color: color, width: 42, height: 42, radius: 14),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _SkeletonBar(color: color, width: 150, height: 14),
                  const SizedBox(height: 9),
                  _SkeletonBar(color: color, width: 205, height: 11),
                ],
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

class _SkeletonBar extends StatelessWidget {
  const _SkeletonBar({
    required this.color,
    this.width = double.infinity,
    required this.height,
    this.radius = 8,
  });

  final Color color;
  final double width;
  final double height;
  final double radius;

  @override
  Widget build(BuildContext context) => Container(
    width: width,
    height: height,
    decoration: BoxDecoration(
      color: color,
      borderRadius: BorderRadius.circular(radius),
    ),
  );
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

class LocalReminderService {
  static const _shoppingReminderId = 1;
  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  Future<void> initialize() async {
    timezone_data.initializeTimeZones();
    final localTimezone = await FlutterTimezone.getLocalTimezone();
    timezone.setLocalLocation(timezone.getLocation(localTimezone.identifier));
    await _plugin.initialize(
      settings: const InitializationSettings(
        iOS: DarwinInitializationSettings(
          requestAlertPermission: false,
          requestBadgePermission: false,
          requestSoundPermission: false,
        ),
      ),
    );
  }

  Future<bool> requestPermission() async {
    final result = await _plugin
        .resolvePlatformSpecificImplementation<
          IOSFlutterLocalNotificationsPlugin
        >()
        ?.requestPermissions(alert: true, sound: true);
    return result ?? false;
  }

  Future<void> schedule({
    required List<Map<String, dynamic>> items,
    required List<Map<String, dynamic>> shopping,
    required bool expiryEnabled,
    required bool shoppingEnabled,
  }) async {
    await _plugin.cancelAll();
    final now = timezone.TZDateTime.now(timezone.local);
    final details = const NotificationDetails(
      iOS: DarwinNotificationDetails(
        presentAlert: true,
        presentBadge: false,
        presentSound: true,
      ),
    );

    if (expiryEnabled) {
      final datedItems =
          items
              .where((item) => (item['date'] as String? ?? '').isNotEmpty)
              .toList()
            ..sort(
              (a, b) => (a['date'] as String).compareTo(b['date'] as String),
            );
      for (final item in datedItems.take(50)) {
        final parsed = DateTime.tryParse(item['date'] as String);
        if (parsed == null) continue;
        final due = timezone.TZDateTime(
          timezone.local,
          parsed.year,
          parsed.month,
          parsed.day,
          23,
          59,
        );
        if (!due.isAfter(now)) continue;
        var scheduled = timezone.TZDateTime(
          timezone.local,
          parsed.year,
          parsed.month,
          parsed.day - 1,
          9,
        );
        if (!scheduled.isAfter(now)) {
          scheduled = now.add(const Duration(minutes: 1));
        }
        final itemName = item['name'] as String? ?? 'A grocery item';
        final id = 100 + (item['id'].toString().hashCode & 0x3fffffff);
        await _plugin.zonedSchedule(
          id: id,
          title: 'Use $itemName soon',
          body: 'Best before ${item['date']}. Check your Stockd inventory.',
          scheduledDate: scheduled,
          notificationDetails: details,
          androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
        );
      }
    }

    final hasItemsToBuy = shopping.any(
      (item) => item['done'] != 1 && item['done'] != true,
    );
    if (shoppingEnabled && hasItemsToBuy) {
      var scheduled = timezone.TZDateTime(
        timezone.local,
        now.year,
        now.month,
        now.day,
        17,
      );
      if (!scheduled.isAfter(now)) {
        scheduled = timezone.TZDateTime(
          timezone.local,
          now.year,
          now.month,
          now.day + 1,
          17,
        );
      }
      await _plugin.zonedSchedule(
        id: _shoppingReminderId,
        title: 'Stockd shopping reminder',
        body: 'Your shopping list still has items to buy.',
        scheduledDate: scheduled,
        notificationDetails: details,
        androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
        matchDateTimeComponents: DateTimeComponents.time,
      );
    }
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

  Future<({bool expiry, bool shopping})> reminderSettings() async {
    final preferences = await SharedPreferences.getInstance();
    return (
      expiry: preferences.getBool('expiry_reminders') ?? false,
      shopping: preferences.getBool('shopping_reminders') ?? false,
    );
  }

  Future<void> setReminderEnabled(String type, bool enabled) async {
    final key = switch (type) {
      'expiry' => 'expiry_reminders',
      'shopping' => 'shopping_reminders',
      _ => throw ArgumentError.value(type, 'type', 'Unknown reminder type'),
    };
    final preferences = await SharedPreferences.getInstance();
    await preferences.setBool(key, enabled);
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
      version: 3,
      onCreate: (db, version) async {
        await db.execute(
          'CREATE TABLE items (id INTEGER PRIMARY KEY, shoppingId INTEGER, createdAt TEXT, updatedAt TEXT, deletedAt TEXT, name TEXT, category TEXT, quantity TEXT, minimumQuantity REAL, date TEXT, icon TEXT, status TEXT)',
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
        if (oldVersion < 3) {
          await db.execute('ALTER TABLE items ADD COLUMN minimumQuantity REAL');
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

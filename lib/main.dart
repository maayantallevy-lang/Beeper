import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data'; 
import 'package:flutter/services.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:timezone/data/latest_all.dart' as tz;
import 'package:timezone/timezone.dart' as tz;
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:uuid/uuid.dart';

// -----------------------------------------------------------------------------
// GLOBAL OBJECTS
// -----------------------------------------------------------------------------

final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin =
    FlutterLocalNotificationsPlugin();

const String baseChannelId = 'critical_alert_channel_prod';
const String baseChannelName = 'התראות חירום';
const String channelDesc = 'ערוץ להודעות דחופות עם עקיפת שקט';

const MethodChannel platformChannel = MethodChannel('com.example.alerts/ringtone');

// -----------------------------------------------------------------------------
// LOGGING SYSTEM
// -----------------------------------------------------------------------------

class AppLogger {
  static const _key = 'app_internal_logs';
  
  static Future<void> log(String type, String message) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      List<String> logs = prefs.getStringList(_key) ?? [];
      
      final timestamp = DateFormat('dd/MM HH:mm:ss').format(DateTime.now());
      final entry = "$timestamp [$type] $message";
      
      // Keep only last 200 logs to save memory
      logs.insert(0, entry);
      if (logs.length > 200) logs = logs.sublist(0, 200);
      
      await prefs.setStringList(_key, logs);
      print("LOG: $entry"); // Also print to console
    } catch (e) {
      print("Logging Error: $e");
    }
  }

  static Future<List<String>> getLogs() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getStringList(_key) ?? [];
  }
}

// -----------------------------------------------------------------------------
// BACKGROUND HANDLER
// -----------------------------------------------------------------------------

@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp();
  await AppLogger.log("BG_MSG", "Received: ${message.messageId}");
  
  await _triggerNaggingLogic(
    message.data['title'] ?? message.notification?.title ?? "הודעת ביפר",
    message.data['body'] ?? message.notification?.body ?? "התקבלה הודעה חדשה"
  );
}

// -----------------------------------------------------------------------------
// MAIN ENTRY POINT
// -----------------------------------------------------------------------------

void main() {
  runZonedGuarded(() async {
    WidgetsFlutterBinding.ensureInitialized();
    
    // Timezone setup using flutter_timezone for correct local time
    tz.initializeTimeZones();
    try {
      final String currentTimeZone = await FlutterTimezone.getLocalTimezone();
      tz.setLocalLocation(tz.getLocation(currentTimeZone));
    } catch (e) {
      // Fallback to UTC if something fails
      tz.setLocalLocation(tz.getLocation('UTC'));
    }

    runApp(const BeeperApp());
  }, (error, stack) {
    AppLogger.log("CRASH", "Main error: $error");
  });
}

// -----------------------------------------------------------------------------
// NAGGING LOGIC
// -----------------------------------------------------------------------------

Future<void> _triggerNaggingLogic(String title, String body) async {
  await AppLogger.log("ALERT", "Starting logic for: $title");
  final prefs = await SharedPreferences.getInstance();
  
  // 1. History Save
  final messageData = {
    'id': const Uuid().v4(),
    'title': title,
    'body': body,
    'timestamp': DateTime.now().toIso8601String(),
    'read': false,
  };
  
  List<String> history = prefs.getStringList('beeper_history') ?? [];
  history.insert(0, jsonEncode(messageData));
  await prefs.setStringList('beeper_history', history);

  // 2. User Settings
  bool isQuietTime = _checkQuietHours(prefs);
  bool isGlobalSilent = prefs.getBool('is_global_silent') ?? false;
  // Frequency is stored in SECONDS now for better precision (30s support)
  int frequencySeconds = prefs.getInt('nag_frequency_seconds') ?? 60;
  String? customSoundUri = prefs.getString('custom_sound_uri');
  
  AndroidNotificationDetails androidDetails;
  
  // 3. Build Channel
  if (isQuietTime || isGlobalSilent) {
    androidDetails = const AndroidNotificationDetails(
      'silent_channel_prod',
      'התראות שקטות',
      importance: Importance.high,
      priority: Priority.high,
      playSound: false,
      enableVibration: true,
    );
    await AppLogger.log("MODE", "Silent mode active");
  } else {
    String currentChannelId = baseChannelId;
    
    AndroidNotificationSound? soundObj;
    if (customSoundUri != null && customSoundUri.isNotEmpty) {
      currentChannelId = "${baseChannelId}_${customSoundUri.hashCode}";
      soundObj = UriAndroidNotificationSound(customSoundUri);
    }

    final androidPlugin = flutterLocalNotificationsPlugin
        .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
        
    try {
      await androidPlugin?.createNotificationChannel(
        AndroidNotificationChannel(
          currentChannelId,
          baseChannelName,
          description: channelDesc,
          importance: Importance.max,
          playSound: true,
          sound: soundObj, 
          enableVibration: true,
          audioAttributesUsage: AudioAttributesUsage.alarm,
        )
      );
    } catch (e) {
      await AppLogger.log("ERR_CHAN", "Channel create: $e");
    }

    // REMOVED LED/LIGHTS CONFIGURATION AS REQUESTED
    androidDetails = AndroidNotificationDetails(
      currentChannelId,
      baseChannelName,
      channelDescription: channelDesc,
      importance: Importance.max,
      priority: Priority.max,
      fullScreenIntent: true,
      category: AndroidNotificationCategory.alarm,
      visibility: NotificationVisibility.public,
      audioAttributesUsage: AudioAttributesUsage.alarm,
      playSound: true,
      sound: soundObj,
      enableVibration: true,
      vibrationPattern: Int64List.fromList([0, 1000, 500, 1000, 500, 1000]),
    );
  }

  // 4. Immediate Notification
  try {
    await flutterLocalNotificationsPlugin.show(
      0,
      title,
      body,
      NotificationDetails(android: androidDetails),
    );
  } catch (e) {
    await AppLogger.log("ERR_SHOW", "Show immediate: $e");
  }

  // 5. Schedule Repetitions (AlarmClock Mode)
  if (!isQuietTime && !isGlobalSilent) {
    try {
      final now = tz.TZDateTime.now(tz.local);
      for (int i = 1; i <= 5; i++) {
        final scheduledTime = now.add(Duration(seconds: i * frequencySeconds));
        
        await flutterLocalNotificationsPlugin.zonedSchedule(
          i + 100,
          "$title (חזרה $i)",
          body,
          scheduledTime,
          NotificationDetails(android: androidDetails),
          // CRITICAL: AlarmClock mode for Doze/Battery saver bypass
          androidScheduleMode: AndroidScheduleMode.alarmClock,
          uiLocalNotificationDateInterpretation:
              UILocalNotificationDateInterpretation.absoluteTime,
        );
      }
      await AppLogger.log("SCHED", "Scheduled 5 repeats every $frequencySeconds sec");
    } catch (e) {
      await AppLogger.log("ERR_SCHED", "Schedule failed: $e");
    }
  }
}

bool _checkQuietHours(SharedPreferences prefs) {
  final start = prefs.getInt('quiet_start_hour') ?? -1;
  final end = prefs.getInt('quiet_end_hour') ?? -1;
  if (start == -1 || end == -1) return false;
  
  final now = DateTime.now().hour;
  if (start < end) return now >= start && now < end;
  return now >= start || now < end;
}

// -----------------------------------------------------------------------------
// UI COMPONENTS
// -----------------------------------------------------------------------------

class BeeperApp extends StatelessWidget {
  const BeeperApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'ביפר',
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: Colors.black,
        primaryColor: Colors.greenAccent,
        colorScheme: const ColorScheme.dark(
          primary: Colors.greenAccent,
          secondary: Colors.redAccent,
          surface: Color(0xFF111111),
        ),
        textTheme: const TextTheme(
          bodyMedium: TextStyle(fontFamily: 'Courier', color: Colors.greenAccent),
          titleMedium: TextStyle(fontFamily: 'Courier', fontWeight: FontWeight.bold),
          titleLarge: TextStyle(fontFamily: 'Courier', fontWeight: FontWeight.bold, color: Colors.greenAccent),
        ),
        appBarTheme: AppBarTheme(
          backgroundColor: Colors.grey[900],
          titleTextStyle: const TextStyle(fontFamily: 'Courier', fontSize: 20, fontWeight: FontWeight.bold, color: Colors.white),
        )
      ),
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: const [Locale('he', 'IL')],
      locale: const Locale('he', 'IL'),
      home: const InitScreen(),
    );
  }
}

class InitScreen extends StatefulWidget {
  const InitScreen({super.key});

  @override
  State<InitScreen> createState() => _InitScreenState();
}

class _InitScreenState extends State<InitScreen> {
  String _status = "מאתחל...";
  bool _hasError = false;

  @override
  void initState() {
    super.initState();
    _initializeApp();
  }

  Future<void> _initializeApp() async {
    try {
      await Firebase.initializeApp();
      
      // Fixed Icon Definition
      const androidSettings = AndroidInitializationSettings('ic_launcher');
      
      await flutterLocalNotificationsPlugin.initialize(
        const InitializationSettings(android: androidSettings),
        onDidReceiveNotificationResponse: (details) {
            AppLogger.log("UI", "User tapped notification");
        }
      );
      
      // Initial Basic Permission Request
      await [
        Permission.notification,
        Permission.scheduleExactAlarm,
      ].request();

      FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);
      
      try {
        await FirebaseMessaging.instance.subscribeToTopic('all_users');
      } catch (e) {
        AppLogger.log("SUB_ERR", "Topic subscribe failed: $e");
      }

      if (mounted) {
        Navigator.pushReplacement(
          context, MaterialPageRoute(builder: (_) => const BeeperScreen())
        );
      }
    } catch (e) {
      setState(() {
        _hasError = true;
        _status = "שגיאה קריטית באתחול:\n$e";
      });
      AppLogger.log("FATAL", "Init failed: $e");
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: _hasError 
          ? Text(_status, textAlign: TextAlign.center, style: const TextStyle(color: Colors.red))
          : const CircularProgressIndicator(color: Colors.greenAccent),
      ),
    );
  }
}

class BeeperScreen extends StatefulWidget {
  const BeeperScreen({super.key});

  @override
  State<BeeperScreen> createState() => _BeeperScreenState();
}

class _BeeperScreenState extends State<BeeperScreen> with WidgetsBindingObserver {
  List<Map<String, dynamic>> _messages = [];
  bool _isSubscribed = false; 
  
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadMessages();
    _ensureSubscription();
    
    FirebaseMessaging.onMessage.listen((msg) {
      AppLogger.log("FG_MSG", "Msg received in foreground");
      _triggerNaggingLogic(
        msg.data['title'] ?? msg.notification?.title ?? "הודעה",
        msg.data['body'] ?? msg.notification?.body ?? "תוכן הודעה"
      );
      _loadMessages();
    });
  }

  Future<void> _ensureSubscription() async {
    try {
      await FirebaseMessaging.instance.subscribeToTopic('all_users');
      setState(() => _isSubscribed = true);
    } catch (e) {
      setState(() => _isSubscribed = false);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _loadMessages();
  }

  Future<void> _loadMessages() async {
    final prefs = await SharedPreferences.getInstance();
    final history = prefs.getStringList('beeper_history') ?? [];
    setState(() {
      _messages = history.map((e) => jsonDecode(e) as Map<String, dynamic>).toList();
    });
  }

  Future<void> _stopBeeper() async {
    await flutterLocalNotificationsPlugin.cancelAll();
    AppLogger.log("ACTION", "User stopped beeper");
    
    final prefs = await SharedPreferences.getInstance();
    List<String> history = prefs.getStringList('beeper_history') ?? [];
    List<String> updated = [];
    for (var item in history) {
      var map = jsonDecode(item);
      map['read'] = true;
      updated.add(jsonEncode(map));
    }
    await prefs.setStringList('beeper_history', updated);
    _loadMessages();
    
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text("הביפר הושתק"), backgroundColor: Colors.green)
    );
  }

  Future<void> _clearAll() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('beeper_history');
    _loadMessages();
  }

  Future<void> _checkAndRequestPermissions() async {
    Map<Permission, PermissionStatus> statuses = await [
      Permission.notification,
      Permission.scheduleExactAlarm,
      Permission.ignoreBatteryOptimizations,
    ].request();

    bool batteryOpt = await Permission.ignoreBatteryOptimizations.isGranted;
    
    if (mounted) {
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: Colors.grey[900],
          title: const Text("סטטוס הרשאות", style: TextStyle(color: Colors.white)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _permRow("התראות", statuses[Permission.notification]),
              _permRow("תזמון מדויק", statuses[Permission.scheduleExactAlarm]),
              _permRow("החרגת סוללה (Doze)", statuses[Permission.ignoreBatteryOptimizations]),
              const SizedBox(height: 10),
              if (!batteryOpt)
                 const Text(
                  "הערה: חובה לאשר 'החרגת סוללה' כדי שהביפר יעבוד כשהמסך כבוי במכשירי שיאומי/סמסונג.",
                  style: TextStyle(color: Colors.orange, fontSize: 12),
                ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text("סגור"),
            )
          ],
        )
      );
    }
  }

  Widget _permRow(String name, PermissionStatus? status) {
    bool isOk = status == PermissionStatus.granted;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4.0),
      child: Row(
        children: [
          Icon(isOk ? Icons.check_circle : Icons.error, color: isOk ? Colors.green : Colors.red, size: 16),
          const SizedBox(width: 8),
          Text(name, style: TextStyle(color: isOk ? Colors.greenAccent : Colors.redAccent)),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    bool hasUnread = _messages.any((m) => m['read'] == false);

    return Scaffold(
      appBar: AppBar(
        title: const Text("BEEPER // PROD", style: TextStyle(letterSpacing: 2)),
        centerTitle: true,
        leading: IconButton(
          icon: const Icon(Icons.shield_outlined, color: Colors.orangeAccent),
          onPressed: _checkAndRequestPermissions,
          tooltip: "בדיקת הרשאות",
        ),
        actions: [
          IconButton(
             icon: const Icon(Icons.list_alt, color: Colors.cyanAccent),
             onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const LogsScreen())),
             tooltip: "יומן אירועים",
          ),
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const SettingsPage())),
          )
        ],
      ),
      body: Column(
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            color: hasUnread ? Colors.red[900] : Colors.green[900]!.withOpacity(0.3),
            child: Text(
              hasUnread ? "!!! התראה פעילה !!!" : "מערכת מוכנה",
              textAlign: TextAlign.center,
              style: TextStyle(
                color: hasUnread ? Colors.white : Colors.greenAccent,
                fontWeight: FontWeight.bold,
                fontSize: 18,
                letterSpacing: 1.5
              ),
            ),
          ),
          
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: SizedBox(
              height: 80,
              width: double.infinity,
              child: ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.grey[800],
                  foregroundColor: Colors.redAccent,
                  side: const BorderSide(color: Colors.redAccent, width: 2),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
                ),
                onPressed: _stopBeeper,
                icon: const Icon(Icons.notifications_off, size: 32),
                label: const Text(
                  "עצור / קראתי",
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)
                ),
              ),
            ),
          ),

          Expanded(
            child: Container(
              margin: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xFF0F2015),
                border: Border.all(color: Colors.grey[700]!, width: 4),
                borderRadius: BorderRadius.circular(8),
              ),
              child: _messages.isEmpty 
                ? const Center(child: Text("אין הודעות", style: TextStyle(color: Colors.grey)))
                : ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: ListView.separated(
                    itemCount: _messages.length,
                    separatorBuilder: (_, __) => const Divider(color: Colors.green, height: 1),
                    itemBuilder: (context, index) {
                      final msg = _messages[index];
                      final isRead = msg['read'];
                      final time = DateFormat('HH:mm dd/MM').format(DateTime.parse(msg['timestamp']));
                      
                      return ListTile(
                        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                        tileColor: isRead ? null : Colors.green.withOpacity(0.1),
                        leading: Icon(
                          isRead ? Icons.check : Icons.warning_amber,
                          color: isRead ? Colors.green[800] : Colors.greenAccent,
                        ),
                        title: Text(
                          "${msg['title']} [$time]",
                          style: TextStyle(
                            color: isRead ? Colors.green[700] : Colors.greenAccent,
                            fontWeight: FontWeight.bold,
                            fontSize: 14
                          ),
                        ),
                        subtitle: Text(
                          msg['body'],
                          style: TextStyle(
                            color: isRead ? Colors.green[800] : Colors.white,
                            fontSize: 16
                          ),
                        ),
                      );
                    },
                  ),
                ),
            ),
          ),
          
          Padding(
            padding: const EdgeInsets.only(bottom: 16.0),
            child: TextButton.icon(
              onPressed: _clearAll,
              icon: Icon(Icons.delete_forever, color: Colors.grey[600]),
              label: Text("נקה היסטוריה", style: TextStyle(color: Colors.grey[600])),
            ),
          )
        ],
      ),
    );
  }
}

// -----------------------------------------------------------------------------
// LOGS SCREEN
// -----------------------------------------------------------------------------

class LogsScreen extends StatefulWidget {
  const LogsScreen({super.key});

  @override
  State<LogsScreen> createState() => _LogsScreenState();
}

class _LogsScreenState extends State<LogsScreen> {
  List<String> _logs = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final l = await AppLogger.getLogs();
    setState(() => _logs = l);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("יומן אירועים טכני"),
        actions: [
          IconButton(
            icon: const Icon(Icons.copy),
            onPressed: () {
              Clipboard.setData(ClipboardData(text: _logs.join("\n")));
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("הלוג הועתק")));
            },
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _load,
          )
        ],
      ),
      body: ListView.builder(
        padding: const EdgeInsets.all(8),
        itemCount: _logs.length,
        itemBuilder: (ctx, i) => Text(
          _logs[i], 
          style: const TextStyle(fontFamily: 'Courier', fontSize: 12, color: Colors.greenAccent)
        ),
      ),
    );
  }
}

// -----------------------------------------------------------------------------
// SETTINGS PAGE
// -----------------------------------------------------------------------------

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  int _start = -1, _end = -1;
  bool _isGlobalSilent = false;
  int _frequencySeconds = 60;
  String? _soundUri;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _start = prefs.getInt('quiet_start_hour') ?? -1;
      _end = prefs.getInt('quiet_end_hour') ?? -1;
      _isGlobalSilent = prefs.getBool('is_global_silent') ?? false;
      _frequencySeconds = prefs.getInt('nag_frequency_seconds') ?? 60;
      _soundUri = prefs.getString('custom_sound_uri');
    });
  }

  Future<void> _setHour(String key) async {
    final t = await showTimePicker(context: context, initialTime: const TimeOfDay(hour: 0, minute: 0));
    if (t != null) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(key, t.hour);
      _load();
    }
  }

  Future<void> _toggleSilent(bool val) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('is_global_silent', val);
    setState(() => _isGlobalSilent = val);
  }

  Future<void> _setFrequency(int? val) async {
    if (val != null) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt('nag_frequency_seconds', val);
      setState(() => _frequencySeconds = val);
    }
  }

  Future<void> _openSystemRingtonePicker() async {
    try {
      final String? result = await platformChannel.invokeMethod('pickRingtone', {
        'existingUri': _soundUri 
      });

      if (result != null) {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('custom_sound_uri', result);
        setState(() => _soundUri = result);
        AppLogger.log("SETTING", "Ringtone changed");
      }
    } on PlatformException catch (e) {
      AppLogger.log("ERR", "Pick ringtone: ${e.message}");
    }
  }

  Future<void> _resetSound() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('custom_sound_uri');
    setState(() => _soundUri = null);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("הגדרות ביפר")),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          _buildHeader("הגדרות התראה"),
          _buildCard(
            child: Column(
              children: [
                SwitchListTile(
                  title: const Text("מצב שקט תמידי", style: TextStyle(color: Colors.greenAccent, fontWeight: FontWeight.bold)),
                  value: _isGlobalSilent,
                  onChanged: _toggleSilent,
                  activeColor: Colors.greenAccent,
                ),
                const Divider(color: Colors.grey),
                ListTile(
                  title: const Text("תדירות נדנוד", style: TextStyle(color: Colors.greenAccent)),
                  subtitle: const Text("כל כמה זמן הביפר יצפצף?"),
                  trailing: DropdownButton<int>(
                    value: _frequencySeconds,
                    dropdownColor: Colors.grey[900],
                    style: const TextStyle(color: Colors.greenAccent),
                    items: const [
                      DropdownMenuItem(value: 30, child: Text("30 שניות")),
                      DropdownMenuItem(value: 60, child: Text("1 דקה")),
                      DropdownMenuItem(value: 120, child: Text("2 דקות")),
                      DropdownMenuItem(value: 300, child: Text("5 דקות")),
                    ],
                    onChanged: _setFrequency,
                  ),
                ),
              ],
            ),
          ),
          
          const SizedBox(height: 30),
          _buildHeader("צליל התראה"),
          _buildCard(
            child: Column(
              children: [
                ListTile(
                  title: const Text("צליל נבחר", style: TextStyle(color: Colors.white)),
                  subtitle: Text(
                    _soundUri != null ? "מותאם אישית" : "ברירת מחדל של האפליקציה",
                    style: const TextStyle(color: Colors.grey, fontSize: 12)
                  ),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (_soundUri != null)
                        IconButton(
                          icon: const Icon(Icons.refresh, color: Colors.orange),
                          onPressed: _resetSound,
                        ),
                      IconButton(
                        icon: const Icon(Icons.notifications_active, color: Colors.greenAccent),
                        onPressed: _openSystemRingtonePicker,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 30),
          _buildHeader("שעות שקטות"),
          _buildCard(
            child: Column(
              children: [
                ListTile(
                  title: const Text("התחלה", style: TextStyle(color: Colors.white)),
                  trailing: Text(
                    _start == -1 ? "--:--" : "${_start.toString().padLeft(2, '0')}:00",
                    style: const TextStyle(fontSize: 18, color: Colors.greenAccent, fontFamily: 'Courier'),
                  ),
                  onTap: () => _setHour('quiet_start_hour'),
                ),
                ListTile(
                  title: const Text("סיום", style: TextStyle(color: Colors.white)),
                  trailing: Text(
                    _end == -1 ? "--:--" : "${_end.toString().padLeft(2, '0')}:00",
                    style: const TextStyle(fontSize: 18, color: Colors.greenAccent, fontFamily: 'Courier'),
                  ),
                  onTap: () => _setHour('quiet_end_hour'),
                ),
              ],
            ),
          ),
          
           if (_start != -1)
            Padding(
              padding: const EdgeInsets.only(top: 20.0),
              child: Center(
                child: OutlinedButton.icon(
                  onPressed: () async {
                    final p = await SharedPreferences.getInstance();
                    await p.remove('quiet_start_hour');
                    await p.remove('quiet_end_hour');
                    _load();
                  },
                  icon: const Icon(Icons.delete_outline, color: Colors.red),
                  label: const Text("בטל שעות שקטות", style: TextStyle(color: Colors.red)),
                  style: OutlinedButton.styleFrom(side: const BorderSide(color: Colors.red)),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildHeader(String title) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Text(
        title,
        style: TextStyle(color: Colors.grey[500], fontSize: 14, letterSpacing: 1),
      ),
    );
  }

  Widget _buildCard({required Widget child}) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.grey[900],
        border: Border.all(color: Colors.greenAccent.withOpacity(0.3)),
        borderRadius: BorderRadius.circular(8),
      ),
      child: child,
    );
  }
}

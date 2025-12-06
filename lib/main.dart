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
// LOGGING SYSTEM
// -----------------------------------------------------------------------------

class AppLogger {
  static const String _key = 'beeper_logs_v_final';

  static Future<void> log(String message) async {
    final String timestamp = DateFormat('HH:mm:ss').format(DateTime.now());
    final String entry = "[$timestamp] $message";
    print("LOG: $entry");

    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      final List<String> logs = prefs.getStringList(_key) ?? [];
      logs.insert(0, entry);
      if (logs.length > 300) logs.removeRange(300, logs.length);
      await prefs.setStringList(_key, logs);
    } catch (e) {
      print("Log Error: $e");
    }
  }

  static Future<List<String>> getLogs() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    return prefs.getStringList(_key) ?? [];
  }

  static Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key);
  }
}

// -----------------------------------------------------------------------------
// GLOBAL OBJECTS
// -----------------------------------------------------------------------------

final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin =
    FlutterLocalNotificationsPlugin();

const String baseChannelName = 'התראות ביפר';
const String channelDesc = 'ערוץ חירום';
const MethodChannel platformChannel = MethodChannel('com.example.alerts/ringtone');

// -----------------------------------------------------------------------------
// HELPER: INITIALIZE
// -----------------------------------------------------------------------------

Future<void> _ensureNotificationInit() async {
  // 1. הגדרת Timezone דינמית מהמכשיר - קריטי לנודניק
  tz.initializeTimeZones();
  try {
    final String timeZoneName = await FlutterTimezone.getLocalTimezone();
    tz.setLocalLocation(tz.getLocation(timeZoneName));
  } catch (e) {
    try { tz.setLocalLocation(tz.getLocation('UTC')); } catch (_) {}
  }

  // 2. הגדרת אייקון - התיקון הקריטי: רק השם, ללא נתיב!
  const androidSettings = AndroidInitializationSettings('ic_launcher');
  const initSettings = InitializationSettings(android: androidSettings);
  
  await flutterLocalNotificationsPlugin.initialize(
    initSettings,
    onDidReceiveNotificationResponse: (details) {
      AppLogger.log("Notification Tapped");
    },
  );
}

// -----------------------------------------------------------------------------
// BACKGROUND HANDLER
// -----------------------------------------------------------------------------

@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp();
  await AppLogger.log("BG MSG: ${message.data}");
  await _ensureNotificationInit();
  await _triggerNaggingLogic(
    message.data['title'] ?? "ביפר",
    message.data['body'] ?? "הודעה חדשה"
  );
}

// -----------------------------------------------------------------------------
// MAIN ENTRY POINT
// -----------------------------------------------------------------------------

void main() {
  runZonedGuarded(() {
    WidgetsFlutterBinding.ensureInitialized();
    runApp(const BeeperApp());
  }, (error, stack) {
    AppLogger.log("CRASH: $error");
  });
}

// -----------------------------------------------------------------------------
// NAGGING LOGIC
// -----------------------------------------------------------------------------

Future<void> _triggerNaggingLogic(String title, String body) async {
  await AppLogger.log(">>> ALERT START: $title");
  
  try {
    final String timeZoneName = await FlutterTimezone.getLocalTimezone();
    tz.setLocalLocation(tz.getLocation(timeZoneName));
  } catch (_) {}

  final prefs = await SharedPreferences.getInstance();
  await prefs.reload();

  // History
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

  // Settings
  bool isQuietTime = _checkQuietHours(prefs);
  bool isGlobalSilent = prefs.getBool('is_global_silent') ?? false;
  bool isInQuietMode = isQuietTime || isGlobalSilent;

  // חישוב שניות (אם לא הוגדר עדיין, ברירת מחדל 30 שניות)
  int frequencySeconds = prefs.getInt('nag_frequency_seconds') ?? 30;
  if (frequencySeconds <= 0) frequencySeconds = 30;

  String? customSoundUri = prefs.getString('custom_sound_uri');
  bool enableVibrate;
  bool playSound;

  if (isInQuietMode) {
    enableVibrate = prefs.getBool('quiet_vibrate_enabled') ?? true;
    playSound = false;
    await AppLogger.log("Mode: QUIET");
  } else {
    enableVibrate = prefs.getBool('normal_vibrate_enabled') ?? true;
    playSound = true;
    await AppLogger.log("Mode: NORMAL");
  }

  // Channel ID (v20 - clean slate without LED)
  String settingsHash = "${isInQuietMode}_${enableVibrate}_${customSoundUri.hashCode}";
  String dynamicChannelId = "beeper_v20_$settingsHash";

  AndroidNotificationSound? soundObj;
  if (playSound && customSoundUri != null && customSoundUri.isNotEmpty) {
    soundObj = UriAndroidNotificationSound(customSoundUri);
  }

  Int64List? vibrationPattern;
  if (enableVibrate) {
    // רטט חזק: 0 המתנה, 1000 רטט...
    vibrationPattern = Int64List.fromList([0, 1000, 500, 1000]);
  }

  final androidPlugin = flutterLocalNotificationsPlugin
      .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
      
  try {
    await androidPlugin?.createNotificationChannel(
      AndroidNotificationChannel(
        dynamicChannelId,
        baseChannelName,
        description: channelDesc,
        importance: Importance.max,
        playSound: playSound,
        sound: soundObj, 
        enableVibration: enableVibrate,
        vibrationPattern: vibrationPattern,
        enableLights: false, // בוטל לחלוטין
        audioAttributesUsage: AudioAttributesUsage.alarm,
      )
    );
  } catch (e) {
    await AppLogger.log("ChanErr: $e");
  }

  final androidDetails = AndroidNotificationDetails(
    dynamicChannelId,
    baseChannelName,
    channelDescription: channelDesc,
    importance: Importance.max,
    priority: Priority.max,
    fullScreenIntent: true,
    category: AndroidNotificationCategory.alarm,
    visibility: NotificationVisibility.public,
    audioAttributesUsage: AudioAttributesUsage.alarm,
    playSound: playSound,
    sound: soundObj,
    enableVibration: enableVibrate,
    vibrationPattern: vibrationPattern,
    enableLights: false,
    ongoing: true,
    autoCancel: false,
    ticker: title,
  );

  // 1. Immediate Notification
  try {
    await flutterLocalNotificationsPlugin.show(
      0,
      title,
      body,
      NotificationDetails(android: androidDetails),
    );
    await AppLogger.log("Immediate Sent");
  } catch (e) {
    await AppLogger.log("Immediate FAIL: $e");
  }

  // 2. Nagging Loop (Repeating Alarm)
  bool shouldNag = (playSound || enableVibrate);
  if (shouldNag) {
    try {
      final now = tz.TZDateTime.now(tz.local); 
      for (int i = 1; i <= 10; i++) { 
        // חישוב זמן עתידי מדויק בשניות
        final scheduledTime = now.add(Duration(seconds: (i * frequencySeconds) + 2));
        
        await flutterLocalNotificationsPlugin.zonedSchedule(
          i + 1000,
          "$title (נודניק $i)",
          body,
          scheduledTime,
          NotificationDetails(android: androidDetails),
          // שימוש ב-alarmClock הוא היחיד שיעיר מכשירי שיאומי במצב שינה
          androidScheduleMode: AndroidScheduleMode.alarmClock,
          uiLocalNotificationDateInterpretation:
              UILocalNotificationDateInterpretation.absoluteTime,
        );
      }
      await AppLogger.log("Scheduled 10 nags (Every ${frequencySeconds}s)");
    } catch (e) {
      await AppLogger.log("Schedule FAIL: $e");
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
      await AppLogger.log("=== APP INIT ===");
      await Firebase.initializeApp();
      
      await _ensureNotificationInit();
      
      // בקשת הרשאות קריטיות
      await [
        Permission.notification,
        Permission.scheduleExactAlarm,
        Permission.ignoreBatteryOptimizations, // חובה לשיאומי!
      ].request();
      
      final androidPlugin = flutterLocalNotificationsPlugin
          .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
      await androidPlugin?.requestNotificationsPermission();

      FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);
      await FirebaseMessaging.instance.subscribeToTopic('all_users');

      if (mounted) {
        Navigator.pushReplacement(
          context, MaterialPageRoute(builder: (_) => const BeeperScreen())
        );
      }
    } catch (e) {
      await AppLogger.log("INIT ERROR: $e");
      setState(() {
        _hasError = true;
        _status = "שגיאה: $e";
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (!_hasError) const CircularProgressIndicator(color: Colors.greenAccent),
            if (_hasError) Padding(
              padding: const EdgeInsets.all(20.0),
              child: Text(_status, textAlign: TextAlign.center, style: const TextStyle(color: Colors.red)),
            ),
          ],
        ),
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
  
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadMessages();
    
    FirebaseMessaging.onMessage.listen((msg) {
      AppLogger.log("FG MSG: ${msg.data}");
      _triggerNaggingLogic(
        msg.data['title'] ?? "הודעה",
        msg.data['body'] ?? "תוכן הודעה"
      );
      _loadMessages();
    });
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
    await prefs.reload();
    final history = prefs.getStringList('beeper_history') ?? [];
    setState(() {
      _messages = history.map((e) => jsonDecode(e) as Map<String, dynamic>).toList();
    });
  }

  Future<void> _stopBeeper() async {
    await AppLogger.log("STOP CLICKED");
    await flutterLocalNotificationsPlugin.cancelAll();
    
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

  Future<void> _runSelfTest() async {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text("מבצע בדיקה..."), duration: Duration(seconds: 1))
    );
    await _triggerNaggingLogic("בדיקה עצמית", "התראה זו מדמה התראת אמת מהשרת");
    _loadMessages();
  }

  Future<void> _checkAllPermissions() async {
    StringBuffer report = StringBuffer();
    
    var notifStatus = await Permission.notification.status;
    report.writeln("Notifications: $notifStatus");
    if (!notifStatus.isGranted) await Permission.notification.request();

    var alarmStatus = await Permission.scheduleExactAlarm.status;
    report.writeln("Alarm (Snooze): $alarmStatus");
    if (!alarmStatus.isGranted) await Permission.scheduleExactAlarm.request();

    var batteryStatus = await Permission.ignoreBatteryOptimizations.status;
    report.writeln("Battery: $batteryStatus");
    if (!batteryStatus.isGranted) {
       await Permission.ignoreBatteryOptimizations.request();
    }

    await AppLogger.log("PERM CHECK:\n$report");
    
    if (mounted) {
      showDialog(context: context, builder: (_) => AlertDialog(
        title: const Text("דוח הרשאות"),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(report.toString(), style: const TextStyle(color: Colors.white)),
            const SizedBox(height: 20),
            const Text(
              "במכשירי Xiaomi: חובה לאפשר 'Autostart' בהגדרות האפליקציה!",
              style: TextStyle(color: Colors.orange, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 10),
            ElevatedButton(
              onPressed: () => openAppSettings(),
              child: const Text("פתח הגדרות אפליקציה"),
            )
          ],
        ),
        backgroundColor: Colors.grey[900],
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    bool hasUnread = _messages.any((m) => m['read'] == false);

    return Scaffold(
      appBar: AppBar(
        title: const Text("BEEPER SYSTEM", style: TextStyle(letterSpacing: 2)),
        centerTitle: true,
        leading: IconButton(
          icon: const Icon(Icons.assignment, color: Colors.yellowAccent),
          onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const LogViewerScreen())),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.shield, color: Colors.blueAccent),
            onPressed: _checkAllPermissions,
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
            child: Row(
              children: [
                Expanded(
                  child: SizedBox(
                    height: 80,
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
                const SizedBox(width: 10),
                SizedBox(
                  height: 80,
                  width: 80,
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.blueGrey[800],
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
                    ),
                    onPressed: _runSelfTest,
                    child: const Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.volume_up),
                        Text("בדיקה", style: TextStyle(fontSize: 10)),
                      ],
                    ),
                  ),
                ),
              ],
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
// LOG VIEWER WITH COPY
// -----------------------------------------------------------------------------

class LogViewerScreen extends StatefulWidget {
  const LogViewerScreen({super.key});

  @override
  State<LogViewerScreen> createState() => _LogViewerScreenState();
}

class _LogViewerScreenState extends State<LogViewerScreen> {
  List<String> logs = [];

  @override
  void initState() {
    super.initState();
    _loadLogs();
  }

  Future<void> _loadLogs() async {
    final l = await AppLogger.getLogs();
    setState(() => logs = l);
  }

  Future<void> _copyLogs() async {
    final text = logs.join('\n');
    await Clipboard.setData(ClipboardData(text: text));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("הלוג הועתק ללוח"), backgroundColor: Colors.white, duration: Duration(seconds: 1)),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("יומן מערכת"),
        actions: [
          IconButton(
            icon: const Icon(Icons.copy, color: Colors.cyanAccent), 
            onPressed: _copyLogs,
          ),
          IconButton(icon: const Icon(Icons.refresh), onPressed: _loadLogs),
          IconButton(icon: const Icon(Icons.delete), onPressed: () async {
            await AppLogger.clear();
            _loadLogs();
          }),
        ],
      ),
      body: Container(
        color: Colors.black,
        child: ListView.builder(
          itemCount: logs.length,
          padding: const EdgeInsets.all(10),
          itemBuilder: (context, index) {
            final log = logs[index];
            Color color = Colors.greenAccent;
            if (log.contains("FAIL") || log.contains("ERROR") || log.contains("CRASH")) {
              color = Colors.redAccent;
            } else if (log.contains("BG MSG")) {
              color = Colors.orangeAccent;
            }
            
            return Padding(
              padding: const EdgeInsets.only(bottom: 8.0),
              child: SelectableText(log, style: TextStyle(color: color, fontFamily: 'Courier', fontSize: 12)),
            );
          },
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
  int _frequencySeconds = 30; 
  String? _soundUri;

  bool _normVib = true;
  bool _quietVib = true;

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
      _frequencySeconds = prefs.getInt('nag_frequency_seconds') ?? 30;
      _soundUri = prefs.getString('custom_sound_uri');
      _normVib = prefs.getBool('normal_vibrate_enabled') ?? true;
      _quietVib = prefs.getBool('quiet_vibrate_enabled') ?? true;
    });
  }

  Future<void> _saveBool(String key, bool val) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(key, val);
    _load();
  }

  Future<void> _setHour(String key) async {
    final t = await showTimePicker(context: context, initialTime: const TimeOfDay(hour: 0, minute: 0));
    if (t != null) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(key, t.hour);
      _load();
    }
  }

  Future<void> _toggleGlobalSilent(bool val) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('is_global_silent', val);
    setState(() => _isGlobalSilent = val);
  }

  Future<void> _setFrequencySeconds(int? val) async {
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
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("צלצול עודכן"), backgroundColor: Colors.green)
        );
      }
    } on PlatformException catch (e) {
      print("Error picking ringtone: ${e.message}");
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
          _buildHeader("מצב רגיל"),
          _buildCard(
            child: Column(
              children: [
                SwitchListTile(
                  title: const Text("רטט", style: TextStyle(color: Colors.white)),
                  value: _normVib,
                  onChanged: (v) => _saveBool('normal_vibrate_enabled', v),
                  activeColor: Colors.greenAccent,
                ),
                const Divider(height: 1, color: Colors.grey),
                ListTile(
                  title: const Text("צליל נבחר", style: TextStyle(color: Colors.white)),
                  subtitle: Text(
                    _soundUri != null ? "מותאם אישית" : "ברירת מחדל",
                    style: const TextStyle(color: Colors.grey, fontSize: 12)
                  ),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
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

          const SizedBox(height: 20),
          _buildHeader("מצב שקט"),
          _buildCard(
            child: Column(
              children: [
                 SwitchListTile(
                  title: const Text("שקט תמידי", style: TextStyle(color: Colors.greenAccent, fontWeight: FontWeight.bold)),
                  subtitle: const Text("מתעלם משעות - המכשיר תמיד בשקט"),
                  value: _isGlobalSilent,
                  onChanged: _toggleGlobalSilent,
                  activeColor: Colors.greenAccent,
                ),
                const Divider(height: 1, color: Colors.grey),
                SwitchListTile(
                  title: const Text("רטט בשקט", style: TextStyle(color: Colors.white)),
                  value: _quietVib,
                  onChanged: (v) => _saveBool('quiet_vibrate_enabled', v),
                  activeColor: Colors.orangeAccent,
                ),
              ],
            ),
          ),

          const SizedBox(height: 20),
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
                const Divider(height: 1, color: Colors.grey),
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
          
          const SizedBox(height: 20),
          _buildHeader("כללי"),
           _buildCard(
            child: ListTile(
              title: const Text("תדירות נודניק", style: TextStyle(color: Colors.white)),
              trailing: DropdownButton<int>(
                value: _frequencySeconds,
                dropdownColor: Colors.grey[900],
                style: const TextStyle(color: Colors.greenAccent),
                items: const [
                  DropdownMenuItem(value: 30, child: Text("30 שניות (דחוף!)")),
                  DropdownMenuItem(value: 60, child: Text("דקה אחת")),
                  DropdownMenuItem(value: 120, child: Text("2 דקות")),
                  DropdownMenuItem(value: 300, child: Text("5 דקות")),
                ],
                onChanged: _setFrequencySeconds,
              ),
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

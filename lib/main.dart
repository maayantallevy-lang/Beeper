import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data'; // חובה עבור Int64List (רטט)
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
import 'package:uuid/uuid.dart';

// -----------------------------------------------------------------------------
// GLOBAL OBJECTS
// -----------------------------------------------------------------------------

final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin =
    FlutterLocalNotificationsPlugin();

// v4 - שם חדש כדי לנקות את כל ההגדרות הישנות בטלפון
const String baseChannelId = 'critical_alert_channel_v4';
const String baseChannelName = 'התראות חירום';
const String channelDesc = 'ערוץ להודעות דחופות עם עקיפת שקט';

const MethodChannel platformChannel = MethodChannel('com.example.alerts/ringtone');

// -----------------------------------------------------------------------------
// BACKGROUND HANDLER
// -----------------------------------------------------------------------------

@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp();
  print("BACKGROUND MSG: ${message.data}");
  // הפעלה גם ברקע
  await _triggerNaggingLogic(
    message.data['title'] ?? message.notification?.title ?? "הודעת ביפר",
    message.data['body'] ?? message.notification?.body ?? "התקבלה הודעה חדשה"
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
    print("CRITICAL ERROR IN MAIN: $error");
  });
}

// -----------------------------------------------------------------------------
// NAGGING LOGIC (THE ENGINE)
// -----------------------------------------------------------------------------

Future<void> _triggerNaggingLogic(String title, String body) async {
  print("--- STARTING ALERT LOGIC: $title ---");
  final prefs = await SharedPreferences.getInstance();
  
  // 1. שמירה בהיסטוריה
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

  // 2. הגדרות משתמש
  bool isQuietTime = _checkQuietHours(prefs);
  bool isGlobalSilent = prefs.getBool('is_global_silent') ?? false;
  int frequencyMinutes = prefs.getInt('nag_frequency') ?? 1;
  String? customSoundUri = prefs.getString('custom_sound_uri');
  
  tz.initializeTimeZones();
  
  AndroidNotificationDetails androidDetails;
  
  // 3. בניית הערוץ
  if (isQuietTime || isGlobalSilent) {
    androidDetails = const AndroidNotificationDetails(
      'silent_channel_v4',
      'התראות שקטות',
      importance: Importance.high,
      priority: Priority.high,
      playSound: false,
      enableVibration: true,
    );
  } else {
    String currentChannelId = baseChannelId;
    
    // אובייקט סאונד
    AndroidNotificationSound? soundObj;
    if (customSoundUri != null && customSoundUri.isNotEmpty) {
      currentChannelId = "${baseChannelId}_${customSoundUri.hashCode}";
      soundObj = UriAndroidNotificationSound(customSoundUri);
    }

    final androidPlugin = flutterLocalNotificationsPlugin
        .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
        
    // יצירת הערוץ בפועל מול מערכת ההפעלה
    try {
      await androidPlugin?.createNotificationChannel(
        AndroidNotificationChannel(
          currentChannelId,
          baseChannelName,
          description: channelDesc,
          importance: Importance.max, // הכי גבוה
          playSound: true,
          sound: soundObj, 
          enableVibration: true,
          audioAttributesUsage: AudioAttributesUsage.alarm, // מתנהג כשעון מעורר
        )
      );
    } catch (e) {
      print("Error creating channel: $e");
    }

    androidDetails = AndroidNotificationDetails(
      currentChannelId,
      baseChannelName,
      channelDescription: channelDesc,
      importance: Importance.max,
      priority: Priority.max,
      fullScreenIntent: true, // קריטי להקפצה
      category: AndroidNotificationCategory.alarm,
      visibility: NotificationVisibility.public,
      audioAttributesUsage: AudioAttributesUsage.alarm,
      playSound: true,
      sound: soundObj,
      enableVibration: true,
      // רטט חזק: המתנה 0, רטט 1000ms, המתנה 500ms, רטט 1000ms...
      vibrationPattern: Int64List.fromList([0, 1000, 500, 1000, 500, 1000]),
    );
  }

  // 4. התראה מיידית (ללא תזמון) - כדי לוודא שזה קופץ עכשיו
  try {
    print("Showing IMMEDIATE notification...");
    await flutterLocalNotificationsPlugin.show(
      0, // מזהה קבוע להתראה הראשית
      title,
      body,
      NotificationDetails(android: androidDetails),
    );
  } catch (e) {
    print("ERROR SHOWING NOTIFICATION: $e");
  }

  // 5. תזמון חזרות (רק אם לא שקט)
  if (!isQuietTime && !isGlobalSilent) {
    try {
      final now = tz.TZDateTime.now(tz.local);
      for (int i = 1; i <= 5; i++) {
        final scheduledTime = now.add(Duration(minutes: i * frequencyMinutes));
        await flutterLocalNotificationsPlugin.zonedSchedule(
          i + 100,
          "$title (חזרה $i)",
          body,
          scheduledTime,
          NotificationDetails(android: androidDetails),
          androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
          uiLocalNotificationDateInterpretation:
              UILocalNotificationDateInterpretation.absoluteTime,
        );
      }
    } catch (e) {
      print("ERROR SCHEDULING: $e");
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
      tz.initializeTimeZones();
      
      // --- התיקון הקריטי: שימוש בנתיב המלא @mipmap/ic_launcher ---
      const androidSettings = AndroidInitializationSettings('@mipmap/ic_launcher');
      // -----------------------------------------------------------
      
      await flutterLocalNotificationsPlugin.initialize(
        const InitializationSettings(android: androidSettings),
        onDidReceiveNotificationResponse: (details) {
            print("User tapped notification: ${details.payload}");
        }
      );
      
      // בקשת הרשאות אגרסיבית
      await [
        Permission.notification,
        Permission.scheduleExactAlarm,
      ].request();
      
      // וידוא נוסף מול הפלאגין
      final androidPlugin = flutterLocalNotificationsPlugin
          .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
      await androidPlugin?.requestNotificationsPermission();

      FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);
      
      try {
        await FirebaseMessaging.instance.subscribeToTopic('all_users');
        print("Subscribed to all_users");
      } catch (e) {
        print("Subscribe error: $e");
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
  bool _isSubscribed = false; 
  
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadMessages();
    _ensureSubscription();
    
    FirebaseMessaging.onMessage.listen((msg) {
      print("FOREGROUND MSG: ${msg.data}");
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
    final status = await Permission.notification.status;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text("הרשאה: $status | מפעיל בדיקה..."), 
        duration: const Duration(seconds: 1)
      )
    );
    
    await _triggerNaggingLogic("בדיקה עצמית", "בדיקת מערכת סאונד והתראות");
    _loadMessages();
  }

  @override
  Widget build(BuildContext context) {
    bool hasUnread = _messages.any((m) => m['read'] == false);

    return Scaffold(
      appBar: AppBar(
        title: const Text("BEEPER // SYSTEM", style: TextStyle(letterSpacing: 2)),
        centerTitle: true,
        actions: [
          Container(
            margin: const EdgeInsets.all(16),
            width: 12,
            height: 12,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: _isSubscribed ? Colors.greenAccent : Colors.red,
            ),
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
  int _frequency = 1;
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
      _frequency = prefs.getInt('nag_frequency') ?? 1;
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
      await prefs.setInt('nag_frequency', val);
      setState(() => _frequency = val);
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
        
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text("צלצול עודכן"), backgroundColor: Colors.green)
          );
        }
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
          _buildHeader("הגדרות התראה"),
          _buildCard(
            child: Column(
              children: [
                SwitchListTile(
                  title: const Text("מצב שקט תמידי", style: TextStyle(color: Colors.greenAccent, fontWeight: FontWeight.bold)),
                  subtitle: const Text("קבלת התראות ללא סאונד (רטט בלבד)"),
                  value: _isGlobalSilent,
                  onChanged: _toggleSilent,
                  activeColor: Colors.greenAccent,
                ),
                const Divider(color: Colors.grey),
                ListTile(
                  title: const Text("תדירות נדנוד", style: TextStyle(color: Colors.greenAccent)),
                  subtitle: const Text("כל כמה זמן הביפר יצפצף?"),
                  trailing: DropdownButton<int>(
                    value: _frequency,
                    dropdownColor: Colors.grey[900],
                    style: const TextStyle(color: Colors.greenAccent),
                    items: const [
                      DropdownMenuItem(value: 1, child: Text("כל דקה (דחוף)")),
                      DropdownMenuItem(value: 2, child: Text("כל 2 דקות")),
                      DropdownMenuItem(value: 5, child: Text("כל 5 דקות")),
                      DropdownMenuItem(value: 10, child: Text("כל 10 דקות")),
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
                          tooltip: "חזור לברירת מחדל",
                        ),
                      IconButton(
                        icon: const Icon(Icons.notifications_active, color: Colors.greenAccent),
                        onPressed: _openSystemRingtonePicker,
                        tooltip: "בחר צליל מערכת",
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 30),
          _buildHeader("שעות שקטות (אוטומטי)"),
          _buildCard(
            child: Column(
              children: [
                ListTile(
                  title: const Text("שעת התחלה", style: TextStyle(color: Colors.white)),
                  trailing: Text(
                    _start == -1 ? "--:--" : "${_start.toString().padLeft(2, '0')}:00",
                    style: const TextStyle(fontSize: 18, color: Colors.greenAccent, fontFamily: 'Courier'),
                  ),
                  leading: const Icon(Icons.nights_stay, color: Colors.greenAccent),
                  onTap: () => _setHour('quiet_start_hour'),
                ),
                const Divider(color: Colors.grey),
                ListTile(
                  title: const Text("שעת סיום", style: TextStyle(color: Colors.white)),
                  trailing: Text(
                    _end == -1 ? "--:--" : "${_end.toString().padLeft(2, '0')}:00",
                    style: const TextStyle(fontSize: 18, color: Colors.greenAccent, fontFamily: 'Courier'),
                  ),
                  leading: const Icon(Icons.wb_sunny, color: Colors.greenAccent),
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
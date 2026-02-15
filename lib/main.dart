// ignore_for_file: deprecated_member_use

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

void main() {
  runApp(const PacpressApp());
}

class PacpressApp extends StatelessWidget {
  const PacpressApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Pacpress',
      theme: ThemeData(
        brightness: Brightness.dark,
        useMaterial3: true,
        colorSchemeSeed: const Color(0xFF6D5EF6),
        snackBarTheme: SnackBarThemeData(
          behavior: SnackBarBehavior.floating,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        ),
      ),
      home: const PacpressHomePage(),
    );
  }
}

/// Press-and-hold repeating icon button:
/// - tap = exactly 1 step
/// - hold = repeats after a delay
/// - later accelerates
///
/// This avoids the "tap increments twice" issue by NOT stepping on tapDown.
class RepeatIconButton extends StatefulWidget {
  const RepeatIconButton({
    super.key,
    required this.icon,
    required this.onStep,
    this.enabled = true,
    this.initialDelay = const Duration(milliseconds: 450),
    this.repeatPeriod = const Duration(milliseconds: 110),
    this.fastPeriod = const Duration(milliseconds: 65),
    this.accelerateAfter = const Duration(milliseconds: 1200),
  });

  final IconData icon;
  final VoidCallback onStep;
  final bool enabled;

  final Duration initialDelay;
  final Duration repeatPeriod;
  final Duration fastPeriod;
  final Duration accelerateAfter;

  @override
  State<RepeatIconButton> createState() => _RepeatIconButtonState();
}

class _RepeatIconButtonState extends State<RepeatIconButton> {
  Timer? _startTimer;
  Timer? _repeatTimer;
  Timer? _accelTimer;
  bool _holding = false;

  void _stopAll() {
    _holding = false;
    _startTimer?.cancel();
    _repeatTimer?.cancel();
    _accelTimer?.cancel();
    _startTimer = null;
    _repeatTimer = null;
    _accelTimer = null;
  }

  void _startHold() {
    if (!widget.enabled) return;
    _holding = true;

    _startTimer?.cancel();
    _repeatTimer?.cancel();
    _accelTimer?.cancel();

    // After initial delay, start repeating
    _startTimer = Timer(widget.initialDelay, () {
      if (!_holding || !mounted || !widget.enabled) return;

      _repeatTimer = Timer.periodic(widget.repeatPeriod, (_) {
        if (!_holding || !mounted || !widget.enabled) return;
        widget.onStep();
      });

      // After accelerateAfter, speed it up
      _accelTimer = Timer(widget.accelerateAfter, () {
        _repeatTimer?.cancel();
        _repeatTimer = Timer.periodic(widget.fastPeriod, (_) {
          if (!_holding || !mounted || !widget.enabled) return;
          widget.onStep();
        });
      });
    });
  }

  @override
  void dispose() {
    _stopAll();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final enabled = widget.enabled;

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: enabled ? widget.onStep : null, // ✅ single step
      onLongPressStart: enabled ? (_) => _startHold() : null,
      onLongPressEnd: (_) => _stopAll(),
      onLongPressCancel: _stopAll,
      child: Container(
        width: 46,
        height: 46,
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(enabled ? 0.08 : 0.03),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: Colors.white.withOpacity(0.08)),
        ),
        child: Icon(widget.icon, size: 22),
      ),
    );
  }
}

class PacpressHomePage extends StatefulWidget {
  const PacpressHomePage({super.key});

  @override
  State<PacpressHomePage> createState() => _PacpressHomePageState();
}

class _PacpressHomePageState extends State<PacpressHomePage> {
  // ======= Connect target
  String wsHost = '192.168.132.180';
  int wsPort = 8080;
  String get wsUrl => 'ws://$wsHost:$wsPort';

  // Controllers (prevents “typing lag” from recreating controllers each build)
  late final TextEditingController _hostCtl;
  late final TextEditingController _portCtl;

  // ======= Live device/meta
  bool deviceConnected = false; // raw WS link (not used for UI truth)
  DateTime? _lastMessageAt; // freshness

  String deviceName = 'Pacpress Controller';

  bool staConnected = false;
  bool apMode = false;
  String wifiSsid = '';
  String ip = '';

  // Health
  bool dsOk = true, xOk = true, dfOk = true, dfValid = true;
  int errDS = 0, errX = 0, errDF = 0;

  // Readings
  double feedPsi = 0.0;
  int pumpCount = 0;

  // Optional: “pump active” if ESP provides it
  bool pumpActive = false;
  bool pumpActiveValid = false;

  bool pressClosed = false;
  bool cycleOn = false;
  bool cycleOver = false;

  // DS live
  int ds1StartFeedPressure = 0;
  int ds2FinalPressurePsi = 0;
  int ds3FeedPressureInc = 0;
  int ds4StrokeTimer = 0;
  int ds5FinalTimer = 0;

  // DS editable
  int eDS1 = 0, eDS2 = 0, eDS3 = 0, eDS4 = 0, eDS5 = 0;

  // ✅ edit state (fixes “jump back”)
  bool dsDirty = false; // user edited
  bool dsSending = false; // write in-flight

  // Last ACK
  String lastAckLabel = '—';
  bool lastAckOk = true;
  int lastAckErr = 0;
  DateTime? lastAckAt;

  // UI
  int tab = 0;
  final List<Map<String, dynamic>> logs = [];

  // WebSocket
  WebSocketChannel? _channel;
  StreamSubscription? _sub;
  Timer? _reconnectTimer;

  // UI debounce (less jank)
  Timer? _uiDebounce;

  Timer? _dsWriteTimeout; // times out sending state (never locks steppers)

  bool get connectedFresh =>
      _lastMessageAt != null &&
      DateTime.now().difference(_lastMessageAt!) < const Duration(seconds: 2);

  @override
  void initState() {
    super.initState();
    _hostCtl = TextEditingController(text: wsHost);
    _portCtl = TextEditingController(text: wsPort.toString());
    _connect();
  }

  @override
  void dispose() {
    _uiDebounce?.cancel();
    _reconnectTimer?.cancel();
    _sub?.cancel();
    _channel?.sink.close();
    _dsWriteTimeout?.cancel();
    _hostCtl.dispose();
    _portCtl.dispose();
    super.dispose();
  }

  // ======= Haptics
  void _hapticLight() => HapticFeedback.selectionClick();
  void _hapticSuccess() => HapticFeedback.lightImpact();

  // ======= Toast
  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).clearSnackBars();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg, style: const TextStyle(fontWeight: FontWeight.w700)),
        duration: const Duration(milliseconds: 1200),
      ),
    );
  }

  void _scheduleUi() {
    _uiDebounce?.cancel();
    _uiDebounce = Timer(const Duration(milliseconds: 100), () {
      if (mounted) setState(() {});
    });
  }

  // ======= tolerant parsers (helps field testing)
  double? _readNum(Map<String, dynamic> d, List<String> keys) {
    for (final k in keys) {
      final v = d[k];
      if (v is num) return v.toDouble();
      if (v is String) {
        final parsed = double.tryParse(v.trim());
        if (parsed != null) return parsed;
      }
    }
    return null;
  }

  int? _readInt(Map<String, dynamic> d, List<String> keys) {
    for (final k in keys) {
      final v = d[k];
      if (v is int) return v;
      if (v is num) return v.toInt();
      if (v is String) {
        final parsed = int.tryParse(v.trim());
        if (parsed != null) return parsed;
      }
    }
    return null;
  }

  bool? _readBool(Map<String, dynamic> d, List<String> keys) {
    for (final k in keys) {
      final v = d[k];
      if (v is bool) return v;
      if (v is num) return v != 0;
      if (v is String) {
        final s = v.toLowerCase().trim();
        if (s == 'true' || s == '1' || s == 'on') return true;
        if (s == 'false' || s == '0' || s == 'off') return false;
      }
    }
    return null;
  }

  void _connect() {
    // HARD reset connection state so it can’t lie
    deviceConnected = false;
    _lastMessageAt = null;
    _scheduleUi();

    _reconnectTimer?.cancel();

    try {
      _sub?.cancel();
      _channel?.sink.close();
    } catch (_) {}

    () async {
      try {
        final ch = IOWebSocketChannel.connect(
          Uri.parse(wsUrl),
          connectTimeout: const Duration(seconds: 3),
        );
        _channel = ch;

        _sub = ch.stream.listen(
          (message) {
            deviceConnected = true;
            _lastMessageAt = DateTime.now();

            Map<String, dynamic>? data;
            try {
              final decoded = jsonDecode(message);
              if (decoded is Map) data = decoded.cast<String, dynamic>();
            } catch (_) {}

            if (data == null) {
              _scheduleUi();
              return;
            }

            // ACK messages
            if (data.containsKey('ack')) {
              lastAckLabel = (data['ack'] ?? 'ack').toString();
              lastAckOk = data['ok'] == true;
              lastAckErr =
                  (data['err'] is num) ? (data['err'] as num).toInt() : 0;
              lastAckAt = DateTime.now();

              final label = lastAckLabel.toUpperCase();
              if (lastAckOk) {
                _toast('$label ✓');
              } else {
                _toast('$label failed (err $lastAckErr)');
              }

              if (lastAckLabel == 'ds') {
                dsSending = false;
                _dsWriteTimeout?.cancel();

                // If write succeeded, clear dirty so next live updates can sync again
                if (lastAckOk) {
                  dsDirty = false;
                  _hapticSuccess();
                }
              }

              _scheduleUi();
              return;
            }

            // Device meta
            deviceName = (data['deviceName'] ?? deviceName).toString();
            wifiSsid = (data['ssid'] ?? wifiSsid).toString();
            ip = (data['ip'] ?? ip).toString();
            staConnected = data['staConnected'] == true;
            apMode = data['apMode'] == true;

            // Health
            dsOk = data['dsOk'] == true;
            xOk = data['xOk'] == true;
            dfOk = data['dfOk'] == true;
            dfValid = data['dfValid'] == true;
            errDS = ((data['errDS'] as num?)?.toInt()) ?? errDS;
            errX = ((data['errX'] as num?)?.toInt()) ?? errX;
            errDF = ((data['errDF'] as num?)?.toInt()) ?? errDF;

            // Readings (tolerant keys)
            final psi = _readNum(data, [
              'feedPsi',
              'psi',
              'pressure',
              'pressurePsi',
              'dfPsi',
              'outputPsi',
              'livePsi',
            ]);
            if (psi != null) feedPsi = psi;

            final pc = _readInt(data, [
              'pumpCount',
              'pump',
              'pumps',
              'flowCount',
              'strokeCount',
            ]);
            if (pc != null) pumpCount = pc;

            final pa = _readBool(data, [
              'pumpActive',
              'flow',
              'flowOn',
              'pumpOn',
              'pumpState',
            ]);
            pumpActiveValid = pa != null;
            if (pa != null) pumpActive = pa;

            pressClosed = data['pressClosed'] == true;
            cycleOn = data['cycleOn'] == true;
            cycleOver = data['cycleOver'] == true;

            // DS live
            ds1StartFeedPressure = _readInt(data, [
                  'startFeedPressure',
                  'DS1',
                ]) ??
                ds1StartFeedPressure;

            ds2FinalPressurePsi = _readInt(data, [
                  'finalPressurePsi',
                  'DS2',
                ]) ??
                ds2FinalPressurePsi;

            ds3FeedPressureInc = _readInt(data, [
                  'feedPressureIncrement',
                  'DS3',
                ]) ??
                ds3FeedPressureInc;

            ds4StrokeTimer = _readInt(data, [
                  'strokeCounterTimer',
                  'DS4',
                ]) ??
                ds4StrokeTimer;

            ds5FinalTimer = _readInt(data, [
                  'finalPressureTimer',
                  'DS5',
                ]) ??
                ds5FinalTimer;

            // ✅ Only sync editable DS from live when not editing + not sending
            if (!dsDirty && !dsSending) {
              eDS1 = ds1StartFeedPressure.clamp(0, 100);
              eDS2 = ds2FinalPressurePsi.clamp(0, 100);
              eDS3 = ds3FeedPressureInc.clamp(0, 100);
              eDS4 = ds4StrokeTimer;
              eDS5 = ds5FinalTimer;
            }

            _scheduleUi();
          },
          onError: (_) {
            deviceConnected = false;
            _scheduleReconnect();
            _scheduleUi();
          },
          onDone: () {
            deviceConnected = false;
            _scheduleReconnect();
            _scheduleUi();
          },
        );
      } catch (_) {
        deviceConnected = false;
        _scheduleReconnect();
        _scheduleUi();
      }
    }();
  }

  void _scheduleReconnect() {
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(const Duration(seconds: 2), _connect);
  }

  void _send(Map<String, dynamic> obj) {
    final ch = _channel;
    if (ch == null) return;
    try {
      ch.sink.add(jsonEncode(obj));
    } catch (_) {}
  }

  void _start() {
    _hapticLight();
    _send({"cmd": "start"});
    _log("Start pressed");
  }

  void _stop() {
    _hapticLight();
    _send({"cmd": "stop"});
    _log("Stop pressed");
  }

  void _sendDS() {
    _hapticLight();
    dsDirty = true;
    dsSending = true;

    // Ensure capped values before sending
    final s1 = eDS1.clamp(0, 100);
    final s2 = eDS2.clamp(0, 100);
    final s3 = eDS3.clamp(0, 100); // non-negative cap

    eDS1 = s1;
    eDS2 = s2;
    eDS3 = s3;

    _send({
      "set": {"DS1": eDS1, "DS2": eDS2, "DS3": eDS3, "DS4": eDS4, "DS5": eDS5}
    });

    // If ACK never arrives, stop "Sending…" so UI stays usable
    _dsWriteTimeout?.cancel();
    _dsWriteTimeout = Timer(const Duration(milliseconds: 1800), () {
      dsSending = false;
      _scheduleUi();
    });

    _log("Sent DS1–DS5");
    setState(() {});
  }

  void _resetEditsToLive() {
    _hapticLight();
    eDS1 = ds1StartFeedPressure.clamp(0, 100);
    eDS2 = ds2FinalPressurePsi.clamp(0, 100);
    eDS3 = ds3FeedPressureInc.clamp(0, 100);
    eDS4 = ds4StrokeTimer;
    eDS5 = ds5FinalTimer;
    dsDirty = false;
    dsSending = false;
    setState(() {});
  }

  void _log(String label) {
    logs.insert(0, {
      "time": DateTime.now(),
      "label": label,
      "psi": feedPsi,
      "pump": pumpCount,
    });
    if (logs.length > 150) logs.removeLast();
  }

  @override
  Widget build(BuildContext context) {
    final pages = [_home(), _menu(), _connection(), _logs()];

    return Scaffold(
      appBar: AppBar(
        title: Text(deviceName),
        centerTitle: true,
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: _pill(
              label: connectedFresh ? 'Connected' : 'Disconnected',
              ok: connectedFresh,
            ),
          ),
        ],
      ),
      body: IndexedStack(index: tab, children: pages),
      bottomNavigationBar: NavigationBar(
        selectedIndex: tab,
        onDestinationSelected: (i) => setState(() => tab = i),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.home_outlined), label: 'Home'),
          NavigationDestination(icon: Icon(Icons.tune), label: 'Menu'),
          NavigationDestination(icon: Icon(Icons.wifi), label: 'Connection'),
          NavigationDestination(icon: Icon(Icons.list_alt), label: 'Logs'),
        ],
      ),
    );
  }

  // ===================== HOME =====================
  Widget _home() {
    final ratio = (feedPsi / 100.0).clamp(0.0, 1.0);

    return SafeArea(
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _card(
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    children: [
                      _bigNumber('Feed PSI', feedPsi.toStringAsFixed(2)),
                      const SizedBox(height: 8),
                      _bigNumber('Pump Count', '$pumpCount'),
                    ],
                  ),
                ),
                const SizedBox(width: 14),
                SizedBox(
                  width: 76,
                  height: 240,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(20),
                    child: Stack(
                      alignment: Alignment.bottomCenter,
                      children: [
                        Container(color: Colors.white.withOpacity(0.06)),
                        AnimatedFractionallySizedBox(
                          duration: const Duration(milliseconds: 220),
                          curve: Curves.easeOutCubic,
                          heightFactor: ratio,
                          child: Container(
                            decoration: const BoxDecoration(
                              gradient: LinearGradient(
                                begin: Alignment.bottomCenter,
                                end: Alignment.topCenter,
                                colors: [Color(0xFF6D5EF6), Color(0xFF22D3EE)],
                              ),
                            ),
                          ),
                        ),
                        Positioned(
                          top: 10,
                          left: 0,
                          right: 0,
                          child: Column(
                            children: [
                              Text(
                                '${(ratio * 100).round()}%',
                                style: TextStyle(
                                  fontWeight: FontWeight.w800,
                                  color: Colors.white.withOpacity(0.85),
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                '0–100',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: Colors.white.withOpacity(0.55),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          _card(
            child: Wrap(
              spacing: 10,
              runSpacing: 10,
              alignment: WrapAlignment.center,
              children: [
                _pill(label: 'Press Closed', ok: pressClosed),
                _pill(label: 'Cycle On', ok: cycleOn),
                _pill(label: 'Cycle Over', ok: cycleOver),
                if (pumpActiveValid) _pill(label: 'Pump', ok: pumpActive),
              ],
            ),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: FilledButton(
                  onPressed: connectedFresh ? _start : null,
                  child: const Text('Start'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: OutlinedButton(
                  onPressed: connectedFresh ? _stop : null,
                  child: const Text('Stop'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // ===================== MENU =====================
  Widget _menu() {
    // Disable steppers while sending so values can’t change mid-write.
    final stepperEnabled = !dsSending;

    return SafeArea(
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _card(
            child: Column(
              children: [
                _stepperRow(
                  title: 'Starting Feed Pressure (0–100)',
                  value: eDS1,
                  enabled: stepperEnabled,
                  onMinus: () => setState(() {
                    _hapticLight();
                    dsDirty = true;
                    eDS1 = (eDS1 - 1).clamp(0, 100);
                  }),
                  onPlus: () => setState(() {
                    _hapticLight();
                    dsDirty = true;
                    eDS1 = (eDS1 + 1).clamp(0, 100);
                  }),
                ),
                _divider(),
                _stepperRow(
                  title: 'Final Pressure PSI (0–100)',
                  value: eDS2,
                  enabled: stepperEnabled,
                  onMinus: () => setState(() {
                    _hapticLight();
                    dsDirty = true;
                    eDS2 = (eDS2 - 1).clamp(0, 100);
                  }),
                  onPlus: () => setState(() {
                    _hapticLight();
                    dsDirty = true;
                    eDS2 = (eDS2 + 1).clamp(0, 100);
                  }),
                ),
                _divider(),
                _stepperRow(
                  title: 'Feed Pressure Increase (0–100)',
                  value: eDS3,
                  enabled: stepperEnabled,
                  onMinus: () => setState(() {
                    _hapticLight();
                    dsDirty = true;
                    eDS3 = (eDS3 - 1).clamp(0, 100);
                  }),
                  onPlus: () => setState(() {
                    _hapticLight();
                    dsDirty = true;
                    eDS3 = (eDS3 + 1).clamp(0, 100);
                  }),
                ),
                _divider(),
                _stepperRow(
                  title: 'Stroke Counter Timer',
                  value: eDS4,
                  enabled: stepperEnabled,
                  onMinus: () => setState(() {
                    _hapticLight();
                    dsDirty = true;
                    eDS4 = (eDS4 - 1).clamp(0, 5000);
                  }),
                  onPlus: () => setState(() {
                    _hapticLight();
                    dsDirty = true;
                    eDS4 = (eDS4 + 1).clamp(0, 5000);
                  }),
                ),
                _divider(),
                _stepperRow(
                  title: 'Final Pressure Timer',
                  value: eDS5,
                  enabled: stepperEnabled,
                  onMinus: () => setState(() {
                    _hapticLight();
                    dsDirty = true;
                    eDS5 = (eDS5 - 1).clamp(0, 5000);
                  }),
                  onPlus: () => setState(() {
                    _hapticLight();
                    dsDirty = true;
                    eDS5 = (eDS5 + 1).clamp(0, 5000);
                  }),
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: FilledButton(
                  onPressed: connectedFresh && !dsSending ? _sendDS : null,
                  child: Text(
                    dsSending
                        ? 'Sending…'
                        : (dsDirty ? 'Send Changes' : 'Send DS1–DS5'),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: OutlinedButton(
                  onPressed: (dsDirty || dsSending) ? _resetEditsToLive : null,
                  child: const Text('Reset to Live'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          _card(
            child: Text(
              'Edits: ${dsDirty ? "UNSENT" : "SYNCED"}'
              '   •   Last ACK: $lastAckLabel • ${lastAckOk ? "OK" : "ERR"}'
              '${lastAckErr != 0 ? " ($lastAckErr)" : ""}'
              '${lastAckAt != null ? " • ${lastAckAt!.toLocal().toString().split(".").first}" : ""}',
              style: TextStyle(color: Colors.white.withOpacity(0.8)),
            ),
          ),
        ],
      ),
    );
  }

  // ===================== CONNECTION =====================
  Widget _connection() {
    return SafeArea(
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _card(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Status',
                    style:
                        TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
                const SizedBox(height: 10),
                _pill(label: 'Connected to "$deviceName"', ok: connectedFresh),
                const SizedBox(height: 10),
                _pill(
                  label:
                      'Connected to Wi-Fi: "${wifiSsid.isEmpty ? "—" : wifiSsid}"',
                  ok: staConnected,
                ),
                const SizedBox(height: 10),
                Text(
                  'Device IP: ${ip.isEmpty ? "—" : ip}   •   AP Mode: ${apMode ? "ON" : "OFF"}',
                  style: TextStyle(color: Colors.white.withOpacity(0.75)),
                ),
                const SizedBox(height: 10),
                Text(
                  'Last message: ${_lastMessageAt == null ? "—" : _lastMessageAt!.toLocal().toString().split(".").first}',
                  style: TextStyle(color: Colors.white.withOpacity(0.6)),
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          _card(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Health',
                    style:
                        TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: [
                    _pill(label: 'DS ${dsOk ? "OK" : "BAD"}', ok: dsOk),
                    _pill(label: 'X ${xOk ? "OK" : "BAD"}', ok: xOk),
                    _pill(label: 'DF3 ${dfOk ? "OK" : "BAD"}', ok: dfOk),
                    _pill(
                        label: 'Float ${dfValid ? "Valid" : "N/A"}',
                        ok: dfValid),
                  ],
                ),
                const SizedBox(height: 10),
                Text('errDS=$errDS • errX=$errX • errDF=$errDF',
                    style: TextStyle(color: Colors.white.withOpacity(0.75))),
              ],
            ),
          ),
          const SizedBox(height: 14),
          _card(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Connect Target',
                    style:
                        TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _hostCtl,
                        decoration: const InputDecoration(
                          labelText: 'ESP32 IP',
                          hintText: '192.168.x.x',
                          border: OutlineInputBorder(),
                        ),
                        onChanged: (v) => wsHost = v.trim(),
                      ),
                    ),
                    const SizedBox(width: 10),
                    SizedBox(
                      width: 110,
                      child: TextField(
                        controller: _portCtl,
                        decoration: const InputDecoration(
                          labelText: 'Port',
                          border: OutlineInputBorder(),
                        ),
                        keyboardType: TextInputType.number,
                        onChanged: (v) =>
                            wsPort = int.tryParse(v.trim()) ?? wsPort,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: FilledButton(
                        onPressed: () {
                          _hapticLight();
                          _hostCtl.text = wsHost;
                          _portCtl.text = wsPort.toString();
                          _connect();
                        },
                        child: Text('Connect to $wsUrl'),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: [
                    OutlinedButton.icon(
                      onPressed: () {
                        _hapticLight();
                        wsHost = '192.168.4.1';
                        wsPort = 8080;
                        _hostCtl.text = wsHost;
                        _portCtl.text = wsPort.toString();
                        _connect();
                        _toast('Switched to AP default (192.168.4.1)');
                      },
                      icon: const Icon(Icons.router),
                      label: const Text('AP Default'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ===================== LOGS =====================
  Widget _logs() {
    if (logs.isEmpty) return const Center(child: Text('No logs yet.'));
    return SafeArea(
      child: ListView.separated(
        padding: const EdgeInsets.all(16),
        itemCount: logs.length,
        separatorBuilder: (_, __) => const SizedBox(height: 10),
        itemBuilder: (context, i) {
          final l = logs[i];
          final t =
              (l["time"] as DateTime).toLocal().toString().split(".").first;

          final psi = l["psi"];
          final pump = l["pump"];
          final psiVal =
              (psi is num) ? psi.toDouble() : double.tryParse('$psi') ?? 0.0;
          final pumpVal =
              (pump is num) ? pump.toInt() : int.tryParse('$pump') ?? 0;

          return _card(
            child: ListTile(
              title: Text('$t — ${l["label"]}'),
              subtitle: Text(
                'PSI: ${psiVal.toStringAsFixed(2)} • Pump: $pumpVal',
              ),
            ),
          );
        },
      ),
    );
  }

  // ===================== UI HELPERS =====================
  Widget _card({required Widget child}) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.06),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: Colors.white.withOpacity(0.08)),
      ),
      padding: const EdgeInsets.all(14),
      child: child,
    );
  }

  Widget _bigNumber(String label, String value) {
    return Column(
      children: [
        Text(label, style: TextStyle(color: Colors.white.withOpacity(0.65))),
        const SizedBox(height: 6),
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 180),
          switchInCurve: Curves.easeOut,
          switchOutCurve: Curves.easeIn,
          transitionBuilder: (child, anim) =>
              FadeTransition(opacity: anim, child: child),
          child: Text(
            value,
            key: ValueKey('$label:$value'),
            style: const TextStyle(fontSize: 34, fontWeight: FontWeight.w800),
          ),
        ),
      ],
    );
  }

  Widget _pill({required String label, required bool ok}) {
    final c = ok ? Colors.greenAccent : Colors.redAccent;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(999),
        color: c.withOpacity(0.12),
        border: Border.all(color: c.withOpacity(0.35)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(color: c, shape: BoxShape.circle),
          ),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              label,
              style: TextStyle(fontWeight: FontWeight.w700, color: c),
            ),
          ),
        ],
      ),
    );
  }

  Widget _divider() => Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Divider(color: Colors.white.withOpacity(0.10), height: 1),
      );

  Widget _stepperRow({
    required String title,
    required int value,
    required bool enabled,
    required VoidCallback onMinus,
    required VoidCallback onPlus,
  }) {
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title,
                  style: const TextStyle(
                      fontSize: 16, fontWeight: FontWeight.w700)),
              const SizedBox(height: 6),
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 160),
                transitionBuilder: (child, anim) =>
                    FadeTransition(opacity: anim, child: child),
                child: Text(
                  '$value',
                  key: ValueKey('$title:$value'),
                  style:
                      const TextStyle(fontSize: 26, fontWeight: FontWeight.w800),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 8),
        RepeatIconButton(icon: Icons.remove, enabled: enabled, onStep: onMinus),
        const SizedBox(width: 8),
        RepeatIconButton(icon: Icons.add, enabled: enabled, onStep: onPlus),
      ],
    );
  }
}

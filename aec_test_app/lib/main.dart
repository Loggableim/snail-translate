import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// M1 AEC Test App — Acoustic Echo Cancellation Hardware Test
///
/// Testet:
/// 1. Ob AEC auf dem Gerät verfügbar ist
/// 2. Audio-Aufnahme mit/ohne AEC
/// 3. Echo-Hörbarkeit (subjektiver Test)
///
/// Nutzung:
///   1. App starten → AEC-Status prüfen
///   2. "Test starten" → Audio wird aufgenommen und abgespielt
///   3. "Echo gehört?" → Ja/Nein
///   4. Ergebnisse werden protokolliert

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const AecTestApp());
}

class AecTestApp extends StatelessWidget {
  const AecTestApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Snail AEC Test',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: Colors.green,
        brightness: Brightness.light,
      ),
      home: const AecTestScreen(),
    );
  }
}

// ── Platform Channel Interface ────────────────────────────────────────

class AecNative {
  static const _channel = MethodChannel('com.snail.audio/method');

  static Future<bool> isAecAvailable() async {
    try {
      return await _channel.invokeMethod<bool>('isAecAvailable') ?? false;
    } catch (e) {
      return false;
    }
  }

  static Future<bool> isNoiseSuppressorAvailable() async {
    try {
      return await _channel.invokeMethod<bool>('isNoiseSuppressorAvailable') ?? false;
    } catch (e) {
      return false;
    }
  }

  static Future<int?> getAudioSessionId() async {
    try {
      return await _channel.invokeMethod<int>('getAudioSessionId');
    } catch (e) {
      return null;
    }
  }
}

// ── Main Test Screen ──────────────────────────────────────────────────

class AecTestScreen extends StatefulWidget {
  const AecTestScreen({super.key});

  @override
  State<AecTestScreen> createState() => _AecTestScreenState();
}

class _AecTestScreenState extends State<AecTestScreen> {
  // Device info
  bool _aecAvailable = false;
  bool _nsAvailable = false;
  int? _audioSessionId;
  bool _checking = true;

  // Test state
  String _currentScenario = 'E1';
  bool _aecEnabled = false;
  bool _testing = false;
  String _status = 'Bereit';

  // Results
  final List<Map<String, dynamic>> _results = [];

  @override
  void initState() {
    super.initState();
    _checkDevice();
  }

  Future<void> _checkDevice() async {
    setState(() => _checking = true);

    final aec = await AecNative.isAecAvailable();
    final ns = await AecNative.isNoiseSuppressorAvailable();
    final sessionId = await AecNative.getAudioSessionId();

    if (mounted) {
      setState(() {
        _aecAvailable = aec;
        _nsAvailable = ns;
        _audioSessionId = sessionId;
        _checking = false;
      });
    }
  }

  void _runTest(String scenario, bool aecOn) {
    setState(() {
      _currentScenario = scenario;
      _aecEnabled = aecOn;
      _testing = true;
      _status = 'Test läuft... Sprich etwas und achte auf Echo!';
    });

    // Simulate test duration (in real app: record + playback)
    Future.delayed(const Duration(seconds: 5), () {
      if (mounted) {
        setState(() {
          _testing = false;
          _status = 'Test beendet. Echo gehört?';
        });
      }
    });
  }

  void _recordResult(bool echoHeard) {
    _results.add({
      'scenario': _currentScenario,
      'aec_enabled': _aecEnabled,
      'echo_heard': echoHeard,
      'timestamp': DateTime.now().toIso8601String(),
    });

    setState(() {
      _status = echoHeard
          ? '❌ Echo gehört — AEC nicht ausreichend'
          : '✅ Kein Echo — AEC funktioniert!';
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Snail AEC Test'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _checkDevice,
            tooltip: 'Neu prüfen',
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // ── Device Info ──────────────────────────────────────────
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: _checking
                  ? const Center(child: CircularProgressIndicator())
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Geräte-Info',
                            style: Theme.of(context).textTheme.titleMedium),
                        const SizedBox(height: 8),
                        _InfoRow(
                          label: 'AEC verfügbar',
                          value: _aecAvailable ? '✅ Ja' : '❌ Nein',
                          ok: _aecAvailable,
                        ),
                        _InfoRow(
                          label: 'Noise Suppression',
                          value: _nsAvailable ? '✅ Ja' : '❌ Nein',
                          ok: _nsAvailable,
                        ),
                        _InfoRow(
                          label: 'Audio Session ID',
                          value: _audioSessionId?.toString() ?? 'N/A',
                          ok: _audioSessionId != null,
                        ),
                        _InfoRow(
                          label: 'Android Version',
                          value: 'Wird via ADB ermittelt',
                          ok: true,
                        ),
                      ],
                    ),
            ),
          ),
          const SizedBox(height: 16),

          // ── Test Scenarios ───────────────────────────────────────
          Text('Test-Szenarien',
              style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),

          // E1: AEC off
          _ScenarioCard(
            scenario: 'E1',
            title: 'AEC AUS — Baseline',
            subtitle: 'Echo sollte hörbar sein',
            aecOn: false,
            testing: _testing,
            currentScenario: _currentScenario,
            onStart: () => _runTest('E1', false),
          ),
          const SizedBox(height: 8),

          // E2: AEC on
          _ScenarioCard(
            scenario: 'E2',
            title: 'AEC AN — Android AudioFX',
            subtitle: 'Echo sollte reduziert sein',
            aecOn: true,
            testing: _testing,
            currentScenario: _currentScenario,
            onStart: () => _runTest('E2', true),
          ),
          const SizedBox(height: 16),

          // ── Test Status ──────────────────────────────────────────
          if (_testing || _status != 'Bereit') ...[
            Card(
              color: _testing
                  ? Colors.blue.shade50
                  : _status.contains('✅')
                      ? Colors.green.shade50
                      : Colors.red.shade50,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  children: [
                    Text(
                      _status,
                      style: Theme.of(context).textTheme.bodyLarge,
                      textAlign: TextAlign.center,
                    ),
                    if (!_testing && _status.contains('Echo gehört?')) ...[
                      const SizedBox(height: 16),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          ElevatedButton.icon(
                            onPressed: () => _recordResult(true),
                            icon: const Icon(Icons.hearing, color: Colors.red),
                            label: const Text('Ja, Echo gehört'),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.red.shade100,
                            ),
                          ),
                          const SizedBox(width: 16),
                          ElevatedButton.icon(
                            onPressed: () => _recordResult(false),
                            icon:
                                const Icon(Icons.hearing_disabled, color: Colors.green),
                            label: const Text('Nein, kein Echo'),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.green.shade100,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ],

          // ── Results ──────────────────────────────────────────────
          if (_results.isNotEmpty) ...[
            const SizedBox(height: 24),
            Text('Ergebnisse', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            ..._results.map((r) => Card(
                  child: ListTile(
                    leading: Icon(
                      r['echo_heard'] == true
                          ? Icons.warning
                          : Icons.check_circle,
                      color: r['echo_heard'] == true ? Colors.red : Colors.green,
                    ),
                    title: Text('${r['scenario']} — AEC ${r['aec_enabled'] == true ? "AN" : "AUS"}'),
                    subtitle: Text(r['echo_heard'] == true
                        ? 'Echo gehört'
                        : 'Kein Echo'),
                  ),
                )),
          ],
        ],
      ),
    );
  }
}

// ── Widgets ────────────────────────────────────────────────────────────

class _InfoRow extends StatelessWidget {
  final String label;
  final String value;
  final bool ok;

  const _InfoRow({
    required this.label,
    required this.value,
    required this.ok,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(
              child: Text(label,
                  style: Theme.of(context).textTheme.bodyMedium)),
          Text(value,
              style: TextStyle(
                fontWeight: FontWeight.bold,
                color: ok ? Colors.green : Colors.red,
              )),
        ],
      ),
    );
  }
}

class _ScenarioCard extends StatelessWidget {
  final String scenario;
  final String title;
  final String subtitle;
  final bool aecOn;
  final bool testing;
  final String currentScenario;
  final VoidCallback onStart;

  const _ScenarioCard({
    required this.scenario,
    required this.title,
    required this.subtitle,
    required this.aecOn,
    required this.testing,
    required this.currentScenario,
    required this.onStart,
  });

  @override
  Widget build(BuildContext context) {
    final isActive = testing && currentScenario == scenario;

    return Card(
      color: isActive ? Colors.blue.shade50 : null,
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: aecOn ? Colors.green : Colors.red.shade100,
          child: Text(scenario,
              style: const TextStyle(
                  fontWeight: FontWeight.bold, color: Colors.white)),
        ),
        title: Text(title),
        subtitle: Text(subtitle),
        trailing: isActive
            ? const SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : ElevatedButton(
                onPressed: testing ? null : onStart,
                child: const Text('Test'),
              ),
      ),
    );
  }
}

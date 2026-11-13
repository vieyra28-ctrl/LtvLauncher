import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';
import 'package:flauncher/flauncher_channel.dart';
import 'package:flauncher/models/weather_data.dart';
import 'package:flutter/widgets.dart';

class WeatherService extends ChangeNotifier with WidgetsBindingObserver {
  final FLauncherChannel _channel;
  StreamSubscription<dynamic>? _subscription;
  Timer? _refreshTimer;
  DateTime? _lastResumeCheck;
  String? _lastJson;

  WeatherData? _weatherData;
  bool _isBreezyInstalled = false;
  bool _initialized = false;

  // Built-in Open-Meteo fallback (Hermosillo) when Breezy Weather has no data.
  bool _weatherFromOpenMeteo = false;
  DateTime? _lastOpenMeteoFetch;

  bool get _isTest => Platform.environment.containsKey('FLUTTER_TEST');

  WeatherService(this._channel) {
    if (!_isTest) {
      WidgetsBinding.instance.addObserver(this);
    }
    _init();
  }

  WeatherData? get weatherData => _weatherData;
  bool get isBreezyInstalled => _isBreezyInstalled;
  bool get initialized => _initialized;
  bool get hasWeather => _weatherData != null;

  Future<void> _init() async {
    try {
      await _fetchLatest();

      _subscription = _channel.addWeatherChangedListener((event) {
        if (event is String && event.isNotEmpty) {
          _processWeatherJson(event);
        }
      });
      _startPeriodicTimer();
    } catch (e, stack) {
      developer.log("Error initializing WeatherService", error: e, stackTrace: stack);
    } finally {
      _initialized = true;
      notifyListeners();
    }
  }

  void _startPeriodicTimer() {
    _refreshTimer?.cancel();
    // 15-minute fallback timer in case a broadcast was missed while paused
    _refreshTimer = Timer.periodic(const Duration(minutes: 15), (_) => _fetchLatest());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused || state == AppLifecycleState.hidden) {
      _refreshTimer?.cancel();
      _refreshTimer = null;
    } else if (state == AppLifecycleState.resumed) {
      _checkWeatherOnResume();
      _startPeriodicTimer();
    }
  }

  Future<void> _checkWeatherOnResume() async {
    final now = DateTime.now();
    if (_lastResumeCheck != null && now.difference(_lastResumeCheck!).inSeconds < 60) {
      return;
    }
    _lastResumeCheck = now;
    await _fetchLatest();
  }

  Future<void> _fetchLatest() async {
    try {
      _isBreezyInstalled = await _channel.isBreezyWeatherInstalled();
      final latestJson = await _channel.getLatestWeatherData();
      if (latestJson != null && latestJson.isNotEmpty) {
        _processWeatherJson(latestJson);
      }
    } catch (e, stack) {
      developer.log("Failed to fetch latest weather data", error: e, stackTrace: stack);
    }

    // Built-in fallback: Open-Meteo for Hermosillo, only when Breezy has no
    // data. At most one small call every 30 minutes; on failure it shows
    // nothing and retries on the next cycle.
    if (_weatherData == null || _weatherFromOpenMeteo) {
      final now = DateTime.now();
      if (_lastOpenMeteoFetch == null ||
          now.difference(_lastOpenMeteoFetch!).inMinutes >= 30) {
        await _fetchOpenMeteo();
      }
    }
  }

  /// Fetches the current temperature in Hermosillo from Open-Meteo
  /// (free, no API key). A single small async request; failures are silent
  /// and never block the UI.
  Future<void> _fetchOpenMeteo() async {
    if (_isTest) return;
    _lastOpenMeteoFetch = DateTime.now();
    final client = HttpClient();
    try {
      client.connectionTimeout = const Duration(seconds: 10);
      final request = await client.getUrl(Uri.parse(
          'https://api.open-meteo.com/v1/forecast?latitude=29.07&longitude=-110.95&current=temperature_2m&timezone=America%2FHermosillo'));
      final response = await request.close().timeout(const Duration(seconds: 10));
      if (response.statusCode != 200) return;
      final body = await response.transform(utf8.decoder).join();
      final json = jsonDecode(body) as Map<String, dynamic>;
      final current = json['current'] as Map<String, dynamic>?;
      final temp = (current?['temperature_2m'] as num?)?.round();
      if (temp == null) return;
      // Don't overwrite Breezy data that arrived meanwhile.
      if (_weatherData != null && !_weatherFromOpenMeteo) return;
      _weatherData = WeatherData(
        currentTemp: temp,
        location: 'Hermosillo',
        timestamp: DateTime.now().millisecondsSinceEpoch ~/ 1000,
      );
      _weatherFromOpenMeteo = true;
      notifyListeners();
    } catch (e, stack) {
      // No internet or API error: show nothing, retry on the next cycle.
      developer.log("Open-Meteo fetch failed", error: e, stackTrace: stack);
    } finally {
      client.close();
    }
  }

  void _processWeatherJson(String jsonString) {
    if (jsonString == _lastJson && _weatherData != null) {
      return;
    }
    try {
      _weatherData = WeatherData.fromJsonString(jsonString);
      _lastJson = jsonString;
      _weatherFromOpenMeteo = false;
      notifyListeners();
    } catch (e, stack) {
      developer.log("Failed to parse weather JSON", error: e, stackTrace: stack);
    }
  }

  Future<bool> openBreezyWeather() async {
    try {
      return await _channel.openBreezyWeather();
    } catch (e) {
      return false;
    }
  }

  Future<void> refresh() async {
    await _fetchLatest();
    notifyListeners();
  }

  @override
  void dispose() {
    if (!_isTest) {
      WidgetsBinding.instance.removeObserver(this);
    }
    _refreshTimer?.cancel();
    _subscription?.cancel();
    super.dispose();
  }
}

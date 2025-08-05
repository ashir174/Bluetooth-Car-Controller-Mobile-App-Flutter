import 'dart:convert';
import 'dart:async';
import 'dart:typed_data';
import 'dart:math' as math;
import 'dart:collection';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_joystick/flutter_joystick.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setPreferredOrientations([
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ]).then((_) => runApp(MainScreen()));
}

class MainScreen extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Bluetooth Control',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(),
      home: JoyPad(),
    );
  }
}

class JoyPad extends StatefulWidget {
  @override
  State<JoyPad> createState() => _JoyPadState();
}

class _JoyPadState extends State<JoyPad> with TickerProviderStateMixin {
  final String targetDeviceName = "ESP32";
  BluetoothDevice? targetDevice;
  BluetoothCharacteristic? targetCharacteristic;

  bool isConnected = false;
  bool isLed1On = false;
  bool isLed2On = false;
  bool isHornOn = false;
  double sliderValue = 0.0;

  // Temperature management - synced with ESP32
  double temperature = 25.0; // Match ESP32 baseline
  double baselineTemp = 25.0; // Match ESP32 starting temperature
  Timer? _temperatureUpdateTimer;
  Timer? _hardwareRequestTimer;
  DateTime _lastHardwareUpdate = DateTime.now();
  bool _isReceivingHardwareData = false;

  // Temperature simulation for when hardware unavailable
  double _simulatedTemp = 25.0;
  double _tempTrend = 0.0;

  // Improved synchronization settings
  static const Duration _hardwareTimeout = Duration(seconds: 6); // Reduced timeout
  static const Duration _updateInterval = Duration(milliseconds: 500); // Faster UI updates
  static const Duration _hardwareRequestInterval = Duration(seconds: 3); // Reduced requests to match ESP32

  late AnimationController _blinkController;
  late AnimationController _hornController;
  late AnimationController _gaugeController;

  @override
  void initState() {
    super.initState();
    _initializeAnimations();
    _startTemperatureSystem();
    startScan();
  }

  void _initializeAnimations() {
    _blinkController = AnimationController(
      duration: const Duration(milliseconds: 400),
      vsync: this,
    )..repeat(reverse: true);

    _hornController = AnimationController(
      duration: const Duration(milliseconds: 100),
      vsync: this,
    );

    _gaugeController = AnimationController(
      duration: const Duration(milliseconds: 750),
      vsync: this,
    );

    _gaugeController.forward();
  }

  void _startTemperatureSystem() {
    print("🌡️ Starting temperature management system");

    // Main temperature update loop - runs continuously for smooth UI
    _temperatureUpdateTimer = Timer.periodic(_updateInterval, (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      _updateTemperature();
    });

    // Hardware request timer - synced with ESP32 sending frequency
    _startHardwareRequestTimer();
  }

  void _startHardwareRequestTimer() {
    _hardwareRequestTimer?.cancel();
    _hardwareRequestTimer = Timer.periodic(_hardwareRequestInterval, (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }

      if (isConnected && targetCharacteristic != null) {
        // Only request if we haven't received data recently
        if (!_isHardwareDataRecent()) {
          _requestTemperatureFromHardware();
        }
        _checkHardwareTimeout();
      }
    });
  }

  void _updateTemperature() {
    double newTemp;

    if (_isReceivingHardwareData && _isHardwareDataRecent()) {
      // Use hardware data when available and recent
      newTemp = temperature; // Keep current hardware value
    } else {
      // Generate simulated temperature matching ESP32 range
      newTemp = _generateSimulatedTemperature();
      _isReceivingHardwareData = false;
    }

    // Smooth temperature transitions for better UX
    if ((newTemp - temperature).abs() > 0.1) {
      setState(() {
        temperature = _smoothTemperatureTransition(temperature, newTemp);
      });
      _animateGauge();
    }
  }

  double _generateSimulatedTemperature() {
    // Match ESP32 temperature range exactly (20-34°C)
    double targetTemp = baselineTemp;

    // Add random variation to target
    if (math.Random().nextInt(50) == 0) {
      _tempTrend = (math.Random().nextDouble() - 0.5) * 1.0; // ±0.5°C trend
    }

    // Apply trend and small random variations
    targetTemp += _tempTrend;
    targetTemp += (math.Random().nextDouble() - 0.5) * 0.2; // ±0.1°C noise

    // Gradually decay trend
    _tempTrend *= 0.98;

    // Keep within ESP32 hardware range (20-34°C) - exact match
    targetTemp = targetTemp.clamp(20.0, 34.0);

    // Occasional variations within ESP32 range
    if (math.Random().nextInt(100) == 0) {
      targetTemp += (math.Random().nextDouble() - 0.5) * 4.0; // ±2°C spike
      targetTemp = targetTemp.clamp(20.0, 34.0);
    }

    return targetTemp;
  }

  double _smoothTemperatureTransition(double current, double target) {
    double diff = target - current;
    double maxChange = 0.15; // Slightly faster for better sync

    if (diff.abs() <= maxChange) {
      return target;
    } else {
      return current + (diff > 0 ? maxChange : -maxChange);
    }
  }

  void _requestTemperatureFromHardware() {
    if (isConnected && targetCharacteristic != null) {
      try {
        sendData("GET_TEMP");
        print("🔄 Temperature requested from ESP32");
      } catch (e) {
        print("❌ Error requesting temperature: $e");
      }
    }
  }

  void _checkHardwareTimeout() {
    if (_isReceivingHardwareData &&
        DateTime.now().difference(_lastHardwareUpdate) > _hardwareTimeout) {
      print("⏰ Hardware temperature timeout - switching to simulation");
      _isReceivingHardwareData = false;
    }
  }

  bool _isHardwareDataRecent() {
    return DateTime.now().difference(_lastHardwareUpdate) < _hardwareTimeout;
  }

  void _animateGauge() {
    if (_gaugeController.isCompleted || _gaugeController.isDismissed) {
      _gaugeController.reset();
      _gaugeController.forward();
    }
  }

  void _handleIncomingData(String data) {
    print("📨 Processing data: $data");

    if (data.startsWith("TEMP:")) {
      try {
        String tempString = data.substring(5).trim();
        double receivedTemp = double.parse(tempString);

        // Validate temperature range - ESP32 sends 20-34°C
        if (receivedTemp >= 15.0 && receivedTemp <= 40.0) {
          print("✅ Valid hardware temperature received: ${receivedTemp.toStringAsFixed(1)}°C");

          setState(() {
            temperature = receivedTemp;
            baselineTemp = receivedTemp; // Update baseline for simulation fallback
          });

          _isReceivingHardwareData = true;
          _lastHardwareUpdate = DateTime.now();
          _animateGauge();

          print("🌡️ Hardware temperature updated: ${receivedTemp.toStringAsFixed(1)}°C");
        } else {
          print("❌ Invalid temperature value received: $receivedTemp (out of range)");
        }
      } catch (e) {
        print("❌ Error parsing temperature: $e");
      }
    } else {
      print("📡 Other data received: $data");
    }
  }

  @override
  void dispose() {
    print("🧹 Disposing temperature system");
    _temperatureUpdateTimer?.cancel();
    _hardwareRequestTimer?.cancel();
    _blinkController.dispose();
    _hornController.dispose();
    _gaugeController.dispose();
    super.dispose();
  }

  void startScan() async {
    setState(() => isConnected = false);
    print("🔍 Starting BLE scan...");
    FlutterBluePlus.startScan(timeout: const Duration(seconds: 5));
    FlutterBluePlus.scanResults.listen((results) async {
      for (ScanResult r in results) {
        if (r.device.name.contains(targetDeviceName)) {
          print("📱 Found ESP32: ${r.device.name}");
          FlutterBluePlus.stopScan();
          await connectToDevice(r.device);
          break;
        }
      }
    });
  }

  Future<void> connectToDevice(BluetoothDevice device) async {
    try {
      print("🔌 Connecting to ESP32...");
      await device.connect();
      List<BluetoothService> services = await device.discoverServices();

      for (var service in services) {
        for (var c in service.characteristics) {
          if (c.properties.write) {
            setState(() {
              targetDevice = device;
              targetCharacteristic = c;
              isConnected = true;
            });

            // Set up notification listener
            if (c.properties.notify) {
              try {
                await c.setNotifyValue(true);
                c.value.listen((value) {
                  if (value.isNotEmpty) {
                    String data = String.fromCharCodes(value).trim();
                    _handleIncomingData(data);
                  }
                });
                print("🔔 Notifications enabled");
              } catch (e) {
                print("❌ Error enabling notifications: $e");
              }
            }

            sendData("CONNECTED");

            // Start hardware requests immediately after connection
            _startHardwareRequestTimer();

            // Request initial temperature after connection
            Future.delayed(Duration(milliseconds: 1000), () {
              if (mounted && isConnected) {
                print("🔄 Requesting initial temperature...");
                _requestTemperatureFromHardware();
              }
            });

            print("✅ Connected to ESP32 successfully");
            return;
          }
        }
      }
    } catch (e) {
      print("❌ Connection error: $e");
      setState(() {
        isConnected = false;
        targetDevice = null;
        targetCharacteristic = null;
        _isReceivingHardwareData = false;
      });
    }
  }

  void disconnect() async {
    if (targetDevice != null) {
      try {
        await targetDevice!.disconnect();
      } catch (e) {
        print("❌ Disconnect error: $e");
      }

      setState(() {
        targetDevice = null;
        targetCharacteristic = null;
        isConnected = false;
        _isReceivingHardwareData = false;
      });

      _hardwareRequestTimer?.cancel();
      print("🔌 Disconnected from ESP32");
    }
  }

  void sendData(String data) {
    if (targetCharacteristic != null && isConnected) {
      try {
        List<int> bytes = utf8.encode("$data\n");
        targetCharacteristic!.write(bytes, withoutResponse: false);
        print("📤 Sent: $data");
      } catch (e) {
        print("❌ Send error: $e");
      }
    }
  }

  void handleJoystick(double x, double y) {
    String direction;
    if (y < -0.5) {
      direction = "UP";
    } else if (y > 0.5) {
      direction = "DOWN";
    } else if (x < -0.5) {
      direction = "LEFT";
    } else if (x > 0.5) {
      direction = "RIGHT";
    } else {
      direction = "STOP";
    }
    sendData(direction);
  }

  Color _getTemperatureColor(double temp) {
    if (temp < 22) return Colors.blue[400]!;
    if (temp < 26) return Colors.cyan[400]!;
    if (temp < 30) return Colors.green[400]!;
    if (temp < 32) return Colors.orange[400]!;
    if (temp < 34) return Colors.red[400]!;
    return Colors.red[700]!;
  }

  String _getTemperatureStatus(double temp) {
    if (temp < 22) return "COLD";
    if (temp < 26) return "COOL";
    if (temp < 30) return "NORMAL";
    if (temp < 32) return "WARM";
    if (temp < 34) return "HOT";
    return "CRITICAL";
  }

  Widget buildTemperatureGauge() {
    return Container(
      width: 140,
      height: 140,
      child: Stack(
        alignment: Alignment.center,
        children: [
          // Background circle
          Container(
            width: 130,
            height: 130,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: Colors.grey[900],
              border: Border.all(color: Colors.grey[700]!, width: 2),
            ),
          ),
          // Temperature arc
          AnimatedBuilder(
            animation: _gaugeController,
            builder: (context, child) {
              return CustomPaint(
                size: Size(120, 120),
                painter: TemperatureGaugePainter(
                  temperature: temperature,
                  color: _getTemperatureColor(temperature),
                  animationValue: _gaugeController.value,
                ),
              );
            },
          ),
          // Center content
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                "${temperature.toStringAsFixed(1)}°C",
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: _getTemperatureColor(temperature),
                ),
              ),
              Text(
                _getTemperatureStatus(temperature),
                style: TextStyle(
                  fontSize: 8,
                  fontWeight: FontWeight.w500,
                  color: Colors.grey[400],
                ),
              ),
              // Status indicator
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 6,
                    height: 6,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: _isReceivingHardwareData
                          ? Colors.green[400]
                          : Colors.orange[400],
                    ),
                  ),
                  SizedBox(width: 4),
                  Text(
                    _isReceivingHardwareData ? "HW" : "SIM",
                    style: TextStyle(
                      fontSize: 6,
                      fontWeight: FontWeight.w600,
                      color: _isReceivingHardwareData
                          ? Colors.green[400]
                          : Colors.orange[400],
                    ),
                  ),
                ],
              ),
            ],
          ),
          // Temperature scale markers adjusted for 20-34°C range
          ...List.generate(5, (index) {
            double angle = -math.pi + (index * math.pi / 4);
            double markerRadius = 55;
            int tempValue = 20 + (index * 4); // 20, 24, 28, 32, 36
            return Positioned(
              left: 70 + markerRadius * math.cos(angle) - 8,
              top: 70 + markerRadius * math.sin(angle) - 8,
              child: Container(
                width: 16,
                height: 16,
                child: Center(
                  child: Text(
                    "$tempValue",
                    style: TextStyle(
                      fontSize: 8,
                      color: Colors.grey[500],
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ),
            );
          }),
        ],
      ),
    );
  }

  Widget buildLedSwitch(String label, bool isOn, void Function(bool) onChanged) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(label, style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w500)),
        const SizedBox(height: 2),
        Transform.scale(
          scale: 0.8,
          child: Switch(
            value: isOn,
            onChanged: onChanged,
            activeColor: const Color(0xFF4742C5),
            activeTrackColor: const Color(0xff308bd0),
            inactiveThumbColor: Colors.red,
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
        ),
      ],
    );
  }

  Widget buildConnectionIndicator() {
    return AnimatedBuilder(
      animation: _blinkController,
      builder: (_, __) => Container(
        width: 16,
        height: 16,
        margin: const EdgeInsets.symmetric(horizontal: 8),
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: isConnected
              ? Colors.green
              : _blinkController.value > 0.5
              ? Colors.red
              : Colors.red.withOpacity(0.2),
        ),
      ),
    );
  }

  Widget buildEnhancedHornButton() {
    return AnimatedBuilder(
      animation: _hornController,
      builder: (_, __) => Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(25),
          gradient: LinearGradient(
            colors: isHornOn ? [
              const Color(0xFF4742C5),
              const Color(0xff308bd0),
            ] : [
              Colors.red[400]!,
              Colors.red[600]!,
            ],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          boxShadow: [
            BoxShadow(
              color: isHornOn
                  ? const Color(0xff308bd0).withOpacity(0.4)
                  : Colors.red.withOpacity(0.4),
              blurRadius: isHornOn ? 12 : 8,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Transform.scale(
          scale: 1.0 + (_hornController.value * 0.15),
          child: ElevatedButton.icon(
            onPressed: () {
              _hornController.forward().then((_) => _hornController.reverse());
              setState(() => isHornOn = !isHornOn);
              sendData(isHornOn ? "HORN ON" : "HORN OFF");
            },
            icon: Icon(
              isHornOn ? Icons.campaign : Icons.campaign_outlined,
              size: 18,
              color: _hornController.value > 0.5 ? Colors.yellow[200] : Colors.white,
            ),
            label: Text(
              isHornOn ? "ON" : "HORN",
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.bold,
                color: Colors.white,
              ),
            ),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.transparent,
              shadowColor: Colors.transparent,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              minimumSize: const Size(80, 36),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(25),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget buildEnhancedSlider() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Text("Speed", style: TextStyle(fontSize: 11)),
        SizedBox(
          width: 120,
          child: SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 3,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 8),
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
              activeTrackColor: const Color(0xff308bd0),
              inactiveTrackColor: Colors.grey[700],
              thumbColor: const Color(0xff308bd0),
              valueIndicatorColor: const Color(0xff308bd0),
              valueIndicatorTextStyle: const TextStyle(fontSize: 12, color: Colors.white),
            ),
            child: Slider(
              min: 0,
              max: 100,
              divisions: 100,
              value: sliderValue,
              label: sliderValue.toInt().toString(),
              onChanged: (value) {
                setState(() => sliderValue = value);
                sendData("SLIDER ${value.toInt()}");
              },
            ),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        toolbarHeight: 60,
        backgroundColor: Colors.grey[900],
        elevation: 2,
        leading: buildConnectionIndicator(),
        title: Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            buildLedSwitch("Front Light", isLed1On, (value) {
              setState(() => isLed1On = value);
              sendData(value ? "Front Light ON" : "Front Light OFF");
            }),
            buildLedSwitch("Back Light", isLed2On, (value) {
              setState(() => isLed2On = value);
              sendData(value ? "Back Light ON" : "Back Light OFF");
            }),
            buildEnhancedHornButton(),
            buildEnhancedSlider(),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh, size: 20),
            onPressed: startScan,
            tooltip: 'Scan',
          ),
          IconButton(
            icon: Icon(
              isConnected ? Icons.bluetooth_connected : Icons.bluetooth_disabled,
              size: 20,
            ),
            onPressed: isConnected ? disconnect : startScan,
            tooltip: isConnected ? 'Disconnect' : 'Connect',
          ),
        ],
      ),
      body: Stack(
        children: [
          Center(
            child: Padding(
              padding: const EdgeInsets.all(20.0),
              child: Joystick(
                mode: JoystickMode.all,
                listener: (details) => handleJoystick(details.x, details.y),
              ),
            ),
          ),
          Positioned(
            left: 30,
            top: 0,
            bottom: 0,
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    "ESP32-BLE",
                    style: TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.bold,
                      foreground: Paint()
                        ..shader = LinearGradient(
                          colors: [Color(0xff308bd0), Color(0xFF4742C5),],
                        ).createShader(Rect.fromLTWH(0.0, 0.0, 200.0, 70.0)),
                    ),
                  ),
                  Text(
                    "App",
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w500,
                      foreground: Paint()
                        ..shader = LinearGradient(
                          colors: [Color(0xff308bd0), Color(0xFF4742C5),],
                        ).createShader(Rect.fromLTWH(0.0, 0.0, 200.0, 70.0)),
                    ),
                  ),
                ],
              ),
            ),
          ),
          Positioned(
            right: 30,
            top: 0,
            bottom: 0,
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    "Temperature",
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                      color: Colors.grey[300],
                    ),
                  ),
                  SizedBox(height: 8),
                  buildTemperatureGauge(),
                  SizedBox(height: 8),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class TemperatureGaugePainter extends CustomPainter {
  final double temperature;
  final Color color;
  final double animationValue;

  TemperatureGaugePainter({
    required this.temperature,
    required this.color,
    required this.animationValue,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2 - 10;

    // Background arc
    final backgroundPaint = Paint()
      ..color = Colors.grey[800]!
      ..style = PaintingStyle.stroke
      ..strokeWidth = 8
      ..strokeCap = StrokeCap.round;

    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      -math.pi,
      math.pi,
      false,
      backgroundPaint,
    );

    // Temperature arc
    final tempPaint = Paint()
      ..shader = LinearGradient(
        colors: [
          color.withOpacity(0.3),
          color,
          color.withOpacity(0.8),
        ],
        stops: [0.0, 0.5, 1.0],
      ).createShader(Rect.fromCircle(center: center, radius: radius))
      ..style = PaintingStyle.stroke
      ..strokeWidth = 8
      ..strokeCap = StrokeCap.round;

    // Calculate sweep angle based on temperature (20-34°C range - matches ESP32)
    double normalizedTemp = ((temperature.clamp(20, 34) - 20) / 14); // 14°C range
    double sweepAngle = math.pi * normalizedTemp * animationValue;

    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      -math.pi,
      sweepAngle,
      false,
      tempPaint,
    );

    // Draw needle
    final needleAngle = -math.pi + (math.pi * normalizedTemp * animationValue);
    final needleLength = radius - 15;
    final needleEnd = Offset(
      center.dx + needleLength * math.cos(needleAngle),
      center.dy + needleLength * math.sin(needleAngle),
    );

    final needlePaint = Paint()
      ..color = color
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round;

    canvas.drawLine(center, needleEnd, needlePaint);

    // Draw center dot
    final centerPaint = Paint()
      ..color = color
      ..style = PaintingStyle.fill;

    canvas.drawCircle(center, 4, centerPaint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}
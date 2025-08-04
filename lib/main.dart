import 'dart:convert';
import 'dart:async';
import 'dart:typed_data';
import 'dart:math' as math;
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
  double temperature = 25.0; // Current temperature in Celsius
  Timer? _temperatureTimer;

  late AnimationController _blinkController;
  late AnimationController _hornController;
  late AnimationController _gaugeController;

  @override
  void initState() {
    super.initState();
    _blinkController = AnimationController(
      duration: const Duration(milliseconds: 800),
      vsync: this,
    )..repeat(reverse: true);

    _hornController = AnimationController(
      duration: const Duration(milliseconds: 200),
      vsync: this,
    );

    _gaugeController = AnimationController(
      duration: const Duration(milliseconds: 1500),
      vsync: this,
    );

    startScan();
  }

  // Start temperature monitoring when ESP32 is connected
  void _startTemperatureMonitoring() {
    _temperatureTimer?.cancel();
    _temperatureTimer = Timer.periodic(Duration(minutes: 1), (timer) {
      if (isConnected && targetCharacteristic != null) {
        _requestTemperature();
      } else {
        timer.cancel();
      }
    });
    // Request temperature immediately when connected
    _requestTemperature();
  }

  // Stop temperature monitoring
  void _stopTemperatureMonitoring() {
    _temperatureTimer?.cancel();
    _temperatureTimer = null;
  }

  // Request temperature from ESP32
  void _requestTemperature() {
    if (isConnected && targetCharacteristic != null) {
      sendData("GET_TEMP");
    }
  }

  // Handle incoming data from ESP32
  void _handleIncomingData(String data) {
    if (data.startsWith("TEMP:")) {
      double receivedTemp = double.parse(data.substring(5));
      setState(() {
        temperature = receivedTemp;
      });
      _gaugeController.forward(from: 0);
      print("Received temperature: ${receivedTemp}°C");
    }
  }

  @override
  void dispose() {
    _temperatureTimer?.cancel();
    _blinkController.dispose();
    _hornController.dispose();
    _gaugeController.dispose();
    super.dispose();
  }

  void startScan() async {
    setState(() => isConnected = false);
    FlutterBluePlus.startScan(timeout: const Duration(seconds: 5));
    FlutterBluePlus.scanResults.listen((results) async {
      for (ScanResult r in results) {
        if (r.device.name.contains(targetDeviceName)) {
          FlutterBluePlus.stopScan();
          await connectToDevice(r.device);
          break;
        }
      }
    });
  }

  Future<void> connectToDevice(BluetoothDevice device) async {
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

          // Set up notification listener for temperature data
          if (c.properties.notify) {
            await c.setNotifyValue(true);
            c.value.listen((value) {
              String data = String.fromCharCodes(value);
              _handleIncomingTemp(data);
            });
          }

          sendData("CONNECTED");
          _startTemperatureMonitoring();
          return;
        }
      }
    }
  }

  // Handle incoming data from ESP32
  void _handleIncomingTemp(String data) {
    if (data.startsWith("TEMP:")) {
      double receivedTemp = double.parse(data.substring(5));
      setState(() {
        temperature = receivedTemp;
      });
      _gaugeController.forward(from: 0);
      print("Received temperature: ${receivedTemp}°C");
    }
  }

  void disconnect() async {
    _stopTemperatureMonitoring(); // Stop temperature monitoring
    if (targetDevice != null) {
      await targetDevice!.disconnect();
      setState(() {
        targetDevice = null;
        targetCharacteristic = null;
        isConnected = false;
      });
    }
  }

  void sendData(String data) {
    if (targetCharacteristic != null) {
      targetCharacteristic!.write(utf8.encode("$data\n"));
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
    if (temp < 25) return Colors.blue[400]!;        // Cold
    if (temp < 35) return Colors.cyan[400]!;        // Cool
    if (temp < 45) return Colors.green[400]!;       // Normal
    if (temp < 55) return Colors.orange[400]!;      // Warm
    if (temp < 65) return Colors.red[400]!;         // Hot
    return Colors.red[700]!;                        // Critical
  }

  String _getTemperatureStatus(double temp) {
    if (temp < 25) return "COLD";
    if (temp < 35) return "COOL";
    if (temp < 45) return "NORMAL";
    if (temp < 55) return "WARM";
    if (temp < 65) return "HOT";
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
          CustomPaint(
            size: Size(120, 120),
            painter: TemperatureGaugePainter(
              temperature: temperature,
              color: _getTemperatureColor(temperature),
              animation: _gaugeController,
            ),
          ),
          // Center content
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                "${temperature.toInt()}°C",
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
            ],
          ),
          // Temperature scale markers (20°C to 70°C)
          ...List.generate(6, (index) {
            double angle = -math.pi + (index * math.pi / 5);
            double markerRadius = 55;
            int tempValue = 20 + (index * 10); // 20, 30, 40, 50, 60, 70
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
          // Existing centered joystick
          Center(
            child: Padding(
              padding: const EdgeInsets.all(20.0),
              child: Joystick(
                mode: JoystickMode.all,
                listener: (details) => handleJoystick(details.x, details.y),
              ),
            ),
          ),
          // Existing text on the left
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
          // New temperature gauge on the right
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
  final AnimationController animation;

  TemperatureGaugePainter({
    required this.temperature,
    required this.color,
    required this.animation,
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

    // Calculate sweep angle based on temperature (20-70°C range)
    double normalizedTemp = ((temperature.clamp(20, 70) - 20) / 50);
    double sweepAngle = math.pi * normalizedTemp * animation.value;

    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      -math.pi,
      sweepAngle,
      false,
      tempPaint,
    );

    // Draw needle
    final needleAngle = -math.pi + (math.pi * normalizedTemp * animation.value);
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
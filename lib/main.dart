import 'dart:convert';
import 'dart:typed_data';
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

  late AnimationController _blinkController;
  late AnimationController _hornController;

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

    startScan();
  }

  @override
  void dispose() {
    _blinkController.dispose();
    _hornController.dispose();
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
          sendData("CONNECTED");
          return;
        }
      }
    }
  }

  void disconnect() async {
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
          // New text on the left
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
        ],
      ),
    );
  }
}
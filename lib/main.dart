import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:frame_vision_gemini/text_pagination.dart';
import 'package:google_generative_ai/google_generative_ai.dart';
import 'package:logging/logging.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simple_frame_app/frame_vision_app.dart';
import 'package:simple_frame_app/simple_frame_app.dart';
import 'package:simple_frame_app/tx/plain_text.dart';

void main() => runApp(const MainApp());

final _log = Logger("MainApp");

class MainApp extends StatefulWidget {
  const MainApp({super.key});

  @override
  MainAppState createState() => MainAppState();
}

class MainAppState extends State<MainApp> with SimpleFrameAppState, FrameVisionAppState {
  GenerativeModel? _model;
  String _apiKey = '';
  String _prompt = '';
  final TextEditingController _apiKeyTextFieldController = TextEditingController();
  final TextEditingController _promptTextFieldController = TextEditingController();

  Image? _image;
  Uint8List? _uprightImageBytes;
  ImageMetadata? _imageMeta;
  bool _processing = false;
  bool _workflowRunning = false;   // Flag to track the workflow status

  final List<String> _responseTextList = [];
  final TextPagination _pagination = TextPagination();

  MainAppState() {
    Logger.root.level = Level.FINE;
    Logger.root.onRecord.listen((record) {
      debugPrint('${record.level.name}: ${record.time}: ${record.message}');
    });
  }

  @override
  void dispose() {
    _apiKeyTextFieldController.dispose();
    _promptTextFieldController.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    resolution = 720;
    asyncInit();
  }

  Future<void> asyncInit() async {
    await _loadApiKey();
    await _loadPrompt();
    tryScanAndConnectAndStart(andRun: true);
    _workflowRunning = true;
    _startWorkflow();
  }

  GenerativeModel _initModel() {
    return GenerativeModel(
      model: 'gemini-2.0-flash-exp',
      apiKey: _apiKey,
      safetySettings: [
        SafetySetting(HarmCategory.harassment, HarmBlockThreshold.none),
        SafetySetting(HarmCategory.hateSpeech, HarmBlockThreshold.none),
        SafetySetting(HarmCategory.dangerousContent, HarmBlockThreshold.none),
        SafetySetting(HarmCategory.sexuallyExplicit, HarmBlockThreshold.none),
      ]
    );
  }

  Future<void> _loadApiKey() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _apiKey = prefs.getString('api_key') ?? '';
      _apiKeyTextFieldController.text = _apiKey;
    });
    if (_apiKey != '') {
      _model = _initModel();
    }
  }

  Future<void> _saveApiKey() async {
    _apiKey = _apiKeyTextFieldController.text;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('api_key', _apiKey);
    _model = _initModel();
  }

  Future<void> _loadPrompt() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _prompt = prefs.getString('prompt') ?? '';
      _promptTextFieldController.text = _prompt;
    });
  }

  Future<void> _savePrompt() async {
    _prompt = _promptTextFieldController.text;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('prompt', _prompt);
  }

  @override
  Future<void> onRun() async {
    await frame!.sendMessage(
      TxPlainText(
        msgCode: 0x0a,
        text: '1-Tap: share image & response'
      )
    );
  }

  @override
  Future<void> onCancel() async {
    _responseTextList.clear();
    _pagination.clear();
    _workflowRunning = false; // Ensure workflow is stopped
  }

  @override
  Future<void> onTap(int taps) async {
    if (taps == 1 && _uprightImageBytes != null) {
      // Share the image and response text
      _shareImage(_uprightImageBytes, _responseTextList.join('\n'));
    }
  }

  /// This method starts and repeats the workflow
  Future<void> _startWorkflow() async {
    while (_workflowRunning) {
      _log.fine('Taking picture in 5 seconds...');
      await Future.delayed(Duration(seconds: 5)); // Wait 5 seconds
      if (!_workflowRunning) break; // Check if the workflow has been stopped

      // Start new vision capture
      await capture().then(process);

      _log.fine('Processing complete, waiting 5 seconds...');
      await Future.delayed(Duration(seconds: 5)); // Wait 5 seconds before repeating
    }
  }

  FutureOr<void> process((Uint8List, ImageMetadata) photo) async {
    var imageData = photo.$1;
    var meta = photo.$2;
    _responseTextList.clear();

    try {
      _uprightImageBytes = imageData;
      Image im = Image.memory(imageData, gaplessPlayback: true,);

      setState(() {
        _image = im;
        _imageMeta = meta;
      });

      if (_model != null) {
        final content = [
          Content.data('image/jpeg', _uprightImageBytes!),
          Content.text(_prompt)
        ];
        var responseStream = _model!.generateContentStream(content);
        _pagination.clear();

        await for (final response in responseStream) {
          _log.fine(response.text);
          _appendResponseText(response.text!);
          setState(() {});
          await frame!.sendMessage(
            TxPlainText(
              msgCode: 0x0a,
              text: _pagination.getCurrentPage().join('\n')
            )
          );
        }
      } else {
        throw Exception('Set an API key to get model responses');
      }
      _processing = false;

    } catch (e) {
      String err = 'Error processing photo: $e';
      _log.fine(err);
      setState(() {
        _responseTextList.add(err);
      });
      _processing = false;
    }
  }

  void _appendResponseText(String text) {
    List<String> splitText = text.split('\n');
    if (_responseTextList.isEmpty) {
      _responseTextList.addAll(splitText);
      for (var line in splitText) {
        _pagination.appendLine(line);
      }
    } else {
      if (splitText.isNotEmpty) {
        String updatedLastLine = _responseTextList[_responseTextList.length - 1] + splitText[0];
        _responseTextList[_responseTextList.length - 1] = updatedLastLine;
        _pagination.updateLastLine(updatedLastLine);
        _responseTextList.addAll(splitText.skip(1));
        for (var line in splitText.skip(1)) {
          _pagination.appendLine(line);
        }
      }
    }
  }

  static void _shareImage(Uint8List? jpegBytes, String text) async {
    if (jpegBytes != null) {
      try {
        await Share.shareXFiles(
          [XFile.fromData(jpegBytes, mimeType: 'image/jpeg', name: 'image.jpg')],
          text: text,
        );
      } catch (e) {
        _log.severe('Error preparing image for sharing: $e');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Gemini - Frame Vision',
      theme: ThemeData.dark(),
      home: Scaffold(
        resizeToAvoidBottomInset: true,
        appBar: AppBar(
          title: const Text('Gemini - Frame Vision'),
          actions: [getBatteryWidget()]
        ),
        drawer: getCameraDrawer(),
        body: Column(
          children: [
            Row(
              children: [
                Expanded(child: TextField(controller: _apiKeyTextFieldController, obscureText: true, obscuringCharacter: '*', decoration: const InputDecoration(hintText: 'Enter Gemini api_key'),)),
                ElevatedButton(onPressed: _saveApiKey, child: const Text('Save'))
              ],
            ),
            Row(
              children: [
                Expanded(child: TextField(controller: _promptTextFieldController, obscureText: false, decoration: const InputDecoration(hintText: 'Enter prompt'),)),
                ElevatedButton(onPressed: _savePrompt, child: const Text('Save'))
              ],
            ),
            Expanded(
            child: GestureDetector(
              onTap: () {
                if (_uprightImageBytes != null) {
                  _shareImage(_uprightImageBytes, _responseTextList.join('\n'));
                }
              },
              child: CustomScrollView(
                slivers: [
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: _image,
                    ),
                  ),
                  if (_imageMeta != null)
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: Column(children: [
                          ImageMetadataWidget(meta: _imageMeta!),
                          const Divider()
                        ]),
                      ),
                    ),
                  SliverList(
                    delegate: SliverChildBuilderDelegate(
                      (context, index) {
                        return Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16.0,
                          ),
                          child: Text(
                            _responseTextList[index],
                            style: TextStyle(fontSize: 18), // Increase font size here
                          ),
                        );
                      },
                      childCount: _responseTextList.length,
                    ),
                  ),
                  SliverFillRemaining(
                    hasScrollBody: false,
                    child: Container(), // Empty container to allow scrolling
                  ),
                ],
              ),
            ),
          ),
          ],
        ),
        floatingActionButton: getFloatingActionButtonWidget(const Icon(Icons.camera_alt), const Icon(Icons.cancel)),
        persistentFooterButtons: getFooterButtonsWidget(),
      ),
    );
  }
}

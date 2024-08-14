import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:buffered_list_stream/buffered_list_stream.dart';
import 'package:flutter/material.dart';
import 'package:logging/logging.dart';
import 'package:record/record.dart';
import 'package:vosk_flutter/vosk_flutter.dart';
import 'package:http/http.dart' as http;

import 'frame_helper.dart';
import 'simple_frame_app.dart';

void main() => runApp(const MainApp());

final _log = Logger("MainApp");

Future<WikiResult> fetchWiki() async {
  String query = 'Weezer';
  final response = await http
      .get(Uri.parse('https://en.wikipedia.org/w/api.php?action=query&format=json&prop=pageimages%7Cpageterms%7cinfo&inprop=url&generator=prefixsearch&redirects=1&formatversion=2&piprop=thumbnail&pithumbsize=200&pilimit=10&wbptterms=description&gpssearch=$query&gpsoffset=0'));

  if (response.statusCode == 200) {
    // If the server did return a 200 OK response,
    // then parse the JSON.
    return WikiResult.fromJson(jsonDecode(response.body) as Map<String, dynamic>);
  } else {
    // If the server did not return a 200 OK response,
    // then throw an exception.
    throw Exception('Failed to load wiki result');
  }
}

class WikiResult {
  final int pageId;
  final String title;
  final String description;
  final String? thumbUri;
  final int? thumbWidth;
  final int? thumbHeight;

  const WikiResult({
    required this.pageId,
    required this.title,
    required this.description,
    this.thumbUri,
    this.thumbWidth,
    this.thumbHeight
  });

  factory WikiResult.fromJson(Map<String, dynamic> json) {
    String? thumbUri;
    int? thumbWidth, thumbHeight;

    Map<String, dynamic> page = json['query']['pages'][0];
    int pageid = page['pageid'];
    String title = page['title'];
    String description = page['terms']['description'][0];

    if (page.containsKey('thumbnail')) {
      Map<String, dynamic> thumb = page['thumbnail'];
      thumbUri = thumb['source'];
      thumbWidth = thumb['width'];
      thumbHeight = thumb['height'];
    }

    return WikiResult(
          pageId: pageid,
          title: title,
          description: description,
          thumbUri: thumbUri,
          thumbWidth: thumbWidth,
          thumbHeight: thumbHeight
        );
  }
}

class MainApp extends StatefulWidget {
  const MainApp({super.key});

  @override
  MainAppState createState() => MainAppState();
}

/// SimpleFrameAppState mixin helps to manage the lifecycle of the Frame connection outside of this file
class MainAppState extends State<MainApp> with SimpleFrameAppState {

  MainAppState() {
    Logger.root.level = Level.FINE;
    Logger.root.onRecord.listen((record) {
      debugPrint('${record.level.name}: [${record.loggerName}] ${record.time}: ${record.message}');
    });
  }

  /// Wiki Frame application members
  static const _modelName = 'vosk-model-small-en-us-0.15.zip';
  final _vosk = VoskFlutterPlugin.instance();
  late final Model _model;
  late final Recognizer _recognizer;
  static const _sampleRate = 16000;

  String _partialResult = "N/A";
  String _finalResult = "N/A";
  static const _textStyle = TextStyle(fontSize: 30);

  // Wikipedia query results
  late Future<WikiResult> futureWikiResult;


  @override
  void initState() {
    super.initState();
    currentState = ApplicationState.initializing;
    // asynchronously kick off Vosk initialization
    _initVosk();
    futureWikiResult = fetchWiki();
  }

  @override
  void dispose() async {
    _model.dispose();
    _recognizer.dispose();
    super.dispose();
  }

  void _initVosk() async {
    final enSmallModelPath = await ModelLoader().loadFromAssets('assets/$_modelName');
    _model = await _vosk.createModel(enSmallModelPath);
    _recognizer = await _vosk.createRecognizer(model: _model, sampleRate: _sampleRate);

    currentState = ApplicationState.disconnected;
    if (mounted) setState(() {});
  }

  /// Sets up the Audio used for the application.
  /// Returns true if the audio is set up correctly, in which case
  /// it also returns a reference to the AudioRecorder and the
  /// audioSampleBufferedStream
  Future<(bool, AudioRecorder?, Stream<List<int>>?)> startAudio() async {
    // create a fresh AudioRecorder each time we run - it will be dispose()d when we click stop
    AudioRecorder audioRecorder = AudioRecorder();

    // Check and request permission if needed
    if (!await audioRecorder.hasPermission()) {
      return (false, null, null);
    }

    try {
      // start the audio stream
      // TODO select suitable sample rate for the Frame given BLE bandwidth constraints if we want to switch to Frame mic
      final recordStream = await audioRecorder.startStream(
        const RecordConfig(encoder: AudioEncoder.pcm16bits,
          numChannels: 1,
          sampleRate: _sampleRate));

      // buffer the audio stream into chunks of 4096 samples
      final audioSampleBufferedStream = bufferedListStream(
        recordStream.map((event) {
          return event.toList();
        }),
        // samples are PCM16, so 2 bytes per sample
        4096 * 2,
      );

      return (true, audioRecorder, audioSampleBufferedStream);
    } catch (e) {
      _log.severe('Error starting Audio: $e');
      return (false, null, null);
    }
  }

  Future<void> stopAudio(AudioRecorder recorder) async {
    // stop the audio
    await recorder.stop();
    await recorder.dispose();
  }

  /// This application uses vosk speech-to-text to listen to audio from the host mic, convert to text,
  /// and send the text to the Frame in real-time. It has a running main loop in this function
  /// and also on the Frame (frame_app.lua)
  @override
  Future<void> runApplication() async {
    currentState = ApplicationState.running;
    _partialResult = '';
    _finalResult = '';
    if (mounted) setState(() {});

    try {
      var (ok, audioRecorder, audioSampleBufferedStream) = await startAudio();
      if (!ok) {
        currentState = ApplicationState.ready;
        if (mounted) setState(() {});
        return;
      }

      // try to get the Frame into a known state by making sure there's no main loop running
      frame!.sendBreakSignal();
      await Future.delayed(const Duration(milliseconds: 500));

      // clean up by deregistering any handler and deleting any prior script
      await frame!.sendString('frame.bluetooth.receive_callback(nil);print(0)', awaitResponse: true);
      await Future.delayed(const Duration(milliseconds: 500));
      await frame!.sendString('frame.file.remove("frame_app.lua");print(0)', awaitResponse: true);
      await Future.delayed(const Duration(milliseconds: 500));

      // send our frame_app to the Frame
      // it listens to data being sent and renders the text on the display
      await frame!.uploadScript('frame_app.lua', 'assets/frame_app.lua');
      await Future.delayed(const Duration(milliseconds: 500));

      // kick off the main application loop
      await frame!.sendString('require("frame_app")', awaitResponse: true);
      await Future.delayed(const Duration(milliseconds: 500));

      // -----------------------------------------------------------------------
      // frame_app is installed on Frame and running, start our application loop
      // -----------------------------------------------------------------------

      String prevText = '';

      // loop over the incoming audio data and send reults to Frame
      await for (var audioSample in audioSampleBufferedStream!) {
        // if the user has clicked Stop we want to jump out of the main loop and stop processing
        if (currentState != ApplicationState.running) {
          break;
        }

        // recognizer blocks until it has something
        final resultReady = await _recognizer.acceptWaveformBytes(Uint8List.fromList(audioSample));

        // TODO consider enabling alternatives, and word times, and ...?
        String text = resultReady ?
            jsonDecode(await _recognizer.getResult())['text']
          : jsonDecode(await _recognizer.getPartialResult())['partial'];

        // If the text is the same as the previous one, we don't send it to Frame and force a redraw
        // The recognizer often produces a bunch of empty string in a row too, so this means
        // we send the first one (clears the display) but not subsequent ones
        // Often the final result matches the last partial, so if it's a final result then show it
        // on the phone but don't send it
        if (text == prevText) {
          if (resultReady) {
            setState(() { _finalResult = text; _partialResult = ''; });
          }
          continue;
        }
        else if (text.isEmpty) {
          // turn the empty string into a single space and send
          // still can't put it through the wrapped-text-chunked-sender
          // because it will be zero bytes payload so no message will
          // be sent.
          // Users might say this first empty partial
          // comes a bit soon and hence the display is cleared a little sooner
          // than they want (not like audio hangs around in the air though
          // after words are spoken!)
          frame!.sendData([0x0b, 0x20]);
          prevText = '';
          continue;
        }

        if (_log.isLoggable(Level.FINE)) {
          _log.fine('Recognized text: $text');
        }

        // sentence fragments can be longer than MTU (200-ish bytes) so we introduce a header
        // byte to indicate if this is a non-final chunk or a final chunk, which is interpreted
        // on the other end in frame_app
        try {
          // send current text to Frame, splitting into "longText"-marked chunks if required
          String wrappedText = FrameHelper.wrapText(text, 640, 4);

          int sentBytes = 0;
          int bytesRemaining = wrappedText.length;
          int chunksize = frame!.maxDataLength! - 1;
          List<int> bytes;

          while (sentBytes < wrappedText.length) {
            if (bytesRemaining <= chunksize) {
              // final chunk
              bytes = [0x0b] + wrappedText.substring(sentBytes, sentBytes + bytesRemaining).codeUnits;
            }
            else {
              // non-final chunk
              bytes = [0x0a] + wrappedText.substring(sentBytes, sentBytes + chunksize).codeUnits;
            }

            // send the chunk
            frame!.sendData(bytes);

            sentBytes += bytes.length;
            bytesRemaining = wrappedText.length - sentBytes;
          }
        }
        catch (e) {
          _log.severe('Error sending text to Frame: $e');
          break;
        }

        // update the phone UI too
        setState(() => resultReady ? _finalResult = text : _partialResult = text);
        prevText = text;
      }

      // ----------------------------------------------------------------------
      // finished the main application loop, shut it down here and on the Frame
      // ----------------------------------------------------------------------

      await stopAudio(audioRecorder!);

      // send a break to stop the Lua app loop on Frame
      await frame!.sendBreakSignal();
      await Future.delayed(const Duration(milliseconds: 500));

      // deregister the data handler
      await frame!.sendString('frame.bluetooth.receive_callback(nil);print(0)', awaitResponse: true);
      await Future.delayed(const Duration(milliseconds: 500));

    } catch (e) {
      _log.fine('Error executing application logic: $e');
    }

    currentState = ApplicationState.ready;
    if (mounted) setState(() {});
  }

  /// The runApplication function will keep running until we interrupt it here
  /// and tell it to start shutting down. It will interrupt the frame_app
  /// and perform the cleanup on Frame and here
  @override
  Future<void> interruptApplication() async {
    currentState = ApplicationState.stopping;
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    // work out the states of the footer buttons based on the app state
    List<Widget> pfb = [];

    switch (currentState) {
      case ApplicationState.disconnected:
        pfb.add(TextButton(onPressed: scanOrReconnectFrame, child: const Text('Connect Frame')));
        pfb.add(const TextButton(onPressed: null, child: Text('Start')));
        pfb.add(const TextButton(onPressed: null, child: Text('Finish')));
        break;

      case ApplicationState.initializing:
      case ApplicationState.scanning:
      case ApplicationState.connecting:
      case ApplicationState.disconnecting:
      case ApplicationState.stopping:
        pfb.add(const TextButton(onPressed: null, child: Text('Connect Frame')));
        pfb.add(const TextButton(onPressed: null, child: Text('Start')));
        pfb.add(const TextButton(onPressed: null, child: Text('Finish')));
        break;

      case ApplicationState.ready:
        pfb.add(const TextButton(onPressed: null, child: Text('Connect Frame')));
        pfb.add(TextButton(onPressed: runApplication, child: const Text('Start')));
        pfb.add(TextButton(onPressed: disconnectFrame, child: const Text('Finish')));
        break;

      case ApplicationState.running:
        pfb.add(const TextButton(onPressed: null, child: Text('Connect Frame')));
        pfb.add(TextButton(onPressed: interruptApplication, child: const Text('Stop')));
        pfb.add(const TextButton(onPressed: null, child: Text('Finish')));
        break;
    }

    return MaterialApp(
      title: 'Wiki Frame',
      theme: ThemeData.dark(),
      home: Scaffold(
        appBar: AppBar(
          title: const Text("Wiki Frame"),
          actions: [getBatteryWidget()]
        ),
        body: Center(
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 16),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Align(alignment: Alignment.centerLeft,
                  child: Text('Partial: $_partialResult', style: _textStyle)
                ),
                const Divider(),
                Align(alignment: Alignment.centerLeft,
                  child: Text('Final: $_finalResult', style: _textStyle)
                ),
                FutureBuilder<WikiResult>(
                  future: futureWikiResult,
                  builder: (context, snapshot) {
                    if (snapshot.hasData) {
                      return Text(snapshot.data!.title);
                    } else if (snapshot.hasError) {
                      return Text('${snapshot.error}');
                    }

                    // By default, show a loading spinner.
                    return const CircularProgressIndicator();
                  },
                ),
              ],
            ),
          ),
        ),
        persistentFooterButtons: pfb,
      ),
    );
  }
}

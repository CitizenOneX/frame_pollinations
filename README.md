# Pollinations.ai Image Generation

Listens for a search phrase from the user, requests image generation from [Pollinations.ai](https://pollinations.ai/) using its [API](https://github.com/pollinations/pollinations/#readme) and displays the query and the generated image for display in Frame. (Note, image generation can take 10s of seconds depending on load and other factors.)

Tested on Android, but should be able to work on iOS also.

Flutter package `speech_to_text` uses platform-provided speech to text capability, apparently either on-device or cloud-based (although here we request `onDevice`). It uses the system microphone, which will be either the phone or possibly a connected bluetooth headset, but unless/until Frame could be connected as a bluetooth mic, it can't be used as we can't feed its streamed audio into the platform speech service.
Alternatives that can be fed streamed audio bytes include Vosk, but that is Android-only.

Times out after 5s on my Android device (`speech_to_text` allows different timeouts to be requested.)

Thumbnails are presently quantized to 4-bit (16 colors) and dithered using the [Dart image package](https://pub.dev/packages/image) and displayed progressively.

### Frameshots


### Framecast


### Screenshots


### Architecture

import 'dart:io';

Future<Directory> g3UpdateDownloadDirectory() async {
  final localData = Platform.environment['LOCALAPPDATA'];
  if (localData == null || localData.isEmpty) {
    throw StateError('Windows application data directory unavailable');
  }
  final cache = Directory('$localData${Platform.pathSeparator}g3NetworX${Platform.pathSeparator}Fernwartung${Platform.pathSeparator}Downloads');
  await cache.create(recursive: true);
  return cache.createTemp('update-');
}

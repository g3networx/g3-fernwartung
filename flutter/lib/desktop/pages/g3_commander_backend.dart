import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:get/get.dart';
import '../../models/platform_model.dart';
import '../../models/file_model.dart';
import '../../models/model.dart';
import 'g3_commander.dart';

class NativeCommanderBackend extends CommanderBackend {
  NativeCommanderBackend(this.ffi) {
    for (final side in [true, false]) {
      workers.add(ever(controller(side).directory, (_) => notifyListeners()));
    }
    workers.add(
        ever(ffi.fileModel.jobController.jobTable, (_) => notifyListeners()));
    ffi.ffiModel.addListener(notifyListeners);
  }
  final FFI ffi;
  final workers = <Worker>[];
  final previewJobs = <int>{};
  FileController controller(bool local) =>
      local ? ffi.fileModel.localController : ffi.fileModel.remoteController;
  @override
  String get remoteName => ffi.id;
  @override
  bool get ready =>
      ffi.ffiModel.pi.version.isNotEmpty &&
      controller(false).homePath.isNotEmpty;
  @override
  String path(bool local) => controller(local).directory.value.path;
  @override
  List<CommanderEntry> entries(bool local) => controller(local)
      .directory
      .value
      .entries
      .map((e) => CommanderEntry(e.path, e.name,
          directory: e.isDirectory,
          drive: e.isDrive,
          size: e.size,
          modified: e.lastModified()))
      .toList();
  @override
  List<CommanderJob> get jobs => ffi.fileModel.jobController.jobTable
      .map((job) => CommanderJob(
          job.id,
          job.jobName,
          job.getStatus(),
          job.percent,
          job.state == JobState.inProgress || job.state == JobState.paused))
      .toList();
  Entry entry(bool local, String path) => controller(local)
      .directory
      .value
      .entries
      .firstWhere((e) => e.path == path);
  SelectedItems selection(bool local, List<String> paths) {
    final items = SelectedItems(isLocal: local);
    for (final path in paths) {
      final item = entry(local, path);
      if (item.isDrive) throw StateError('Drive is not a file');
      items.add(item);
    }
    return items;
  }

  @override
  Future<void> navigate(bool local, String path) async {
    if (!await controller(local).openDirectory(path))
      throw StateError('Directory unavailable');
  }

  @override
  Future<void> parent(bool local) async {
    controller(local).goToParentDirectory();
  }

  @override
  Future<void> roots(bool local) => navigate(local, '/');
  @override
  Future<void> refresh() => ffi.fileModel.refreshAll();
  @override
  Future<void> copy(bool local, List<String> paths) async {
    final source = controller(local);
    final destination = controller(!local);
    if (destination.options.value.isWindows &&
        destination.directory.value.path == '/')
      throw StateError('Select a target folder');
    await source.sendFiles(
        selection(local, paths), destination.directoryData());
  }

  @override
  Future<void> rename(bool local, String path) =>
      controller(local).renameAction(entry(local, path), local);
  @override
  Future<void> mkdir(bool local, String name) async {
    final target = controller(local);
    if (name == '.' ||
        name == '..' ||
        name.contains('\u0000') ||
        !PathUtil.validName(name, target.options.value.isWindows) ||
        (target.options.value.isWindows && path(local) == '/'))
      throw StateError('Invalid folder');
    await target.createDir(
        PathUtil.join(path(local), name, target.options.value.isWindows));
  }

  @override
  Future<void> delete(bool local, List<String> paths) =>
      controller(local).removeAction(selection(local, paths));
  @override
  Future<void> cancel(int id) async {
    final jobs = ffi.fileModel.jobController;
    await jobs.cancelJob(id);
    final index = jobs.getJob(id);
    if (index >= 0 &&
        (jobs.jobTable[index].state == JobState.inProgress ||
            jobs.jobTable[index].state == JobState.paused)) {
      jobs.jobTable[index].state = JobState.done;
      jobs.jobTable[index].err = 'cancel';
      jobs.jobTable.refresh();
    }
  }

  static const previewLimit = 1024 * 1024;
  Future<String> readPreview(File file) async {
    final bytes = await file
        .openRead(0, previewLimit + 1)
        .fold<List<int>>([], (data, part) => data..addAll(part));
    if (bytes.length > previewLimit)
      return 'Vorschau auf 1 MiB begrenzt. Datei zum Anzeigen kopieren.';
    if (bytes.contains(0)) return 'Binärdatei · keine Textvorschau.';
    return utf8.decode(bytes, allowMalformed: true);
  }

  @override
  Future<String> preview(bool local, String path) async {
    final item = entry(local, path);
    if (!item.isFile) throw StateError('Select a file');
    if (item.size > previewLimit)
      return 'Vorschau auf 1 MiB begrenzt. Datei zum Anzeigen kopieren.';
    if (local) return readPreview(File(path));
    final directory = await Directory.systemTemp.createTemp('opslinx-preview-');
    final target = '${directory.path}${Platform.pathSeparator}preview.txt';
    final jobs = ffi.fileModel.jobController;
    final id = jobs.addTransferJob(item, true);
    previewJobs.add(id);
    final completion = Completer<void>();
    final subscription = jobs.jobTable.listen((_) {
      final index = jobs.getJob(id);
      if (index < 0 || completion.isCompleted) return;
      final job = jobs.jobTable[index];
      if (job.state == JobState.error ||
          (job.state == JobState.done && job.err.isNotEmpty)) {
        completion.completeError(StateError('Preview transfer failed'));
      } else if (job.state == JobState.done) {
        completion.complete();
      }
    });
    var finished = false;
    try {
      bind.sessionSendFiles(
          sessionId: ffi.sessionId,
          actId: id,
          path: path,
          to: target,
          fileNum: 0,
          includeHidden: false,
          isRemote: true,
          isDir: false);
      await completion.future.timeout(const Duration(seconds: 60));
      finished = true;
      return await readPreview(File(target));
    } finally {
      await subscription.cancel();
      previewJobs.remove(id);
      if (finished) {
        await directory.delete(recursive: true);
      } else {
        // Do not remove a target file while the native writer may still hold it.
        final index = jobs.getJob(id);
        if (index >= 0 && jobs.jobTable[index].state == JobState.inProgress)
          await cancel(id);
      }
    }
  }

  @override
  void dispose() {
    for (final worker in workers) {
      worker.dispose();
    }
    ffi.ffiModel.removeListener(notifyListeners);
    for (final id in previewJobs) {
      unawaited(cancel(id).catchError((Object _) {}));
    }
    super.dispose();
  }
}

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class CommanderEntry {
  const CommanderEntry(this.path, this.name,
      {this.directory = false,
      this.drive = false,
      this.size = 0,
      this.modified});
  final String path, name;
  final bool directory, drive;
  final int size;
  final DateTime? modified;
}

class CommanderJob {
  const CommanderJob(
      this.id, this.name, this.status, this.progress, this.active);
  final int id;
  final String name, status;
  final double progress;
  final bool active;
}

abstract class CommanderBackend extends ChangeNotifier {
  String get remoteName;
  String path(bool local);
  List<CommanderEntry> entries(bool local);
  List<CommanderJob> get jobs;
  bool get ready;
  Future<void> navigate(bool local, String path);
  Future<void> parent(bool local);
  Future<void> roots(bool local);
  Future<void> refresh();
  Future<void> copy(bool local, List<String> paths);
  Future<void> rename(bool local, String path);
  Future<void> mkdir(bool local, String name);
  Future<void> delete(bool local, List<String> paths);
  Future<String> preview(bool local, String path);
  Future<void> cancel(int job);
}

class G3Commander extends StatefulWidget {
  const G3Commander({super.key, required this.backend});
  final CommanderBackend backend;
  @override
  State<G3Commander> createState() => _G3CommanderState();
}

class _G3CommanderState extends State<G3Commander> {
  bool local = true, busy = false;
  String? error;
  final selected = <bool, Set<String>>{true: {}, false: {}};
  final cursor = <bool, String?>{true: null, false: null};
  final nodes = <bool, FocusNode>{true: FocusNode(), false: FocusNode()};
  final scroll = <bool, ScrollController>{
    true: ScrollController(),
    false: ScrollController()
  };
  CommanderBackend get backend => widget.backend;
  static const blue = Color(0xff101f52), cyan = Color(0xff83e4e8);

  @override
  void initState() {
    super.initState();
    backend.addListener(update);
  }

  @override
  void dispose() {
    backend.removeListener(update);
    for (final node in nodes.values) {
      node.dispose();
    }
    for (final controller in scroll.values) {
      controller.dispose();
    }
    super.dispose();
  }

  void update() {
    if (!mounted) return;
    setState(() {
      for (final side in [true, false]) {
        final paths = backend.entries(side).map((e) => e.path).toSet();
        selected[side]!.retainAll(paths);
        if (!paths.contains(cursor[side])) cursor[side] = null;
      }
    });
  }

  List<CommanderEntry> rows(bool side) =>
      [...backend.entries(side)]..sort((a, b) {
          final kind = (a.directory || a.drive ? 0 : 1)
              .compareTo(b.directory || b.drive ? 0 : 1);
          return kind != 0
              ? kind
              : a.name.toLowerCase().compareTo(b.name.toLowerCase());
        });

  List<String> targets() => selected[local]!.isNotEmpty
      ? selected[local]!.toList()
      : cursor[local] == null
          ? []
          : [cursor[local]!];

  void activatePane(bool side) {
    setState(() => local = side);
    nodes[side]!.requestFocus();
  }

  Future<void> run(Future<void> Function() action) async {
    if (busy || !backend.ready) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await action();
    } catch (_) {
      if (mounted)
        setState(() => error =
            'Aktion fehlgeschlagen. Verbindung, Rechte und Zielpfad prüfen.');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<String?> askName() async {
    var name = '';
    return showDialog<String>(
        context: context,
        builder: (context) => AlertDialog(
              title: const Text('Neuer Ordner'),
              content: TextField(
                  autofocus: true,
                  decoration: const InputDecoration(labelText: 'Ordnername'),
                  onChanged: (value) => name = value,
                  onSubmitted: (value) => Navigator.pop(context, value)),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Abbrechen')),
                FilledButton(
                    onPressed: () => Navigator.pop(context, name),
                    child: const Text('Erstellen'))
              ],
            ));
  }

  Future<void> command(int key) async {
    final side = local;
    final paths = targets();
    if (key == 3 && paths.length == 1) {
      await run(() async {
        final text = await backend.preview(side, paths.single);
        if (!mounted) return;
        await showDialog<void>(
            context: context,
            builder: (context) => AlertDialog(
                  title: const Text('Dateiansicht · nur lesen'),
                  content: SizedBox(
                      width: 850,
                      height: 520,
                      child: SingleChildScrollView(
                          child: SelectableText(text,
                              style: const TextStyle(
                                  fontFamily: 'Consolas', fontSize: 13)))),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(context),
                        child: const Text('Schließen'))
                  ],
                ));
      });
    } else if (key == 5 && paths.isNotEmpty) {
      await run(() => backend.copy(side, paths));
    } else if (key == 6 && paths.length == 1) {
      await run(() => backend.rename(side, paths.single));
    } else if (key == 7) {
      await run(() async {
        final name = await askName();
        if (name != null && name.isNotEmpty) await backend.mkdir(side, name);
      });
    } else if (key == 8 && paths.isNotEmpty) {
      await run(() => backend.delete(side, paths));
    }
  }

  KeyEventResult onKey(bool side, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent)
      return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.tab) {
      activatePane(!side);
      return KeyEventResult.handled;
    }
    if (busy || !backend.ready) return KeyEventResult.ignored;
    final function = {
      LogicalKeyboardKey.f3: 3,
      LogicalKeyboardKey.f5: 5,
      LogicalKeyboardKey.f6: 6,
      LogicalKeyboardKey.f7: 7,
      LogicalKeyboardKey.f8: 8
    }[key];
    if (function != null) {
      if (event is KeyDownEvent) command(function);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.backspace) {
      run(() => backend.parent(side));
      return KeyEventResult.handled;
    }
    final list = rows(side);
    if (list.isEmpty) return KeyEventResult.ignored;
    var index = list.indexWhere((e) => e.path == cursor[side]);
    if (key == LogicalKeyboardKey.arrowDown ||
        key == LogicalKeyboardKey.arrowUp ||
        key == LogicalKeyboardKey.home ||
        key == LogicalKeyboardKey.end) {
      if (key == LogicalKeyboardKey.home) {
        index = 0;
      } else if (key == LogicalKeyboardKey.end) {
        index = list.length - 1;
      } else {
        index = (index + (key == LogicalKeyboardKey.arrowDown ? 1 : -1))
            .clamp(0, list.length - 1);
      }
      setState(() => cursor[side] = list[index].path);
      if (scroll[side]!.hasClients)
        scroll[side]!.jumpTo(
            (index * 30.0).clamp(0, scroll[side]!.position.maxScrollExtent));
      return KeyEventResult.handled;
    }
    if (index < 0) return KeyEventResult.ignored;
    final entry = list[index];
    if (key == LogicalKeyboardKey.insert || key == LogicalKeyboardKey.space) {
      if (!entry.drive)
        setState(() {
          if (!selected[side]!.remove(entry.path))
            selected[side]!.add(entry.path);
        });
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.enter) {
      if (entry.directory || entry.drive) {
        run(() => backend.navigate(side, entry.path));
      } else {
        command(3);
      }
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) => Theme(
        data: ThemeData.dark(useMaterial3: true).copyWith(
            scaffoldBackgroundColor: blue,
            colorScheme: const ColorScheme.dark(primary: cyan, surface: blue),
            textTheme: ThemeData.dark()
                .textTheme
                .apply(fontFamily: 'Consolas', bodyColor: Colors.white)),
        child: Builder(
            builder: (context) => Material(
                color: blue,
                child: Column(children: [
                  Container(
                      color: const Color(0xff06132e),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 7),
                      child: Row(children: [
                        const Icon(Icons.folder_open, color: cyan),
                        const SizedBox(width: 8),
                        Expanded(
                            child: Text(
                                'OPSLinX Commander · ${backend.remoteName}',
                                overflow: TextOverflow.ellipsis)),
                        Text(
                            backend.ready
                                ? 'Eigene Dateiverbindung'
                                : 'Verbindung wird aufgebaut …',
                            style: const TextStyle(color: cyan)),
                        IconButton(
                            tooltip: 'Aktualisieren',
                            onPressed: busy || !backend.ready
                                ? null
                                : () => run(backend.refresh),
                            icon: const Icon(Icons.refresh))
                      ])),
                  if (error != null)
                    MaterialBanner(content: Text(error!), actions: [
                      TextButton(
                          onPressed: () => setState(() => error = null),
                          child: const Text('OK'))
                    ]),
                  Expanded(
                      child: Row(children: [
                    Expanded(child: pane(context, true)),
                    Expanded(child: pane(context, false))
                  ])),
                  if (backend.jobs.isNotEmpty)
                    SizedBox(
                        height: 110,
                        child: ListView(
                            children: backend.jobs.reversed
                                .map((job) => ListTile(
                                      dense: true,
                                      title: Text(job.name,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis),
                                      subtitle: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Text(job.status),
                                            LinearProgressIndicator(
                                                value: job.progress.clamp(0, 1))
                                          ]),
                                      trailing: job.active
                                          ? IconButton(
                                              tooltip: 'Übertragung abbrechen',
                                              icon: const Icon(
                                                  Icons.cancel_outlined),
                                              onPressed: () async {
                                                try {
                                                  await backend.cancel(job.id);
                                                } catch (_) {
                                                  if (mounted)
                                                    setState(() => error =
                                                        'Abbrechen fehlgeschlagen.');
                                                }
                                              })
                                          : null,
                                    ))
                                .toList())),
                  if (busy)
                    const Padding(
                        padding: EdgeInsets.all(4),
                        child: Text('Aktion läuft …')),
                  Container(
                      color: const Color(0xff06132e),
                      child: Row(children: [
                        for (final item in [
                          (3, 'Anzeigen'),
                          (5, 'Kopieren'),
                          (6, 'Umbenennen'),
                          (7, 'Ordner'),
                          (8, 'Löschen')
                        ])
                          Expanded(
                              child: TextButton(
                                  onPressed: busy || !backend.ready
                                      ? null
                                      : () => command(item.$1),
                                  child: Text('F${item.$1} ${item.$2}',
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis))),
                      ])),
                ]))),
      );

  Widget pane(BuildContext context, bool side) {
    final list = rows(side);
    return Container(
        margin: const EdgeInsets.all(4),
        decoration: BoxDecoration(
            color: blue,
            border: Border.all(
                color: local == side ? cyan : const Color(0xff526184),
                width: 2)),
        child: Column(children: [
          Container(
              color: local == side
                  ? const Color(0xff204d72)
                  : const Color(0xff162749),
              child: Row(children: [
                Expanded(
                    child: TextButton(
                        onPressed: () => activatePane(side),
                        child: Text(side ? 'Lokal' : backend.remoteName,
                            maxLines: 1, overflow: TextOverflow.ellipsis))),
                IconButton(
                    tooltip: 'Laufwerke',
                    onPressed: busy || !backend.ready
                        ? null
                        : () {
                            activatePane(side);
                            run(() => backend.roots(side));
                          },
                    icon: const Icon(Icons.storage)),
                IconButton(
                    tooltip: 'Übergeordneter Ordner',
                    onPressed: busy || !backend.ready
                        ? null
                        : () {
                            activatePane(side);
                            run(() => backend.parent(side));
                          },
                    icon: const Icon(Icons.arrow_upward)),
              ])),
          Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: TextFormField(
                  key: ValueKey('${side}_${backend.path(side)}'),
                  initialValue: backend.path(side),
                  style: const TextStyle(fontSize: 13),
                  decoration: const InputDecoration(
                      isDense: true,
                      border: InputBorder.none,
                      hintText: 'Pfad'),
                  onTap: () => setState(() => local = side),
                  onFieldSubmitted: (path) {
                    activatePane(side);
                    run(() => backend.navigate(side, path));
                  })),
          const Padding(
              padding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              child: Row(children: [
                Expanded(
                    flex: 5,
                    child: Text('Name', style: TextStyle(color: cyan))),
                Expanded(
                    flex: 2,
                    child: Text('Größe', style: TextStyle(color: cyan))),
                Expanded(
                    flex: 3,
                    child: Text('Geändert', style: TextStyle(color: cyan))),
              ])),
          Expanded(
              child: Focus(
                  autofocus: side,
                  focusNode: nodes[side],
                  onKeyEvent: (_, event) => onKey(side, event),
                  onFocusChange: (focused) {
                    if (focused && local != side) setState(() => local = side);
                  },
                  child: ListView.builder(
                      controller: scroll[side],
                      itemExtent: 30,
                      itemCount: list.length,
                      itemBuilder: (context, index) {
                        final entry = list[index];
                        final marked = selected[side]!.contains(entry.path);
                        final current = cursor[side] == entry.path;
                        final date = entry.modified
                                ?.toLocal()
                                .toString()
                                .substring(0, 16) ??
                            '';
                        return InkWell(
                          key: ValueKey('${side}_${entry.path}'),
                          onTapDown: (_) {
                            activatePane(side);
                            setState(() => cursor[side] = entry.path);
                          },
                          onDoubleTap: () {
                            if (busy || !backend.ready) return;
                            activatePane(side);
                            setState(() => cursor[side] = entry.path);
                            if (entry.directory || entry.drive) {
                              run(() => backend.navigate(side, entry.path));
                            } else {
                              command(3);
                            }
                          },
                          child: Container(
                              color: current ? const Color(0xff087b91) : null,
                              padding:
                                  const EdgeInsets.symmetric(horizontal: 8),
                              child: DefaultTextStyle(
                                  style: TextStyle(
                                      fontFamily: 'Consolas',
                                      fontSize: 13,
                                      color: marked
                                          ? Colors.yellowAccent
                                          : Colors.white),
                                  child: Row(children: [
                                    SizedBox(
                                        width: 22,
                                        child: entry.drive
                                            ? const Icon(Icons.storage,
                                                size: 16)
                                            : Checkbox(
                                                value: marked,
                                                onChanged: busy
                                                    ? null
                                                    : (value) {
                                                        activatePane(side);
                                                        setState(() {
                                                          cursor[side] =
                                                              entry.path;
                                                          if (value == true) {
                                                            selected[side]!.add(
                                                                entry.path);
                                                          } else {
                                                            selected[side]!
                                                                .remove(
                                                                    entry.path);
                                                          }
                                                        });
                                                      })),
                                    Expanded(
                                        flex: 5,
                                        child: Text(
                                            '${entry.directory || entry.drive ? "/" : ""}${entry.name}',
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis)),
                                    Expanded(
                                        flex: 2,
                                        child: Text(
                                            entry.drive
                                                ? '<LW>'
                                                : entry.directory
                                                    ? '<DIR>'
                                                    : '${entry.size}',
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis)),
                                    Expanded(
                                        flex: 3,
                                        child: Text(entry.drive ? '' : date,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis)),
                                  ]))),
                        );
                      }))),
          Padding(
              padding: const EdgeInsets.all(6),
              child: Text(
                  '${list.length} Einträge · ${selected[side]!.length} markiert · Tab: Seite wechseln',
                  style: const TextStyle(fontSize: 11, color: cyan))),
        ]));
  }
}

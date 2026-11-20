import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hbb/mobile/pages/server_page.dart';
import 'package:flutter_hbb/mobile/pages/settings_page.dart';
import 'package:flutter_hbb/web/settings_page.dart';
import 'package:get/get.dart';
import '../../common.dart';
import '../../common/widgets/chat_page.dart';
import '../../consts.dart';
import '../../g3_addressbook.dart';
import '../../g3_addressbook_credentials.dart';
import '../../g3_android_settings.dart';
import '../../g3_android_update_transport.dart';
import '../../g3_handoff_uri.dart';
import '../../models/platform_model.dart';
import '../../models/state_model.dart';
import 'connection_page.dart';
import 'opstalx_lab_page.dart';

abstract class PageShape extends Widget {
  final String title = "";
  final Widget icon = Icon(null);
  final List<Widget> appBarActions = [];
}

class G3MobileAddressBookPage extends StatelessWidget implements PageShape {
  const G3MobileAddressBookPage({super.key});

  @override
  String get title => 'Adressbuch';

  @override
  Widget get icon => const Icon(Icons.contact_page_outlined);

  @override
  List<Widget> get appBarActions => const [];

  @override
  Widget build(BuildContext context) => SafeArea(
        child: G3AddressBook(
          mobile: true,
          credentials: G3AndroidAddressBookCredentials(supported: androidVersion >= 23),
          onConnect: (value) async {
          final uri = Uri.parse(value);
          final handoff = g3HandoffArguments(uri);
          if (handoff != null) {
            await redeemG3Session(handoff.last);
          } else if (uri.scheme == 'g3fernwartung' &&
              uri.path.isEmpty &&
              !uri.hasQuery &&
              !uri.hasFragment &&
              RegExp(r'^[A-Za-z0-9_-]{6,40}$').hasMatch(uri.authority)) {
            await connect(context, uri.authority);
          } else {
            throw const FormatException('Ungültige Verbindungsfreigabe');
          }
        }),
      );
}

class _OpsTalxNavigationPage extends StatelessWidget implements PageShape {
  const _OpsTalxNavigationPage();

  @override
  String get title => 'Video-Hilfe';
  @override
  Widget get icon => const Icon(Icons.video_call_outlined);
  @override
  List<Widget> get appBarActions => const [];

  @override
  Widget build(BuildContext context) => const OpsTalxLabPage();
}

class HomePage extends StatefulWidget {
  static final homeKey = GlobalKey<HomePageState>();

  HomePage() : super(key: homeKey);

  @override
  HomePageState createState() => HomePageState();
}

class HomePageState extends State<HomePage> with WidgetsBindingObserver {
  var _selectedIndex = 0;
  int get selectedIndex => _selectedIndex;
  final List<PageShape> _pages = [];
  int get _defaultTabIndex {
    final addressBook =
        _pages.indexWhere((page) => page is G3MobileAddressBookPage);
    return addressBook < 0 ? 0 : addressBook;
  }

  bool get _g3AndroidClient => isAndroid && kG3AndroidClient;
  int _chatPageTabIndex = -1;
  G3AndroidUpdate? _androidUpdate;
  final _timeSinceUpdateCheck = Stopwatch();
  bool _checkingAndroidUpdate = false;
  bool get isChatPageCurrentTab => isAndroid
      ? _selectedIndex == _chatPageTabIndex
      : false; // change this when ios have chat page

  void refreshPages() {
    setState(() {
      initPages();
    });
  }

  @override
  void initState() {
    super.initState();
    initPages();
    _selectedIndex = _defaultTabIndex;
    if (_g3AndroidClient) {
      WidgetsBinding.instance.addObserver(this);
      unawaited(gFFI.serverModel.fetchID());
      unawaited(_checkAndroidUpdate());
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(gFFI.serverModel.fetchID());
      unawaited(_checkAndroidUpdate());
    }
  }

  @override
  void dispose() {
    if (_g3AndroidClient) WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> _checkAndroidUpdate() async {
    if (_checkingAndroidUpdate ||
        (_timeSinceUpdateCheck.isRunning &&
            _timeSinceUpdateCheck.elapsed < const Duration(minutes: 1))) {
      return;
    }
    _checkingAndroidUpdate = true;
    _timeSinceUpdateCheck
      ..reset()
      ..start();
    try {
      final update = await g3AvailableAndroidUpdate();
      if (mounted && update != _androidUpdate) {
        setState(() => _androidUpdate = update);
      }
    } catch (_) {
      // Keep a previously found update when the feed is temporarily offline.
    } finally {
      _checkingAndroidUpdate = false;
    }
  }

  void _showAndroidSettings() {
    unawaited(showG3AndroidSettings(context, update: _androidUpdate));
  }

  void initPages() {
    _pages.clear();
    if (!bind.isIncomingOnly()) {
      _pages.add(ConnectionPage(
        appBarActions: [],
      ));
      if (_g3AndroidClient) {
        _pages.add(const G3MobileAddressBookPage());
      }
    }
    if (isAndroid && !bind.isOutgoingOnly()) {
      _chatPageTabIndex = _pages.length;
      _pages.addAll([
        ChatPage(type: ChatPageType.mobileMain),
        ServerPage(assistedSupport: _g3AndroidClient),
      ]);
    }
    if (_g3AndroidClient && const bool.fromEnvironment('G3_OPSTALX')) {
      _pages.add(const _OpsTalxNavigationPage());
    }
    if (!_g3AndroidClient || bind.isIncomingOnly()) {
      _pages.add(SettingsPage());
    }
  }

  @override
  Widget build(BuildContext context) {
    return WillPopScope(
        onWillPop: () async {
          final defaultTab = _defaultTabIndex;
          if (_selectedIndex != defaultTab) {
            setState(() {
              _selectedIndex = defaultTab;
            });
          } else {
            return true;
          }
          return false;
        },
        child: Scaffold(
          // backgroundColor: MyTheme.grayBg,
          appBar: AppBar(
            centerTitle: true,
            title: _g3AndroidClient ? _g3AndroidTitle(context) : appTitle(),
            bottom: _androidUpdate == null
                ? null
                : PreferredSize(
                    preferredSize: const Size.fromHeight(48),
                    child: TextButton.icon(
                      onPressed: _showAndroidSettings,
                      icon: const Icon(Icons.system_update),
                      label: const Text('Update verfügbar'),
                    ),
                  ),
            actions: [
              ..._pages.elementAt(_selectedIndex).appBarActions,
              if (_g3AndroidClient)
                IconButton(
                  tooltip: 'Einstellungen',
                  icon: const Icon(Icons.settings_outlined),
                  onPressed: _showAndroidSettings,
                ),
            ],
          ),
          bottomNavigationBar: BottomNavigationBar(
            key: navigationBarKey,
            items: _pages
                .map((page) =>
                    BottomNavigationBarItem(icon: page.icon, label: page.title))
                .toList(),
            currentIndex: _selectedIndex,
            type: BottomNavigationBarType.fixed,
            selectedItemColor: MyTheme.accent, //
            unselectedItemColor: MyTheme.darkGray,
            onTap: (index) => setState(() {
              // close chat overlay when go chat page
              if (_selectedIndex != index) {
                _selectedIndex = index;
                if (isChatPageCurrentTab) {
                  gFFI.chatModel.hideChatIconOverlay();
                  gFFI.chatModel.hideChatWindowOverlay();
                  gFFI.chatModel.mobileClearClientUnread(
                      gFFI.chatModel.currentKey.connId);
                }
              }
            }),
          ),
          body: _g3AndroidClient
              ? IndexedStack(index: _selectedIndex, children: _pages)
              : _pages.elementAt(_selectedIndex),
        ));
  }

  Widget _g3AndroidTitle(BuildContext context) => ValueListenableBuilder(
      valueListenable: gFFI.serverModel.serverId,
      builder: (context, value, _) {
        final id = value.text.replaceAll(RegExp(r'\s'), '');
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('g3 OpsLinX'),
            if (RegExp(r'^[A-Za-z0-9_-]{6,40}$').hasMatch(id))
              Tooltip(
                message: 'Geräte-ID kopieren',
                child: InkWell(
                  onTap: () async {
                    await Clipboard.setData(ClipboardData(text: id));
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Geräte-ID kopiert')),
                      );
                    }
                  },
                  child: Text('ID ${value.text}',
                      style: Theme.of(context).textTheme.bodySmall),
                ),
              ),
          ],
        );
      });

  Widget appTitle() {
    final currentUser = gFFI.chatModel.currentUser;
    final currentKey = gFFI.chatModel.currentKey;
    if (isChatPageCurrentTab &&
        currentUser != null &&
        currentKey.peerId.isNotEmpty) {
      final connected =
          gFFI.serverModel.clients.any((e) => e.id == currentKey.connId);
      return Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Tooltip(
            message: currentKey.isOut
                ? translate('Outgoing connection')
                : translate('Incoming connection'),
            child: Icon(
              currentKey.isOut
                  ? Icons.call_made_rounded
                  : Icons.call_received_rounded,
            ),
          ),
          Expanded(
            child: Center(
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    "${currentUser.firstName}   ${currentUser.id}",
                  ),
                  if (connected)
                    Container(
                      width: 10,
                      height: 10,
                      decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: Color.fromARGB(255, 133, 246, 199)),
                    ).marginSymmetric(horizontal: 2),
                ],
              ),
            ),
          ),
        ],
      );
    }
    return Text(bind.mainGetAppNameSync());
  }
}

class WebHomePage extends StatelessWidget {
  final connectionPage =
      ConnectionPage(appBarActions: <Widget>[const WebSettingsPage()]);

  @override
  Widget build(BuildContext context) {
    stateGlobal.isInMainPage = true;
    handleUnilink(context);
    return Scaffold(
      // backgroundColor: MyTheme.grayBg,
      appBar: AppBar(
        centerTitle: true,
        title: Text("${bind.mainGetAppNameSync()} (Preview)"),
        actions: connectionPage.appBarActions,
      ),
      body: connectionPage,
    );
  }

  handleUnilink(BuildContext context) {
    if (webInitialLink.isEmpty) {
      return;
    }
    final link = webInitialLink;
    webInitialLink = '';
    final splitter = ["/#/", "/#", "#/", "#"];
    var fakelink = '';
    for (var s in splitter) {
      if (link.contains(s)) {
        var list = link.split(s);
        if (list.length < 2 || list[1].isEmpty) {
          return;
        }
        list.removeAt(0);
        fakelink = "rustdesk://${list.join(s)}";
        break;
      }
    }
    if (fakelink.isEmpty) {
      return;
    }
    final uri = Uri.tryParse(fakelink);
    if (uri == null) {
      return;
    }
    final args = urlLinkToCmdArgs(uri);
    if (args == null || args.isEmpty) {
      return;
    }
    bool isFileTransfer = false;
    bool isViewCamera = false;
    bool isTerminal = false;
    String? id;
    String? password;
    var loginMethod = '';
    for (int i = 0; i < args.length; i++) {
      switch (args[i]) {
        case '--connect':
        case '--play':
          id = args[i + 1];
          i++;
          break;
        case '--file-transfer':
          isFileTransfer = true;
          id = args[i + 1];
          i++;
          break;
        case '--view-camera':
          isViewCamera = true;
          id = args[i + 1];
          i++;
          break;
        case '--terminal':
          isTerminal = true;
          id = args[i + 1];
          i++;
          break;
        case '--terminal-admin':
          setEnvTerminalAdmin();
          isTerminal = true;
          id = args[i + 1];
          i++;
          break;
        case '--password':
          password = args[i + 1];
          i++;
          break;
        case '--request-approval':
          loginMethod = 'request-approval';
          break;
        default:
          break;
      }
    }
    if (id != null) {
      connect(context, id, 
        isFileTransfer: isFileTransfer, 
        isViewCamera: isViewCamera, 
        isTerminal: isTerminal,
        loginMethod: loginMethod,
        password: password);
    }
  }
}

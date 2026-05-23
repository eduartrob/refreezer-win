import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:fluttertoast/fluttertoast.dart';
import 'package:logging/logging.dart';
import 'package:url_launcher/url_launcher.dart';

import '../api/deezer.dart';
import '../api/deezer_login.dart';
import '../api/definitions.dart';
import '../utils/navigator_keys.dart';
import '../settings.dart';
import '../translations.i18n.dart';
import 'home_screen.dart';

class LoginWidget extends StatefulWidget {
  final Function? callback;
  const LoginWidget({required this.callback, super.key});

  @override
  _LoginWidgetState createState() => _LoginWidgetState();
}

class _LoginWidgetState extends State<LoginWidget> {
  String? _arl;
  String? _error;

  // True when running on Windows/Linux/macOS — InAppWebView not supported
  bool get _isDesktop =>
      !Platform.isAndroid && !Platform.isIOS;

  //Initialize deezer etc
  Future _init() async {
    deezerAPI.arl = settings.arl;

    //Pre-cache homepage
    if (!await HomePage().exists()) {
      await deezerAPI.authorize();
      settings.offlineMode = false;
      HomePage hp = await deezerAPI.homePage();
      if (hp.sections.isNotEmpty) await hp.save();
    }
  }

  //Call _init()
  void _start() async {
    if (settings.arl != null) {
      _init().then((_) {
        if (widget.callback != null) widget.callback!();
      });
    }
  }

  //Check if deezer available in current country
  void _checkAvailability() async {
    bool? available = await DeezerAPI.checkAvailability();
    if (!(available ?? false)) {
      showDialog(
          context: mainNavigatorKey.currentContext!,
          builder: (context) => AlertDialog(
                title: Text('Deezer is unavailable'.i18n),
                content: Text(
                    'Deezer is unavailable in your country, ReFreezer might not work properly. Please use a VPN'
                        .i18n),
                actions: [
                  TextButton(
                    child: Text('Continue'.i18n),
                    onPressed: () {
                      if (context.mounted) Navigator.of(context).pop();
                    },
                  )
                ],
              ));
    }
  }

  @override
  void initState() {
    _start();
    _checkAvailability();
    super.initState();
  }

  void errorDialog() {
    showDialog(
        context: context,
        builder: (context) {
          return AlertDialog(
            title: Text('Error'.i18n),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                    'Error logging in! Please check your token and internet connection and try again.'
                        .i18n),
                if (_error != null) Text('\n\n$_error')
              ],
            ),
            actions: <Widget>[
              TextButton(
                child: Text('Dismiss'.i18n),
                onPressed: () {
                  _error = null;
                  Navigator.of(context).pop();
                },
              )
            ],
          );
        });
  }

  void _update() async {
    setState(() => {});

    //Try logging in
    try {
      deezerAPI.arl = settings.arl;
      bool resp = await deezerAPI.rawAuthorize(
          onError: (e) => setState(() => _error = e.toString()));
      if (resp == false) {
        //false, not null
        int arlLength = (settings.arl ?? '').length;
        if (arlLength != 175 && arlLength != 192) {
          _error = '${(_error ?? '')}Invalid ARL length!';
        }
        setState(() => settings.arl = null);
        errorDialog();
      }
      //On error show dialog and reset to null
    } catch (e) {
      _error = e.toString();
      if (kDebugMode) {
        print('Login error: $e');
      }
      setState(() => settings.arl = null);
      errorDialog();
    }

    await settings.save();
    _start();
  }

  // ARL auth: called on "Save" click, Enter and DPAD_Center press
  void goARL(FocusNode? node, TextEditingController controller) {
    node?.unfocus();
    controller.clear();
    settings.arl = _arl?.trim();
    Navigator.of(context).pop();
    _update();
  }

  /// Builds a button that is grayed out and non-interactive on desktop.
  /// Shows a tooltip explaining why it's unavailable.
  Widget _disabledOnDesktop({
    required String label,
    required String reason,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32.0),
      child: Tooltip(
        message: reason,
        child: OutlinedButton(
          style: OutlinedButton.styleFrom(
            foregroundColor: Colors.grey,
            side: const BorderSide(color: Colors.grey),
          ),
          onPressed: null, // disabled
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(label),
              const SizedBox(width: 6),
              const Icon(Icons.block, size: 16, color: Colors.grey),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    //If arl is set, show loading
    if (settings.arl != null) {
      return const Scaffold(
        body: Center(
          child: CircularProgressIndicator(),
        ),
      );
    }
    TextEditingController controller = TextEditingController();
    // For "DPAD center" key handling on remote controls
    FocusNode focusNode = FocusNode(
        skipTraversal: true,
        descendantsAreFocusable: false,
        onKeyEvent: (node, event) {
          if (event.logicalKey == LogicalKeyboardKey.select) {
            goARL(node, controller);
          }
          return KeyEventResult.handled;
        });

    return Scaffold(
      body: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8.0),
        child: ListView(
          children: <Widget>[
            const FreezerTitle(),
            const SizedBox(height: 8.0),
            Text(
              'Please login using your Deezer account.'.i18n,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 16.0),
            ),
            const SizedBox(height: 16.0),

            // ── Desktop notice ────────────────────────────────────────
            if (_isDesktop)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 32.0, vertical: 8.0),
                child: Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.amber.withOpacity(0.15),
                    border: Border.all(color: Colors.amber.shade700),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.info_outline, color: Colors.amber.shade700),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          'On Windows, use "Login using token (ARL)" below. '
                          'Open deezer.com in your browser, log in, and copy your ARL cookie.',
                          style: TextStyle(color: Colors.amber.shade200, fontSize: 13),
                        ),
                      ),
                    ],
                  ),
                ),
              ),

            // ── Email login (disabled on desktop) ────────────────────
            if (_isDesktop)
              _disabledOnDesktop(
                label: 'Login using email'.i18n,
                reason: 'Not available on Windows — use token login below',
              )
            else
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 32.0),
                child: OutlinedButton(
                  child: Text('Login using email'.i18n),
                  onPressed: () {
                    showDialog(
                        context: context,
                        builder: (context) => EmailLogin(_update));
                  },
                ),
              ),

            // ── Browser login (disabled on desktop) ──────────────────
            if (_isDesktop)
              _disabledOnDesktop(
                label: 'Login using browser'.i18n,
                reason: 'Built-in browser not available on Windows — use token login below',
              )
            else
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 32.0),
                child: OutlinedButton(
                  child: Text('Login using browser'.i18n),
                  onPressed: () {
                    Navigator.of(context).push(MaterialPageRoute(
                        builder: (context) => LoginBrowser(_update)));
                  },
                ),
              ),

            // ── Token / ARL login (always available, highlighted on desktop) ──
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32.0),
              child: _isDesktop
                  ? ElevatedButton.icon(
                      icon: const Icon(Icons.vpn_key),
                      label: Text('Login using token (ARL)'.i18n),
                      style: ElevatedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 14),
                      ),
                      onPressed: () => _showArlDialog(context, focusNode, controller),
                    )
                  : OutlinedButton(
                      child: Text('Login using token'.i18n),
                      onPressed: () => _showArlDialog(context, focusNode, controller),
                    ),
            ),

            const SizedBox(height: 16.0),
            const Divider(),
            const SizedBox(height: 8.0),

            Text(
              "If you don't have account, you can register on deezer.com for free."
                  .i18n,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 16.0),
            ),

            // ── Open deezer.com in system browser ────────────────────
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32.0),
              child: OutlinedButton(
                child: Text(_isDesktop
                    ? 'Open deezer.com (to get ARL)'.i18n
                    : 'Open in browser'.i18n),
                onPressed: () {
                  if (_isDesktop) {
                    launchUrl(Uri.parse('https://deezer.com/login'),
                        mode: LaunchMode.externalApplication);
                  } else {
                    InAppBrowser.openWithSystemBrowser(
                        url: WebUri('https://deezer.com/register'));
                  }
                },
              ),
            ),

            // ── Desktop ARL instructions ──────────────────────────────
            if (_isDesktop)
              Padding(
                padding: const EdgeInsets.fromLTRB(32, 12, 32, 8),
                child: Text(
                  'How to get your ARL:\n'
                  '1. Open deezer.com above and log in\n'
                  '2. Press F12 → Application → Cookies → deezer.com\n'
                  '3. Find the cookie named "arl" and copy its value\n'
                  '4. Paste it in "Login using token (ARL)" above',
                  style: TextStyle(
                    fontSize: 12,
                    color: Colors.grey.shade400,
                    height: 1.6,
                  ),
                ),
              ),

            const SizedBox(height: 8.0),
            const Divider(),
            const SizedBox(height: 8.0),
            Text(
              "By using this app, you don't agree with the Deezer ToS".i18n,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 16.0),
            )
          ],
        ),
      ),
    );
  }

  void _showArlDialog(BuildContext context, FocusNode focusNode,
      TextEditingController controller) {
    showDialog(
        context: context,
        builder: (context) {
          Future.delayed(const Duration(seconds: 1),
              () => {focusNode.requestFocus()});
          return AlertDialog(
            title: Text('Enter ARL'.i18n),
            content: TextField(
              onChanged: (String s) => _arl = s,
              decoration:
                  InputDecoration(labelText: 'Token (ARL)'.i18n),
              focusNode: focusNode,
              controller: controller,
              onSubmitted: (String s) {
                goARL(focusNode, controller);
              },
            ),
            actions: <Widget>[
              TextButton(
                child: Text('Save'.i18n),
                onPressed: () => goARL(null, controller),
              )
            ],
          );
        });
  }
}


class LoginBrowser extends StatelessWidget {
  final Function updateParent;
  const LoginBrowser(this.updateParent, {super.key});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: <Widget>[
        Expanded(
          child: InAppWebView(
            initialUrlRequest:
                URLRequest(url: WebUri('https://deezer.com/login')),
            onLoadStart:
                (InAppWebViewController controller, WebUri? loadedUri) async {
              //Offers URL
              if (!loadedUri!.path.contains('/login') &&
                  !loadedUri.path.contains('/register')) {
                controller.evaluateJavascript(
                    source: 'window.location.href = "/open_app"');
              }

              //Parse arl from url
              if (loadedUri
                      .toString()
                      .startsWith('intent://deezer.page.link') ||
                  loadedUri.toString().startsWith('intent://dzr.page.link')) {
                try {
                  //Actual url is in `link` query parameter
                  Uri linkUri = Uri.parse(loadedUri.queryParameters['link']!);
                  String? arl = linkUri.queryParameters['arl'];
                  settings.arl = arl;
                  // Clear cookies for next login after logout
                  CookieManager.instance().deleteAllCookies();
                  Navigator.of(context).pop();
                  updateParent();
                } catch (e) {
                  Logger.root
                      .severe('Error loading ARL from browser login: $e');
                }
              }
            },
          ),
        ),
      ],
    );
  }
}

class EmailLogin extends StatefulWidget {
  final Function callback;
  const EmailLogin(this.callback, {super.key});

  @override
  _EmailLoginState createState() => _EmailLoginState();
}

class _EmailLoginState extends State<EmailLogin> {
  String? _email;
  String? _password;
  bool _loading = false;

  Future _login() async {
    setState(() => _loading = true);
    //Try logging in
    String? arl;
    String? exception;
    try {
      arl = await DeezerLogin.getArlByEmailAndPassword(_email!, _password!);
    } on DeezerLoginException catch (dle) {
      exception = dle.toString();
    } catch (e, st) {
      exception = e.toString();
      if (kDebugMode) {
        print(e);
        print(st);
      }
    }
    setState(() => _loading = false);
    settings.arl = arl;
    if (mounted) Navigator.of(context).pop();

    if (exception == null) {
      //Success
      widget.callback();
      return;
    } else if (mounted) {
      //Error
      showDialog(
          context: context,
          builder: (context) => AlertDialog(
                title: Text('Error logging in!'.i18n),
                content: Text(
                    'Error logging in using email, please check your credentials.\n\nError: ${exception!}'),
                actions: [
                  TextButton(
                    child: Text('Dismiss'.i18n),
                    onPressed: () {
                      Navigator.of(context).pop();
                    },
                  )
                ],
              ));
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('Email Login'.i18n),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: _loading
            ? [const CircularProgressIndicator()]
            : [
                TextField(
                  decoration: InputDecoration(labelText: 'Email'.i18n),
                  onChanged: (s) => _email = s,
                ),
                Container(
                  height: 8.0,
                ),
                TextField(
                  obscureText: true,
                  decoration: InputDecoration(labelText: 'Password'.i18n),
                  onChanged: (s) => _password = s,
                )
              ],
      ),
      actions: [
        if (!_loading)
          TextButton(
            child: const Text('Login'),
            onPressed: () async {
              if (_email != null && _password != null) {
                await _login();
              } else {
                Fluttertoast.showToast(
                    msg: 'Missing email or password!'.i18n,
                    gravity: ToastGravity.BOTTOM,
                    toastLength: Toast.LENGTH_SHORT);
              }
            },
          )
      ],
    );
  }
}

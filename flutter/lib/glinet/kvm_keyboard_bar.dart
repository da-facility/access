import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// A strip of extra keys above the system keyboard. Keystrokes are sent as
/// they are typed; a text box can be opened to edit text before sending it.
class KvmKeyboardBar extends StatefulWidget {
  final FocusNode focus;
  final Set<String> modifiers;
  final ValueChanged<String> onType;
  final ValueChanged<String> onKey;
  final ValueChanged<String> onModifier;
  final Future<void> Function(String) onSendText;
  final VoidCallback onClose;

  const KvmKeyboardBar(
      {super.key,
      required this.focus,
      required this.modifiers,
      required this.onType,
      required this.onKey,
      required this.onModifier,
      required this.onSendText,
      required this.onClose});

  @override
  State<KvmKeyboardBar> createState() => _KvmKeyboardBarState();
}

// The hidden field always holds this text with the cursor at its end, so a
// backspace on an otherwise empty field is still reported as an edit.
const _sentinel = '​​​​​​​​';
const _resetValue = TextEditingValue(
    text: _sentinel,
    selection: TextSelection.collapsed(offset: _sentinel.length));

class _KvmKeyboardBarState extends State<KvmKeyboardBar> {
  final _typing = TextEditingController.fromValue(_resetValue);
  final _text = TextEditingController();
  final _textFocus = FocusNode();
  bool _textBox = false;
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    _typing.addListener(_typed);
    WidgetsBinding.instance
        .addPostFrameCallback((_) => widget.focus.requestFocus());
  }

  @override
  void dispose() {
    _typing.dispose();
    _text.dispose();
    _textFocus.dispose();
    super.dispose();
  }

  void _typed() {
    final value = _typing.value;
    if (value.text == _sentinel) return;
    // Wait until the system keyboard commits a composed word.
    if (value.composing.isValid && !value.composing.isCollapsed) return;
    var common = 0;
    while (common < value.text.length &&
        common < _sentinel.length &&
        value.text.codeUnitAt(common) == _sentinel.codeUnitAt(common)) {
      common++;
    }
    for (var i = common; i < _sentinel.length; i++) {
      widget.onKey('Backspace');
    }
    final inserted = value.text.substring(common).replaceAll('​', '');
    for (final char in inserted.characters) {
      widget.onType(char);
    }
    _typing.value = _resetValue;
  }

  Future<void> _send(Future<String?> Function() text) async {
    if (_sending) return;
    setState(() => _sending = true);
    try {
      final value = await text();
      if (value == null || value.isEmpty) return;
      await widget.onSendText(value);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(error.toString())));
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  void _toggleTextBox() {
    setState(() => _textBox = !_textBox);
    (_textBox ? _textFocus : widget.focus).requestFocus();
  }

  Widget _key(String label, VoidCallback? onPressed,
          {bool selected = false, String? tooltip, IconData? icon}) =>
      Tooltip(
          message: tooltip ?? label,
          child: TextButton(
              onPressed: onPressed,
              style: TextButton.styleFrom(
                  foregroundColor:
                      selected ? Colors.lightBlueAccent : Colors.white,
                  backgroundColor: selected ? Colors.white12 : null,
                  disabledForegroundColor: Colors.white30,
                  minimumSize: const Size(44, 40),
                  padding: const EdgeInsets.symmetric(horizontal: 8)),
              child: icon == null ? Text(label) : Icon(icon, size: 20)));

  @override
  Widget build(BuildContext context) => Material(
        color: const Color(0xff1c1c1e),
        child: SafeArea(
            top: false,
            bottom: false,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              if (_textBox)
                Padding(
                    padding: const EdgeInsets.fromLTRB(12, 8, 8, 0),
                    child: Row(children: [
                      Expanded(
                          child: TextField(
                              controller: _text,
                              focusNode: _textFocus,
                              minLines: 1,
                              maxLines: 5,
                              style: const TextStyle(color: Colors.white),
                              decoration: const InputDecoration(
                                  isDense: true,
                                  hintText: 'Text to send',
                                  hintStyle: TextStyle(color: Colors.white38),
                                  border: OutlineInputBorder()))),
                      IconButton(
                          tooltip: 'Send text',
                          color: Colors.white,
                          onPressed: _sending
                              ? null
                              : () => _send(() async {
                                    final value = _text.text;
                                    _text.clear();
                                    return value;
                                  }),
                          icon: const Icon(Icons.send)),
                    ])),
              SizedBox(
                  height: 44,
                  child: Row(children: [
                    // Keeps the system keyboard open and reports keystrokes.
                    SizedBox(
                        width: 1,
                        height: 1,
                        child: Opacity(
                            opacity: 0,
                            child: TextField(
                                controller: _typing,
                                focusNode: widget.focus,
                                keyboardType: TextInputType.visiblePassword,
                                textInputAction: TextInputAction.newline,
                                maxLines: null,
                                autocorrect: false,
                                enableSuggestions: false,
                                enableIMEPersonalizedLearning: false,
                                smartDashesType: SmartDashesType.disabled,
                                smartQuotesType: SmartQuotesType.disabled,
                                showCursor: false,
                                enableInteractiveSelection: false))),
                    Expanded(
                        child: ListView(
                            scrollDirection: Axis.horizontal,
                            children: [
                          for (final entry in {
                            'Esc': 'Escape',
                            'Tab': 'Tab',
                          }.entries)
                            _key(entry.key, () => widget.onKey(entry.value)),
                          for (final entry in {
                            'Ctrl': 'ControlLeft',
                            'Alt': 'AltLeft',
                            'Shift': 'ShiftLeft',
                            '⌘': 'MetaLeft'
                          }.entries)
                            _key(
                                entry.key,
                                () => setState(
                                    () => widget.onModifier(entry.value)),
                                selected:
                                    widget.modifiers.contains(entry.value)),
                          for (final entry in {
                            '←': 'ArrowLeft',
                            '↑': 'ArrowUp',
                            '↓': 'ArrowDown',
                            '→': 'ArrowRight',
                          }.entries)
                            _key(entry.key, () => widget.onKey(entry.value)),
                          _key('Text box', _toggleTextBox,
                              selected: _textBox, icon: Icons.edit_note),
                          _key(
                              'Paste',
                              _sending
                                  ? null
                                  : () => _send(() async =>
                                      (await Clipboard.getData(
                                              Clipboard.kTextPlain))
                                          ?.text),
                              tooltip: 'Paste this phone\'s clipboard',
                              icon: Icons.content_paste),
                        ])),
                    _key('Close keyboard', widget.onClose,
                        icon: Icons.keyboard_hide),
                  ])),
            ])),
      );
}

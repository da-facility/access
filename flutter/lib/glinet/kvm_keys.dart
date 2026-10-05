import 'package:flutter/services.dart';

String? kvmKey(PhysicalKeyboardKey key) {
  final usage = key.usbHidUsage;
  if (usage >> 16 != 7) return null;
  final code = usage & 0xffff;
  if (code >= 4 && code <= 29) {
    return 'Key${String.fromCharCode(65 + code - 4)}';
  }
  if (code >= 30 && code <= 38) return 'Digit${code - 29}';
  if (code >= 58 && code <= 69) return 'F${code - 57}';
  return const <int, String>{
    39: 'Digit0',
    40: 'Enter',
    41: 'Escape',
    42: 'Backspace',
    43: 'Tab',
    44: 'Space',
    45: 'Minus',
    46: 'Equal',
    47: 'BracketLeft',
    48: 'BracketRight',
    49: 'Backslash',
    51: 'Semicolon',
    52: 'Quote',
    53: 'Backquote',
    54: 'Comma',
    55: 'Period',
    56: 'Slash',
    57: 'CapsLock',
    70: 'PrintScreen',
    71: 'ScrollLock',
    72: 'Pause',
    73: 'Insert',
    74: 'Home',
    75: 'PageUp',
    76: 'Delete',
    77: 'End',
    78: 'PageDown',
    79: 'ArrowRight',
    80: 'ArrowLeft',
    81: 'ArrowDown',
    82: 'ArrowUp',
    83: 'NumLock',
    84: 'NumpadDivide',
    85: 'NumpadMultiply',
    86: 'NumpadSubtract',
    87: 'NumpadAdd',
    88: 'NumpadEnter',
    89: 'Numpad1',
    90: 'Numpad2',
    91: 'Numpad3',
    92: 'Numpad4',
    93: 'Numpad5',
    94: 'Numpad6',
    95: 'Numpad7',
    96: 'Numpad8',
    97: 'Numpad9',
    98: 'Numpad0',
    99: 'NumpadDecimal',
    224: 'ControlLeft',
    225: 'ShiftLeft',
    226: 'AltLeft',
    227: 'MetaLeft',
    228: 'ControlRight',
    229: 'ShiftRight',
    230: 'AltRight',
    231: 'MetaRight',
  }[code];
}

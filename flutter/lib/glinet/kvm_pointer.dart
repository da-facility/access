import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

/// A touch trackpad over the remote video. Physical mice use direct coordinates.
class KvmPointer extends StatefulWidget {
  final bool enabled;
  final ValueChanged<Offset> onMove;
  final void Function(String, bool) onButton;
  final VoidCallback onTap;
  final void Function(int, int) onScroll;
  final VoidCallback onFocus;
  final Widget child;

  const KvmPointer(
      {super.key,
      required this.enabled,
      required this.onMove,
      required this.onButton,
      required this.onTap,
      required this.onScroll,
      required this.onFocus,
      required this.child});

  @override
  State<KvmPointer> createState() => _KvmPointerState();
}

class _KvmPointerState extends State<KvmPointer> {
  Offset _cursor = const Offset(.5, .5);
  int? _pointer;
  String? _button;
  double _travel = 0;
  Duration _started = Duration.zero;

  void _move(Offset position) {
    _cursor = Offset(position.dx.clamp(0.0, 1.0), position.dy.clamp(0.0, 1.0));
    widget.onMove(_cursor);
  }

  void _release() {
    if (_button != null) widget.onButton(_button!, false);
    _pointer = null;
    _button = null;
  }

  @override
  void didUpdateWidget(KvmPointer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.enabled) _release();
  }

  @override
  void dispose() {
    _release();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, size) {
        Offset normalized(Offset point) =>
            Offset(point.dx / size.maxWidth, point.dy / size.maxHeight);
        return Listener(
          behavior: HitTestBehavior.opaque,
          onPointerDown: (event) {
            if (!widget.enabled || _pointer != null) return;
            widget.onFocus();
            _pointer = event.pointer;
            _travel = 0;
            _started = event.timeStamp;
            if (event.kind == PointerDeviceKind.mouse) {
              _button =
                  event.buttons & kSecondaryMouseButton != 0 ? 'right' : 'left';
              _move(normalized(event.localPosition));
              widget.onButton(_button!, true);
            } else {
              // Sync the remote cursor without jumping to the finger's location.
              _move(_cursor);
            }
          },
          onPointerMove: (event) {
            if (!widget.enabled || event.pointer != _pointer) return;
            _travel += event.localDelta.distance;
            _move(event.kind == PointerDeviceKind.mouse
                ? normalized(event.localPosition)
                : _cursor + normalized(event.localDelta));
          },
          onPointerUp: (event) {
            if (event.pointer != _pointer) return;
            if (widget.enabled &&
                event.kind != PointerDeviceKind.mouse &&
                _travel < 8 &&
                event.timeStamp - _started <
                    const Duration(milliseconds: 350)) {
              widget.onTap();
            }
            _release();
          },
          onPointerCancel: (event) {
            if (event.pointer == _pointer) _release();
          },
          onPointerHover: (event) {
            if (widget.enabled) _move(normalized(event.localPosition));
          },
          onPointerSignal: (event) {
            if (widget.enabled && event is PointerScrollEvent) {
              widget.onScroll(-event.scrollDelta.dx.sign.toInt(),
                  -event.scrollDelta.dy.sign.toInt());
            }
          },
          child: widget.child,
        );
      });
}

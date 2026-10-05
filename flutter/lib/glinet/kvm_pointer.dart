import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

/// A touch trackpad over the remote video. Physical mice use direct coordinates.
class KvmPointer extends StatefulWidget {
  final bool enabled;
  final ValueNotifier<double> zoom;
  final ValueChanged<Offset> onMove;
  final void Function(String, bool) onButton;
  final VoidCallback onTap;
  final void Function(int, int) onScroll;
  final VoidCallback onFocus;
  final VoidCallback? onMultitouch;
  final Widget child;

  const KvmPointer(
      {super.key,
      required this.enabled,
      required this.zoom,
      required this.onMove,
      required this.onButton,
      required this.onTap,
      required this.onScroll,
      required this.onFocus,
      this.onMultitouch,
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
  final _touches = <int>{};
  double get _zoom => widget.zoom.value;
  Offset _pan = Offset.zero;
  double _startZoom = 1;
  Offset _anchor = Offset.zero;
  Offset _lastFocal = Offset.zero;
  Offset _scroll = Offset.zero;
  bool _pinching = false;
  ScaleUpdateDetails? _pendingScale;
  bool _scaleFrameScheduled = false;

  Offset _clampPan(Offset pan) =>
      Offset(pan.dx.clamp(1 - _zoom, 0.0), pan.dy.clamp(1 - _zoom, 0.0));

  void _scaleUpdate(ScaleUpdateDetails details, Size size) {
    if (!widget.enabled || details.pointerCount < 2) return;
    _pendingScale = details;
    if (_scaleFrameScheduled) return;
    _scaleFrameScheduled = true;
    // Read both fingers together: their individual events can temporarily look
    // like a pinch during a horizontal scroll.
    WidgetsBinding.instance.scheduleFrameCallback((_) {
      _scaleFrameScheduled = false;
      if (mounted) _applyScale(size);
    });
  }

  void _applyScale(Size size) {
    final details = _pendingScale;
    _pendingScale = null;
    if (!widget.enabled || details == null) return;
    _pinching |= (details.scale - 1).abs() > .04;
    if (_pinching) {
      setState(() {
        widget.zoom.value = (_startZoom * details.scale).clamp(1.0, 4.0);
        final focal = Offset(details.localFocalPoint.dx / size.width,
            details.localFocalPoint.dy / size.height);
        _pan = _clampPan(focal - _anchor * _zoom);
      });
      _scroll = Offset.zero;
    } else {
      _scroll += details.localFocalPoint - _lastFocal;
      final x = (_scroll.dx / 12).truncate();
      final y = (_scroll.dy / 12).truncate();
      if (x != 0 || y != 0) {
        widget.onScroll(x, y);
        _scroll -= Offset(x * 12.0, y * 12.0);
      }
    }
    _lastFocal = details.localFocalPoint;
  }

  void _move(Offset position) {
    _cursor = Offset(position.dx.clamp(0.0, 1.0), position.dy.clamp(0.0, 1.0));
    widget.onMove(_cursor);
    if (_zoom > 1) {
      final visible = _cursor * _zoom + _pan;
      final pan = _clampPan(_pan +
          Offset(visible.dx.clamp(.05, .95) - visible.dx,
              visible.dy.clamp(.05, .95) - visible.dy));
      if (pan != _pan) setState(() => _pan = pan);
    }
  }

  void _release() {
    if (_button != null) widget.onButton(_button!, false);
    _pointer = null;
    _button = null;
  }

  void _zoomChanged() {
    setState(() => _pan = _clampPan(_pan));
  }

  @override
  void initState() {
    super.initState();
    widget.zoom.addListener(_zoomChanged);
  }

  @override
  void didUpdateWidget(KvmPointer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.zoom != widget.zoom) {
      oldWidget.zoom.removeListener(_zoomChanged);
      widget.zoom.addListener(_zoomChanged);
      _pan = _clampPan(_pan);
    }
    if (!widget.enabled) {
      _release();
      _touches.clear();
      _pendingScale = null;
    }
  }

  @override
  void dispose() {
    widget.zoom.removeListener(_zoomChanged);
    _release();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, size) {
        Offset normalized(Offset point) =>
            Offset(point.dx / size.maxWidth, point.dy / size.maxHeight);
        final viewport = Size(size.maxWidth, size.maxHeight);
        return GestureDetector(
            behavior: HitTestBehavior.opaque,
            dragStartBehavior: DragStartBehavior.down,
            onScaleStart: (details) {
              _startZoom = _zoom;
              _anchor = (normalized(details.localFocalPoint) - _pan) / _zoom;
              _lastFocal = details.localFocalPoint;
              _scroll = Offset.zero;
              _pinching = false;
            },
            onScaleUpdate: (details) => _scaleUpdate(details, viewport),
            onScaleEnd: (_) => _applyScale(viewport),
            child: Listener(
              behavior: HitTestBehavior.opaque,
              onPointerDown: (event) {
                if (!widget.enabled) return;
                if (event.kind != PointerDeviceKind.mouse) {
                  _touches.add(event.pointer);
                  if (_touches.length > 1) {
                    _release();
                    widget.onMultitouch?.call();
                    return;
                  }
                }
                if (_pointer != null) return;
                widget.onFocus();
                _pointer = event.pointer;
                _travel = 0;
                _started = event.timeStamp;
                if (event.kind == PointerDeviceKind.mouse) {
                  _button = event.buttons & kSecondaryMouseButton != 0
                      ? 'right'
                      : 'left';
                  _move((normalized(event.localPosition) - _pan) / _zoom);
                  widget.onButton(_button!, true);
                } else {
                  // Sync without moving the zoomed view before a possible pinch.
                  widget.onMove(_cursor);
                }
              },
              onPointerMove: (event) {
                if (!widget.enabled || event.pointer != _pointer) return;
                _travel += event.localDelta.distance;
                _move(event.kind == PointerDeviceKind.mouse
                    ? (normalized(event.localPosition) - _pan) / _zoom
                    : _cursor + normalized(event.localDelta) / _zoom);
              },
              onPointerUp: (event) {
                _touches.remove(event.pointer);
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
                _touches.remove(event.pointer);
                if (event.pointer == _pointer) _release();
              },
              onPointerHover: (event) {
                if (widget.enabled) {
                  _move((normalized(event.localPosition) - _pan) / _zoom);
                }
              },
              onPointerSignal: (event) {
                if (widget.enabled && event is PointerScrollEvent) {
                  widget.onScroll(-event.scrollDelta.dx.sign.toInt(),
                      -event.scrollDelta.dy.sign.toInt());
                }
              },
              child: ClipRect(
                  child: Transform(
                alignment: Alignment.topLeft,
                transform: Matrix4.identity()
                  ..translate(_pan.dx * size.maxWidth, _pan.dy * size.maxHeight)
                  ..scale(_zoom),
                child: widget.child,
              )),
            ));
      });
}

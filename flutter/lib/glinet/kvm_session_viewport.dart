import 'dart:math' as math;

import 'package:flutter/material.dart';

/// A shortcut shown in the arc that slides in from the screen edge.
class KvmEdgeAction {
  final String label;
  final IconData icon;
  final VoidCallback? onPressed;
  final bool selected;
  final bool destructive;

  const KvmEdgeAction(this.label, this.icon, this.onPressed,
      {this.selected = false, this.destructive = false});
}

/// The remote display owns the screen. Swiping in from either edge opens an
/// arc of shortcuts; its last entry opens the full session controls.
class KvmSessionViewport extends StatefulWidget {
  final double aspectRatio;
  final Widget display;
  final List<KvmEdgeAction> actions;
  final List<Widget> leading;
  final List<Widget> trailing;
  final ValueChanged<bool>? onMenuChanged;

  const KvmSessionViewport(
      {super.key,
      required this.aspectRatio,
      required this.display,
      this.actions = const [],
      required this.leading,
      required this.trailing,
      this.onMenuChanged});

  @override
  State<KvmSessionViewport> createState() => KvmSessionViewportState();
}

class KvmSessionViewportState extends State<KvmSessionViewport> {
  static const _edge = 18.0;
  bool _arc = false;
  bool _panel = false;
  bool _right = true;
  double _swipe = 0;

  bool get menuOpen => _arc || _panel;

  void _set({bool arc = false, bool panel = false, bool? right}) {
    final wasOpen = menuOpen;
    setState(() {
      _arc = arc;
      _panel = panel;
      if (right != null) _right = right;
    });
    if (wasOpen != menuOpen) widget.onMenuChanged?.call(menuOpen);
  }

  /// Opens the shortcut arc, or closes whatever is open.
  void toggleActions() => menuOpen ? close() : _set(arc: true);

  void close() => _set();

  Widget _edgeZone(bool right) => Positioned(
      top: 0,
      bottom: 0,
      left: right ? null : 0,
      right: right ? 0 : null,
      width: _edge,
      child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onHorizontalDragStart: (_) => _swipe = 0,
          onHorizontalDragUpdate: (details) {
            _swipe += right ? -details.delta.dx : details.delta.dx;
            if (_swipe > 24 && !menuOpen) _set(arc: true, right: right);
          },
          child: right
              ? Center(
                  child: Tooltip(
                      message: 'Open session controls',
                      child: GestureDetector(
                          onTap: () => _set(arc: true, right: true),
                          child: Container(
                              width: 5,
                              height: 56,
                              decoration: BoxDecoration(
                                  color: Colors.white38,
                                  borderRadius: BorderRadius.circular(3))))))
              : null));

  Widget _arcButtons(BoxConstraints bounds) {
    final more =
        KvmEdgeAction('All controls', Icons.tune, () => _set(panel: true));
    final actions = [
      ...widget.actions.where((action) => !action.destructive),
      more,
      ...widget.actions.where((action) => action.destructive),
    ];
    const inset = 12.0;
    final count = actions.length;
    final size = math
        .min(56.0, (bounds.maxHeight - inset * 2) / (count * 1.15))
        .clamp(32.0, 56.0);
    final step = size * 1.15;
    final half = step * (count - 1) / 2;
    final bulge = size * 1.3;
    return Stack(children: [
      for (var i = 0; i < count; i++)
        Builder(builder: (context) {
          final action = actions[i];
          final dy = -half + i * step;
          final t = dy / (half + size);
          final offset = inset + bulge * math.sqrt(1 - t * t);
          final onTap = action.onPressed == null
              ? null
              : () {
                  if (!identical(action, more)) close();
                  action.onPressed!();
                };
          final circle = Material(
              color: action.destructive
                  ? const Color(0xffe53935)
                  : action.selected
                      ? const Color(0xff0d47a1)
                      : const Color(0xff1e88e5),
              shape: const CircleBorder(
                  side: BorderSide(color: Colors.white54, width: 1.5)),
              elevation: 6,
              child: InkWell(
                  customBorder: const CircleBorder(),
                  onTap: onTap,
                  child: SizedBox(
                      width: size,
                      height: size,
                      child: Icon(action.icon,
                          color: action.onPressed == null
                              ? Colors.white38
                              : Colors.white,
                          size: size * .45))));
          final label = GestureDetector(
              onTap: onTap,
              child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                      color: Colors.black54,
                      borderRadius: BorderRadius.circular(6)),
                  child: Text(action.label,
                      style:
                          const TextStyle(color: Colors.white, fontSize: 12))));
          return Positioned(
              top: bounds.maxHeight / 2 + dy - size / 2,
              left: _right ? null : offset,
              right: _right ? offset : null,
              height: size,
              child: Tooltip(
                  message: action.label,
                  child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: _right
                          ? [label, const SizedBox(width: 6), circle]
                          : [circle, const SizedBox(width: 6), label])));
        }),
    ]);
  }

  Widget _controlsPanel(BoxConstraints bounds) => Align(
      alignment: _right ? Alignment.centerRight : Alignment.centerLeft,
      child: Padding(
          padding: const EdgeInsets.all(12),
          child: Focus(
              canRequestFocus: false,
              descendantsAreFocusable: false,
              child: Material(
                  color: const Color(0xff1c1c1e),
                  elevation: 12,
                  borderRadius: BorderRadius.circular(20),
                  clipBehavior: Clip.antiAlias,
                  child: ConstrainedBox(
                      constraints: BoxConstraints(
                          maxWidth: math.min(320.0, bounds.maxWidth - 24),
                          maxHeight: math.max(0.0, bounds.maxHeight - 24)),
                      child: SingleChildScrollView(
                          padding: const EdgeInsets.all(12),
                          child:
                              Column(mainAxisSize: MainAxisSize.min, children: [
                            Row(children: [
                              const Expanded(
                                  child: Text('Session controls',
                                      style: TextStyle(
                                          color: Colors.white,
                                          fontSize: 16,
                                          fontWeight: FontWeight.w600))),
                              IconButton(
                                  tooltip: 'Close controls',
                                  onPressed: close,
                                  icon: const Icon(Icons.close,
                                      color: Colors.white)),
                            ]),
                            Wrap(
                                alignment: WrapAlignment.spaceEvenly,
                                spacing: 4,
                                runSpacing: 8,
                                children: widget.leading),
                            const Divider(color: Colors.white24, height: 24),
                            Wrap(
                                alignment: WrapAlignment.spaceEvenly,
                                spacing: 4,
                                runSpacing: 8,
                                children: widget.trailing),
                          ])))))));

  @override
  Widget build(BuildContext context) => ColoredBox(
        color: Colors.black,
        child: Stack(children: [
          // Keep the remote screen's bottom edge out of the system's own
          // swipe area, so a phone's home gesture can start there.
          Positioned.fill(
              bottom: MediaQuery.systemGestureInsetsOf(context).bottom,
              child: Center(
                  child: AspectRatio(
                      aspectRatio: widget.aspectRatio, child: widget.display))),
          if (!menuOpen) ...[_edgeZone(false), _edgeZone(true)],
          if (menuOpen)
            Positioned.fill(
                child: ModalBarrier(
                    color: Colors.black38,
                    dismissible: true,
                    onDismiss: close,
                    semanticsLabel: 'Close session controls')),
          if (menuOpen)
            Positioned.fill(
                child: SafeArea(
                    child: LayoutBuilder(
                        builder: (context, bounds) => _panel
                            ? _controlsPanel(bounds)
                            : _arcButtons(bounds)))),
        ]),
      );
}

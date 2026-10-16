import 'dart:math' as math;

import 'package:flutter/material.dart';

/// The remote display owns the screen; only the floating controls use safe areas.
class KvmSessionViewport extends StatefulWidget {
  final double aspectRatio;
  final Widget display;
  final List<Widget> leading;
  final List<Widget> trailing;
  final ValueChanged<bool>? onMenuChanged;

  const KvmSessionViewport(
      {super.key,
      required this.aspectRatio,
      required this.display,
      required this.leading,
      required this.trailing,
      this.onMenuChanged});

  @override
  State<KvmSessionViewport> createState() => _KvmSessionViewportState();
}

class _KvmSessionViewportState extends State<KvmSessionViewport> {
  bool _open = false;
  bool _right = true;
  double _heightFraction = .85;
  double? _dragX;

  void _toggle() {
    setState(() => _open = !_open);
    widget.onMenuChanged?.call(_open);
  }

  @override
  Widget build(BuildContext context) => ColoredBox(
        color: Colors.black,
        child: Stack(children: [
          Positioned.fill(
              child: Center(
                  child: AspectRatio(
                      aspectRatio: widget.aspectRatio, child: widget.display))),
          if (_open)
            Positioned.fill(
                child: ModalBarrier(
                    color: Colors.black38,
                    dismissible: true,
                    onDismiss: _toggle,
                    semanticsLabel: 'Close session controls')),
          Positioned.fill(
              child: SafeArea(child: LayoutBuilder(builder: (context, bounds) {
            const diameter = 52.0;
            const inset = 12.0;
            final maxX = math.max(inset, bounds.maxWidth - diameter - inset);
            final travel =
                math.max(0.0, bounds.maxHeight - diameter - inset * 2);
            final x = (_dragX ?? (_right ? maxX : inset)).clamp(inset, maxX);
            final y = inset + travel * _heightFraction;
            final above = y > travel / 2;
            final panelWidth = math.min(320.0, bounds.maxWidth - inset * 2);
            final panelHeight = math.max(
                0.0,
                above
                    ? y - inset * 2
                    : bounds.maxHeight - y - diameter - inset * 2);
            return Stack(children: [
              if (_open)
                Positioned(
                    left: _right ? null : inset,
                    right: _right ? inset : null,
                    bottom: above ? bounds.maxHeight - y + inset : null,
                    top: above ? null : y + diameter + inset,
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
                                    maxWidth: panelWidth,
                                    maxHeight: panelHeight),
                                child: SingleChildScrollView(
                                    padding: const EdgeInsets.all(12),
                                    child: Column(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Row(children: [
                                            const Expanded(
                                                child: Text('Session controls',
                                                    style: TextStyle(
                                                        color: Colors.white,
                                                        fontSize: 16,
                                                        fontWeight:
                                                            FontWeight.w600))),
                                            IconButton(
                                                tooltip: 'Close controls',
                                                onPressed: _toggle,
                                                icon: const Icon(Icons.close,
                                                    color: Colors.white)),
                                          ]),
                                          Wrap(
                                              alignment:
                                                  WrapAlignment.spaceEvenly,
                                              spacing: 4,
                                              runSpacing: 8,
                                              children: widget.leading),
                                          const Divider(
                                              color: Colors.white24,
                                              height: 24),
                                          Wrap(
                                              alignment:
                                                  WrapAlignment.spaceEvenly,
                                              spacing: 4,
                                              runSpacing: 8,
                                              children: widget.trailing),
                                        ])))))),
              Positioned(
                  left: x,
                  top: y,
                  child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onPanUpdate: _open
                          ? null
                          : (details) => setState(() {
                                _dragX = ((_dragX ?? x) + details.delta.dx)
                                    .clamp(inset, maxX);
                                if (travel > 0) {
                                  _heightFraction = (_heightFraction +
                                          details.delta.dy / travel)
                                      .clamp(0.0, 1.0);
                                }
                              }),
                      onPanEnd: _open
                          ? null
                          : (_) => setState(() {
                                _right = (_dragX ?? x) + diameter / 2 >
                                    bounds.maxWidth / 2;
                                _dragX = null;
                              }),
                      child: Material(
                          color: const Color(0xe61c1c1e),
                          shape: const CircleBorder(
                              side: BorderSide(color: Colors.white24)),
                          elevation: 6,
                          child: SizedBox(
                              width: diameter,
                              height: diameter,
                              child: IconButton(
                                  tooltip: _open
                                      ? 'Close session controls'
                                      : 'Open session controls',
                                  onPressed: _toggle,
                                  icon: Icon(_open ? Icons.close : Icons.apps,
                                      color: Colors.white, size: 24)))))),
            ]);
          }))),
        ]),
      );
}

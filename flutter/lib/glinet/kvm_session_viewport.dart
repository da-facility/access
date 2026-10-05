import 'package:flutter/material.dart';

/// Reserve compact controls beside a landscape display, or above/below portrait.
class KvmSessionViewport extends StatelessWidget {
  final double aspectRatio;
  final Widget display;
  final List<Widget> leading;
  final List<Widget> trailing;

  const KvmSessionViewport(
      {super.key,
      required this.aspectRatio,
      required this.display,
      required this.leading,
      required this.trailing});

  Widget _controls(List<Widget> children, bool vertical) => Focus(
        canRequestFocus: false,
        descendantsAreFocusable: false,
        child: SingleChildScrollView(
          scrollDirection: vertical ? Axis.vertical : Axis.horizontal,
          child:
              vertical ? Column(children: children) : Row(children: children),
        ),
      );

  @override
  Widget build(BuildContext context) => ColoredBox(
        color: Colors.black,
        child: LayoutBuilder(builder: (context, constraints) {
          final landscape = constraints.maxWidth > constraints.maxHeight;
          final video = Expanded(
              child: Center(
                  child:
                      AspectRatio(aspectRatio: aspectRatio, child: display)));
          return SafeArea(
            bottom: !landscape,
            child: landscape
                ? Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                        SizedBox(width: 48, child: _controls(leading, true)),
                        video,
                        SizedBox(width: 48, child: _controls(trailing, true)),
                      ])
                : Column(children: [
                    SizedBox(height: 48, child: _controls(leading, false)),
                    video,
                    SizedBox(height: 48, child: _controls(trailing, false)),
                  ]),
          );
        }),
      );
}

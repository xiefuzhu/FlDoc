import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../../app/theme.dart';
import '../markdown/md_model.dart';
import '../render/block_renderer.dart';
import 'mermaid_renderer.dart';

/// Renders a ```mermaid code block via [MermaidRenderer] with fallback to
/// syntax-highlighted source code on failure/timeout (FR-RD-04).
class MermaidBlock extends StatefulWidget {
  const MermaidBlock({super.key, required this.source, required this.style});

  final String source;
  final ReaderStyle style;

  @override
  State<MermaidBlock> createState() => _MermaidBlockState();
}

class _MermaidBlockState extends State<MermaidBlock> {
  Future<MermaidRenderResult>? _future;
  bool _showSource = false;

  @override
  void initState() {
    super.initState();
    _kick();
  }

  @override
  void didUpdateWidget(covariant MermaidBlock oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.source != widget.source || oldWidget.style.dark != widget.style.dark) {
      _kick();
    }
  }

  void _kick() {
    _future = MermaidRenderer.instance.render(widget.source, dark: widget.style.dark);
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.style;
    return FutureBuilder<MermaidRenderResult>(
      future: _future,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: s.codeBg,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: s.border),
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              const SizedBox(width: 14, height: 14, child: ProgressRing(strokeWidth: 2)),
              const SizedBox(width: 10),
              Text('正在渲染 Mermaid 图表…', style: TextStyle(fontSize: 13, color: s.muted)),
            ]),
          );
        }
        final res = snap.data;
        if (res != null && res.ok && !_showSource) {
          return Container(
            decoration: BoxDecoration(
              color: s.surface,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: s.border),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Container(
                  padding: const EdgeInsets.fromLTRB(12, 2, 4, 2),
                  decoration: BoxDecoration(border: Border(bottom: BorderSide(color: s.border))),
                  child: Row(children: [
                    Text('mermaid', style: TextStyle(fontSize: 12, color: s.muted)),
                    const Spacer(),
                    HyperlinkButton(
                      onPressed: () => setState(() => _showSource = true),
                      child: const Text('查看源码', style: TextStyle(fontSize: 12)),
                    ),
                  ]),
                ),
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: res.pngFile != null
                        ? Image.file(res.pngFile!, filterQuality: FilterQuality.medium)
                        : SvgPicture.string(res.svgText!),
                  ),
                ),
              ],
            ),
          );
        }

        // Fallback or user chose source view.
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (res != null && !res.ok)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: InfoBar(
                  title: const Text('Mermaid 渲染失败'),
                  content: Text(res.error ?? '未知错误'),
                  severity: InfoBarSeverity.warning,
                  isLong: false,
                ),
              )
            else if (_showSource)
              Align(
                alignment: Alignment.centerRight,
                child: HyperlinkButton(
                  onPressed: () => setState(() => _showSource = false),
                  child: const Text('查看图表', style: TextStyle(fontSize: 12)),
                ),
              ),
            CodeBlockView(
              language: 'mermaid',
              run: InlineRun([Seg(widget.source, styles: const {SegStyle.code})]),
              style: s,
            ),
          ],
        );
      },
    );
  }
}

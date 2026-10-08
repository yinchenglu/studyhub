import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// 图片 / 动图查看器：左右滑动切换、双指缩放、保存提示
/// 动图（GIF / 动画 WebP）会直接动起来。
class ImageViewerPage extends StatefulWidget {
  final List<String> images;
  final Map<String, String> headers;
  final int initialIndex;
  final List<String>? titles;

  const ImageViewerPage({
    super.key,
    required this.images,
    this.headers = const {},
    this.initialIndex = 0,
    this.titles,
  });

  @override
  State<ImageViewerPage> createState() => _ImageViewerPageState();
}

class _ImageViewerPageState extends State<ImageViewerPage> {
  late final PageController _controller;
  late int _index;
  bool _uiVisible = true;

  @override
  void initState() {
    super.initState();
    _index = widget.initialIndex;
    _controller = PageController(initialPage: _index);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  }

  @override
  void dispose() {
    _controller.dispose();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: GestureDetector(
        onTap: () => setState(() => _uiVisible = !_uiVisible),
        child: Stack(
          children: [
            PageView.builder(
              controller: _controller,
              itemCount: widget.images.length,
              onPageChanged: (i) => setState(() => _index = i),
              itemBuilder: (context, i) {
                final url = widget.images[i];
                return InteractiveViewer(
                  minScale: 1,
                  maxScale: 6,
                  child: Center(
                    child: CachedNetworkImage(
                      imageUrl: url,
                      httpHeaders: widget.headers,
                      fit: BoxFit.contain,
                      fadeInDuration: const Duration(milliseconds: 120),
                      placeholder: (_, __) => const SizedBox(
                        height: 42,
                        width: 42,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white24),
                      ),
                      errorWidget: (_, u, e) => Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.broken_image_outlined, color: Colors.white38, size: 44),
                          const SizedBox(height: 10),
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 32),
                            child: Text('加载失败：$u', style: const TextStyle(color: Colors.white38, fontSize: 12), textAlign: TextAlign.center),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
            if (_uiVisible) _topBar(),
            if (_uiVisible && widget.images.length > 1) _indicator(),
          ],
        ),
      ),
    );
  }

  Widget _topBar() {
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: SafeArea(
        child: Container(
          color: Colors.black.withOpacity(0.35),
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
          child: Row(
            children: [
              IconButton(
                icon: const Icon(Icons.close, color: Colors.white),
                onPressed: () => Navigator.of(context).pop(),
              ),
              Expanded(
                child: Text(
                  (widget.titles != null && _index < widget.titles!.length)
                      ? widget.titles![_index]
                      : '${_index + 1} / ${widget.images.length}',
                  style: const TextStyle(color: Colors.white, fontSize: 14),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              IconButton(
                tooltip: '保存到手机相册',
                icon: const Icon(Icons.download_outlined, color: Colors.white),
                onPressed: () {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('长按图片可另存：本版本请在「视频」里用长按菜单下载到本地')),
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _indicator() {
    return Positioned(
      bottom: 0,
      left: 0,
      right: 0,
      child: SafeArea(
        child: Container(
          color: Colors.black.withOpacity(0.35),
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: Center(
            child: Text('${_index + 1} / ${widget.images.length}', style: const TextStyle(color: Colors.white70, fontSize: 13)),
          ),
        ),
      ),
    );
  }
}

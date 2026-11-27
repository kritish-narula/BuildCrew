import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

/// Network image for low-end phones: disk + memory cache (a photo is downloaded once), decoded at the size it is DRAWN
/// (not at 12 MP), with a short fade-in over a flat placeholder. Use instead of `Image.network`.
class NetImage extends StatelessWidget {
  const NetImage(this.url, {super.key, this.width, this.height, this.fit = BoxFit.cover, this.placeholder, this.radius});
  final String url;
  final double? width, height;
  final BoxFit fit;
  final Widget? placeholder;
  final BorderRadius? radius;

  @override
  Widget build(BuildContext context) {
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final bg = Container(width: width, height: height, color: const Color(0xFFEFF1F4), child: placeholder);
    final img = CachedNetworkImage(
      imageUrl: url,
      width: width,
      height: height,
      fit: fit,
      memCacheWidth: (width != null && width!.isFinite) ? (width! * dpr).round() : 800,
      fadeInDuration: const Duration(milliseconds: 150),
      fadeOutDuration: Duration.zero,
      placeholder: (_, __) => bg,
      errorWidget: (_, __, ___) => Container(
          width: width, height: height, color: const Color(0xFFEFF1F4), child: const Icon(Icons.image_not_supported_outlined, color: Color(0xFF9AA3AF))),
    );
    return radius == null ? img : ClipRRect(borderRadius: radius!, child: img);
  }
}

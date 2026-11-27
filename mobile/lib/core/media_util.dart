import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:path_provider/path_provider.dart';

/// Longest edge / quality for every photo that leaves the phone (work photos, selfies, proofs, documents stay readable).
const kMaxPhotoEdge = 1600;
const kPhotoQuality = 75;
const _skipBelowBytes = 250 * 1024; // already small: do not re-encode (and lose quality for nothing)

/// Returns a path to a JPEG no larger than [kMaxPhotoEdge] on its long edge at ~[kPhotoQuality] % quality, or the original
/// when it is already small / compression is not possible. Never throws: a failed compression just uploads the original.
Future<String> compressImage(String path) async {
  try {
    final f = File(path);
    if (!f.existsSync() || f.lengthSync() < _skipBelowBytes) return path;
    final dir = (await getTemporaryDirectory()).path;
    final out = '$dir/up_${DateTime.now().microsecondsSinceEpoch}.jpg';
    final r = await FlutterImageCompress.compressAndGetFile(path, out,
        minWidth: kMaxPhotoEdge, minHeight: kMaxPhotoEdge, quality: kPhotoQuality, format: CompressFormat.jpeg, keepExif: false);
    if (r == null) return path;
    return File(r.path).lengthSync() < f.lengthSync() ? r.path : path;
  } catch (e) {
    debugPrint('compress skipped: $e');
    return path;
  }
}

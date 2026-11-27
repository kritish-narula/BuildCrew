import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';

import '../l10n/gen/app_localizations.dart';
import 'common.dart';

/// Add photos to a job in one go: camera (one photo) or gallery (several at once, up to [remaining]).
/// Same on-device resize/compress and private copy as `pickPhoto`. Returns the saved file paths (empty = cancelled).
Future<List<String>> pickPhotos(BuildContext context, {required int remaining}) async {
  if (remaining <= 0) return const [];
  final l = L.of(context);
  final src = await showModalBottomSheet<ImageSource>(
    context: context,
    showDragHandle: true,
    builder: (c) => SafeArea(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        ListTile(
            minTileHeight: 60,
            leading: const IconBadge(Icons.photo_camera_rounded, size: 40),
            title: Text(l.takePhoto, maxLines: 1, overflow: TextOverflow.ellipsis),
            onTap: () => Navigator.pop(c, ImageSource.camera)),
        ListTile(
            minTileHeight: 60,
            leading: const IconBadge(Icons.photo_library_rounded, size: 40),
            title: Text(l.cxPickSeveral, maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: Text(l.cxPickSeveralSub(remaining), maxLines: 1, overflow: TextOverflow.ellipsis),
            onTap: () => Navigator.pop(c, ImageSource.gallery)),
        const SizedBox(height: 8),
      ]),
    ),
  );
  if (src == null) return const [];
  try {
    final picker = ImagePicker();
    final List<XFile> files;
    if (src == ImageSource.camera) {
      final x = await picker.pickImage(source: src, maxWidth: 1600, maxHeight: 1600, imageQuality: 72);
      files = x == null ? const [] : [x];
    } else if (remaining >= 2) {
      // pickMultiImage insists on limit >= 2; with one slot left a single pick is used instead.
      files = await picker.pickMultiImage(maxWidth: 1600, maxHeight: 1600, imageQuality: 72, limit: remaining);
    } else {
      final x = await picker.pickImage(source: src, maxWidth: 1600, maxHeight: 1600, imageQuality: 72);
      files = x == null ? const [] : [x];
    }
    if (files.isEmpty) return const [];
    // Some gallery apps ignore `limit`: never return more than fits.
    final dir = Directory('${(await getApplicationDocumentsDirectory()).path}/photos');
    await dir.create(recursive: true);
    final out = <String>[];
    var n = 0;
    for (final x in files.take(remaining)) {
      final ext = x.path.contains('.') ? x.path.split('.').last : 'jpg';
      final kept = await File(x.path).copy('${dir.path}/${DateTime.now().microsecondsSinceEpoch}_${n++}.$ext');
      out.add(kept.path);
    }
    return out;
  } on PlatformException catch (e) {
    if (context.mounted) showError(context, e);
    return const [];
  }
}

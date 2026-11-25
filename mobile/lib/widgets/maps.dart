import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../core/location.dart';
import '../core/theme.dart';
import '../l10n/gen/app_localizations.dart';
import 'common.dart' show BtnLabel;
import 'media.dart' show AppImage;

const _tiles = 'https://tile.openstreetmap.org/{z}/{x}/{y}.png';

Widget _attribution() => const Positioned(
      right: 6,
      bottom: 4,
      child: DecoratedBox(
        decoration: BoxDecoration(color: Color(0xB3FFFFFF), borderRadius: BorderRadius.all(Radius.circular(6))),
        child: Padding(padding: EdgeInsets.symmetric(horizontal: 6, vertical: 1), child: Text('© OpenStreetMap', style: TextStyle(fontSize: 10, height: 1.3, color: BC.inkSoft))),
      ),
    );

/// Where the job is. Before a worker is hired we show only the AREA (a soft circle, no exact
/// pin) — the customer's exact address is revealed only to the hired worker.
class JobMap extends StatelessWidget {
  const JobMap({super.key, required this.lat, required this.lng, this.exact = false, this.me, this.height = 180, this.onDirections});
  final double lat, lng;
  final bool exact;
  final (double, double)? me;
  final double height;
  final VoidCallback? onDirections;

  @override
  Widget build(BuildContext context) {
    final l = L.of(context);
    final job = LatLng(lat, lng);
    return ClipRRect(
      borderRadius: BorderRadius.circular(BC.r),
      child: SizedBox(
        height: height,
        child: Stack(children: [
          FlutterMap(
            options: MapOptions(
              initialCenter: job,
              initialZoom: exact ? 16 : 14,
              interactionOptions: const InteractionOptions(flags: InteractiveFlag.pinchZoom | InteractiveFlag.drag),
            ),
            children: [
              if (AppImage.allowNetwork) TileLayer(urlTemplate: _tiles, userAgentPackageName: 'com.buildcrew.app'),
              if (!exact)
                CircleLayer(circles: [
                  CircleMarker(point: job, radius: 400, useRadiusInMeter: true, color: BC.brand.withValues(alpha: 0.18), borderColor: BC.brand, borderStrokeWidth: 2),
                ]),
              MarkerLayer(markers: [
                if (me != null)
                  Marker(
                    point: LatLng(me!.$1, me!.$2),
                    width: 22,
                    height: 22,
                    child: Container(decoration: BoxDecoration(color: BC.info, shape: BoxShape.circle, border: Border.all(color: Colors.white, width: 3))),
                  ),
                if (exact)
                  Marker(point: job, width: 44, height: 44, alignment: Alignment.topCenter, child: const Icon(Icons.location_on_rounded, color: BC.brand, size: 44)),
              ]),
            ],
          ),
          _attribution(),
          if (onDirections != null)
            Positioned(
              left: 10,
              bottom: 10,
              child: FilledButton.icon(
                onPressed: onDirections,
                style: FilledButton.styleFrom(
                    minimumSize: const Size(0, BC.btnXs),
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                icon: const Icon(Icons.directions_rounded, size: 20),
                label: BtnLabel(l.directions),
              ),
            ),
        ]),
      ),
    );
  }
}

/// Customer picks the job location: centre pin stays fixed, the map moves under it.
/// "Use my location" jumps to GPS; the address is looked up whenever the map stops moving.
class LocationPicker extends StatefulWidget {
  const LocationPicker({super.key, required this.initial, required this.onChanged, this.height = 260, this.initialZoom = 16});
  final LatLng initial;
  final double initialZoom;
  final void Function(LatLng point) onChanged;
  final double height;
  @override
  State<LocationPicker> createState() => LocationPickerState();
}

class LocationPickerState extends State<LocationPicker> {
  final _map = MapController();
  bool _moving = false;

  @override
  void dispose() {
    _map.dispose();
    super.dispose();
  }

  void moveTo(LatLng p) {
    try {
      _map.move(p, 17);
    } catch (_) {/* map not laid out yet */}
  }

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(BC.rMd),
      child: SizedBox(
        height: widget.height,
        child: Stack(alignment: Alignment.center, children: [
          FlutterMap(
            mapController: _map,
            options: MapOptions(
              initialCenter: widget.initial,
              initialZoom: widget.initialZoom,
              onPositionChanged: (camera, gesture) {
                if (gesture && !_moving && mounted) setState(() => _moving = true);
              },
              onMapEvent: (e) {
                if (!mounted) return;
                if (e is MapEventMoveEnd || e is MapEventFlingAnimationEnd || e is MapEventDoubleTapZoomEnd) {
                  setState(() => _moving = false);
                  widget.onChanged(_map.camera.center);
                }
              },
            ),
            children: [if (AppImage.allowNetwork) TileLayer(urlTemplate: _tiles, userAgentPackageName: 'com.buildcrew.app')],
          ),
          // fixed centre pin (lifts while dragging)
          IgnorePointer(
            child: AnimatedSlide(
              duration: const Duration(milliseconds: 150),
              offset: Offset(0, _moving ? -0.75 : -0.5),
              child: const Icon(Icons.location_on_rounded, color: BC.brand, size: 52),
            ),
          ),
          _attribution(),
        ]),
      ),
    );
  }
}

/// Distance label from the worker's current position (if known) to a point.
String? distanceFromMe(double lat, double lng) {
  final p = LocationService.last;
  if (p == null) return null;
  return LocationService.km(p.latitude, p.longitude, lat, lng).toStringAsFixed(1);
}


/// Customer's live view: the house, the worker's moving position and the line between them.
class TrackingMap extends StatelessWidget {
  const TrackingMap({super.key, required this.houseLat, required this.houseLng, this.workerLat, this.workerLng, this.height = 220});
  final double houseLat, houseLng;
  final double? workerLat, workerLng;
  final double height;

  @override
  Widget build(BuildContext context) {
    final house = LatLng(houseLat, houseLng);
    final worker = workerLat == null ? null : LatLng(workerLat!, workerLng!);
    final bounds = worker == null ? null : LatLngBounds.fromPoints([house, worker]);
    return ClipRRect(
      borderRadius: BorderRadius.circular(BC.r),
      child: SizedBox(
        height: height,
        child: Stack(children: [
          FlutterMap(
            options: MapOptions(
              initialCenter: house,
              initialZoom: 14,
              initialCameraFit: bounds == null ? null : CameraFit.bounds(bounds: bounds, padding: const EdgeInsets.all(48), maxZoom: 16),
            ),
            children: [
              if (AppImage.allowNetwork) TileLayer(urlTemplate: _tiles, userAgentPackageName: 'com.buildcrew.app'),
              if (worker != null) PolylineLayer(polylines: [Polyline(points: [worker, house], color: BC.info, strokeWidth: 4)]),
              MarkerLayer(markers: [
                Marker(
                  point: house,
                  width: 44,
                  height: 44,
                  child: Container(
                    decoration: BoxDecoration(color: BC.brand, shape: BoxShape.circle, border: Border.all(color: Colors.white, width: 3)),
                    child: const Icon(Icons.home_rounded, color: Colors.white, size: 22),
                  ),
                ),
                if (worker != null)
                  Marker(
                    point: worker,
                    width: 44,
                    height: 44,
                    child: Container(
                      decoration: BoxDecoration(color: BC.info, shape: BoxShape.circle, border: Border.all(color: Colors.white, width: 3)),
                      child: const Icon(Icons.two_wheeler_rounded, color: Colors.white, size: 22),
                    ),
                  ),
              ]),
            ],
          ),
          _attribution(),
        ]),
      ),
    );
  }
}

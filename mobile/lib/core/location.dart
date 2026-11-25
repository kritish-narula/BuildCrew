import 'dart:async';

import 'package:flutter/material.dart';
import 'package:geocoding/geocoding.dart';
import 'package:geolocator/geolocator.dart';
import 'package:url_launcher/url_launcher.dart';

import '../l10n/gen/app_localizations.dart';
import 'theme.dart';

/// Everything location in one place, with the failure cases handled *for the user*:
///  * GPS switched off      → dialog with "Turn on location" (opens system settings)
///  * permission denied     → asks again; if "don't ask again" → "Open app settings"
///  * slow/indoor GPS fix   → instant last-known position first, then a fresh fix
///                            (balanced accuracy, 20 s limit) — never hangs forever
class LocationService {
  LocationService._();
  static Position? last;

  /// Silent: only returns a position if permission is ALREADY granted (no dialogs).
  static Future<Position?> quiet() async {
    try {
      final perm = await Geolocator.checkPermission();
      if (perm != LocationPermission.always && perm != LocationPermission.whileInUse) return null;
      if (!await Geolocator.isLocationServiceEnabled()) return null;
      final lk = await Geolocator.getLastKnownPosition();
      if (lk != null) last = lk;
      last = await Geolocator.getCurrentPosition(
              locationSettings: const LocationSettings(accuracy: LocationAccuracy.medium, timeLimit: Duration(seconds: 15)))
          .catchError((_) => lk ?? last!);
      return last;
    } catch (_) {
      return last;
    }
  }

  /// Interactive: explains and fixes problems. Returns null only if the user gives up.
  static Future<Position?> get(BuildContext context, {bool precise = true}) async {
    final l = L.of(context);
    if (!await Geolocator.isLocationServiceEnabled()) {
      if (!context.mounted) return null;
      final go = await _ask(context, Icons.location_off_rounded, l.gpsOffTitle, l.gpsOffBody, l.turnOnLocation);
      if (go != true) return null;
      await Geolocator.openLocationSettings();
      // give the user time to flip the switch and come back
      for (var i = 0; i < 20 && !await Geolocator.isLocationServiceEnabled(); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 500));
      }
      if (!await Geolocator.isLocationServiceEnabled()) return null;
    }
    var perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied) perm = await Geolocator.requestPermission();
    if (perm == LocationPermission.deniedForever || perm == LocationPermission.denied) {
      if (!context.mounted) return null;
      final go = await _ask(context, Icons.lock_outline_rounded, l.locPermTitle, l.locPermBody, l.openSettings);
      if (go == true) await Geolocator.openAppSettings();
      return null;
    }
    try {
      final fresh = await Geolocator.getCurrentPosition(
        locationSettings: LocationSettings(
            accuracy: precise ? LocationAccuracy.high : LocationAccuracy.medium, timeLimit: const Duration(seconds: 20)),
      );
      return last = fresh;
    } catch (_) {
      // Indoors / weak signal: fall back to the last known fix rather than failing.
      final lk = await Geolocator.getLastKnownPosition();
      if (lk != null) return last = lk;
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l.gpsWeak, style: const TextStyle(fontSize: 16))));
      }
      return null;
    }
  }

  static Future<bool?> _ask(BuildContext context, IconData icon, String title, String body, String action) => showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          icon: Icon(icon, size: 44, color: BC.brand),
          title: Text(title, textAlign: TextAlign.center),
          content: Text(body, textAlign: TextAlign.center, style: const TextStyle(fontSize: 16)),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: Text(L.of(context).cancel)),
            FilledButton(onPressed: () => Navigator.pop(c, true), child: Text(action)),
          ],
        ),
      );

  /// Reverse geocoding via Android's built-in geocoder (free, no API key).
  static Future<Address?> address(double lat, double lng) async {
    try {
      final p = (await placemarkFromCoordinates(lat, lng).timeout(const Duration(seconds: 8))).firstOrNull;
      if (p == null) return null;
      String? nz(String? s) => (s == null || s.trim().isEmpty) ? null : s.trim();
      final area = nz(p.subLocality) ?? nz(p.locality) ?? nz(p.subAdministrativeArea);
      final city = nz(p.locality) ?? nz(p.subAdministrativeArea) ?? nz(p.administrativeArea);
      final line = [nz(p.name), nz(p.street), area, city, nz(p.postalCode)].whereType<String>().toSet().join(', ');
      return Address(area: area ?? city ?? '', city: city ?? '', line: line);
    } catch (_) {
      return null;
    }
  }

  static double km(double lat1, double lng1, double lat2, double lng2) => Geolocator.distanceBetween(lat1, lng1, lat2, lng2) / 1000;

  /// Turn-by-turn directions in Google Maps (or any maps app).
  static Future<void> directions(double lat, double lng) =>
      launchUrl(Uri.parse('https://www.google.com/maps/dir/?api=1&destination=$lat,$lng'), mode: LaunchMode.externalApplication);
}

class Address {
  Address({required this.area, required this.city, required this.line});
  final String area, city, line;
}

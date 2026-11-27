import 'package:flutter/material.dart';

import '../../l10n/gen/app_localizations.dart';

/// A common job the customer can start from with one tap (first step of Post a job): sets the trade and fills a
/// starter description (always >= 50 characters, so the description rule is met) that the customer then edits.
class JobTemplate {
  const JobTemplate(this.id, this.trade, this.icon);
  final String id, trade;
  final IconData icon;
}

/// Twelve everyday jobs, in the order they are shown.
const jobTemplates = <JobTemplate>[
  JobTemplate('TapLeak', 'plumber', Icons.water_drop_rounded),
  JobTemplate('FanFitting', 'electrician', Icons.air_rounded),
  JobTemplate('SwitchSocket', 'electrician', Icons.power_rounded),
  JobTemplate('WallPaint', 'painter', Icons.format_paint_rounded),
  JobTemplate('DoorRepair', 'carpenter', Icons.door_front_door_rounded),
  JobTemplate('Furniture', 'carpenter', Icons.bed_rounded),
  JobTemplate('CompoundWall', 'mason', Icons.fence_rounded),
  JobTemplate('TileFixing', 'mason', Icons.grid_view_rounded),
  JobTemplate('Plaster', 'mason', Icons.water_damage_rounded),
  JobTemplate('BathroomFit', 'plumber', Icons.bathtub_rounded),
  JobTemplate('NewWiring', 'electrician', Icons.cable_rounded),
  JobTemplate('HelperDay', 'helper', Icons.handyman_rounded),
];

String templateTitle(L l, String id) => switch (id) {
      'TapLeak' => l.tplTapLeakTitle,
      'FanFitting' => l.tplFanFittingTitle,
      'SwitchSocket' => l.tplSwitchSocketTitle,
      'WallPaint' => l.tplWallPaintTitle,
      'DoorRepair' => l.tplDoorRepairTitle,
      'Furniture' => l.tplFurnitureTitle,
      'CompoundWall' => l.tplCompoundWallTitle,
      'TileFixing' => l.tplTileFixingTitle,
      'Plaster' => l.tplPlasterTitle,
      'BathroomFit' => l.tplBathroomFitTitle,
      'NewWiring' => l.tplNewWiringTitle,
      _ => l.tplHelperDayTitle,
    };

/// The starter description in the user's language (Hindi for Hindi, English otherwise).
String templateText(L l, String id) => switch (id) {
      'TapLeak' => l.tplTapLeakText,
      'FanFitting' => l.tplFanFittingText,
      'SwitchSocket' => l.tplSwitchSocketText,
      'WallPaint' => l.tplWallPaintText,
      'DoorRepair' => l.tplDoorRepairText,
      'Furniture' => l.tplFurnitureText,
      'CompoundWall' => l.tplCompoundWallText,
      'TileFixing' => l.tplTileFixingText,
      'Plaster' => l.tplPlasterText,
      'BathroomFit' => l.tplBathroomFitText,
      'NewWiring' => l.tplNewWiringText,
      _ => l.tplHelperDayText,
    };

/// Language of [templateText]: only Hindi has its own text, every other app language gets English.
String templateLang(L l) => l.localeName.startsWith('hi') ? 'hi' : 'en';

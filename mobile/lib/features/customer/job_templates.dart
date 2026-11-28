import 'package:flutter/material.dart';

import '../../l10n/gen/app_localizations.dart';

/// Id of the "Other work — I'll explain" option every trade has: no starter text, the customer describes the work on the next step.
const otherJobId = 'Other';

/// A common job the customer can start from with one tap (first step of Post a job, shown under its trade): sets a
/// starter description (always >= 50 characters, so the description rule is met) that the customer then edits.
class JobTemplate {
  JobTemplate(this.id, this.trade, this.icon, this.title, this.text);
  final String id, trade;
  final IconData icon;

  /// Localised title and starter description (Hindi, Hinglish and English have their own text).
  final String Function(L l) title, text;
}

/// Every trade's everyday jobs, in the order they are shown (the trade's "Other work" option is added by the screen).
final jobTemplates = <JobTemplate>[
  // ---- mason
  JobTemplate('CompoundWall', 'mason', Icons.fence_rounded, (l) => l.tplCompoundWallTitle, (l) => l.tplCompoundWallText),
  JobTemplate('TileFixing', 'mason', Icons.grid_view_rounded, (l) => l.tplTileFixingTitle, (l) => l.tplTileFixingText),
  JobTemplate('Plaster', 'mason', Icons.water_damage_rounded, (l) => l.tplPlasterTitle, (l) => l.tplPlasterText),
  JobTemplate('BrickPartition', 'mason', Icons.vertical_split_rounded, (l) => l.tplBrickPartitionTitle, (l) => l.tplBrickPartitionText),
  JobTemplate('FloorRepair', 'mason', Icons.layers_rounded, (l) => l.tplFloorRepairTitle, (l) => l.tplFloorRepairText),
  JobTemplate('SmallConstruction', 'mason', Icons.home_work_rounded, (l) => l.tplSmallConstructionTitle, (l) => l.tplSmallConstructionText),
  // ---- plumber
  JobTemplate('TapLeak', 'plumber', Icons.water_drop_rounded, (l) => l.tplTapLeakTitle, (l) => l.tplTapLeakText),
  JobTemplate('PipeLeak', 'plumber', Icons.plumbing_rounded, (l) => l.tplPipeLeakTitle, (l) => l.tplPipeLeakText),
  JobTemplate('ToiletFlush', 'plumber', Icons.wc_rounded, (l) => l.tplToiletFlushTitle, (l) => l.tplToiletFlushText),
  JobTemplate('BathroomFit', 'plumber', Icons.bathtub_rounded, (l) => l.tplBathroomFitTitle, (l) => l.tplBathroomFitText),
  JobTemplate('TankMotor', 'plumber', Icons.settings_rounded, (l) => l.tplTankMotorTitle, (l) => l.tplTankMotorText),
  JobTemplate('DrainBlock', 'plumber', Icons.waves_rounded, (l) => l.tplDrainBlockTitle, (l) => l.tplDrainBlockText),
  // ---- electrician
  JobTemplate('FanFitting', 'electrician', Icons.air_rounded, (l) => l.tplFanFittingTitle, (l) => l.tplFanFittingText),
  JobTemplate('SwitchSocket', 'electrician', Icons.power_rounded, (l) => l.tplSwitchSocketTitle, (l) => l.tplSwitchSocketText),
  JobTemplate('NewWiring', 'electrician', Icons.cable_rounded, (l) => l.tplNewWiringTitle, (l) => l.tplNewWiringText),
  JobTemplate('LightFitting', 'electrician', Icons.lightbulb_rounded, (l) => l.tplLightFittingTitle, (l) => l.tplLightFittingText),
  JobTemplate('MCBFuse', 'electrician', Icons.flash_on_rounded, (l) => l.tplMCBFuseTitle, (l) => l.tplMCBFuseText),
  JobTemplate('InverterGeyser', 'electrician', Icons.battery_charging_full_rounded, (l) => l.tplInverterGeyserTitle, (l) => l.tplInverterGeyserText),
  // ---- carpenter
  JobTemplate('DoorRepair', 'carpenter', Icons.door_front_door_rounded, (l) => l.tplDoorRepairTitle, (l) => l.tplDoorRepairText),
  JobTemplate('Furniture', 'carpenter', Icons.bed_rounded, (l) => l.tplFurnitureTitle, (l) => l.tplFurnitureText),
  JobTemplate('Cupboard', 'carpenter', Icons.door_sliding_rounded, (l) => l.tplCupboardTitle, (l) => l.tplCupboardText),
  JobTemplate('NewShelf', 'carpenter', Icons.view_agenda_rounded, (l) => l.tplNewShelfTitle, (l) => l.tplNewShelfText),
  JobTemplate('WindowFrame', 'carpenter', Icons.window_rounded, (l) => l.tplWindowFrameTitle, (l) => l.tplWindowFrameText),
  JobTemplate('ModularKitchen', 'carpenter', Icons.kitchen_rounded, (l) => l.tplModularKitchenTitle, (l) => l.tplModularKitchenText),
  // ---- painter
  JobTemplate('WallPaint', 'painter', Icons.format_paint_rounded, (l) => l.tplWallPaintTitle, (l) => l.tplWallPaintText),
  JobTemplate('FullHouse', 'painter', Icons.house_rounded, (l) => l.tplFullHouseTitle, (l) => l.tplFullHouseText),
  JobTemplate('Waterproofing', 'painter', Icons.umbrella_rounded, (l) => l.tplWaterproofingTitle, (l) => l.tplWaterproofingText),
  JobTemplate('DoorGrillPaint', 'painter', Icons.door_front_door_rounded, (l) => l.tplDoorGrillPaintTitle, (l) => l.tplDoorGrillPaintText),
  JobTemplate('TexturePutty', 'painter', Icons.texture_rounded, (l) => l.tplTexturePuttyTitle, (l) => l.tplTexturePuttyText),
  // ---- helper
  JobTemplate('HelperDay', 'helper', Icons.handyman_rounded, (l) => l.tplHelperDayTitle, (l) => l.tplHelperDayText),
  JobTemplate('Shifting', 'helper', Icons.local_shipping_rounded, (l) => l.tplShiftingTitle, (l) => l.tplShiftingText),
  JobTemplate('SiteCleaning', 'helper', Icons.cleaning_services_rounded, (l) => l.tplSiteCleaningTitle, (l) => l.tplSiteCleaningText),
  JobTemplate('MaterialCarry', 'helper', Icons.inventory_2_rounded, (l) => l.tplMaterialCarryTitle, (l) => l.tplMaterialCarryText),
];

/// The common jobs of one trade (without "Other work").
List<JobTemplate> templatesFor(String trade) => [for (final t in jobTemplates) if (t.trade == trade) t];

JobTemplate? templateById(String id) {
  for (final t in jobTemplates) {
    if (t.id == id) return t;
  }
  return null;
}

String templateTitle(L l, String id) => templateById(id)?.title(l) ?? l.pjOtherWork;

/// The starter description in the user's language. Empty for "Other work": the customer writes or speaks it on the next step.
String templateText(L l, String id) => templateById(id)?.text(l) ?? '';

/// Language of [templateText]: only Hindi has its own language code; Hinglish (Roman script) and every other app language count as English.
String templateLang(L l) => l.localeName.startsWith('hi') ? 'hi' : 'en';

import '../l10n/gen/app_localizations.dart';

/// Friendly text for API error codes. The real backend already sends a message in the user's language;
/// the on-device demo throws codes with an empty message, so every code the demo can raise is mapped
/// here (and it is also the fallback if a server message is ever empty).
/// [param] carries the one number some messages need (e.g. minutes until a no-show can be reported).
String? errorMessageFor(L l, String code, [String param = '']) => switch (code) {
      'err.job_closed' => l.errJobClosed,
      'err.hire_cancelled' => l.errHireCancelled,
      'err.job_disputed' => l.errJobDisputed,
      'err.proof_required' => l.errProofRequired,
      'err.nothing_to_send_back' => l.errNothingToSendBack,
      'err.job_started' => l.errJobStarted,
      'err.job_started_dispute' => l.errJobStartedDispute,
      'err.no_show_too_early' => l.errNoShowTooEarly(param.isEmpty ? '60' : param),
      'err.nudge_too_soon' => l.errNudgeTooSoon,
      'err.date_in_past' => l.errDateInPast,
      'err.date_too_far' => l.errDateTooFar,
      'err.chat_closed' => l.errChatClosed,
      'err.too_early_to_dispute' => l.errTooEarlyDispute,
      'err.payment_not_held' => l.errPaymentNotHeld,
      'err.already_rated' => l.errAlreadyRated,
      'err.payment_pending' => l.errPaymentPending,
      'err.validation' => l.errValidation,
      'err.too_many_photos' => l.errTooManyPhotos,
      'err.account_suspended' => l.errAccountSuspended,
      'err.job_not_completed' => l.errJobNotCompleted,
      'err.start_code_invalid' => l.errStartCodeInvalid(param.isEmpty ? '?' : param),
      'err.start_code_locked' => l.errStartCodeLocked(param.isEmpty ? '10' : param),
      'err.start_code_required' => l.errStartCodeRequired,
      'err.trip_not_active' || 'err.trip_expired' => l.errTripNotActive,
      'err.warranty_expired' => l.errWarrantyExpired,
      'err.refix_open' => l.errRefixOpen,
      'err.refix_limit' => l.errRefixLimit(param.isEmpty ? '2' : param),
      'err.kyc_required' => l.errKycRequired,
      'err.direct_only' => l.errDirectOnly,
      _ => null,
    };

final _digits = RegExp(r'^\d+$');

/// True when [message] is empty or just the numeric parameter the demo attaches.
bool needsLocalText(String message) => message.isEmpty || _digits.hasMatch(message);

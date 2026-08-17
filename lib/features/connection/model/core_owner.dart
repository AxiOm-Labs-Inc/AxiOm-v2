import 'package:hooks_riverpod/hooks_riverpod.dart';

/// Who currently owns the sing-box core session.
///
/// The device has a single core (on Android — a single VPN slot), shared by
/// the main VPN and the Telemost tunnel. The owner tag lets each service
/// show its own status without peeking at the other one: the home screen
/// reports «connected» only for [CoreOwner.vpn], the Telemost tab — only
/// for [CoreOwner.telemost].
enum CoreOwner { none, vpn, telemost }

/// In-memory only by design: after an app-process restart the owner is
/// unknown, and the core status stream alone drives the UI (a surviving
/// core session then looks like a VPN session — acceptable, it is a VPN).
final coreOwnerProvider = StateProvider<CoreOwner>((ref) => CoreOwner.none);

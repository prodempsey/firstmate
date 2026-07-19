// Internal, package-private symbols.
//
// The raw exclusive-transaction primitive is keyed by this symbol rather than a
// public method name, so the arbitrary-SQL surface is not part of the public
// ControlPlaneStore contract (spec section 3.1: "The coordinator exposes no
// direct SQL mutation API"). Only in-package domain methods and a clearly
// test-only internal adapter import this symbol; ordinary callers see only the
// domain-level methods on ControlPlaneStore.
//
// This module is intentionally NOT re-exported from any public entrypoint.

export const RUN_EXCLUSIVE = Symbol('control-plane.store.runExclusive');

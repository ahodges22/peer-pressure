// Peer agent registry.

import { agent as codex } from "./codex.mjs";
import { agent as claude } from "./claude.mjs";
import { agent as cursor } from "./cursor.mjs";
import { peerIdFor } from "../host.mjs";

const AGENTS = { codex, claude, cursor };

export function getAgent(id) {
  const a = AGENTS[id];
  if (!a) throw new Error(`unknown agent '${id}'`);
  return a;
}

/** The agent that reviews work produced by `host`, unless explicitly selected. */
export function peerFor(host, override) {
  if (override === undefined) return getAgent(peerIdFor(host));
  if (override === "cursor") return getAgent("cursor");
  throw new Error(`unknown peer '${override}'`);
}

export { MAX_PAYLOAD_BYTES, PayloadTooLargeError, parseStatus, classifyTransient } from "./common.mjs";

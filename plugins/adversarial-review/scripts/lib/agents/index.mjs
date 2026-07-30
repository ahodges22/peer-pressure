// Peer agent registry.

import { agent as codex } from "./codex.mjs";
import { agent as claude } from "./claude.mjs";
import { peerIdFor } from "../host.mjs";

const AGENTS = { codex, claude };

export function getAgent(id) {
  const a = AGENTS[id];
  if (!a) throw new Error(`unknown agent '${id}'`);
  return a;
}

/** The agent that reviews work produced by `host`. */
export function peerFor(host) {
  return getAgent(peerIdFor(host));
}

export { MAX_PAYLOAD_BYTES, PayloadTooLargeError, parseStatus, classifyTransient } from "./common.mjs";

export type PointerBridgePhase = "down" | "up" | "move" | "cancel";

export function shouldPostPointerEvent(
  phase: PointerBridgePhase,
  continuousReader: boolean
): boolean {
  return phase !== "move" || !continuousReader;
}

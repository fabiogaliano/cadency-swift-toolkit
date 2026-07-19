// Narrow declaration seam for the two upstream-compatible coordinate helpers
// consumed by typed Cadency interaction modules.
export declare function toNativeRect(rect: DOMRect): {
  width: number;
  height: number;
  left: number;
  top: number;
  right: number;
  bottom: number;
};

export declare function adjustPointToViewport(point: {
  x: number;
  y: number;
}): { x: number; y: number };

export interface ChapterWindowConfiguration {
  prefetchBehind: number;
  prefetchAhead: number;
  maxMounted: number;
}

export interface ChapterWindowRequest {
  requestedCenterIndex: number;
  landingCorrectionTarget: number | undefined;
  spineItemCount: number;
  loadedChapterIndices: readonly number[];
  pendingNavigationTarget: number | undefined;
  userScrolling: boolean;
  configuration: ChapterWindowConfiguration;
}

export interface ChapterWindowPlan {
  indicesToMount: number[];
  indicesToUnmount: number[];
}

export function planChapterWindow(
  request: ChapterWindowRequest
): ChapterWindowPlan {
  if (request.spineItemCount === 0) {
    return { indicesToMount: [], indicesToUnmount: [] };
  }

  const centerIndex = clampIndex(
    request.landingCorrectionTarget ?? request.requestedCenterIndex,
    request.spineItemCount
  );
  const start = Math.max(0, centerIndex - request.configuration.prefetchBehind);
  const end = Math.min(
    request.spineItemCount - 1,
    centerIndex + request.configuration.prefetchAhead
  );
  const indicesToMount = indicesFrom(start, end);
  const mountedLimit = request.userScrolling
    ? Math.max(
        request.configuration.maxMounted * 2,
        request.configuration.maxMounted + 4
      )
    : request.configuration.maxMounted;

  const projectedMountedCount = new Set([
    ...request.loadedChapterIndices,
    ...indicesToMount,
  ]).size;
  if (projectedMountedCount <= mountedLimit) {
    return { indicesToMount, indicesToUnmount: [] };
  }

  const indicesToUnmount = request.loadedChapterIndices
    .filter(
      (index) =>
        (index < start || index > end) &&
        index !== request.pendingNavigationTarget
    )
    .sort(
      (left, right) =>
        distance(right, centerIndex) - distance(left, centerIndex)
    )
    .slice(0, projectedMountedCount - mountedLimit);

  return { indicesToMount, indicesToUnmount };
}

function clampIndex(index: number, spineItemCount: number): number {
  return Math.max(0, Math.min(index, spineItemCount - 1));
}

function indicesFrom(start: number, end: number): number[] {
  const indices: number[] = [];
  for (let index = start; index <= end; index++) {
    indices.push(index);
  }
  return indices;
}

function distance(index: number, centerIndex: number): number {
  return Math.abs(index - centerIndex);
}

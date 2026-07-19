export interface ProgressionInput {
  totalHeight: number;
  viewportHeight: number;
  scrollY: number;
  activeChapterIndex: number;
}

export interface ProgressionPayload {
  first: number;
  last: number;
  activeChapter: number;
}

export function progressionPayload(
  input: ProgressionInput
): ProgressionPayload {
  const maxY = Math.max(1, input.totalHeight - input.viewportHeight);
  const totalHeight = Math.max(1, input.totalHeight);
  return {
    first: clamp(input.scrollY / maxY),
    last: clamp((input.scrollY + input.viewportHeight) / totalHeight),
    activeChapter: input.activeChapterIndex,
  };
}

function clamp(value: number): number {
  return Math.max(0, Math.min(1, value));
}

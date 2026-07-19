export type ChapterState<Iframe> =
  | { kind: "spacer"; height: number }
  | { kind: "loading"; height: number; iframe: Iframe }
  | { kind: "loaded"; height: number; iframe: Iframe }
  | { kind: "error"; height: number; iframe: Iframe };

export type ChapterTransitionResult =
  | { kind: "applied" }
  | { kind: "stale" }
  | {
      kind: "illegal";
      transition: string;
      currentState: ChapterState<unknown>["kind"] | "absent";
    };

export class ChapterRegistry<Iframe = HTMLIFrameElement> {
  readonly #chapters = new Map<number, ChapterState<Iframe>>();

  initialize(index: number, height: number): ChapterTransitionResult {
    const current = this.#chapters.get(index);
    if (current !== undefined) {
      return illegal("absent -> spacer", current);
    }
    this.#chapters.set(index, { kind: "spacer", height });
    return { kind: "applied" };
  }

  beginLoading(index: number, iframe: Iframe): ChapterTransitionResult {
    const current = this.#chapters.get(index);
    if (current?.kind !== "spacer") {
      return illegal("spacer -> loading", current);
    }
    this.#chapters.set(index, {
      kind: "loading",
      height: current.height,
      iframe,
    });
    return { kind: "applied" };
  }

  loaded(index: number, iframe: Iframe): ChapterTransitionResult {
    const current = this.#chapters.get(index);
    if (current?.kind !== "loading" || current.iframe !== iframe) {
      return { kind: "stale" };
    }
    this.#chapters.set(index, { ...current, kind: "loaded" });
    return { kind: "applied" };
  }

  failed(index: number, iframe: Iframe): ChapterTransitionResult {
    const current = this.#chapters.get(index);
    if (current?.kind !== "loading" || current.iframe !== iframe) {
      return { kind: "stale" };
    }
    this.#chapters.set(index, { ...current, kind: "error" });
    return { kind: "applied" };
  }

  unmount(index: number, height: number): ChapterTransitionResult {
    const current = this.#chapters.get(index);
    if (current === undefined || current.kind === "spacer") {
      return { kind: "stale" };
    }
    this.#chapters.set(index, { kind: "spacer", height });
    return { kind: "applied" };
  }

  updateHeight(index: number, height: number): ChapterTransitionResult {
    const current = this.#chapters.get(index);
    if (current === undefined) {
      return illegal("height update", current);
    }
    this.#chapters.set(index, { ...current, height });
    return { kind: "applied" };
  }

  state(index: number): ChapterState<Iframe>["kind"] | undefined {
    return this.#chapters.get(index)?.kind;
  }

  height(index: number): number | undefined {
    return this.#chapters.get(index)?.height;
  }

  iframe(index: number): Iframe | undefined {
    const current = this.#chapters.get(index);
    return current?.kind === "loading" ||
      current?.kind === "loaded" ||
      current?.kind === "error"
      ? current.iframe
      : undefined;
  }

  mountedIndices(): number[] {
    return Array.from(this.#chapters.entries())
      .filter(([, state]) => state.kind !== "spacer")
      .map(([index]) => index);
  }

  forEachMounted(callback: (iframe: Iframe, index: number) => void): void {
    this.#chapters.forEach((state, index) => {
      if (state.kind !== "spacer") {
        callback(state.iframe, index);
      }
    });
  }

  stateEntries(): Array<[number, ChapterState<Iframe>["kind"]]> {
    return Array.from(this.#chapters, ([index, state]) => [index, state.kind]);
  }

  heightEntries(): Array<[number, number]> {
    return Array.from(this.#chapters, ([index, state]) => [
      index,
      state.height,
    ]);
  }
}

function illegal<Iframe>(
  transition: string,
  current: ChapterState<Iframe> | undefined
): ChapterTransitionResult {
  return {
    kind: "illegal",
    transition,
    currentState: current?.kind ?? "absent",
  };
}

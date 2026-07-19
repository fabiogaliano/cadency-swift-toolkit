import { findSpineIndexByHref } from "./navigation-target";

export interface DecorationSnapshot {
  id: string;
  locator: LocatorJSON;
  style: string;
  element: string;
}

interface DecorationSpineItem {
  href: string;
}

export class DecorationRouting {
  readonly #groupSnapshots = new Map<string, readonly DecorationSnapshot[]>();
  readonly #activableGroups = new Set<string>();

  replaceGroup(
    groupName: string,
    decorations: readonly DecorationSnapshot[]
  ): void {
    this.#groupSnapshots.set(groupName, decorations);
  }

  decorationsForSpineIndex(
    spineItems: readonly DecorationSpineItem[],
    groupName: string,
    spineIndex: number
  ): readonly DecorationSnapshot[] {
    const decorations = this.#groupSnapshots.get(groupName) ?? [];
    return decorations.filter(
      (decoration) =>
        findSpineIndexByHref(spineItems, decoration.locator.href) === spineIndex
    );
  }

  forEachGroup(
    callback: (
      decorations: readonly DecorationSnapshot[],
      groupName: string
    ) => void
  ): void {
    this.#groupSnapshots.forEach(callback);
  }

  setGroupActivable(groupName: string, isActivable: boolean): void {
    if (isActivable) {
      this.#activableGroups.add(groupName);
    } else {
      this.#activableGroups.delete(groupName);
    }
  }

  isGroupActivable(groupName: string): boolean {
    return this.#activableGroups.has(groupName);
  }
}

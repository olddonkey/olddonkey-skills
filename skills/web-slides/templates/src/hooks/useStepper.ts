import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import type { ChapterDef } from "../registry/types";

/**
 * Bump this when chapter step counts / structure change so old persisted
 * cursors don't land mid-removed-step.
 */
const STORAGE_KEY = "web-slides-cursor-v1";

/**
 * Same-origin channel that keeps the audience window and the presenter
 * window (`?presenter`) on the same step. Either window can drive; the
 * other follows. See PresenterApp / PRESENTING.md.
 */
const SYNC_CHANNEL = "web-slides-sync";

export type Cursor = { chapter: number; step: number };

export interface StepperState {
  cursor: Cursor;
  totalChapters: number;
  chapterTotalSteps: number;
  globalIndex: number;
  totalGlobal: number;
  next(): void;
  prev(): void;
  jumpToChapter(idx: number, step?: number): void;
  jumpToGlobal(globalIdx: number): void;
}

const clamp = (n: number, lo: number, hi: number) =>
  Math.max(lo, Math.min(hi, n));

/**
 * Clamp a (possibly stale) cursor to the current chapter list. Persisted
 * cursors can outlive structural changes — fewer chapters, fewer steps,
 * a different scaffolded project sharing the same dev-server origin — so
 * we always re-validate before handing one to React.
 */
function sanitize(cursor: Cursor, chapters: ChapterDef[]): Cursor {
  if (chapters.length === 0) return { chapter: 0, step: 0 };
  const chapter = clamp(cursor.chapter | 0, 0, chapters.length - 1);
  const stepCount = chapters[chapter]!.notes.length;
  const step = clamp(cursor.step | 0, 0, Math.max(0, stepCount - 1));
  return { chapter, step };
}

export function useStepper(chapters: ChapterDef[]): StepperState {
  const [cursor, setCursor] = useState<Cursor>(() => {
    const fallback = { chapter: 0, step: 0 };
    if (typeof window === "undefined") return fallback;
    try {
      const raw = window.localStorage.getItem(STORAGE_KEY);
      if (raw) return sanitize(JSON.parse(raw), chapters);
    } catch {
      /* ignore */
    }
    return fallback;
  });

  // Re-sanitize if the chapter list shape changes after mount (e.g. HMR
  // updates `chapters.ts`) — keeps a stale persisted cursor from leaking
  // into a render where it's now out of range.
  useEffect(() => {
    setCursor((cur) => {
      const next = sanitize(cur, chapters);
      return next.chapter === cur.chapter && next.step === cur.step
        ? cur
        : next;
    });
  }, [chapters]);

  useEffect(() => {
    try {
      window.localStorage.setItem(STORAGE_KEY, JSON.stringify(cursor));
    } catch {
      /* ignore */
    }
  }, [cursor]);

  // ── Cross-window sync (audience ⇄ presenter) ──────────────────────────
  // The presenter view runs the SAME stepper in a separate window. We mirror
  // the cursor over a BroadcastChannel so navigating in either window moves
  // both. Notes never travel — only the cursor — so what the audience window
  // shows is exactly the clean slide.
  const channelRef = useRef<BroadcastChannel | null>(null);
  const suppress = useRef(false); // true = this cursor change came from a peer; don't echo it
  const lastSent = useRef<Cursor | null>(null);
  const cursorRef = useRef(cursor);
  cursorRef.current = cursor;

  useEffect(() => {
    if (typeof BroadcastChannel === "undefined") return; // graceful no-sync
    const ch = new BroadcastChannel(SYNC_CHANNEL);
    channelRef.current = ch;
    ch.onmessage = (e) => {
      const data = e.data as { type?: string; cursor?: Cursor } | null;
      if (!data) return;
      if (data.type === "hello") {
        // a window just opened — hand it the live cursor so it snaps into sync
        ch.postMessage({ type: "cursor", cursor: cursorRef.current });
        return;
      }
      if (data.type === "cursor" && data.cursor) {
        const incoming = sanitize(data.cursor, chapters);
        setCursor((cur) => {
          if (cur.chapter === incoming.chapter && cur.step === incoming.step)
            return cur;
          suppress.current = true;
          return incoming;
        });
      }
    };
    ch.postMessage({ type: "hello" }); // ask whoever's already open where we are
    return () => {
      ch.close();
      channelRef.current = null;
    };
  }, [chapters]);

  useEffect(() => {
    const ch = channelRef.current;
    if (!ch) return;
    // A cursor we just adopted from a peer — record it, never echo it back.
    if (suppress.current) {
      suppress.current = false;
      lastSent.current = cursor;
      return;
    }
    const prev = lastSent.current;
    if (prev && prev.chapter === cursor.chapter && prev.step === cursor.step)
      return;
    // Skip the very first value so opening a fresh window can't broadcast its
    // mount cursor and yank a peer somewhere (StrictMode-safe via the ref).
    if (prev === null) {
      lastSent.current = cursor;
      return;
    }
    lastSent.current = cursor;
    ch.postMessage({ type: "cursor", cursor });
  }, [cursor]);

  const offsets = useMemo(() => {
    const arr: number[] = [];
    let acc = 0;
    for (const c of chapters) {
      arr.push(acc);
      acc += c.notes.length;
    }
    return arr;
  }, [chapters]);
  const totalGlobal = useMemo(
    () => chapters.reduce((s, c) => s + c.notes.length, 0),
    [chapters],
  );
  const globalIndex = (offsets[cursor.chapter] ?? 0) + cursor.step;

  const next = useCallback(() => {
    setCursor((cur) => {
      const c = chapters[cur.chapter]!;
      if (cur.step < c.notes.length - 1)
        return { ...cur, step: cur.step + 1 };
      if (cur.chapter < chapters.length - 1)
        return { chapter: cur.chapter + 1, step: 0 };
      return cur;
    });
  }, [chapters]);

  const prev = useCallback(() => {
    setCursor((cur) => {
      if (cur.step > 0) return { ...cur, step: cur.step - 1 };
      if (cur.chapter > 0) {
        const p = chapters[cur.chapter - 1]!;
        return { chapter: cur.chapter - 1, step: p.notes.length - 1 };
      }
      return cur;
    });
  }, [chapters]);

  const jumpToChapter = useCallback(
    (idx: number, step = 0) => {
      const ch = clamp(idx, 0, chapters.length - 1);
      const c = chapters[ch]!;
      setCursor({
        chapter: ch,
        step: clamp(step, 0, c.notes.length - 1),
      });
    },
    [chapters],
  );

  const jumpToGlobal = useCallback(
    (g: number) => {
      const target = clamp(g, 0, totalGlobal - 1);
      let acc = 0;
      for (let i = 0; i < chapters.length; i++) {
        const t = chapters[i]!.notes.length;
        if (target < acc + t) {
          setCursor({ chapter: i, step: target - acc });
          return;
        }
        acc += t;
      }
    },
    [chapters, totalGlobal],
  );

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.target instanceof HTMLInputElement) return;
      if (e.key === "ArrowRight" || e.key === " ") {
        e.preventDefault();
        next();
      } else if (e.key === "ArrowLeft" || e.key === "Backspace") {
        e.preventDefault();
        prev();
      } else if (e.key === "Home") {
        jumpToChapter(0, 0);
      } else if (e.key === "End") {
        const last = chapters.length - 1;
        jumpToChapter(last, chapters[last]!.notes.length - 1);
      } else if (e.key >= "1" && e.key <= "9") {
        const n = Number(e.key) - 1;
        if (n < chapters.length) jumpToChapter(n, 0);
      }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [next, prev, jumpToChapter, chapters]);

  const ch = chapters[cursor.chapter]!;
  return {
    cursor,
    totalChapters: chapters.length,
    chapterTotalSteps: ch.notes.length,
    globalIndex,
    totalGlobal,
    next,
    prev,
    jumpToChapter,
    jumpToGlobal,
  };
}

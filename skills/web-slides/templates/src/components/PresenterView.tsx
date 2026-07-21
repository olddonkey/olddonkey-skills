import { useEffect, useState } from "react";
import "./PresenterView.css";
import { SlidePreview } from "./SlidePreview";
import { CHAPTERS } from "../registry/chapters";
import type { StepperState } from "../hooks/useStepper";

function mmss(totalSec: number) {
  const m = Math.floor(totalSec / 60);
  const s = totalSec % 60;
  return `${String(m).padStart(2, "0")}:${String(s).padStart(2, "0")}`;
}

/** Where `next()` would land — may cross a chapter boundary, or be null at the end. */
function nextLocation(chapter: number, step: number) {
  const c = CHAPTERS[chapter];
  if (!c) return null;
  if (step < c.notes.length - 1) return { chapter, step: step + 1 };
  if (chapter < CHAPTERS.length - 1) return { chapter: chapter + 1, step: 0 };
  return null;
}

/**
 * The presenter console — what the SPEAKER sees, in a window that is never the
 * shared surface. Live slide preview + current speaker note + next note +
 * timer + position. Drive it with the arrow keys (sync moves the audience
 * window too), or click the preview to advance.
 */
export function PresenterView({ stepper }: { stepper: StepperState }) {
  const { cursor } = stepper;
  const ch = CHAPTERS[cursor.chapter]!;
  const note = ch.notes[cursor.step] ?? "";

  const nxt = nextLocation(cursor.chapter, cursor.step);
  const nextCh = nxt ? CHAPTERS[nxt.chapter] : null;
  const nextNote = nxt ? (nextCh!.notes[nxt.step] ?? "") : "";
  const nextCrossesChapter = !!nxt && nxt.chapter !== cursor.chapter;

  // Elapsed-time clock — local to the presenter window, reset with R.
  const [elapsed, setElapsed] = useState(0);
  const [startMs, setStartMs] = useState(() => Date.now());
  useEffect(() => {
    const id = setInterval(
      () => setElapsed(Math.floor((Date.now() - startMs) / 1000)),
      500,
    );
    return () => clearInterval(id);
  }, [startMs]);
  const resetTimer = () => {
    setStartMs(Date.now());
    setElapsed(0);
  };

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "r" || e.key === "R") resetTimer();
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, []);

  return (
    <div className="pv-root">
      <header className="pv-top">
        <span className="pv-loc">
          {String(cursor.chapter).padStart(2, "0")} · {ch.title}
        </span>
        <span className="pv-pos">
          <span className="pv-pos-step">
            step {cursor.step + 1} / {stepper.chapterTotalSteps}
          </span>
          <span className="pv-pos-sep">·</span>
          <span className="pv-pos-global">
            {stepper.globalIndex + 1} / {stepper.totalGlobal} total
          </span>
        </span>
        <button className="pv-timer" onClick={resetTimer}>
          {mmss(elapsed)}
        </button>
      </header>

      <main className="pv-main">
        <section className="pv-stage">
          <span className="pv-tag">NOW</span>
          <button className="pv-preview-click" onClick={stepper.next}>
            <SlidePreview chapterIndex={cursor.chapter} step={cursor.step} />
          </button>
        </section>

        <aside className="pv-notes">
          <div className="pv-note-now">
            <span className="pv-tag">提词 · NOW</span>
            <div className="pv-note-body">
              {note ? note : <span className="pv-note-empty">（这一步没有备注）</span>}
            </div>
          </div>
          <div className="pv-note-next">
            <span className="pv-tag pv-tag-next">
              NEXT ›{" "}
              {nxt
                ? nextCrossesChapter
                  ? `${String(nxt.chapter).padStart(2, "0")} · ${nextCh!.title}`
                  : `step ${nxt.step + 1}`
                : "— 最后一页 —"}
            </span>
            <div className="pv-note-next-body">
              {nxt ? (
                nextNote ? (
                  nextNote
                ) : (
                  <span className="pv-note-empty">（下一步没有备注）</span>
                )
              ) : (
                <span className="pv-note-empty">讲完了 · 收尾</span>
              )}
            </div>
          </div>
        </aside>
      </main>

      <footer className="pv-foot">
        <button className="pv-btn" onClick={stepper.prev}>
          ‹ prev
        </button>
        <button className="pv-btn" onClick={stepper.next}>
          next ›
        </button>
        <span className="pv-foot-hint">
          ← → / 空格 翻页（两个窗口联动） · R 计时归零 · 数字键跳章
        </span>
      </footer>
    </div>
  );
}

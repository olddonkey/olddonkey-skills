import "./NotesOverlay.css";

interface Props {
  open: boolean;
  chapterIndex: number;
  chapterTitle: string;
  step: number;
  totalSteps: number;
  note: string;
  nextNote?: string;
}

/**
 * Presenter notes overlay — speaker talking points for the current step,
 * toggled with the "N" key (see usePresenterNotes).
 *
 * Fixed bottom-left, carries `data-no-advance` so clicking it never advances
 * the stage. Its styling is intentionally theme-INDEPENDENT (a dark glass
 * panel) so notes stay legible on top of any theme. Hidden by default so the
 * audience never sees it — show it on your own screen while presenting.
 */
export function NotesOverlay({
  open,
  chapterIndex,
  chapterTitle,
  step,
  totalSteps,
  note,
  nextNote,
}: Props) {
  if (!open) return null;
  return (
    <div className="notes-overlay" data-no-advance>
      <div className="notes-head">
        <span className="notes-loc">
          {String(chapterIndex + 1).padStart(2, "0")} · {chapterTitle}
        </span>
        <span className="notes-step">
          step {step + 1} / {totalSteps}
        </span>
      </div>
      <div className="notes-body">
        {note ? note : <span className="notes-empty">（这一步没有备注）</span>}
      </div>
      {nextNote ? (
        <div className="notes-next">
          <span className="notes-next-label">next ›</span> {nextNote}
        </div>
      ) : null}
      <div className="notes-hint">N 键隐藏</div>
    </div>
  );
}

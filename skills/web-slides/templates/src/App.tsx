// Global theme styles are loaded once in main.tsx (shared with the presenter
// window) — see main.tsx for the load-order contract (tokens after base).
import { useEffect } from "react";

import { NotesOverlay } from "./components/NotesOverlay";
import { ProgressBar } from "./components/ProgressBar";
import { Stage } from "./components/Stage";
import { usePresenterNotes } from "./hooks/usePresenterNotes";
import { useStepper } from "./hooks/useStepper";
import { CHAPTERS } from "./registry/chapters";

export default function App() {
  const stepper = useStepper(CHAPTERS);
  const ch = CHAPTERS[stepper.cursor.chapter]!;
  const Cmp = ch.Component;

  // Press "P" to open the presenter console in its own window. It stays in
  // sync over a BroadcastChannel (useStepper). In the call, share ONLY this
  // (audience) window — the presenter window is yours. No on-slide button, so
  // nothing about the console ever appears on the shared surface.
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.target instanceof HTMLInputElement) return;
      if (e.key === "p" || e.key === "P") {
        e.preventDefault();
        const url = window.location.pathname + "?presenter";
        window.open(
          url,
          "web-slides-presenter",
          "popup=yes,width=1280,height=860",
        );
      }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, []);

  // Presenter notes overlay — toggled with "N". Notes live in each chapter's
  // notes.ts (the step-count source of truth) and show ONLY here, never on
  // the slide itself. Great for rehearsing / presenting a talk live.
  const { notesOpen } = usePresenterNotes();
  const note = ch.notes[stepper.cursor.step] ?? "";
  const nextNote = ch.notes[stepper.cursor.step + 1];

  return (
    <>
      <Stage onAdvance={stepper.next}>
        <div key={ch.id} className="scene">
          <Cmp step={stepper.cursor.step} />
        </div>
      </Stage>
      <ProgressBar
        chapters={CHAPTERS}
        cursor={stepper.cursor}
        onJumpChapter={stepper.jumpToChapter}
      />
      <NotesOverlay
        open={notesOpen}
        chapterIndex={stepper.cursor.chapter}
        chapterTitle={ch.title}
        step={stepper.cursor.step}
        totalSteps={stepper.chapterTotalSteps}
        note={note}
        nextNote={nextNote}
      />
    </>
  );
}

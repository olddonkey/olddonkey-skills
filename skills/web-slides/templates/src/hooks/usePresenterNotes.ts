import { useEffect, useState } from "react";

/**
 * Presenter-notes overlay toggle.
 *
 * Press "N" to show/hide the speaker notes for the current step. Notes never
 * appear on the slide itself — only in the overlay — so you can rehearse or
 * present a talk live while the audience (or a screen-share) sees just the
 * slide.
 */
export function usePresenterNotes() {
  const [notesOpen, setNotesOpen] = useState(false);

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.target instanceof HTMLInputElement) return;
      if (e.key === "n" || e.key === "N") {
        e.preventDefault();
        setNotesOpen((v) => !v);
      }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, []);

  return { notesOpen };
}

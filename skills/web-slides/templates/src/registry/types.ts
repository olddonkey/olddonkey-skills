import type { ComponentType } from "react";

export interface ChapterStepProps {
  step: number; // 0..(notes.length - 1)
}

/**
 * One step's optional speaker note (presenter talking points).
 *
 * Shown ONLY in the presenter overlay (press "N") — never rendered on the
 * slide, never used for audio. Empty string ("") = a step with no note (it
 * still counts as a step).
 */
export type StepNote = string;

export interface ChapterDef {
  id: string;
  title: string;
  /**
   * Per-step speaker notes. **Length === total steps in this chapter.**
   * This is the single source of truth for the chapter's step count, so the
   * stepper and the chapter `.tsx` switch on `step` cannot drift apart.
   */
  notes: StepNote[];
  Component: ComponentType<ChapterStepProps>;
}

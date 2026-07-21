import type { ChapterDef } from "./types";
import ExampleChapter from "../chapters/01-example/Example";
import { notes as exampleNotes } from "../chapters/01-example/notes";

/**
 * Order = order of presentation.
 *
 * Each chapter MUST provide a `notes: StepNote[]` array. Its length is the
 * chapter's step count — there is no separate `totalSteps` to maintain. This
 * guarantees the runtime stepper and the chapter `.tsx` switch on `step`
 * cannot drift apart.
 *
 * Visual styling (color, fonts) comes entirely from the active theme —
 * chapters never hard-code palette / font names. See THEMES.md.
 */
export const CHAPTERS: ChapterDef[] = [
  {
    id: "example",
    title: "示例章节",
    notes: exampleNotes,
    Component: ExampleChapter,
  },
];

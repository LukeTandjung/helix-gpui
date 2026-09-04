# Architecture direction: a GPUI Helix with inline previews

Status: proposed direction, not an implemented architecture.

## Product goal

Build a GPUI version of Helix that preserves its editing behavior.

**The immediate priority is the main editor itself:** working Helix editing behavior, reliable rendering, input and focus handling, and performance. This is the planned weekend focus. File-tree integration, Pierre ports, diffs, and surrounding UI must not delay or drive that work; pursue them only if time remains.

Longer-term additions remain:

- Inline live previews, with blocks switching between source and rendered content.
- A left-hand file tree that also hosts file-search results instead of a central picker.
- A diff viewer.

Combine the strengths of three projects without retaining three competing editor engines:

| Project | Reuse | Avoid carrying forward |
| --- | --- | --- |
| Helix fork | Buffers, transactions, selections, undo, commands, syntax state, and LSP integration | Terminal-specific assumptions in shared behavior |
| helix-gpui | Custom GPUI text elements, viewport-limited text rendering, and initial input integration | Terminal-buffer-based GUI controls, copied application logic, and polling as the long-term integration |
| Kioto | Source-to-display mappings, preview blocks, inline math, and architectural boundaries | Duplicate editing state and whole-document rebuilding on redraw |

helix-gpui is a useful prototype, not a proven set of optimisation best practices. Port techniques selectively and measure their effects.

## Repository strategy

The current repository is a fork of `polachok/helix-gpui`. It consumes Helix crates from a pinned commit in `polachok/helix`; it does not contain Helix's source workspace.

The preferred longer-term integration base is a maintained Helix fork with a GPUI frontend crate in its Cargo workspace. Local crate dependencies allow shared APIs and the frontend to evolve together. Keep the terminal frontend working and keep changes to upstream code small enough to maintain.

That workspace move is a separate migration decision. Creating this frontend fork does not itself consolidate the Helix and Kioto repositories.

Do not reorganise all of upstream Helix into Kioto's folder structure. Apply the desired architecture to new product code and extract shared Helix behavior only when a concrete frontend need requires it.

## Planned UI libraries and ports

Luke plans to use GPUI ports of Pierre's file tree and diffs. He reports that the file-tree port already exists, but its architecture still needs refinement. Its integration here and further Pierre porting are secondary to getting the main editor working; the diff port is planned, not established as complete.

Luke also plans to use **base-gpui**, his GPUI port of Base UI, for its convenient component API and accessibility primitives. This is the intended direction, subject to checking its suitability in the editor.

Suggested responsibility split:

- **Custom GPUI editor surface:** text, selections, gutters, and inline preview rendering.
- **Pierre ports:** file-tree and diff presentation when those features are scheduled.
- **base-gpui:** surrounding controls such as menus, dialogs, tooltips, and buttons, plus applicable focus and interaction primitives.

Do not make general-purpose component adoption a prerequisite for the main editor or route every text line through it. Accessibility primitives are useful foundations, not proof of end-to-end accessibility: verify keyboard navigation, focus restoration, and platform accessibility exposure in the integrated application.

The file tree should request that Helix open a path and reflect the active document, rather than owning duplicate editor state. Neither the file-tree port's cleanup nor surrounding UI work should expand the initial editor milestone.

## One canonical document

Helix owns the authoritative source text and editing state. Source rendering, inline preview, and diff rendering are views over that state, not separate editable documents.

```text
                    Helix document
                   /       |       \
             Source view  Preview   Diff view
                          blocks
```

A diff additionally needs a comparison snapshot or revision; it must not introduce a competing mutable editor buffer for the current document.

Rules:

- Typing and preview interactions produce Helix edits.
- Undo and redo remain Helix operations.
- Selections remain source selections.
- Preview blocks retain mappings to source ranges.
- Generated content has explicit hit-testing and selection behavior.
- Cached preview results are associated with document identity and revision. Results from outdated work must not overwrite newer state.

Do not port Kioto's replacement text buffer, modal state machine, or undo engine alongside Helix's equivalents.

## Syntax, language servers, and rendering

Tree-sitter, LSP, and Typst have different responsibilities:

- **Tree-sitter** provides local incremental syntax parsing. Helix's syntax state is a candidate source for locating preview regions such as headings, paragraphs, code blocks, and equations.
- **LSP** provides language-server features such as diagnostics, completion, and navigation. It is not the mechanism for local Tree-sitter parsing.
- **Typst** provides syntax, evaluation, and layout capabilities needed for Typst previews, including equation rendering. Tree-sitter does not replace its compiler.

The exact reuse points in the chosen Helix revision and the available grammar queries still need investigation. Some preview features may require Typst's own syntax or evaluation model.

Proposed update flow:

```text
Helix edit and updated syntax
  -> identify affected preview regions
  -> update block projections and source mappings
  -> compile changed math where needed
  -> update cached block layout
  -> prepare and render visible blocks
```

Invalidation must include surrounding structure when an edit changes block boundaries, markup interpretation, or dependencies. A text edit range alone is not always a sufficient invalidation range.

## Keep Kioto's boundaries, not its redundant work

Hexagonal architecture is compatible with a responsive editor. Kioto's observed code-level performance concerns come from repeated work, not from the presence of architectural layers.

Use these responsibilities within cohesive product features:

- **Core:** pure block-projection rules, source mappings, and reveal/selection decisions.
- **App:** orchestration of preview updates, searches, and diff requests around the canonical editing state.
- **Ports:** application-owned contracts for required runtime capabilities, such as filesystem access, clipboard access, or external processes.
- **Adapters:** implementations of those ports.
- **Composition root:** connects concrete capabilities, editor integration, and GPUI views.

Keep pure projection decisions independent of GPUI's mutable window lifecycle. Pixel layout and painting belong with the frontend code that owns them.

Do not create shallow forwarding traits for every Helix function. In-process parsers and libraries do not automatically require ports. Likewise, do not force Helix's existing runtime editor into a supposedly pure core module.

## Display geometry is the main integration risk

Inline previews change more than styling. Helix's existing view logic includes assumptions about rows, columns, scrolling, and cursor visibility. The GPUI frontend must reconcile those assumptions with:

- Hidden markup and generated content.
- Equations taller than a source line.
- Blocks expanding when entered or selected.
- Multiple cursors and selections.
- Mouse hit testing and source-position lookup.
- Viewport anchoring when block heights change.
- Vertical navigation and keeping selections visible.

Kioto's offset maps are a starting point, but source-to-display byte mappings do not by themselves solve pixel geometry or navigation.

Decide explicitly whether movement follows source lines or displayed rows while previews are visible. Also decide how multi-selection reveal, clicks on generated content, and source fallback on preview errors should work. Preserve Helix semantics deliberately rather than allowing rendering details to change them accidentally.

## Performance requirements and evidence

The initial comparison was static code analysis, not a runtime profile. GPUI versions, build modes, document contents, and workloads must be controlled before attributing measured differences.

Relevant findings in the inspected prototypes:

- Kioto's `crates/editor/src/app/main/editor.rs` calls `preview_with_fragments` during prepaint. It reparses and rebuilds projections even for cursor movement and scrolling.
- Kioto lays out all blocks and display rows before skipping offscreen rows during paint.
- Its repeated reverse searches through source line ranges can approach quadratic work over many display rows.
- Its Typst adapter caches compiled frames, but regenerates glyph outlines to measure fragments and again to paint visible fragments. Compilation on a cache miss occurs synchronously on the rendering path.
- Kioto's motion and status-line code also repeat full-document scans.
- helix-gpui's `src/document.rs` limits its main text shaping to a visible rope slice. This is worth preserving, but does not prove that every part of its renderer is efficient.

Design requirements:

1. Distinguish text changes from cursor, selection, viewport, and theme changes.
2. Retain syntax and block projections across unchanged redraws.
3. Maintain indexed source-line lookup rather than repeated linear searches.
4. Cache block dimensions and reusable layout; prepare visible blocks plus a bounded buffer.
5. Separate fragment measurement from outline generation and cache reusable geometry.
6. Run expensive compilation outside the immediate input/render path, with bounded scheduling and stale-result rejection.
7. Keep source editing usable while a preview is pending or fails.
8. Measure input latency and frame-time percentiles, not only average FPS.

A rope alone will not fix whole-document parsing and layout on scroll. Conversely, a rich variable-height preview has more work to do than a plain source editor, so comparisons must distinguish feature cost from avoidable repeated work.

## Incremental delivery

### 1. Establish ordinary Helix editing in GPUI

This is the immediate milestone and takes precedence over every sidebar, diff, and component-port task.

Preserve modal commands, transactions, undo, selections, and splits. Verify file opening and saving, input routing, focus, cursor movement, scrolling, and text rendering. Keep the terminal frontend functional. Establish matching-build performance baselines before adding previews.

Do not require a file tree, Pierre integration, or base-gpui adoption to demonstrate a working main editor.

### 2. Introduce projection and geometry boundaries

Start with plain source blocks. Exercise source/display mapping, viewport lookup, hit testing, and revision-aware invalidation before adding specialised rendering.

### 3. Port one preview feature

Start with a small feature such as headings. Cache projections and layout, limit work to affected and visible blocks, and test cursor movement and selection transitions.

### 4. Add asynchronous math previews

Reuse Kioto's rendering approach selectively. Separate measurement and drawing, cache geometry, and reject outdated results. Test first display, warm-cache redraws, rapid edits, and compilation errors.

### 5. Add sidebar search and diff viewing (secondary)

When editor priorities are satisfied, integrate and refine the existing Pierre file-tree port and pursue the planned diff port. This is optional work if time remains, not part of the immediate editor milestone.

Present file-search results in the left-hand area and open results through the canonical editor. Define diff baselines and whether diff panes are read-only before implementing editing interactions. Use base-gpui for suitable surrounding controls after validating its fit. Keep these features separate from the preview engine.

## Validation

Use comparable release builds, viewport sizes, and documents. Measure plain text at increasing line counts, math-heavy documents with cold and warm caches, scrolling, held movement keys, and typing.

Time parsing, projection construction, fragment preparation, layout, and painting separately. Verify correctness for Unicode positions, multiple selections, undo/redo, changing block heights, stale background results, and preview failure fallback.

The objective is not to merge three codebases indiscriminately. It is to preserve Helix's editing semantics, Kioto's projection model, and selected GPUI rendering techniques behind clear ownership and update boundaries.

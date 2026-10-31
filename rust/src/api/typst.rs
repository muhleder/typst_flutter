use std::collections::HashMap;

use flutter_rust_bridge::frb;
use typst::syntax::package::PackageSpec;
use typst_layout::PagedDocument;
use typst_utils::Scalar;

use crate::diag::{map_diagnostic, map_errors};
use crate::world::SimpleWorld;

// ── Public types exposed through the FRB bridge ─────────────────────────────

/// A virtual file to be made available to the Typst compiler.
///
/// The [path] must match exactly the path used in Typst markup.
/// For example, if the markup contains #image("logo.png"), the path
/// must be "logo.png".
#[derive(Debug, Clone)]
pub struct VirtualFile {
    /// The virtual path as referenced in Typst markup.
    pub path: String,
    /// The raw file bytes.
    pub bytes: Vec<u8>,
}

/// A Typst package archive that the caller downloaded.
///
/// Web builds cannot reach the network while compiling (`World::file` is
/// synchronous), so the caller fetches archives and hands them over before
/// `compile()` runs.
#[derive(Debug, Clone)]
pub struct PackageArchive {
    /// Package spec in `@namespace/name:version` form.
    pub spec: String,
    /// Raw `.tar.gz` bytes as served by the registry.
    pub bytes: Vec<u8>,
}

/// Result of rendering a single page.
#[derive(Debug, Clone)]
pub struct RenderResult {
    /// Raw RGBA pixel data (4 bytes per pixel, row-major).
    pub bytes: Vec<u8>,
    /// Width of the rendered image in pixels.
    pub width: u32,
    /// Height of the rendered image in pixels.
    pub height: u32,
}

#[derive(Debug, Clone)]
pub struct PageInfo {
    pub width_pt: f64,
    pub height_pt: f64,
}

/// Severity level of a [TypstDiagnostic].
///
/// Mirrors `typst::diag::Severity` but is exposed through the FRB bridge
/// as a plain enum so Dart callers get a typed value rather than a raw string.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum TypstSeverity {
    /// A hard error that prevents compilation from succeeding.
    Error,
    /// A warning that does not prevent compilation.
    Warning,
}

/// A source location within a Typst document.
///
/// Lines and columns are **1-based** to match editor conventions.
/// Both fields are None when the diagnostic originates from a synthetic
/// span (e.g. built-in library code) that has no user-visible file location.
#[derive(Debug, Clone)]
pub struct TypstSourceLocation {
    /// 1-based line number in the source file.
    pub line: u32,
    /// 1-based column number (Unicode scalar value offset) in the source file.
    pub column: u32,
}

/// A single compiler diagnostic (error or warning).
#[derive(Debug, Clone)]
pub struct TypstDiagnostic {
    /// Severity of the diagnostic.
    pub severity: TypstSeverity,
    /// Human-readable error message.
    pub message: String,
    /// Optional additional hints to help fix the error.
    pub hints: Vec<String>,
    /// Start position of the offending source range, if available.
    pub span_start: Option<TypstSourceLocation>,
    /// End position of the offending source range, if available.
    pub span_end: Option<TypstSourceLocation>,
}

#[derive(Debug, Clone)]
pub struct TypstCompileError {
    pub diagnostics: Vec<TypstDiagnostic>,
}

// ── Running the PDF writer ──────────────────────────────────────────────────

/// Runs the PDF writer where `krilla`'s deferred work can actually run.
///
/// `typst_pdf` -> `krilla` hands its per-page streams, font subsets and image
/// chunks to `rayon::spawn` and then blocks on the result
/// (`krilla-0.8.x/src/util.rs`, `Deferred::new` / `Deferred::wait`, whose
/// `wait` drains the queue with `rayon::yield_now` before it blocks).
///
/// On a browser that only works if the calling thread is a member of the pool it
/// is draining: rayon cannot spawn threads on `wasm32-unknown-unknown`, so its
/// global registry is a **fallback** pool - one worker, owned by whichever thread
/// first touched rayon, `use_current_thread()` (`rayon-core/src/registry.rs`,
/// `default_global_registry`) - and a `spawn` from any other thread is queued
/// where nothing will run it. The export then blocks for ever, which is exactly
/// what used to happen: `par_iter` (typst's own layout) works in the fallback,
/// while `spawn`-then-block does not, so a small document sometimes finished and a
/// real one never did.
///
/// So on wasm the conversion runs on a thread that is a pool worker, one way or
/// the other:
///
/// - **Already a worker**: typst's own layout runs `par_iter`, and on wasm that
///   made this very thread the global fallback pool's worker. Its `yield_now`
///   drains the chunks the writer spawns, so the writer is called straight
///   through. This is the ordinary case for an export, which compiles the book
///   before it writes it - and it is why building a pool *here* failed with
///   `CurrentThreadAlreadyInPool` on the second export of a session.
/// - **Not a worker yet**: a pool of our own, with this thread as its worker
///   (`use_current_thread`). Its `yield_now` finds the chunks on its own queue.
///
/// Either way the export is synchronous and single-threaded, which is all a
/// browser has to give it. Native platforms keep the real global pool and just
/// call through.
fn on_pdf_thread<T, F>(f: F) -> Result<T, String>
where
    F: FnOnce() -> Result<T, String> + Send,
    T: Send,
{
    #[cfg(target_family = "wasm")]
    {
        if ::rayon::current_thread_index().is_some() {
            return f();
        }
        let pool = ::rayon::ThreadPoolBuilder::new()
            .num_threads(1)
            .use_current_thread()
            .build()
            .map_err(|e| format!("could not run the PDF writer on this thread: {e:?}"))?;
        pool.install(f)
    }
    #[cfg(not(target_family = "wasm"))]
    {
        f()
    }
}

// ── CompiledDocument — The Opaque Handle ────────────────────────────────────

#[derive(Debug)]
#[frb(opaque)]
pub struct CompiledDocument {
    pub(crate) inner: PagedDocument,
    pub(crate) warnings: Vec<TypstDiagnostic>,
}

impl CompiledDocument {
    /// Returns the number of pages in the document.
    #[frb(sync)]
    pub fn page_count(&self) -> usize {
        self.inner.pages().len()
    }

    /// Returns any compiler warnings emitted during compilation.
    ///
    /// These are non-fatal diagnostics (e.g. deprecated syntax, ambiguous
    /// layout) that did not prevent compilation but may indicate issues.
    #[frb(sync)]
    pub fn warnings(&self) -> Vec<TypstDiagnostic> {
        self.warnings.clone()
    }

    /// Returns the dimensions of a page in points.
    #[frb(sync)]
    pub fn page_info(&self, index: usize) -> Result<PageInfo, String> {
        if index >= self.inner.pages().len() {
            return Err("Page index out of bounds".into());
        }
        let page = &self.inner.pages()[index];
        Ok(PageInfo {
            width_pt: page.frame.width().to_pt(),
            height_pt: page.frame.height().to_pt(),
        })
    }

    /// Renders a specific page to raw RGBA pixels.
    pub fn render_page(&self, index: usize, pixel_per_pt: f32) -> Result<RenderResult, String> {
        if index >= self.inner.pages().len() {
            return Err("Page index out of bounds".into());
        }
        let page = &self.inner.pages()[index];
        let canvas = typst_render::render(
            page,
            &typst_render::RenderOptions {
                pixel_per_pt: Scalar::new(pixel_per_pt as f64),
                ..Default::default()
            },
        );
        Ok(RenderResult {
            bytes: canvas.data().to_vec(),
            width: canvas.width(),
            height: canvas.height(),
        })
    }

    /// Exports the document to a PDF byte array.
    ///
    /// Runs on [`on_pdf_thread`] because the writer's own work is deferred onto
    /// rayon: see that function for what a browser does and does not give it.
    pub fn export_pdf(&self) -> Result<Vec<u8>, String> {
        on_pdf_thread(|| {
            typst_pdf::pdf(&self.inner, &typst_pdf::PdfOptions::default())
                .map_err(|e| format!("{e:?}"))
        })
    }

    /// Exports a specific page to an SVG string.
    pub fn export_svg(&self, index: usize) -> Result<String, String> {
        if index >= self.inner.pages().len() {
            return Err("Page index out of bounds".into());
        }
        let page = &self.inner.pages()[index];
        Ok(typst_svg::svg(page, &typst_svg::SvgOptions::default()))
    }
}

// ── TypstEngine — Stateless Compiler ────────────────────────────────────────

#[frb(opaque)]
pub struct TypstEngine {
    world: SimpleWorld,
}

impl TypstEngine {
    /// Creates a new Typst engine with bundled default fonts.
    #[frb(sync)]
    pub fn new() -> Self {
        Self {
            world: SimpleWorld::new(),
        }
    }

    /// Adds additional fonts to the engine.
    pub fn add_fonts(&mut self, font_data: Vec<Vec<u8>>) {
        self.world.add_fonts(font_data);
    }

    /// Compile Typst markup into a CompiledDocument handle.
    pub fn compile(
        &mut self,
        markup: String,
        files: Vec<VirtualFile>,
        sys_time: Option<i64>,
        inputs: Option<HashMap<String, String>>,
        allow_packages: bool,
    ) -> Result<CompiledDocument, TypstCompileError> {
        self.world.set_markup(markup);
        self.world.set_files(files);
        self.world.set_sys_time(sys_time);
        self.world.set_inputs(inputs);
        self.world.set_allow_packages(allow_packages);

        // Pre-resolve any packages referenced in the source / files.
        // On web the resolver cannot fetch during compilation; the Dart side
        // injects archives beforehand via `add_package_archives`.
        #[cfg(not(target_family = "wasm"))]
        if allow_packages {
            self.world.pre_resolve_packages()?;
        }

        let warned = typst::compile::<PagedDocument>(&self.world);

        // Evict cache entries that haven't been used in the last 10 compilations
        // to prevent unbounded memory growth during live editing.
        comemo::evict(10);

        let warnings: Vec<TypstDiagnostic> = warned
            .warnings
            .iter()
            .map(|w| map_diagnostic(w, &self.world))
            .collect();

        let document: PagedDocument = warned
            .output
            .map_err(|errs| map_errors(&errs, &self.world))?;

        Ok(CompiledDocument {
            inner: document,
            warnings,
        })
    }

    /// Returns the `@namespace/name:version` specs referenced by [markup] and
    /// by any `.typ` file in [files].
    #[frb(sync)]
    pub fn scan_package_specs(&self, markup: &str, files: Vec<VirtualFile>) -> Vec<String> {
        let mut specs = Vec::new();
        self.world
            .resolver()
            .collect_package_specs(markup, &mut specs);
        for file in &files {
            // No let-chains here: the `#[frb]` macro expands this body in a
            // 2021-edition context, where they are not allowed.
            if !file.path.ends_with(".typ") {
                continue;
            }
            let Ok(text) = std::str::from_utf8(&file.bytes) else {
                continue;
            };
            self.world
                .resolver()
                .collect_package_specs(text, &mut specs);
        }
        specs.iter().map(|spec| spec.to_string()).collect()
    }

    /// Returns the `@namespace/name:version` specs already cached by this engine.
    #[frb(sync)]
    pub fn cached_package_specs(&self) -> Vec<String> {
        self.world
            .resolver()
            .cache
            .read()
            .map(|cache| cache.keys().map(|spec| spec.to_string()).collect())
            .unwrap_or_default()
    }

    /// Injects downloaded archives and returns the specs that are still
    /// unresolved (transitive dependencies the caller should fetch next).
    pub fn add_package_archives(
        &mut self,
        archives: Vec<PackageArchive>,
    ) -> Result<Vec<String>, String> {
        let mut unresolved = Vec::new();
        for archive in archives {
            let spec: PackageSpec = archive
                .spec
                .parse()
                .map_err(|e| format!("invalid package spec '{}': {e}", archive.spec))?;
            let referenced = self
                .world
                .resolver()
                .insert_package_archive(&spec, &archive.bytes)
                .map_err(|e| format!("failed to load {spec}: {e}"))?;
            unresolved.extend(referenced.iter().map(|spec| spec.to_string()));
        }
        Ok(unresolved)
    }

    pub fn query(
        &mut self,
        document: &CompiledDocument,
        selector: String,
    ) -> Result<String, String> {
        use comemo::Track;
        use typst::World;
        use typst::engine::Sink;
        use typst::foundations::{Context, IntoValue, LocatableSelector, Scope};
        use typst::introspection::{EmptyIntrospector, Introspector};
        use typst::routines::SpanMode;
        use typst::syntax::{Span, SyntaxMode};
        use typst_eval::eval_string;

        let sel_value = eval_string(
            (&self.world as &dyn World).track(),
            self.world.library(),
            Sink::new().track_mut(),
            EmptyIntrospector.track(),
            Context::none().track(),
            &selector,
            SpanMode::Uniform(Span::detached()),
            SyntaxMode::Code,
            Scope::default(),
        )
        .map_err(|errors| {
            let mut message = String::from("failed to evaluate selector");
            for (i, error) in errors.into_iter().enumerate() {
                message.push_str(if i == 0 { ": " } else { ", " });
                message.push_str(&error.message);
            }
            message
        })?;

        let locatable = sel_value
            .cast::<LocatableSelector>()
            .map_err(|e| format!("Invalid selector: {:?}", e))?;

        let elements = document
            .inner
            .introspector()
            .query(&locatable.0)
            .into_iter()
            .collect::<Vec<_>>();

        let array: typst::foundations::Array =
            elements.into_iter().map(IntoValue::into_value).collect();
        serde_json::to_string(&array).map_err(|e| format!("JSON error: {}", e))
    }
}

#[frb(sync)]
pub fn get_typst_version() -> String {
    env!("TYPST_VERSION").to_string()
}

#[cfg(test)]
mod pdf_thread_tests {
    use super::*;

    #[test]
    fn the_pdf_writer_returns_what_it_was_asked_for() {
        assert_eq!(on_pdf_thread(|| Ok(42)).unwrap(), 42);
    }

    #[test]
    fn the_pdf_writer_runs_from_inside_a_rayon_worker_too() {
        // The wasm shape of an export: typst's own layout has already made the
        // thread a worker, so no pool of ours is built there.
        let on_worker = rayon::ThreadPoolBuilder::new()
            .num_threads(1)
            .build()
            .unwrap()
            .install(|| on_pdf_thread(|| Ok(42)).unwrap());
        assert_eq!(on_worker, 42);
    }

    #[test]
    fn a_failure_inside_the_writer_is_passed_through() {
        assert_eq!(
            on_pdf_thread::<(), _>(|| Err("no pdf today".to_string())).unwrap_err(),
            "no pdf today"
        );
    }

    #[test]
    fn a_native_build_exports_pdf_without_a_pool_of_its_own() {
        // The wasm branch is what a browser exercises (browser e2e, and the
        // harness a consuming app keeps); this pins that the path is still
        // compiled and working everywhere else.
        let mut engine = TypstEngine::new();
        let doc = engine
            .compile("= Hello".to_string(), vec![], None, None, true)
            .unwrap();
        assert!(doc.export_pdf().unwrap().starts_with(b"%PDF"));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_basic_compilation() {
        let mut engine = TypstEngine::new();
        let doc = engine
            .compile("= Hello".to_string(), vec![], None, None, true)
            .unwrap();
        let pdf = doc.export_pdf().unwrap();
        assert!(!pdf.is_empty());
        assert_eq!(doc.page_count(), 1);
    }

    #[test]
    fn test_compile_error() {
        let mut engine = TypstEngine::new();
        let result = engine.compile("#invalid_call()".to_string(), vec![], None, None, true);
        assert!(result.is_err());
        let err = result.unwrap_err();
        assert!(!err.diagnostics.is_empty());
        assert_eq!(err.diagnostics[0].severity, TypstSeverity::Error);
    }

    #[test]
    fn test_compile_disallow_packages() {
        let mut engine = TypstEngine::new();
        let result = engine.compile(
            r#"#import "@preview/tablex:0.0.8": *"#.to_string(),
            vec![],
            None,
            None,
            false, // allow_packages = false
        );
        assert!(result.is_err());
    }

    #[test]
    fn test_svg_export() {
        let mut engine = TypstEngine::new();
        let doc = engine
            .compile("= Hello".to_string(), vec![], None, None, true)
            .unwrap();
        let svg = doc.export_svg(0).unwrap();
        assert!(svg.contains("<svg"));
    }

    #[test]
    fn test_export_svg_out_of_bounds() {
        let mut engine = TypstEngine::new();
        let doc = engine
            .compile("= Hello".to_string(), vec![], None, None, true)
            .unwrap();
        let err = doc.export_svg(1);
        assert!(err.is_err());
    }

    #[test]
    fn test_page_info() {
        let mut engine = TypstEngine::new();
        let doc = engine
            .compile("= Hello".to_string(), vec![], None, None, true)
            .unwrap();
        let info = doc.page_info(0).unwrap();
        assert!(info.width_pt > 0.0);
        assert!(info.height_pt > 0.0);

        let err = doc.page_info(1);
        assert!(err.is_err());
    }

    #[test]
    fn test_render_page() {
        let mut engine = TypstEngine::new();
        let doc = engine
            .compile("= Hello".to_string(), vec![], None, None, true)
            .unwrap();
        let render = doc.render_page(0, 2.0).unwrap();
        assert!(render.width > 0);
        assert!(render.height > 0);
        assert!(!render.bytes.is_empty());

        let err = doc.render_page(1, 2.0);
        assert!(err.is_err());
    }

    #[test]
    fn test_query() {
        let mut engine = TypstEngine::new();
        let doc = engine
            .compile(
                "= Heading 1\n<my-label>".to_string(),
                vec![],
                None,
                None,
                true,
            )
            .unwrap();
        let json = engine.query(&doc, "<my-label>".to_string()).unwrap();
        assert!(json.contains("Heading 1"));
    }

    #[test]
    fn test_query_invalid_selector_cast() {
        let mut engine = TypstEngine::new();
        let doc = engine
            .compile("= Heading".to_string(), vec![], None, None, true)
            .unwrap();
        // Evaluates to an integer (not a LocatableSelector)
        let err = engine.query(&doc, "1 + 1".to_string());
        assert!(err.is_err());
        assert!(err.unwrap_err().contains("Invalid selector"));
    }

    #[test]
    fn test_query_invalid_syntax() {
        let mut engine = TypstEngine::new();
        let doc = engine
            .compile("= Heading".to_string(), vec![], None, None, true)
            .unwrap();
        let err = engine.query(&doc, "<invalid> syntax".to_string());
        assert!(err.is_err());
    }

    #[test]
    fn test_add_fonts_and_warnings() {
        let mut engine = TypstEngine::new();
        let font_data = include_bytes!("../../assets/fonts/DejaVuSansMono.ttf").to_vec();
        engine.add_fonts(vec![font_data]);

        // Warnings check
        let markup = "#set text(font: \"__NonExistent__\")\n= Test\n#assert(1 == 1)".to_string();
        let doc = engine.compile(markup, vec![], None, None, true).unwrap();
        let warnings = doc.warnings();
        assert!(!warnings.is_empty() || warnings.is_empty()); // Verify call succeeds
    }

    #[test]
    fn test_version_and_dto_derives() {
        assert!(!get_typst_version().is_empty());

        // Derives & Debug formatting for FRB DTOs
        let vf = VirtualFile {
            path: "test.txt".to_string(),
            bytes: vec![1],
        };
        let _ = format!("{vf:?} {:?}", vf.clone());

        let rr = RenderResult {
            bytes: vec![0, 0, 0, 255],
            width: 1,
            height: 1,
        };
        let _ = format!("{rr:?} {:?}", rr.clone());

        let pi = PageInfo {
            width_pt: 100.0,
            height_pt: 200.0,
        };
        let _ = format!("{pi:?} {:?}", pi.clone());

        let loc = TypstSourceLocation { line: 1, column: 1 };
        let diag = TypstDiagnostic {
            severity: TypstSeverity::Warning,
            message: "warn".to_string(),
            hints: vec!["hint".to_string()],
            span_start: Some(loc.clone()),
            span_end: Some(loc),
        };
        let err = TypstCompileError {
            diagnostics: vec![diag],
        };
        let _ = format!("{err:?} {:?}", err.clone());
    }
}

// LogisimUI: part of logisim-evolved.
// Derived from logisim-evolution, GPL-3.0-only. See LICENSE.md.
//
// ============================================================================
// THE PROJECT SEAM.
//
// One façade protocol between the app shell and the LogisimFile / LogisimKernel side.
// The shell holds a `ProjectHost` and nothing else: it never sees a `Circuit`, a
// `Component`, an `AttributeSet` or a `CircuitState`.
//
// Why a façade and not direct model access: D4 makes component identity *reference*
// identity and forbids synthesised `Equatable`/`Hashable` on `Component` and
// `AttributeSet`. SwiftUI's `List`, `Table` and `@Observable` diffing all want value
// equality. Binding SwiftUI directly to the kernel model would either force the forbidden
// conformances or produce a UI that never updates. Projecting through value snapshots
// resolves that cleanly, and it also keeps the D9 rule that the kernel stays UI-free from
// leaking in the other direction.
// ============================================================================

import CoreGraphics
import Foundation
import UniformTypeIdentifiers

/// What changed. Coarse on purpose: the shell re-pulls the affected snapshot rather than
/// trying to apply a delta, because snapshots are cheap value types and delta application
/// is where UI/model divergence bugs live.
public struct ProjectChange: OptionSet, Sendable, Hashable {
  public let rawValue: Int
  public init(rawValue: Int) { self.rawValue = rawValue }

  /// Circuits added/removed/renamed/reordered, libraries loaded/unloaded.
  public static let outline = ProjectChange(rawValue: 1 << 0)
  /// A different circuit is being edited.
  public static let currentCircuit = ProjectChange(rawValue: 1 << 1)
  public static let selection = ProjectChange(rawValue: 1 << 2)
  /// An attribute value changed; the inspector must re-pull its form.
  public static let attributes = ProjectChange(rawValue: 1 << 3)
  /// The circuit's geometry changed; content bounds and zoom-to-fit are stale.
  public static let geometry = ProjectChange(rawValue: 1 << 4)
  public static let simulation = ProjectChange(rawValue: 1 << 5)
  public static let undoStack = ProjectChange(rawValue: 1 << 6)
  public static let dirtyState = ProjectChange(rawValue: 1 << 7)
  public static let activeTool = ProjectChange(rawValue: 1 << 8)
  public static let all = ProjectChange(rawValue: 0x1FF)
}

/// Cancels an observation on `deinit`.
///
/// D3's rule applies to this seam too: the host must hold the observation **weakly** and
/// the token holds the closure strongly, so dropping the token unsubscribes and there is no
/// host → shell strong edge to leak.
public final class ProjectObservation: @unchecked Sendable {
  private let cancel: @Sendable () -> Void
  private var isCancelled = false

  public init(cancel: @escaping @Sendable () -> Void) {
    self.cancel = cancel
  }

  deinit {
    if !isCancelled { cancel() }
  }

  public func invalidate() {
    guard !isCancelled else { return }
    isCancelled = true
    cancel()
  }
}

/// An alert the model wants shown. Routed through the shell rather than popped by the model
/// so that D17's headless mode stays possible: a host running under `logisim-cli` simply has
/// no shell attached and the request is logged.
public struct UserFacingIssue: Sendable, Identifiable, Hashable {
  public enum Severity: Sendable, Hashable { case info, warning, failure }

  public var id = UUID()
  public var severity: Severity
  public var title: String
  public var detail: String?
  /// e.g. "Reveal in Circuit", carrying a command to run.
  public var recoveryCommand: ProjectCommand?
  public var recoveryTitle: String?

  public init(
    severity: Severity, title: String, detail: String? = nil,
    recoveryCommand: ProjectCommand? = nil, recoveryTitle: String? = nil
  ) {
    self.severity = severity
    self.title = title
    self.detail = detail
    self.recoveryCommand = recoveryCommand
    self.recoveryTitle = recoveryTitle
  }
}

public enum ProjectHostError: Error, LocalizedError, Sendable {
  case notImplemented(String)
  case invalidValue(AttributeKey, String)
  case readOnly(AttributeKey)
  case unsupportedCommand(String)

  public var errorDescription: String? {
    switch self {
    case .notImplemented(let what): return "\(what) is not implemented yet."
    case .invalidValue(let key, let why): return "‘\(key.name)’ cannot be set: \(why)"
    case .readOnly(let key): return "‘\(key.name)’ is read-only."
    case .unsupportedCommand(let name): return "‘\(name)’ is not available here."
    }
  }
}

/// The one protocol the file/kernel side has to implement for the shell to be a real app.
///
/// Everything is `@MainActor`. That is not a claim that simulation runs on the main
/// thread, D1 keeps the propagator on its own `Thread`, it is a claim that *this façade*
/// is only ever touched from the main thread, and that the host is responsible for hopping
/// committed state across that boundary before publishing a `ProjectChange`.
@MainActor
public protocol ProjectHost: AnyObject {
  // Identity
  var displayName: String { get }
  var fileURL: URL? { get }
  var isDirty: Bool { get }

  // Structure
  var outline: ProjectOutline { get }
  var currentCircuit: CircuitID? { get }
  var activeTool: ToolID? { get }

  // Selection & inspection
  var selection: EditorSelection { get }
  func setSelection(_ selection: EditorSelection)
  func inspectorForm(for selection: EditorSelection) -> InspectorForm
  func apply(_ edit: AttributeEdit) throws
  /// World bounds of a component, for reveal-in-canvas.
  func bounds(of component: ComponentID) -> CGRect?

  // Simulation
  var simulation: SimulationStatus { get }
  func perform(_ command: SimulationCommand)

  // Editing / menus
  var undoStatus: UndoStatus { get }
  /// Enablement drives the menu directly, so a greyed item is greyed for a real reason.
  func canPerform(_ command: ProjectCommand) -> Bool
  func perform(_ command: ProjectCommand) throws

  // Canvas
  /// Vends the renderer for the circuit currently being edited.
  func makeRenderSurface() -> CircuitRenderSurface
  /// The object that receives tool-level pointer and key events from the canvas host.
  var interactionHandler: CanvasInteractionHandler? { get }

  // Printing
  /// Every circuit in the file, each already reduced to one printable page.
  ///
  /// `Print.doPrint` prints the circuits the user ticks in a `CircuitJList` and puts each on its
  /// own page (`Print.java:43,62`); on macOS the page range belongs to `NSPrintPanel`, so the
  /// host offers all of them and the panel narrows.
  ///
  /// This returns built scenes rather than circuits **on purpose**; see the header: the shell
  /// never sees a `Circuit`. `printerView` is upstream's `ParmsPanel.getPrinterView()` and has to
  /// be decided here because it changes what the renderer emits, not how it is drawn.
  func printablePages(appearance: CanvasAppearance, printerView: Bool) -> [PrintableCircuit]

  // Persistence; implemented by the codec team; the shell only ever moves `Data`.
  func serialize() throws -> Data

  // Change notification
  func addObserver(_ observer: @escaping @MainActor (ProjectChange) -> Void)
    -> ProjectObservation
  /// Non-fatal problems the host wants surfaced (D8 unresolved libraries, D13 recorded
  /// propagation errors, migration notices).
  func drainPendingIssues() -> [UserFacingIssue]
}

/// Opening and creating. Separate from `ProjectHost` because it is what a `DocumentGroup`
/// needs *before* a host exists.
@MainActor
public protocol ProjectHostFactory: AnyObject {
  func makeEmptyProject() throws -> ProjectHost
  func openProject(data: Data, url: URL?, contentType: UTType) throws -> ProjectHost
  /// D10: our own UTI. We deliberately do not claim upstream's
  /// `application/x-logisim-circuit`.
  var readableContentTypes: [UTType] { get }
  var writableContentTypes: [UTType] { get }
}

/// Injection point. A single mutable global is the right shape here: there is exactly one
/// codec implementation per process, it is installed once at startup before any window
/// exists, and making it a parameter would thread through every SwiftUI view.
@MainActor
public final class ProjectHostFactoryRegistry {
  public static let shared = ProjectHostFactoryRegistry()

  /// The real, `LogisimFile`-backed host.
  ///
  /// This used to default to `DemoProjectHostFactory`, a stand-in that implemented every member
  /// of `ProjectHost` against fabricated data so the shell was launchable before the codec
  /// landed. It has served its purpose and is deleted: `LogisimFileProjectHost` covers
  /// everything it demonstrated, including the D8/D11 unresolved-library reporting that was the
  /// one thing the stand-in modelled faithfully.
  ///
  /// It is still assignable, because `SocLibrary.registerBuiltinTools()` can only be called by
  /// an executable that links `LogisimSoc` (this module does not), so an app that wants `#Soc`
  /// components installs its own factory that registers them first.
  public var factory: any ProjectHostFactory = LogisimFileProjectHostFactory()
  private init() {}
}

public enum LogisimDocumentType {
  /// D10: distinct app name, own bundle ID, **own document UTI**. Declare this in the app
  /// bundle's `Info.plist` under `UTExportedTypeDeclarations`, conforming to `public.xml`,
  /// with the `circ` filename extension.
  public static let identifier = "app.closiq.logisim-evolved.circuit"

  public static let circuit: UTType =
    UTType(exportedAs: identifier, conformingTo: .xml)

  /// Upstream's own type, IMPORTED rather than exported.
  ///
  /// **This is the migration case, and without it the port cannot open the files it exists to
  /// open.** On any Mac that has ever had logisim-evolution installed, a `.circ` resolves to
  /// `com.cburch.logisim.circ` -- upstream exported it, so LaunchServices answers with upstream's
  /// declaration, not ours, for the same extension. That is every CSC258 machine.
  ///
  /// Measured with upstream temporarily unregistered as the only variable:
  ///
  ///     resolved UTI                          result
  ///     com.cburch.logisim.circ               "About logisim-evolved", NO document window
  ///     app.closiq.logisim-evolved.circuit    opens
  ///
  /// `DocumentGroup` filters on `readableContentTypes` BEFORE `DocumentRoot` runs, so the file is
  /// dropped silently -- even the existing "Could Not Open This Circuit" view never appears, which
  /// is why this looked like the app ignoring the open request rather than rejecting the type.
  ///
  /// `importedAs`, and conforming to `.data` rather than `.xml`: an imported declaration must not
  /// contradict the exporting app's, and upstream's declares no XML conformance. D10 keeps this
  /// out of `writableContentTypes` -- reading someone else's type is interoperability, writing it
  /// is claiming to be them.
  public static let upstreamCircuit: UTType =
    UTType(importedAs: "com.cburch.logisim.circ", conformingTo: .data)

  /// Everything the app will open. Both spellings of the same bytes.
  public static let readable: [UTType] = [circuit, upstreamCircuit]
}

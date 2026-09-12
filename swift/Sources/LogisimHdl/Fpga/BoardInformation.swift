// BoardInformation.swift: part of logisim-evolved.
//
// Derived from logisim-evolution `com/cburch/logisim/fpga/data/BoardInformation.java` (152
// lines), reference tree `upstream-java-4.1.0` (D16). GPL-3.0-only. See LICENSE.md.

/// `com.cburch.logisim.fpga.data.BoardInformation`: one FPGA development board: a name, a
/// device, a picture, and the IO components drawn on top of the picture.
///
/// ── D9: where the picture stops being this module's problem ─────────────────────────────────
///
/// Upstream stores a `java.awt.image.BufferedImage`. Here the field is `BoardImage`, which is
/// **data**: either the JPEG bytes the board file's `PixelData` decoded to, or, for the older
/// uncompressed encoding, raw 8-bit RGB triples plus their dimensions. Decoding either into
/// something paintable is the UI's job.
///
/// That is the seam this port assumes, stated plainly so a later renderer does not have to guess
/// it: **`LogisimHdl` hands out `BoardImage`; whoever draws the board turns it into a
/// `CGImage`.** `BoardImage.jpeg` needs `CGImageSourceCreateWithData` and nothing else;
/// `BoardImage.rgb` needs a `CGDataProvider` over the bytes with
/// `bitsPerComponent: 8, bitsPerPixel: 24`. Neither call belongs in this module.
public final class BoardInformation {

  private var components: [FpgaIoInformationContainer] = []
  public private(set) var boardName: String?
  public private(set) var image: BoardImage?

  /// Upstream exposes `fpga` as a bare public field and mutates it in place. Kept, because
  /// `clear()` resets the device rather than replacing it and `BoardReaderClass` assigns a
  /// freshly built one over the top.
  public var fpga = FpgaDevice()

  public init() {
    clear()
  }

  /// `clear()`.
  public func clear() {
    components.removeAll()
    boardName = nil
    fpga.clear()
    image = nil
  }

  /// `addComponent(FpgaIoInformationContainer)`.
  public func addComponent(_ comp: FpgaIoInformationContainer) {
    components.append(comp)
  }

  /// `setComponents(List)`.
  public func setComponents(_ comps: [FpgaIoInformationContainer]) {
    components = comps
  }

  /// `getAllComponents()`. Document order: the order the `<IOComponents>` children appear in,
  /// which is the order the board editor lists them and the order `MappableResourcesContainer`
  /// clones them in.
  public var allComponents: [FpgaIoInformationContainer] { components }

  public func setBoardName(_ name: String?) { boardName = name }
  public func setImage(_ picture: BoardImage?) { image = picture }

  /// `getNrOfDefinedComponents()`.
  public var numberOfDefinedComponents: Int { components.count }

  /// `getComponent(BoardRectangle)`; first component whose rectangle is *geometrically* equal.
  /// See `FpgaBoardRectangle`'s note on why equality ignores everything but the coordinates.
  public func component(at rect: FpgaBoardRectangle) -> FpgaIoInformationContainer? {
    components.first { $0.rectangle == rect }
  }

  /// `getComponentType(BoardRectangle)`.
  public func componentType(at rect: FpgaBoardRectangle) -> String {
    component(at: rect)?.type.rawValue ?? IoComponentTypes.Unknown.rawValue
  }

  /// `getDriveStrength(BoardRectangle)`.
  public func driveStrength(at rect: FpgaBoardRectangle) -> String {
    guard let comp = component(at: rect) else { return "" }
    return DriveStrength.constrainedDriveStrength(comp.driveStrength)
  }

  /// `getIoStandard(BoardRectangle)`.
  public func ioStandard(at rect: FpgaBoardRectangle) -> String {
    guard let comp = component(at: rect) else { return "" }
    return IoStandards.constrainedIoStandard(comp.ioStandard)
  }

  /// `getPullBehavior(BoardRectangle)`.
  public func pullBehavior(at rect: FpgaBoardRectangle) -> String {
    guard let comp = component(at: rect) else { return "" }
    return PullBehaviors.constrainedPullString(comp.pullBehavior)
  }

  /// `getComponents()`: type name to the pin count of each component of that type.
  ///
  /// Upstream builds this with a single `ArrayList` that it `clone()`s into the map and then
  /// `clear()`s, plus a `list.add(count, …)` whose index argument is redundant. The observable
  /// result is one entry per type that has at least one component. Types with none are absent,
  /// not present-and-empty, and the download layer branches on `containsKey`.
  public var componentsByType: [String: [Int]] {
    var result: [String: [Int]] = [:]
    for type in IoComponentTypes.knownComponentSet {
      let counts = components.filter { $0.type == type }.map(\.numberOfPins)
      if !counts.isEmpty { result[type.rawValue] = counts }
    }
    return result
  }

  /// `getIoComponentsOfType(IoComponentTypes, int)`.
  ///
  /// The doubly nested `if` upstream reads oddly but reduces to: for `DIPSwitch` and `PortIo`
  /// the component must have **at least** `nrOfPins` pins; every other type matches regardless.
  /// Kept in that reduced form, with the equivalence stated rather than the nesting copied.
  public func ioComponents(ofType type: IoComponentTypes, numberOfPins: Int)
    -> [FpgaBoardRectangle]
  {
    components.compactMap { comp in
      guard comp.type == type else { return nil }
      if type == .DIPSwitch || type == .PortIo {
        guard numberOfPins <= comp.numberOfPins else { return nil }
      }
      return comp.rectangle
    }
  }
}

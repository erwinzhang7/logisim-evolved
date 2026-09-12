// AssemblerMessage.swift: part of logisim-evolved.
//
// Replaces Java's `StringGetter` (a lazy localised-string handle, `S.getter("Key")`) used
// throughout com.cburch.logisim.soc.util/nios2 for error text attached to `AssemblerToken`s.
//
// Per D5/D9, localisation does not come across into a kernel-adjacent module: the raw message
// key plus its English source string (from resources/logisim/strings/soc/soc.properties) is
// carried here as a plain, non-localised enum: total, `Equatable`, and comparable across a
// differential-testing run without touching `LocaleManager`. The UI layer owns the localised
// table and can switch on `.key` to look one up.
public enum AssemblerMessage: String, Equatable, Sendable {
  case assemblerUnknownOpcode
  case assemblerAssumingEntryPoint
  case assemblerCannotUseInsideMacro
  case assemblerEndOfMacroNotFound
  case assemblerExpectedMacroName
  case assemblerExpectedMacroNrOfParameters
  case assemblerExpectingLabelIdentifier
  case assemblerMissingLabelBefore
  case assemblerNoExecutableSection
  case assemblerReguiresNumberAfterMath
  case assemblerUnknowCharacter
  case assemblerWrongClosingBracket
  case assemblerWrongOpeningBracket
  case assemblerCouldNotFindAddressForLabel
  case assemblerCouldNotFindValueForDefine
  case assemblerDivZero
  case assemblerExpectedImmediateValueAfterMath
  case assemblerDuplicatedLabelNotSupported
  case assemblerDuplicatedName
  case assemblerDuplicatedSectionError
  case assemblerExpectedLabel
  case assemblerExpectedLabelAndNumber
  case assemblerExpectedParameter
  case assemblerExpectingNumber
  case assemblerExpectingPositiveNumber
  case assemblerExpectingSectionName
  case assemblerExpectingString
  case assemblerMacroIncorrectNumberOfParameters
  case assemblerOverlappingSections
  case assemblerUnknownIdentifier
  case assemblerUnknownLabel
  case assemblerUnsupportedAssemblerInstruction
  case assemblerValueOutOfRange
  case assemblerMacroCallingEachotherDeadlock
  case assemblerMacroCannotUseRecurency
  case assemblerMacroParameterNotDefined

  case assemblerExpectedImmediateValue
  case assemblerExpectedNoArguments
  case assemblerExpectedOneArgument
  case assemblerExpectedTwoArguments
  case assemblerExpectedThreeArguments
  case assemblerExpectedFourArguments
  case assemblerExpectedZeroOrOneArgument
  case assemblerImmediateOutOfRange
  case assemblerUnknownRegister
  case assemblerExpectedRegister
  case assemblerExpextedImmediateOrLabel  // sic; matches upstream's typo verbatim

  case nios2AssemblerExpectedBracketedRegister
  case nios2AssemblerExpectedImmediateIndexedRegister
  case nios2CannotUseControlRegister
  case nios2CannotUseCustomRegister
  case nios2ExpectedControlRegister
  case nios2DonePinError

  // ── The RV32IM assembler's own strings (soc.properties:362-381) ────────────────────────────
  //
  // Note the inconsistent prefixes: upstream really does spell some of these `Rv32im…` and
  // others `RV32im…` in the SAME properties file, and the two are different keys. Transcribed
  // exactly, since a "tidied" key resolves to nothing.
  case rv32imAssemblerExpectedOneOrTwoArguments
  case rv32imAssemblerExpectedTwoOrThreeArguments
  case rv32imEcabNotImplemented
  case rv32imAssemblerBug
  case rv32imAssemblerExpectedBracketedRegister
  case rv32imAssemblerExpectedImmediateIndexedRegister
  case rv32imAssemblerNotSupportedYet
  case rv32imMoiNotImplemented

  /// Non-localised English text, matching `soc.properties` verbatim (used for debug output and
  /// as the fallback the UI layer can render before it wires up real localisation).
  public var englishText: String {
    switch self {
    case .assemblerUnknownOpcode: return "Unknown opcode"
    case .assemblerAssumingEntryPoint:
      return
        "Assuming the lowest address with an instruction as entry-point.\nTo make sure that your cpu starts executing at the right address\nplease add a label called \u{2018}_start\u{2019} at the location\nwhere your cpu should start executing the program."
    case .assemblerCannotUseInsideMacro: return "This construct cannot be used inside a macro definition"
    case .assemblerEndOfMacroNotFound: return "Could not find the end of the macro definition"
    case .assemblerExpectedMacroName: return "Expected a name of the macro"
    case .assemblerExpectedMacroNrOfParameters: return "Expected the number of macro parameters"
    case .assemblerExpectingLabelIdentifier: return "Expecting a label"
    case .assemblerMissingLabelBefore: return "For this operator should be a label"
    case .assemblerNoExecutableSection: return "No instructions found that can be executed."
    case .assemblerReguiresNumberAfterMath: return "After a math operation should follow a number"
    case .assemblerUnknowCharacter: return "Unknown character"
    case .assemblerWrongClosingBracket: return "This closing bracket is not supported"
    case .assemblerWrongOpeningBracket: return "This opening bracket is not supported"
    case .assemblerCouldNotFindAddressForLabel: return "Could not determine an address for this label"
    case .assemblerCouldNotFindValueForDefine: return "Could not find a definition of this parameter"
    case .assemblerDivZero: return "Divide by zero error"
    case .assemblerExpectedImmediateValueAfterMath: return "Expected an immediate value after a math operation"
    case .assemblerDuplicatedLabelNotSupported:
      return "Label names must be unique, found multiple definitions of this label"
    case .assemblerDuplicatedName: return "Cannot use the same name for a .equ and a label"
    case .assemblerDuplicatedSectionError: return "Section names must be unique, found multiple sections with this name"
    case .assemblerExpectedLabel: return "Expected a label"
    case .assemblerExpectedLabelAndNumber: return "Expected a label followed by an immediate value"
    case .assemblerExpectedParameter: return "Expected a parameter at this position"
    case .assemblerExpectingNumber: return "Expected a number"
    case .assemblerExpectingPositiveNumber: return "Expected a positive number"
    case .assemblerExpectingSectionName: return "Expecting a name for this section"
    case .assemblerExpectingString: return "Expected a string"
    case .assemblerMacroIncorrectNumberOfParameters: return "Incorrect number of macro parameters specified"
    case .assemblerOverlappingSections: return "This section overlaps with another section"
    case .assemblerUnknownIdentifier: return "I do not know this identifier"
    case .assemblerUnknownLabel: return "This label has not been defined, hence I cannot use it"
    case .assemblerUnsupportedAssemblerInstruction: return "This assembler instruction is not known"
    case .assemblerValueOutOfRange: return "Value is out of range"
    case .assemblerMacroCallingEachotherDeadlock: return "Macros are calling each other causing a deadlock situation"
    case .assemblerMacroCannotUseRecurency: return "Macro is calling itsELF causing a deadlock situation"
    case .assemblerMacroParameterNotDefined:
      return "This macro parameter is not defined, check the number of parameters in your macro definition"
    case .assemblerExpectedImmediateValue: return "Expected an immediate value"
    case .assemblerExpectedNoArguments: return "Expected no arguments"
    case .assemblerExpectedOneArgument: return "Expected one argument"
    case .assemblerExpectedTwoArguments: return "Expected two arguments"
    case .assemblerExpectedThreeArguments: return "Expected three arguments"
    case .assemblerExpectedFourArguments: return "Expected four arguments"
    case .assemblerExpectedZeroOrOneArgument: return "Expected no or one argument"
    case .assemblerImmediateOutOfRange: return "The immediate value is out of range"
    case .assemblerUnknownRegister: return "Unknown register"
    case .assemblerExpectedRegister: return "Expected a register"
    case .assemblerExpextedImmediateOrLabel: return "Expected an immediate value or a label"
    case .nios2AssemblerExpectedBracketedRegister: return "Expected a bracketed register, e.g. (r1)"
    case .nios2AssemblerExpectedImmediateIndexedRegister:
      return "Expected an immediate indexed register, e.g. 5(r1)"
    case .nios2CannotUseControlRegister: return "Cannot use a control register in this context"
    case .nios2CannotUseCustomRegister: return "Cannot use a custom register in this context"
    case .nios2ExpectedControlRegister: return "Expected a control register (e.g. ctl4)"
    case .nios2DonePinError:
      return "Done pin not defined or in error state cannot continue.\n Please check the done pin."
    case .rv32imAssemblerExpectedOneOrTwoArguments: return "Expected one or two arguments"
    case .rv32imAssemblerExpectedTwoOrThreeArguments: return "Expected two or three arguments"
    case .rv32imEcabNotImplemented:
      return "Currently the environmental call and breakpoints are not implemented"
    case .rv32imAssemblerBug: return "BUG!"
    case .rv32imAssemblerExpectedBracketedRegister:
      return "Expected a bracketed register, e.g. (x1)"
    case .rv32imAssemblerExpectedImmediateIndexedRegister:
      return "Expected an immediate indexed register, e.g. 5(x1)"
    case .rv32imAssemblerNotSupportedYet: return "Unsupported asm opcode"
    case .rv32imMoiNotImplemented:
      return "Currently the memory ordering instructions are not implemented"
    }
  }
}

import WasmParser
import WasmTypes

class ISeqAllocator {

    private var buffers: [UnsafeMutableRawBufferPointer] = []

    func allocateBrTable(capacity: Int) -> UnsafeMutableBufferPointer<Instruction.BrTableOperand.Entry> {
        assert(_isPOD(Instruction.BrTableOperand.Entry.self), "Instruction.BrTableOperand.Entry must be POD")
        let buffer = UnsafeMutableBufferPointer<Instruction.BrTableOperand.Entry>.allocate(capacity: capacity)
        self.buffers.append(UnsafeMutableRawBufferPointer(buffer))
        return buffer
    }

    func allocateConstants(_ slots: [UntypedValue]) -> UnsafeBufferPointer<UntypedValue> {
        let buffer = UnsafeMutableBufferPointer<UntypedValue>.allocate(capacity: slots.count)
        _ = buffer.initialize(fromContentsOf: slots)
        self.buffers.append(UnsafeMutableRawBufferPointer(buffer))
        return UnsafeBufferPointer(buffer)
    }

    func allocateInstructions(capacity: Int) -> UnsafeMutableBufferPointer<UInt64> {
        assert(_isPOD(Instruction.self), "Instruction must be POD")
        let buffer = UnsafeMutableBufferPointer<UInt64>.allocate(capacity: capacity)
        self.buffers.append(UnsafeMutableRawBufferPointer(buffer))
        return buffer
    }

    deinit {
        for buffer in buffers {
            buffer.deallocate()
        }
    }
}

protocol TranslatorContext {
    func resolveType(_ index: TypeIndex) throws -> FunctionType
    func resolveBlockType(_ blockType: BlockType) throws -> FunctionType
    func functionType(_ index: FunctionIndex, interner: Interner<FunctionType>) throws -> FunctionType
    func globalType(_ index: GlobalIndex) throws -> ValueType
    func isMemory64(memoryIndex index: MemoryIndex) throws -> Bool
    func isMemory64(tableIndex index: TableIndex) throws -> Bool
    func elementType(_ index: TableIndex) throws -> ReferenceType
    func resolveCallee(_ index: FunctionIndex) -> InternalFunction?
    func isSameInstance(_ instance: InternalInstance) -> Bool
    func resolveGlobal(_ index: GlobalIndex) -> InternalGlobal?
    func validateDataSegment(_ index: DataIndex) throws
    func validateElementSegment(_ index: ElementIndex) throws
    func validateFunctionIndex(_ index: FunctionIndex) throws
}

extension TranslatorContext {
    func addressType(memoryIndex: MemoryIndex) throws -> ValueType {
        return ValueType.addressType(isMemory64: try isMemory64(memoryIndex: memoryIndex))
    }
    func addressType(tableIndex: TableIndex) throws -> ValueType {
        return ValueType.addressType(isMemory64: try isMemory64(tableIndex: tableIndex))
    }
}

extension InternalInstance: TranslatorContext {
    func resolveType(_ index: TypeIndex) throws -> FunctionType {
        guard Int(index) < self.types.count else {
            throw TranslationError("Type index \(index) is out of range")
        }
        return self.types[Int(index)]
    }
    func resolveBlockType(_ blockType: BlockType) throws -> FunctionType {
        try FunctionType(blockType: blockType, typeSection: self.types)
    }
    func functionType(_ index: FunctionIndex, interner: Interner<FunctionType>) throws -> FunctionType {
        guard Int(index) < self.functions.count else {
            throw TranslationError("Function index \(index) is out of range")
        }
        return interner.resolve(self.functions[Int(index)].type)
    }
    func globalType(_ index: GlobalIndex) throws -> ValueType {
        guard Int(index) < self.globals.count else {
            throw TranslationError("Global index \(index) is out of range")
        }
        return self.globals[Int(index)].globalType.valueType
    }
    func isMemory64(memoryIndex index: MemoryIndex) throws -> Bool {
        guard Int(index) < self.memories.count else {
            throw TranslationError("Memory index \(index) is out of range")
        }
        return self.memories[Int(index)].limit.isMemory64
    }
    func isMemory64(tableIndex index: TableIndex) throws -> Bool {
        guard Int(index) < self.tables.count else {
            throw TranslationError("Table index \(index) is out of range")
        }
        return self.tables[Int(index)].limits.isMemory64
    }
    func elementType(_ index: TableIndex) throws -> ReferenceType {
        guard Int(index) < self.tables.count else {
            throw TranslationError("Table index \(index) is out of range")
        }
        return self.tables[Int(index)].tableType.elementType
    }

    func resolveCallee(_ index: FunctionIndex) -> InternalFunction? {
        return self.functions[Int(index)]
    }
    func resolveGlobal(_ index: GlobalIndex) -> InternalGlobal? {
        return self.globals[Int(index)]
    }
    func isSameInstance(_ instance: InternalInstance) -> Bool {
        return instance == self
    }
    func validateDataSegment(_ index: DataIndex) throws {
        _ = try self.dataSegments[validating: Int(index)]
    }
    func validateElementSegment(_ index: ElementIndex) throws {
        _ = try self.elementSegments[validating: Int(index)]
    }
    func validateFunctionIndex(_ index: FunctionIndex) throws {
        _ = try self.functions[validating: Int(index)]
    }
}

fileprivate struct MetaProgramCounter {
    let offsetFromHead: Int
}

/// The layout of the function stack frame.
///
/// A function call frame starts with a "frame header" which contains
/// the function parameters and the result values. The size of the frame
/// header is determined by the maximum number of parameters and results
/// of the function type. While executing the function, the frame header
/// is used as a storage for parameters. On function return, the frame
/// header is used as a storage for the result values.
///
/// On function entry, the stack frame looks like:
///
/// ```
/// | Offset                             | Description          |
/// |------------------------------------|----------------------|
/// | 0                                  | Function parameter 0 |
/// | 1                                  | Function parameter 1 |
/// | ...                                | ...                  |
/// | len(params)-1                      | Function parameter N |
/// ```
///
/// On function return, the stack frame looks like:
/// ```
/// | Offset                             | Description          |
/// |------------------------------------|----------------------|
/// | 0                                  | Function result 0    |
/// | 1                                  | Function result 1    |
/// | ...                                | ...                  |
/// | len(results)-1                     | Function result N    |
/// ```
///
/// The end of the frame header is usually referred to as "stack pointer"
/// (SP). "local" variables and the value stack space are allocated after
/// the frame header. The value stack space is used to store intermediate
/// values usually corresponding to Wasm's value stack. Unlike the Wasm's
/// value stack, a value slot in the value stack space might be absent if
/// the value is backed by a local variable.
/// The slot index is referred to as "register". The register index is
/// relative to the stack pointer, so the register indices for parameters
/// and results are negative.
///
/// ```
/// | Offset                             | Description          |
/// |------------------------------------|----------------------|
/// | 0 ~ max(params, results)-1         | Frame header         |
/// | SP-3                               |   * Saved Instance   |
/// | SP-2                               |   * Saved PC         |
/// | SP-1                               |   * Saved SP         |
/// | SP+0                               | Local variable 0     |
/// | SP+1                               | Local variable 1     |
/// | ...                                | ...                  |
/// | SP+len(locals)-1                   | Local variable N     |
/// | SP+len(locals)                     | Const 0              |
/// | SP+len(locals)+1                   | Const 1              |
/// | ...                                | ...                  |
/// | SP+len(locals)+C                   | Const C              |
/// | SP+len(locals)+C                   | Value stack 0        |
/// | SP+len(locals)+C+1                 | Value stack 1        |
/// | ...                                | ...                  |
/// | SP+len(locals)+C+heighest(stack)-1 | Value stack N        |
/// ```
/// where `C` is the number of constant slots.

struct FrameHeaderLayout {
    let type: FunctionType
    let paramResultBase: VReg
    
    init(type: FunctionType) {
        self.type = type
        self.paramResultBase = Self.size(of: type)
    }

    func paramReg(_ index: Int) -> VReg {
        VReg(index) - paramResultBase
    }

    func returnReg(_ index: Int) -> VReg {
        return VReg(index) - paramResultBase
    }

    internal static func size(of: FunctionType) -> VReg {
        size(parameters: of.parameters.count, results: of.results.count)
    }
    internal static func size(parameters: Int, results: Int) -> VReg {
        VReg(max(parameters, results)) + VReg(numberOfSavingSlots)
    }
    /// The number of slots used to save the current instance, PC, and SP
    internal static var numberOfSavingSlots: Int { 3 }
}

struct StackLayout {
    let frameHeader: FrameHeaderLayout
    let constantSlotSize: Int
    let numberOfLocals: Int

    var stackRegBase: VReg {
        return VReg(numberOfLocals + constantSlotSize)
    }

    init(type: FunctionType, numberOfLocals: Int, codeSize: Int) throws {
        self.frameHeader = FrameHeaderLayout(type: type)
        self.numberOfLocals = numberOfLocals
        // The number of constant slots is determined by the code size
        self.constantSlotSize = max(codeSize / 20, 4)
        let (maxSlots, overflow) = self.constantSlotSize.addingReportingOverflow(numberOfLocals)
        guard !overflow, maxSlots < VReg.max else {
            throw TranslationError("The number of constant slots overflows")
        }
    }

    func localReg(_ index: LocalIndex) -> VReg {
        if index < frameHeader.type.parameters.count {
            return frameHeader.paramReg(Int(index))
        } else {
            return VReg(index) - VReg(frameHeader.type.parameters.count)
        }
    }

    func constReg(_ index: Int) -> VReg {
        return VReg(numberOfLocals + index)
    }

    func dump<Target: TextOutputStream>(to target: inout Target, iseq: InstructionSequence) {
        let frameHeaderSize = FrameHeaderLayout.size(of: frameHeader.type)
        let slotMinIndex = VReg(-frameHeaderSize)
        let slotMaxIndex = VReg(stackRegBase - 1)
        let slotIndexWidth = max(String(slotMinIndex).count, String(slotMaxIndex).count)
        func writeSlot(_ target: inout Target, _ index: VReg, _ description: String) {
            var index = String(index)
            index = String(repeating: " ", count: slotIndexWidth - index.count) + index

            target.write(" [\(index)] \(description)\n")
        }
        func hex(_ value: UInt64) -> String {
            let value = String(value, radix: 16)
            return String(repeating: "0", count: 16 - value.count) + value
        }

        let savedItems: [String] = ["Instance", "Pc", "Sp"]
        for i in 0..<frameHeaderSize-VReg(savedItems.count) {
            var descriptions: [String] = []
            if i < frameHeader.type.parameters.count {
                descriptions.append("Param \(i)")
            }
            if i < frameHeader.type.results.count {
                descriptions.append("Result \(i)")
            }
            writeSlot(&target, VReg(i - frameHeaderSize), descriptions.joined(separator: ", "))
        }

        for (i, name) in savedItems.enumerated() {
            writeSlot(&target, VReg(i - savedItems.count), "Saved \(name)")
        }

        for i in 0..<numberOfLocals {
            writeSlot(&target, VReg(i), "Local \(i)")
        }
        for i in 0..<iseq.constants.count {
            writeSlot(&target, VReg(numberOfLocals + i), "Const \(i) = \(iseq.constants[i])")
        }
    }
}

struct InstructionTranslator<Context: TranslatorContext>: InstructionVisitor {
    typealias Output = Void

    typealias LabelRef = Int
    typealias ValueType = WasmTypes.ValueType

    struct ControlStack {
        typealias BlockType = FunctionType

        struct ControlFrame {
            enum Kind {
                case block(root: Bool)
                case loop
                case `if`(elseLabel: LabelRef, endLabel: LabelRef)

                static var block: Kind { .block(root: false) }
            }

            let blockType: BlockType
            /// The height of `ValueStack` without including the frame parameters
            let stackHeight: Int
            let continuation: LabelRef
            var kind: Kind
            var reachable: Bool = true

            var copyCount: UInt16 {
                switch self.kind {
                case .block, .if:
                    return UInt16(blockType.results.count)
                case .loop:
                    return UInt16(blockType.parameters.count)
                }
            }
        }

        private var frames: [ControlFrame] = []

        var numberOfFrames: Int { frames.count }

        mutating func pushFrame(_ frame: ControlFrame) {
            self.frames.append(frame)
        }

        mutating func popFrame() -> ControlFrame? {
            self.frames.popLast()
        }

        mutating func markUnreachable() throws {
            try setReachability(false)
        }
        mutating func resetReachability() throws {
            try setReachability(true)
        }

        private mutating func setReachability(_ value: Bool) throws {
            guard !self.frames.isEmpty else {
                throw TranslationError("Control stack is empty. Instruction cannot be appeared after \"end\" of function")
            }
            self.frames[self.frames.count - 1].reachable = value
        }

        func currentFrame() throws -> ControlFrame {
            guard let frame = self.frames.last else {
                throw TranslationError("Control stack is empty. Instruction cannot be appeared after \"end\" of function")
            }
            return frame
        }

        func branchTarget(relativeDepth: UInt32) throws -> ControlFrame {
            let index = frames.count - 1 - Int(relativeDepth)
            guard frames.indices.contains(index) else {
                throw TranslationError("Relative depth \(relativeDepth) is out of range")
            }
            return frames[index]
        }
    }

    enum MetaValue: Equatable {
        case some(ValueType)
        case unknown
    }

    enum MetaValueOnStack {
        case local(ValueType, LocalIndex)
        case stack(MetaValue)
        case const(ValueType, Int)

        var type: MetaValue {
            switch self {
            case .local(let type, _): return .some(type)
            case .stack(let type): return type
            case .const(let type, _): return .some(type)
            }
        }
    }

    enum ValueSource {
        case vreg(VReg)
        case const(Int, ValueType)
        case local(LocalIndex)
    }

    struct ValueStack {
        private var values: [MetaValueOnStack] = []
        /// The maximum height of the stack within the function
        private(set) var maxHeight: Int = 0
        var height: Int { values.count }
        let stackRegBase: VReg
        let stackLayout: StackLayout

        init(stackLayout: StackLayout) {
            self.stackRegBase = stackLayout.stackRegBase
            self.stackLayout = stackLayout
        }

        mutating func push(_ value: ValueType) -> VReg {
            push(.some(value))
        }
        mutating func push(_ value: MetaValue) -> VReg {
            // Record the maximum height of the stack we have seen
            maxHeight = max(maxHeight, height)
            let usedRegister = self.values.count
            self.values.append(.stack(value))
            assert(height < UInt16.max)
            return stackRegBase + VReg(usedRegister)
        }
        mutating func pushLocal(_ localIndex: LocalIndex, locals: inout Locals) throws {
            let type = try locals.type(of: localIndex)
            self.values.append(.local(type, localIndex))
        }
        mutating func pushConst(_ index: Int, type: ValueType) {
            assert(index < stackLayout.constantSlotSize)
            self.values.append(.const(type, index))
        }
        mutating func preserveLocalsOnStack(_ localIndex: LocalIndex) -> [VReg] {
            var copyTo: [VReg] = []
            for i in 0..<values.count {
                guard case .local(let type, localIndex) = self.values[i] else { continue }
                self.values[i] = .stack(.some(type))
                copyTo.append(stackRegBase + VReg(i))
            }
            return copyTo
        }

        mutating func preserveLocalsOnStack(depth: Int) -> [(source: LocalIndex, to: VReg)] {
            var copies: [(source: LocalIndex, to: VReg)] = []
            for offset in 0..<min(depth, self.values.count) {
                let valueIndex = self.values.count - 1 - offset
                let value = self.values[valueIndex]
                guard case .local(let type, let localIndex) = value else { continue }
                self.values[valueIndex] = .stack(.some(type))
                copies.append((localIndex, self.stackRegBase + VReg(valueIndex)))
            }
            return copies
        }

        mutating func preserveConstsOnStack(depth: Int) -> [(source: VReg, to: VReg)] {
            var copies: [(source: VReg, to: VReg)] = []
            for offset in 0..<min(depth, self.values.count) {
                let valueIndex = self.values.count - 1 - offset
                let value = self.values[valueIndex]
                guard case .const(let type, let index) = value else { continue }
                self.values[valueIndex] = .stack(.some(type))
                copies.append((stackLayout.constReg(index), self.stackRegBase + VReg(valueIndex)))
            }
            return copies
        }

        func peek(depth: Int) -> ValueSource {
            return makeValueSource(self.values[height - 1 - depth])
        }

        private func makeValueSource(_ value: MetaValueOnStack) -> ValueSource {
            let source: ValueSource
            switch value {
            case .local(_, let localIndex):
                source = .local(localIndex)
            case .stack:
                source = .vreg(stackRegBase + VReg(height))
            case .const(let type, let index):
                source = .const(index, type)
            }
            return source
        }

        mutating func pop() throws -> (MetaValue, ValueSource) {
            guard let value = self.values.popLast() else {
                throw TranslationError("Expected a value on stack but it's empty")
            }
            let source = makeValueSource(value)
            return (value.type, source)
        }
        mutating func pop(_ expected: ValueType) throws -> ValueSource {
            let (value, register) = try pop()
            switch value {
            case .some(let actual):
                guard actual == expected else {
                    throw TranslationError("Expected \(expected) on the stack top but got \(actual)")
                }
            case .unknown: break  // OK
            }
            return register
        }
        mutating func popRef() throws -> ValueSource {
            let (value, register) = try pop()
            switch value {
            case .some(let actual):
                guard case .ref = actual else {
                    throw TranslationError("Expected reference value on the stack top but got \(actual)")
                }
            case .unknown: break  // OK
            }
            return register
        }
        mutating func truncate(height: Int) throws {
            guard height <= self.height else {
                throw TranslationError("Truncating to \(height) but the stack height is \(self.height)")
            }
            while height != self.height {
                guard self.values.popLast() != nil else {
                    throw TranslationError("Internal consistency error: Stack height is \(self.height) but failed to pop")
                }
            }
        }
    }

    fileprivate struct ISeqBuilder {
        typealias InstructionFactoryWithLabel = (
            ISeqBuilder,
            // The position of the next slot of the creating instruction
            _ source: MetaProgramCounter,
            // The position of the resolved label
            _ target: MetaProgramCounter
        ) -> (WasmKit.Instruction)
        typealias BrTableEntryFactory = (ISeqBuilder, MetaProgramCounter) -> Instruction.BrTableOperand.Entry
        typealias BuildingBrTable = UnsafeMutableBufferPointer<Instruction.BrTableOperand.Entry>

        enum OnPinAction {
            case emitInstruction(
                insertAt: MetaProgramCounter,
                source: MetaProgramCounter,
                InstructionFactoryWithLabel
            )
            case fillBrTableEntry(
                buildingTable: BuildingBrTable,
                index: Int, make: BrTableEntryFactory
            )
        }
        struct LabelUser: CustomStringConvertible {
            let action: OnPinAction
            let sourceLine: UInt

            var description: String {
                "LabelUser:\(sourceLine)"
            }
        }
        enum LabelEntry {
            case unpinned(users: [LabelUser])
            case pinned(MetaProgramCounter)
        }

        typealias ResultRelink = (_ result: VReg) -> Instruction
        fileprivate struct LastEmission {
            let position: MetaProgramCounter
            let resultRelink: ResultRelink?
        }

        private var labels: [LabelEntry] = []
        private var unpinnedLabels: Set<LabelRef> = []
        private var instructions: [UInt64] = []
        private var lastEmission: LastEmission?
        fileprivate var insertingPC: MetaProgramCounter {
            MetaProgramCounter(offsetFromHead: instructions.count)
        }
        let engineConfiguration: EngineConfiguration

        init(engineConfiguration: EngineConfiguration) {
            self.engineConfiguration = engineConfiguration
        }

        func assertDanglingLabels() throws {
            for ref in unpinnedLabels {
                let label = labels[ref]
                switch label {
                case .unpinned(let users):
                    guard !users.isEmpty else { continue }
                    throw TranslationError("Internal consistency error: Label (#\(ref)) is used but not pinned at finalization-time: \(users)")
                case .pinned: break // unreachable in theory
                }
            }
        }

        func trace(_ message: @autoclosure () -> String) {
            #if WASMKIT_TRANSLATOR_TRACE
            print(message())
            #endif
        }

        private mutating func assign(at index: Int, _ instruction: Instruction) {
            trace("assign: \(instruction)")
            let headSlot = instruction.headSlot(threadingModel: engineConfiguration.threadingModel)
            trace("        [\(index)] = 0x\(String(headSlot, radix: 16))")
            self.instructions[index] = headSlot
            if let immediate = instruction.rawImmediate {
                var slots: [CodeSlot] = []
                immediate.emit(to: { slots.append($0) })
                for (i, slot) in slots.enumerated() {
                    let slotIndex = index + 1 + i
                    trace("        [\(slotIndex)] = 0x\(String(slot, radix: 16))")
                    self.instructions[slotIndex] = slot
                }
            }
        }

        mutating func resetLastEmission() {
            lastEmission = nil
        }

        mutating func relinkLastInstructionResult(_ newResult: VReg) -> Bool {
            guard let lastEmission = self.lastEmission,
                  let resultRelink = lastEmission.resultRelink else { return false }
            let newInstruction = resultRelink(newResult)
            assign(at: lastEmission.position.offsetFromHead, newInstruction)
            resetLastEmission()
            return true
        }

        private mutating func emitSlot(_ codeSlot: CodeSlot) {
            trace("emitSlot[\(instructions.count)]: 0x\(String(codeSlot, radix: 16))")
            self.instructions.append(codeSlot)
        }

        func dump() {
            for instruction in instructions {
                print(instruction)
            }
        }

        func finalize() -> [UInt64] {
            return instructions
        }

        mutating func emit(_ instruction: Instruction, resultRelink: ResultRelink? = nil) {
            self.lastEmission = LastEmission(position: insertingPC, resultRelink: resultRelink)
            trace("emitInstruction: \(instruction)")
            emitSlot(instruction.headSlot(threadingModel: engineConfiguration.threadingModel))
            if let immediate = instruction.rawImmediate {
                var slots: [CodeSlot] = []
                immediate.emit(to: { slots.append($0) })
                for slot in slots { emitSlot(slot) }
            }
        }

        mutating func putLabel() -> LabelRef {
            let ref = labels.count
            self.labels.append(.pinned(insertingPC))
            return ref
        }

        mutating func allocLabel() -> LabelRef {
            let ref = labels.count
            self.labels.append(.unpinned(users: []))
            self.unpinnedLabels.insert(ref)
            return ref
        }

        fileprivate func resolveLabel(_ ref: LabelRef) -> MetaProgramCounter? {
            let entry = self.labels[ref]
            switch entry {
            case .pinned(let pc): return pc
            case .unpinned: return nil
            }
        }

        fileprivate mutating func pinLabel(_ ref: LabelRef, pc: MetaProgramCounter) throws {
            switch self.labels[ref] {
            case .pinned(let oldPC):
                throw TranslationError("Internal consistency error: Label \(ref) is already pinned at \(oldPC), but tried to pin at \(pc) again")
            case .unpinned(let users):
                self.labels[ref] = .pinned(pc)
                self.unpinnedLabels.remove(ref)
                for user in users {
                    switch user.action {
                    case let .emitInstruction(insertAt, source, make):
                        assign(at: insertAt.offsetFromHead, make(self, source, pc))
                    case let .fillBrTableEntry(brTable, index, make):
                        brTable[index] = make(self, pc)
                    }
                }
            }
        }

        mutating func pinLabelHere(_ ref: LabelRef) throws {
            try pinLabel(ref, pc: insertingPC)
        }

        /// Emit an instruction at the current insertion point with resolved label position
        /// - Parameters:
        ///   - ref: Label reference to be resolved
        ///   - make: Factory closure to make an inserting instruction
        mutating func emitWithLabel<Immediate: InstructionImmediate>(
            _ makeInstruction: @escaping (Immediate) -> Instruction,
            _ ref: LabelRef,
            line: UInt = #line,
            make: @escaping (
                ISeqBuilder,
                // The position of the next slot of the creating instruction
                _ source: MetaProgramCounter,
                // The position of the resolved label
                _ target: MetaProgramCounter
            ) -> (Immediate)
        ) {
            let insertAt = insertingPC

            // Emit dummy instruction to be replaced later
            emitSlot(0)  // dummy opcode
            var immediateSlots = 0
            Immediate.emit(to: { _ in immediateSlots += 1 })
            for _ in 0..<immediateSlots { emitSlot(0) }

            // Schedule actual emission
            emitWithLabel(ref, insertAt: insertAt, line: line, make: {
                makeInstruction(make($0, $1, $2))
            })
        }

        /// Emit an instruction at the specified position with resolved label position
        /// - Parameters:
        ///   - ref: Label reference to be resolved
        ///   - insertAt: Instruction sequence offset to insert at
        ///   - make: Factory closure to make an inserting instruction
        private mutating func emitWithLabel(
            _ ref: LabelRef, insertAt: MetaProgramCounter,
            line: UInt = #line, make: @escaping InstructionFactoryWithLabel
        ) {
            switch self.labels[ref] {
            case .pinned(let pc):
                assign(at: insertAt.offsetFromHead, make(self, insertingPC, pc))
            case .unpinned(var users):
                users.append(LabelUser(action: .emitInstruction(insertAt: insertAt, source: insertingPC, make), sourceLine: line))
                self.labels[ref] = .unpinned(users: users)
            }
        }

        /// Schedule to fill a br_table entry with the resolved label position
        /// - Parameters:
        ///   - ref: Label reference to be resolved
        ///   - table: Building br_table buffer
        ///   - index: Index of the entry to fill
        ///   - make: Factory closure to make an br_table entry
        mutating func fillBrTableEntry(
            _ ref: LabelRef,
            table: BuildingBrTable,
            index: Int, line: UInt = #line,
            make: @escaping BrTableEntryFactory
        ) {
            switch self.labels[ref] {
            case .pinned(let pc):
                table[index] = make(self, pc)
            case .unpinned(var users):
                users.append(LabelUser(action: .fillBrTableEntry(buildingTable: table, index: index, make: make), sourceLine: line))
                self.labels[ref] = .unpinned(users: users)
            }
        }
    }

    struct Locals {
        let types: [ValueType]

        var count: Int { types.count }

        func type(of localIndex: UInt32) throws -> ValueType {
            guard Int(localIndex) < types.count else {
                throw TranslationError("Local index \(localIndex) is out of range")
            }
            return self.types[Int(localIndex)]
        }
    }

    struct ConstSlots {
        private(set) var values: [UntypedValue]
        private var indexByValue: [UntypedValue: Int]
        let stackLayout: StackLayout

        init(stackLayout: StackLayout) {
            self.values = []
            self.indexByValue = [:]
            self.stackLayout = stackLayout
        }

        mutating func allocate(_ value: Value) -> Int? {
            let untyped = UntypedValue(value)
            if let allocated = indexByValue[untyped] {
                // NOTE: Share the same const slot for exactly the same bit pattern
                // values even having different types
                return allocated
            }
            guard values.count < stackLayout.constantSlotSize else { return nil }
            let constSlotIndex = values.count
            values.append(untyped)
            indexByValue[untyped] = constSlotIndex
            return constSlotIndex
        }
    }

    let allocator: ISeqAllocator
    let funcTypeInterner: Interner<FunctionType>
    let module: Context
    private var iseqBuilder: ISeqBuilder
    var controlStack: ControlStack
    var valueStack: ValueStack
    var locals: Locals
    let type: FunctionType
    let stackLayout: StackLayout
    /// The index of the function in the module
    let functionIndex: FunctionIndex
    /// Whether a call to this function should be intercepted
    let intercepting: Bool
    var constantSlots: ConstSlots

    init(
        allocator: ISeqAllocator,
        engineConfiguration: EngineConfiguration,
        funcTypeInterner: Interner<FunctionType>,
        module: Context,
        type: FunctionType,
        locals: [WasmTypes.ValueType],
        functionIndex: FunctionIndex,
        codeSize: Int,
        intercepting: Bool
    ) throws {
        self.allocator = allocator
        self.funcTypeInterner = funcTypeInterner
        self.type = type
        self.module = module
        self.iseqBuilder = ISeqBuilder(engineConfiguration: engineConfiguration)
        self.controlStack = ControlStack()
        self.stackLayout = try StackLayout(
            type: type,
            numberOfLocals: locals.count,
            codeSize: codeSize
        )
        self.valueStack = ValueStack(stackLayout: stackLayout)
        self.locals = Locals(types: type.parameters + locals)
        self.functionIndex = functionIndex
        self.intercepting = intercepting
        self.constantSlots = ConstSlots(stackLayout: stackLayout)

        do {
            let endLabel = self.iseqBuilder.allocLabel()
            let rootFrame = ControlStack.ControlFrame(
                blockType: type,
                stackHeight: 0,
                continuation: endLabel,
                kind: .block(root: true)
            )
            self.controlStack.pushFrame(rootFrame)
        }
    }

    private func returnReg(_ index: Int) -> VReg {
        return stackLayout.frameHeader.returnReg(index)
    }
    private func localReg(_ index: LocalIndex) -> VReg {
        return stackLayout.localReg(index)
    }

    private mutating func emit(_ instruction: Instruction, resultRelink: ISeqBuilder.ResultRelink? = nil) {
        iseqBuilder.emit(instruction, resultRelink: resultRelink)
    }

    @discardableResult
    private mutating func emitCopyStack(from source: VReg, to dest: VReg) -> Bool {
        guard source != dest else { return false }
        emit(.copyStack(Instruction.CopyStackOperand(source: LVReg(source), dest: LVReg(dest))))
        return true
    }

    private mutating func preserveOnStack(depth: Int) {
        preserveLocalsOnStack(depth: depth)
        for (source, dest) in valueStack.preserveConstsOnStack(depth: depth) {
            emitCopyStack(from: source, to: dest)
        }
    }

    private mutating func preserveLocalsOnStack(_ localIndex: LocalIndex) {
        for copyTo in valueStack.preserveLocalsOnStack(localIndex) {
            emitCopyStack(from: localReg(localIndex), to: copyTo)
        }
    }

    /// Emit copy instructions to ensure local variable values on the logical
    /// stack are on the physical stack.
    ///
    /// - Parameter depth: The depth of the logical stack to ensure the values
    ///   are on the physical stack.
    private mutating func preserveLocalsOnStack(depth: Int) {
        for (sourceLocal, destReg) in valueStack.preserveLocalsOnStack(depth: depth) {
            emitCopyStack(from: localReg(sourceLocal), to: destReg)
        }
    }

    /// Perform a precondition check for pop operation on value stack.
    ///
    /// - Parameter typeHint: A type expected to be popped. Only used for diagnostic purpose.
    /// - Returns: `true` if check succeed. `false` if the pop operation is going to be performed in unreachable code path.
    private func checkBeforePop(typeHint: ValueType?) throws -> Bool {
        let controlFrame = try controlStack.currentFrame()
        if _slowPath(valueStack.height <= controlFrame.stackHeight) {
            if controlFrame.reachable {
                let message: String
                if let typeHint {
                    message = "Expected a \(typeHint) value on stack but it's empty"
                } else {
                    message = "Expected a value on stack but it's empty"
                }
                throw TranslationError(message)
            }
            // Too many pop on unreachable path is ignored
            return false
        }
        return true
    }
    private mutating func ensureOnVReg(_ source: ValueSource) -> VReg {
        // TODO: Copy to stack if source is on preg
        // let copyTo = valueStack.stackRegBase + VReg(valueStack.height)
        switch source {
        case .vreg(let register):
            return register
        case .local(let index):
            return stackLayout.localReg(index)
        case .const(let index, _):
            return stackLayout.constReg(index)
        }
    }
    private mutating func ensureOnStack(_ source: ValueSource) -> VReg {
        let copyTo = valueStack.stackRegBase + VReg(valueStack.height)
        switch source {
        case .vreg(let vReg):
            return vReg
        case .local(let localIndex):
            emitCopyStack(from: localReg(localIndex), to: copyTo)
            return copyTo
        case .const(let index, _):
            emitCopyStack(from: stackLayout.constReg(index), to: copyTo)
            return copyTo
        }
    }
    private mutating func popOperand(_ type: ValueType) throws -> ValueSource? {
        guard try checkBeforePop(typeHint: type) else {
            return nil
        }
        return try valueStack.pop(type)
    }

    private mutating func popOnStackOperand(_ type: ValueType) throws -> VReg? {
        guard let op = try popOperand(type) else { return nil }
        return ensureOnStack(op)
    }

    private mutating func popVRegOperand(_ type: ValueType) throws -> VReg? {
        guard let op = try popOperand(type) else { return nil }
        return ensureOnVReg(op)
    }

    private mutating func popAnyOperand() throws -> (MetaValue, ValueSource?) {
        guard try checkBeforePop(typeHint: nil) else {
            return (.unknown, nil)
        }
        return try valueStack.pop()
    }

    private mutating func visitReturnLike() throws {
        preserveOnStack(depth: self.type.results.count)
        for (index, resultType) in self.type.results.enumerated().reversed() {
            let source = ensureOnVReg(try valueStack.pop(resultType))
            let dest = returnReg(index)
            emitCopyStack(from: source, to: dest)
        }
    }

    @discardableResult
    private mutating func copyOnBranch(targetFrame frame: ControlStack.ControlFrame) throws -> Bool {
        preserveOnStack(depth: min(Int(frame.copyCount), valueStack.height - frame.stackHeight))
        let copyCount = VReg(frame.copyCount)
        let sourceBase = valueStack.stackRegBase + VReg(valueStack.height)
        let destBase = valueStack.stackRegBase + VReg(frame.stackHeight)
        var emittedCopy = false
        for i in (0..<copyCount).reversed() {
            let source = sourceBase - 1 - VReg(i)
            let dest: VReg
            if case .block(root: true) = frame.kind {
                dest = returnReg(Int(copyCount - 1 - i))
            } else {
                dest = destBase + copyCount - 1 - VReg(i)
            }
            let copied = emitCopyStack(from: source, to: dest)
            emittedCopy = emittedCopy || copied
        }
        return emittedCopy
    }
    private mutating func translateReturn() throws {
        if intercepting {
            // Emit `onExit` instruction before every `return` instruction
            emit(.onExit(functionIndex))
        }
        try visitReturnLike()
        iseqBuilder.emit(._return)
    }
    private mutating func markUnreachable() throws {
        try controlStack.markUnreachable()
        let currentFrame = try controlStack.currentFrame()
        try valueStack.truncate(height: currentFrame.stackHeight)
    }

    private mutating func finalize() throws -> InstructionSequence {
        if controlStack.numberOfFrames > 1 {
            throw TranslationError("Expect \(controlStack.numberOfFrames - 1) more `end` instructions")
        }
        // Check dangling labels
        try iseqBuilder.assertDanglingLabels()

        iseqBuilder.emit(._return)
        let instructions = iseqBuilder.finalize()
        // TODO: Figure out a way to avoid the copy here while keeping the execution performance.
        let buffer = allocator.allocateInstructions(capacity: instructions.count)
        for (idx, instruction) in instructions.enumerated() {
            buffer[idx] = instruction
        }
        let constants = allocator.allocateConstants(self.constantSlots.values)
        return InstructionSequence(
            instructions: buffer,
            maxStackHeight: Int(valueStack.stackRegBase) + valueStack.maxHeight,
            constants: constants
        )
    }

    // MARK: Main entry point

    /// Translate a Wasm expression into a sequence of instructions.
    mutating func translate(
        code: Code,
        instance: InternalInstance
    ) throws -> InstructionSequence {
        if intercepting {
            // Emit `onEnter` instruction at the beginning of the function
            emit(.onEnter(functionIndex))
        }
        try code.parseExpression(visitor: &self)
        return try finalize()
    }

    // MARK: - Visitor

    mutating func visitUnreachable() throws -> Output {
        emit(.unreachable)
        try markUnreachable()
    }
    mutating func visitNop() -> Output { emit(.nop) }

    mutating func visitBlock(blockType: WasmParser.BlockType) throws -> Output {
        let blockType = try module.resolveBlockType(blockType)
        let endLabel = iseqBuilder.allocLabel()
        var parameters: [ValueSource?] = []
        for param in blockType.parameters.reversed() {
            parameters.append(try popOperand(param))
        }
        let stackHeight = self.valueStack.height
        for (param, value) in zip(blockType.parameters, parameters.reversed()) {
            switch value {
            case .local(let localIndex):
                // Re-push local variables to the stack
                _ = try valueStack.pushLocal(localIndex, locals: &locals)
            case .vreg, nil:
                _ = valueStack.push(param)
            case .const(let index, let type):
                valueStack.pushConst(index, type: type)
            }
        }
        controlStack.pushFrame(ControlStack.ControlFrame(blockType: blockType, stackHeight: stackHeight, continuation: endLabel, kind: .block))
    }

    mutating func visitLoop(blockType: WasmParser.BlockType) throws -> Output {
        let blockType = try module.resolveBlockType(blockType)
        preserveOnStack(depth: blockType.parameters.count)
        iseqBuilder.resetLastEmission()
        for param in blockType.parameters.reversed() {
            _ = try popOperand(param)
        }
        let headLabel = iseqBuilder.putLabel()
        let stackHeight = self.valueStack.height
        for param in blockType.parameters {
            _ = valueStack.push(param)
        }
        controlStack.pushFrame(ControlStack.ControlFrame(blockType: blockType, stackHeight: stackHeight, continuation: headLabel, kind: .loop))
    }

    mutating func visitIf(blockType: WasmParser.BlockType) throws -> Output {
        // Pop condition value
        let condition = try popVRegOperand(.i32)
        let blockType = try module.resolveBlockType(blockType)
        preserveOnStack(depth: blockType.parameters.count)
        let endLabel = iseqBuilder.allocLabel()
        let elseLabel = iseqBuilder.allocLabel()
        for param in blockType.parameters.reversed() {
            _ = try popOperand(param)
        }
        let stackHeight = self.valueStack.height
        for param in blockType.parameters {
            _ = valueStack.push(param)
        }
        controlStack.pushFrame(
            ControlStack.ControlFrame(
                blockType: blockType, stackHeight: stackHeight, continuation: endLabel,
                kind: .if(elseLabel: elseLabel, endLabel: endLabel)
            )
        )
        guard let condition = condition else { return }
        iseqBuilder.emitWithLabel(Instruction.brIfNot, endLabel) { iseqBuilder, selfPC, endPC in
            let targetPC: MetaProgramCounter
            if let elsePC = iseqBuilder.resolveLabel(elseLabel) {
                targetPC = elsePC
            } else {
                targetPC = endPC
            }
            let elseOrEnd = UInt32(targetPC.offsetFromHead - selfPC.offsetFromHead)
            return Instruction.BrIfOperand(condition: LVReg(condition), offset: Int32(elseOrEnd))
        }
    }

    mutating func visitElse() throws -> Output {
        let frame = try controlStack.currentFrame()
        guard case let .if(elseLabel, endLabel) = frame.kind else {
            throw TranslationError("Expected `if` control frame on top of the stack for `else` but got \(frame)")
        }
        preserveOnStack(depth: valueStack.height - frame.stackHeight)
        try controlStack.resetReachability()
        iseqBuilder.resetLastEmission()
        iseqBuilder.emitWithLabel(Instruction.br, endLabel) { _, selfPC, endPC in
            let offset = endPC.offsetFromHead - selfPC.offsetFromHead
            return Int32(offset)
        }
        try valueStack.truncate(height: frame.stackHeight)
        // Re-push parameters
        for parameter in frame.blockType.parameters {
            _ = valueStack.push(parameter)
        }
        try iseqBuilder.pinLabelHere(elseLabel)
    }

    mutating func visitEnd() throws -> Output {
        guard let poppedFrame = controlStack.popFrame() else {
            throw TranslationError("Unexpected `end` instruction")
        }
        // Reset the last emission to avoid relinking the result of the last instruction inside the block.
        // Relinking results across the block boundary is invalid because the producer instruction is not
        // statically known. Think about the following case:
        // ```
        // local.get 0
        // if
        //   i32.const 2
        // else
        //   i32.const 3
        // end
        // local.set 0
        // ```
        //
        iseqBuilder.resetLastEmission()
        if case .block(root: true) = poppedFrame.kind {
            if poppedFrame.reachable {
                try translateReturn()
            }
            try iseqBuilder.pinLabelHere(poppedFrame.continuation)
            return
        }

        // NOTE: `valueStack.height - poppedFrame.stackHeight` is usually the same as `poppedFrame.copyCount`
        // but it's not always the case when this block is already unreachable.
        preserveOnStack(depth: Int(valueStack.height - poppedFrame.stackHeight))
        switch poppedFrame.kind {
        case .block:
            try iseqBuilder.pinLabelHere(poppedFrame.continuation)
        case .loop: break
        case .if:
            try iseqBuilder.pinLabelHere(poppedFrame.continuation)
        }
        try valueStack.truncate(height: poppedFrame.stackHeight)
        for result in poppedFrame.blockType.results {
            _ = valueStack.push(result)
        }
    }

    private static func computePopCount(
        destination: ControlStack.ControlFrame,
        currentFrame: ControlStack.ControlFrame,
        currentHeight: Int
    ) throws -> UInt32 {
        let popCount: UInt32
        if _fastPath(currentFrame.reachable) {
            let count = currentHeight - Int(destination.copyCount) - destination.stackHeight
            guard count >= 0 else {
                throw TranslationError("Stack height underflow: available \(currentHeight), required \(destination.stackHeight + Int(destination.copyCount))")
            }
            popCount = UInt32(count)
        } else {
            // Slow path: This path is taken when "br" is placed after "unreachable"
            // It's ok to put the fake popCount because it will not be executed at runtime.
            popCount = 0
        }
        return popCount
    }

    private mutating func emitBranch<Immediate: InstructionImmediate>(
        _ makeInstruction: @escaping (Immediate) -> Instruction,
        relativeDepth: UInt32,
        make: @escaping (_ offset: Int32, _ copyCount: UInt32, _ popCount: UInt32) -> Immediate
    ) throws {
        let frame = try controlStack.branchTarget(relativeDepth: relativeDepth)
        let copyCount = frame.copyCount
        let popCount = try Self.computePopCount(
            destination: frame,
            currentFrame: try controlStack.currentFrame(),
            currentHeight: valueStack.height
        )
        iseqBuilder.emitWithLabel(makeInstruction, frame.continuation) { _, selfPC, continuation in
            let relativeOffset = continuation.offsetFromHead - selfPC.offsetFromHead
            return make(Int32(relativeOffset), UInt32(copyCount), popCount)
        }
    }
    mutating func visitBr(relativeDepth: UInt32) throws -> Output {
        let frame = try controlStack.branchTarget(relativeDepth: relativeDepth)

        // Copy from the stack top to the bottom to avoid overwrites
        //              [BLOCK1]
        //              [      ]
        //              [      ]
        //              [BLOCK2] () -> (i32, i64)
        // copy [1] +-->[  i32 ]
        //          +---[  i32 ]<--+ copy [2]
        //              [  i64 ]---+
        try copyOnBranch(targetFrame: frame)
        try emitBranch(Instruction.br, relativeDepth: relativeDepth) { offset, copyCount, popCount in
            return offset
        }
        try markUnreachable()
    }

    mutating func visitBrIf(relativeDepth: UInt32) throws -> Output {
        guard let condition = try popVRegOperand(.i32) else { return }

        let frame = try controlStack.branchTarget(relativeDepth: relativeDepth)
        if frame.copyCount == 0 {
            // Optimization where we don't need copying values when the branch taken
            iseqBuilder.emitWithLabel(Instruction.brIf, frame.continuation) { _, selfPC, continuation in
                let relativeOffset = continuation.offsetFromHead - selfPC.offsetFromHead
                return Instruction.BrIfOperand(
                    condition: LVReg(condition), offset: Int32(relativeOffset)
                )
            }
            return
        }
        preserveOnStack(depth: valueStack.height - frame.stackHeight)

        // If branch taken, fallthrough to landing pad, copy stack values
        // then branch to the actual place
        // If branch not taken, branch to the next of the landing pad
        //
        // (block (result i32)
        //   (i32.const 42)
        //   (i32.const 24)
        //   (local.get 0)
        //   (br_if 0) ------+
        //   (local.get 1)   |
        // )         <-------+
        //
        // [0x00] (i32.const 42 reg:0)
        // [0x01] (i32.const 24 reg:1)
        // [0x02] (local.get 0 result=reg:2)
        // [0x03] (br_if_z offset=+0x3 cond=reg:2) --+
        // [0x04] (stack.copy reg:1 -> reg:0)        |
        // [0x05] (br offset=+0x2) --------+         |
        // [0x06] (local.get 1 reg:2) <----|---------+
        // [0x07] ...              <-------+
        let onBranchNotTaken = iseqBuilder.allocLabel()
        iseqBuilder.emitWithLabel(Instruction.brIfNot, onBranchNotTaken) { _, conditionCheckAt, continuation in
            let relativeOffset = continuation.offsetFromHead - conditionCheckAt.offsetFromHead
            return Instruction.BrIfOperand(condition: LVReg(condition), offset: Int32(relativeOffset))
        }
        try copyOnBranch(targetFrame: frame)
        try emitBranch(Instruction.br, relativeDepth: relativeDepth) { offset, copyCount, popCount in
            return offset
        }
        try iseqBuilder.pinLabelHere(onBranchNotTaken)
    }

    mutating func visitBrTable(targets: WasmParser.BrTable) throws -> Output {
        guard let index = try popVRegOperand(.i32) else { return }
        guard try controlStack.currentFrame().reachable else { return }

        let defaultFrame = try controlStack.branchTarget(relativeDepth: targets.defaultIndex)

        preserveOnStack(depth: Int(defaultFrame.copyCount))
        let allLabelIndices = targets.labelIndices + [targets.defaultIndex]
        let tableBuffer = allocator.allocateBrTable(capacity: allLabelIndices.count)
        let operand = Instruction.BrTableOperand(
            baseAddress: tableBuffer.baseAddress!,
            count: UInt16(tableBuffer.count), index: index
        )
        iseqBuilder.emit(.brTable(operand))
        let brTableAt = iseqBuilder.insertingPC

        //
        // (block $l1 (result i32)
        //   (i32.const 63)
        //   (block $l2 (result i32)
        //     (i32.const 42)
        //     (i32.const 24)
        //     (local.get 0)
        //     (br_table $l1 $l2) ---+
        //                           |
        //   )               <-------+
        //   (i32.const 36)          |
        // )              <----------+
        //
        //
        //           [0x00] (i32.const 63 reg:0)
        //           [0x01] (i32.const 42 reg:1)
        //           [0x02] (i32.const 24 reg:2)
        //           [0x03] (local.get 0 result=reg:3)
        //           [0x04] (br_table index=reg:3 offsets=[
        //                    +0x01       -----------------+
        //                    +0x03       -----------------|----+
        //                  ])                             |    |
        //           [0x05] (stack.copy reg:2 -> reg:0) <--+    |
        //  +------- [0x06] (br offset=+0x03)                   |
        //  |        [0x07] (stack.copy reg:2 -> reg:1)  <------+
        //  |  +---- [0x08] (br offset=+0x03)
        //  +--|---> [0x09] (i32.const 36 reg:2)
        //     |     [0x0a] (stack.copy reg:2 -> reg:0)
        //     +---> [0x0b] ...
        for (entryIndex, labelIndex) in allLabelIndices.enumerated() {
            let frame = try controlStack.branchTarget(relativeDepth: labelIndex)
            do {
                let relativeOffset = iseqBuilder.insertingPC.offsetFromHead - brTableAt.offsetFromHead
                tableBuffer[entryIndex] = Instruction.BrTableOperand.Entry(
                    offset: Int32(relativeOffset)
                )
            }
            let emittedCopy = try copyOnBranch(targetFrame: frame)
            if emittedCopy {
                iseqBuilder.emitWithLabel(Instruction.br, frame.continuation) { _, brAt, continuation in
                    let relativeOffset = continuation.offsetFromHead - brAt.offsetFromHead
                    return Int32(relativeOffset)
                }
            } else {
                // Optimization: If no value is copied, we can directly jump to the target
                iseqBuilder.fillBrTableEntry(frame.continuation, table: tableBuffer, index: entryIndex) { _, continuation in
                    return Instruction.BrTableOperand.Entry(offset: Int32(continuation.offsetFromHead - brTableAt.offsetFromHead))
                }
            }
        }
        try markUnreachable()
    }

    mutating func visitReturn() throws -> Output {
        guard try controlStack.currentFrame().reachable else { return }
        try translateReturn()
        try markUnreachable()
    }

    private mutating func visitCallLike(calleeType: FunctionType) throws -> VReg? {
        for parameter in calleeType.parameters.reversed() {
            guard let _ = try popOnStackOperand(parameter) else { return nil }
        }

        let spAddend = valueStack.stackRegBase + VReg(valueStack.height)
            + FrameHeaderLayout.size(of: calleeType)

        for result in calleeType.results {
            _ = valueStack.push(result)
        }
        return VReg(spAddend)
    }
    mutating func visitCall(functionIndex: UInt32) throws -> Output {
        let calleeType = try self.module.functionType(functionIndex, interner: funcTypeInterner)
        guard let spAddend = try visitCallLike(calleeType: calleeType) else { return }
        guard let callee = self.module.resolveCallee(functionIndex) else {
            // Skip actual code emission if validation-only mode
            return
        }
        if callee.isWasm {
            if module.isSameInstance(callee.wasm.instance) {
                emit(.compilingCall(Instruction.CallOperand(callee: callee, spAddend: spAddend)))
                return
            }
        }
        emit(.call(Instruction.CallOperand(callee: callee, spAddend: spAddend)))
    }

    mutating func visitCallIndirect(typeIndex: UInt32, tableIndex: UInt32) throws -> Output {
        let addressType = try module.addressType(tableIndex: tableIndex)
        let address = try popVRegOperand(addressType)  // function address
        let calleeType = try self.module.resolveType(typeIndex)
        guard let spAddend = try visitCallLike(calleeType: calleeType) else { return }
        guard let address = address else { return }
        let internType = funcTypeInterner.intern(calleeType)
        let operand = Instruction.CallIndirectOperand(
            tableIndex: tableIndex,
            type: internType,
            index: address,
            spAddend: spAddend
        )
        emit(.callIndirect(operand))
    }

    mutating func visitDrop() throws -> Output {
        _ = try popAnyOperand()
        iseqBuilder.resetLastEmission()
    }
    mutating func visitSelect() throws -> Output {
        let condition = try popVRegOperand(.i32)
        let (value1Type, value1) = try popAnyOperand()
        let (value2Type, value2) = try popAnyOperand()
        switch (value1Type, value2Type) {
        case let (.some(type1), .some(type2)):
            guard type1 == type2 else {
                throw TranslationError("Type mismatch on `select`. Expected \(value1Type) and \(value2Type) to be same")
            }
        case (.unknown, _), (_, .unknown):
            break
        }
        let result = valueStack.push(value1Type)
        if let condition = condition, let value1 = value1, let value2 = value2 {
            let operand = Instruction.SelectOperand(
                result: result,
                condition: condition,
                onTrue: ensureOnVReg(value2),
                onFalse: ensureOnVReg(value1)
            )
            emit(.select(operand))
        }
    }
    mutating func visitTypedSelect(type: WasmTypes.ValueType) throws -> Output {
        let condition = try popVRegOperand(.i32)
        let (value1Type, value1) = try popAnyOperand()
        let (_, value2) = try popAnyOperand()
        // TODO: Perform actual validation
        // guard value1 == ValueType(type) else {
        //     throw TranslationError("Type mismatch on `select`. Expected \(value1) and \(type) to be same")
        // }
        // guard value2 == ValueType(type) else {
        //     throw TranslationError("Type mismatch on `select`. Expected \(value2) and \(type) to be same")
        // }
        let result = valueStack.push(value1Type)
        if let condition = condition, let value1 = value1, let value2 = value2 {
            let operand = Instruction.SelectOperand(
                result: result,
                condition: condition,
                onTrue: ensureOnVReg(value2),
                onFalse: ensureOnVReg(value1)
            )
            emit(.select(operand))
        }
    }
    mutating func visitLocalGet(localIndex: UInt32) throws -> Output {
        iseqBuilder.resetLastEmission()
        try valueStack.pushLocal(localIndex, locals: &locals)
    }
    mutating func visitLocalSetOrTee(localIndex: UInt32, isTee: Bool) throws {
        preserveLocalsOnStack(localIndex)
        let type = try locals.type(of: localIndex)
        let result = localReg(localIndex)

        guard let op = try popOperand(type) else { return }

        if case .const(let slotIndex, _) = op {
            // Optimize (local.set $x (i32.const $c)) to reg:$x = 42 rather than through const slot
            let value = constantSlots.values[slotIndex]
            let is32Bit = type == .i32 || type == .f32
            if is32Bit {
                emit(.const32(Instruction.Const32Operand(value: UInt32(value.storage), result: LVReg(result))))
            } else {
                emit(.const64(Instruction.Const64Operand(value: value, result: LLVReg(result))))
            }
            return
        }

        let value = ensureOnVReg(op)
        guard try controlStack.currentFrame().reachable else { return }
        if !isTee, iseqBuilder.relinkLastInstructionResult(result) {
            // Good news, copyStack is optimized out :)
            return
        }
        emitCopyStack(from: value, to: result)
    }
    mutating func visitLocalSet(localIndex: UInt32) throws -> Output {
        try visitLocalSetOrTee(localIndex: localIndex, isTee: false)
    }
    mutating func visitLocalTee(localIndex: UInt32) throws -> Output {
        guard try controlStack.currentFrame().reachable else { return }
        try visitLocalSetOrTee(localIndex: localIndex, isTee: true)
        _ = try valueStack.pushLocal(localIndex, locals: &locals)
    }
    mutating func visitGlobalGet(globalIndex: UInt32) throws -> Output {
        let type = try module.globalType(globalIndex)
        let result = valueStack.push(type)
        guard let global = module.resolveGlobal(globalIndex) else {
            // Skip actual code emission if validation-only mode
            return
        }
        emit(.globalGet(Instruction.GlobalAndVRegOperand(reg: LLVReg(result), global: global)))
    }
    mutating func visitGlobalSet(globalIndex: UInt32) throws -> Output {
        let type = try module.globalType(globalIndex)
        guard let value = try popVRegOperand(type) else { return }
        guard let global = module.resolveGlobal(globalIndex) else {
            // Skip actual code emission if validation-only mode
            return
        }
        emit(.globalSet(Instruction.GlobalAndVRegOperand(reg: LLVReg(value), global: global)))
    }

    private mutating func pushEmit(
        _ type: ValueType,
        _ instruction: @escaping (VReg) -> Instruction
    ) {
        let register = valueStack.push(type)
        emit(instruction(register), resultRelink: { newResult in
            instruction(newResult)
        })
    }
    private mutating func popPushEmit(
        _ pop: ValueType,
        _ push: ValueType,
        _ instruction: @escaping (_ popped: VReg, _ result: VReg, ValueStack) -> Instruction
    ) throws {
        let value = try popVRegOperand(pop)
        let result = valueStack.push(push)
        if let value = value {
            emit(instruction(value, result, valueStack), resultRelink: { [valueStack] newResult in
                instruction(value, newResult, valueStack)
            })
        }
    }

    private mutating func pop3Emit(
        _ pops: (ValueType, ValueType, ValueType),
        _ instruction: (
            _ popped: (VReg, VReg, VReg),
            inout ValueStack
        ) -> Instruction
    ) throws {
        guard let pop1 = try popVRegOperand(pops.0),
              let pop2 = try popVRegOperand(pops.1),
              let pop3 = try popVRegOperand(pops.2) else { return }
        emit(instruction((pop1, pop2, pop3), &valueStack))
    }

    private mutating func pop2Emit(
        _ pops: (ValueType, ValueType),
        _ instruction: (
            _ popped: (VReg, VReg),
            inout ValueStack
        ) -> Instruction
    ) throws {
        guard let pop1 = try popVRegOperand(pops.0),
              let pop2 = try popVRegOperand(pops.1) else { return }
        emit(instruction((pop1, pop2), &valueStack))
    }

    private mutating func pop2PushEmit(
        _ pops: (ValueType, ValueType),
        _ push: ValueType,
        _ instruction: @escaping (
            _ popped: (VReg, VReg),
            _ result: VReg
        ) -> Instruction
    ) throws {
        guard let pop1 = try popVRegOperand(pops.0),
              let pop2 = try popVRegOperand(pops.1) else { return }
        let result = valueStack.push(push)
        emit(instruction((pop1, pop2), result), resultRelink: { result in
            instruction((pop1, pop2), result)
        })
    }

    private mutating func visitLoad(
        _ memarg: MemArg,
        _ type: ValueType,
        _ instruction: @escaping (Instruction.LoadOperand) -> Instruction
    ) throws {
        let isMemory64 = try module.isMemory64(memoryIndex: 0)
        let alignLog2Limit = isMemory64 ? 64 : 32
        if memarg.align >= alignLog2Limit {
            throw TranslationError("Alignment 2**\(memarg.align) is out of limit \(alignLog2Limit)")
        }
        try popPushEmit(.address(isMemory64: isMemory64), type) { value, result, stack in
            let loadOperand = Instruction.LoadOperand(
                offset: memarg.offset,
                pointer: value,
                result: result
            )
            return instruction(loadOperand)
        }
    }
    private mutating func visitStore(
        _ memarg: MemArg,
        _ type: ValueType,
        _ instruction: (Instruction.StoreOperand) -> Instruction
    ) throws {
        let isMemory64 = try module.isMemory64(memoryIndex: 0)
        let value = try popVRegOperand(type)
        let pointer = try popVRegOperand(.address(isMemory64: isMemory64))
        if let value = value, let pointer = pointer {
            let storeOperand = Instruction.StoreOperand(
                offset: memarg.offset,
                pointer: pointer,
                value: value
            )
            emit(instruction(storeOperand))
        }
    }
    mutating func visitI32Load(memarg: MemArg) throws -> Output { try visitLoad(memarg, .i32, Instruction.i32Load) }
    mutating func visitI64Load(memarg: MemArg) throws -> Output { try visitLoad(memarg, .i64, Instruction.i64Load) }
    mutating func visitF32Load(memarg: MemArg) throws -> Output { try visitLoad(memarg, .f32, Instruction.f32Load) }
    mutating func visitF64Load(memarg: MemArg) throws -> Output { try visitLoad(memarg, .f64, Instruction.f64Load) }
    mutating func visitI32Load8S(memarg: MemArg) throws -> Output { try visitLoad(memarg, .i32, Instruction.i32Load8S) }
    mutating func visitI32Load8U(memarg: MemArg) throws -> Output { try visitLoad(memarg, .i32, Instruction.i32Load8U) }
    mutating func visitI32Load16S(memarg: MemArg) throws -> Output { try visitLoad(memarg, .i32, Instruction.i32Load16S) }
    mutating func visitI32Load16U(memarg: MemArg) throws -> Output { try visitLoad(memarg, .i32, Instruction.i32Load16U) }
    mutating func visitI64Load8S(memarg: MemArg) throws -> Output { try visitLoad(memarg, .i64, Instruction.i64Load8S) }
    mutating func visitI64Load8U(memarg: MemArg) throws -> Output { try visitLoad(memarg, .i64, Instruction.i64Load8U) }
    mutating func visitI64Load16S(memarg: MemArg) throws -> Output { try visitLoad(memarg, .i64, Instruction.i64Load16S) }
    mutating func visitI64Load16U(memarg: MemArg) throws -> Output { try visitLoad(memarg, .i64, Instruction.i64Load16U) }
    mutating func visitI64Load32S(memarg: MemArg) throws -> Output { try visitLoad(memarg, .i64, Instruction.i64Load32S) }
    mutating func visitI64Load32U(memarg: MemArg) throws -> Output { try visitLoad(memarg, .i64, Instruction.i64Load32U) }
    mutating func visitI32Store(memarg: MemArg) throws -> Output { try visitStore(memarg, .i32, Instruction.i32Store) }
    mutating func visitI64Store(memarg: MemArg) throws -> Output { try visitStore(memarg, .i64, Instruction.i64Store) }
    mutating func visitF32Store(memarg: MemArg) throws -> Output { try visitStore(memarg, .f32, Instruction.f32Store) }
    mutating func visitF64Store(memarg: MemArg) throws -> Output { try visitStore(memarg, .f64, Instruction.f64Store) }
    mutating func visitI32Store8(memarg: MemArg) throws -> Output { try visitStore(memarg, .i32, Instruction.i32Store8) }
    mutating func visitI32Store16(memarg: MemArg) throws -> Output { try visitStore(memarg, .i32, Instruction.i32Store16) }
    mutating func visitI64Store8(memarg: MemArg) throws -> Output { try visitStore(memarg, .i64, Instruction.i64Store8) }
    mutating func visitI64Store16(memarg: MemArg) throws -> Output { try visitStore(memarg, .i64, Instruction.i64Store16) }
    mutating func visitI64Store32(memarg: MemArg) throws -> Output { try visitStore(memarg, .i64, Instruction.i64Store32) }
    mutating func visitMemorySize(memory: UInt32) throws -> Output {
        let sizeType: ValueType = try module.isMemory64(memoryIndex: memory) ? .i64 : .i32
        pushEmit(sizeType, { .memorySize(Instruction.MemorySizeOperand(memoryIndex: memory, result: LVReg($0))) })
    }
    mutating func visitMemoryGrow(memory: UInt32) throws -> Output {
        let isMemory64 = try module.isMemory64(memoryIndex: memory)
        let sizeType = ValueType.address(isMemory64: isMemory64)
        // Just pop/push the same type (i64 or i32) value
        try popPushEmit(sizeType, sizeType) { value, result, stack in
            .memoryGrow(Instruction.MemoryGrowOperand(
                result: result, delta: value, memory: memory
            ))
        }
    }

    private mutating func visitConst(_ type: ValueType, _ value: Value) {
        if let constSlotIndex = constantSlots.allocate(value) {
            valueStack.pushConst(constSlotIndex, type: type)
            iseqBuilder.resetLastEmission()
            return
        }
        let value = UntypedValue(value)
        let is32Bit = type == .i32 || type == .f32
        if is32Bit {
            pushEmit(type, {
                .const32(Instruction.Const32Operand(value: UInt32(value.storage), result: LVReg($0)))
            })
        } else {
            pushEmit(type, { .const64(Instruction.Const64Operand(value: value, result: LLVReg($0))) })
        }
    }
    mutating func visitI32Const(value: Int32) -> Output { visitConst(.i32, .i32(UInt32(bitPattern: value))) }
    mutating func visitI64Const(value: Int64) -> Output { visitConst(.i64, .i64(UInt64(bitPattern: value))) }
    mutating func visitF32Const(value: IEEE754.Float32) -> Output { visitConst(.f32, .f32(value.bitPattern)) }
    mutating func visitF64Const(value: IEEE754.Float64) -> Output { visitConst(.f64, .f64(value.bitPattern)) }
    mutating func visitRefNull(type: WasmTypes.ReferenceType) -> Output {
        pushEmit(.ref(type), { .refNull(Instruction.RefNullOperand(result: $0, type: type)) })
    }
    mutating func visitRefIsNull() throws -> Output {
        let value = try valueStack.popRef()
        let result = valueStack.push(.i32)
        emit(.refIsNull(Instruction.RefIsNullOperand(value: LVReg(ensureOnVReg(value)), result: LVReg(result))))
    }
    mutating func visitRefFunc(functionIndex: UInt32) throws -> Output {
        try self.module.validateFunctionIndex(functionIndex)
        pushEmit(.ref(.funcRef), { .refFunc(Instruction.RefFuncOperand(index: functionIndex, result: LVReg($0))) })
    }

    private mutating func visitUnary(_ operand: ValueType, _ instruction: @escaping (Instruction.UnaryOperand) -> Instruction) throws {
        try popPushEmit(operand, operand) { value, result, stack in
            return instruction(Instruction.UnaryOperand(result: LVReg(result), input: LVReg(value)))
        }
    }
    private mutating func visitBinary(
        _ operand: ValueType,
        _ result: ValueType,
        _ instruction: @escaping (Instruction.BinaryOperand) -> Instruction
    ) throws {
        let rhs = try popVRegOperand(operand)
        let lhs = try popVRegOperand(operand)
        let result = valueStack.push(result)
        guard let lhs = lhs, let rhs = rhs else { return }
        emit(
            instruction(Instruction.BinaryOperand(result: LVReg(result), lhs: lhs, rhs: rhs)),
            resultRelink: { result in
                return instruction(Instruction.BinaryOperand(result: LVReg(result), lhs: lhs, rhs: rhs))
            }
        )
    }
    private mutating func visitCmp(_ operand: ValueType, _ instruction: @escaping (Instruction.BinaryOperand) -> Instruction) throws {
        try visitBinary(operand, .i32, instruction)
    }
    private mutating func visitConversion(_ from: ValueType, _ to: ValueType, _ instruction: @escaping (Instruction.UnaryOperand) -> Instruction) throws {
        try popPushEmit(from, to) { value, result, stack in
            return instruction(Instruction.UnaryOperand(result: LVReg(result), input: LVReg(value)))
        }
    }
    mutating func visitI32Eqz() throws -> Output {
        try popPushEmit(.i32, .i32) { value, result, stack in
                .i32Eqz(Instruction.UnaryOperand(result: LVReg(result), input: LVReg(value)))
        }
    }
    mutating func visitI32Eq() throws -> Output { try visitCmp(.i32, Instruction.i32Eq) }
    mutating func visitI32Ne() throws -> Output { try visitCmp(.i32, Instruction.i32Ne) }
    mutating func visitI32LtS() throws -> Output { try visitCmp(.i32, Instruction.i32LtS) }
    mutating func visitI32LtU() throws -> Output { try visitCmp(.i32, Instruction.i32LtU) }
    mutating func visitI32GtS() throws -> Output { try visitCmp(.i32, Instruction.i32GtS) }
    mutating func visitI32GtU() throws -> Output { try visitCmp(.i32, Instruction.i32GtU) }
    mutating func visitI32LeS() throws -> Output { try visitCmp(.i32, Instruction.i32LeS) }
    mutating func visitI32LeU() throws -> Output { try visitCmp(.i32, Instruction.i32LeU) }
    mutating func visitI32GeS() throws -> Output { try visitCmp(.i32, Instruction.i32GeS) }
    mutating func visitI32GeU() throws -> Output { try visitCmp(.i32, Instruction.i32GeU) }
    mutating func visitI64Eqz() throws -> Output {
        try popPushEmit(.i64, .i32) { value, result, stack in
                .i64Eqz(Instruction.UnaryOperand(result: LVReg(result), input: LVReg(value)))
        }
    }
    mutating func visitI64Eq() throws -> Output { try visitCmp(.i64, Instruction.i64Eq) }
    mutating func visitI64Ne() throws -> Output { try visitCmp(.i64, Instruction.i64Ne) }
    mutating func visitI64LtS() throws -> Output { try visitCmp(.i64, Instruction.i64LtS) }
    mutating func visitI64LtU() throws -> Output { try visitCmp(.i64, Instruction.i64LtU) }
    mutating func visitI64GtS() throws -> Output { try visitCmp(.i64, Instruction.i64GtS) }
    mutating func visitI64GtU() throws -> Output { try visitCmp(.i64, Instruction.i64GtU) }
    mutating func visitI64LeS() throws -> Output { try visitCmp(.i64, Instruction.i64LeS) }
    mutating func visitI64LeU() throws -> Output { try visitCmp(.i64, Instruction.i64LeU) }
    mutating func visitI64GeS() throws -> Output { try visitCmp(.i64, Instruction.i64GeS) }
    mutating func visitI64GeU() throws -> Output { try visitCmp(.i64, Instruction.i64GeU) }
    mutating func visitF32Eq() throws -> Output { try visitCmp(.f32, Instruction.f32Eq) }
    mutating func visitF32Ne() throws -> Output { try visitCmp(.f32, Instruction.f32Ne) }
    mutating func visitF32Lt() throws -> Output { try visitCmp(.f32, Instruction.f32Lt) }
    mutating func visitF32Gt() throws -> Output { try visitCmp(.f32, Instruction.f32Gt) }
    mutating func visitF32Le() throws -> Output { try visitCmp(.f32, Instruction.f32Le) }
    mutating func visitF32Ge() throws -> Output { try visitCmp(.f32, Instruction.f32Ge) }
    mutating func visitF64Eq() throws -> Output { try visitCmp(.f64, Instruction.f64Eq) }
    mutating func visitF64Ne() throws -> Output { try visitCmp(.f64, Instruction.f64Ne) }
    mutating func visitF64Lt() throws -> Output { try visitCmp(.f64, Instruction.f64Lt) }
    mutating func visitF64Gt() throws -> Output { try visitCmp(.f64, Instruction.f64Gt) }
    mutating func visitF64Le() throws -> Output { try visitCmp(.f64, Instruction.f64Le) }
    mutating func visitF64Ge() throws -> Output { try visitCmp(.f64, Instruction.f64Ge) }
    mutating func visitI32Clz() throws -> Output { try visitUnary(.i32, Instruction.i32Clz) }
    mutating func visitI32Ctz() throws -> Output { try visitUnary(.i32, Instruction.i32Ctz) }
    mutating func visitI32Popcnt() throws -> Output { try visitUnary(.i32, Instruction.i32Popcnt) }
    mutating func visitI32Add() throws -> Output { try visitBinary(.i32, .i32, Instruction.i32Add) }
    mutating func visitI32Sub() throws -> Output { try visitBinary(.i32, .i32, Instruction.i32Sub) }
    mutating func visitI32Mul() throws -> Output { try visitBinary(.i32, .i32, Instruction.i32Mul) }
    mutating func visitI32DivS() throws -> Output { try visitBinary(.i32, .i32, Instruction.i32DivS) }
    mutating func visitI32DivU() throws -> Output { try visitBinary(.i32, .i32, Instruction.i32DivU) }
    mutating func visitI32RemS() throws -> Output { try visitBinary(.i32, .i32, Instruction.i32RemS) }
    mutating func visitI32RemU() throws -> Output { try visitBinary(.i32, .i32, Instruction.i32RemU) }
    mutating func visitI32And() throws -> Output { try visitBinary(.i32, .i32, Instruction.i32And) }
    mutating func visitI32Or() throws -> Output { try visitBinary(.i32, .i32, Instruction.i32Or) }
    mutating func visitI32Xor() throws -> Output { try visitBinary(.i32, .i32, Instruction.i32Xor) }
    mutating func visitI32Shl() throws -> Output { try visitBinary(.i32, .i32, Instruction.i32Shl) }
    mutating func visitI32ShrS() throws -> Output { try visitBinary(.i32, .i32, Instruction.i32ShrS) }
    mutating func visitI32ShrU() throws -> Output { try visitBinary(.i32, .i32, Instruction.i32ShrU) }
    mutating func visitI32Rotl() throws -> Output { try visitBinary(.i32, .i32, Instruction.i32Rotl) }
    mutating func visitI32Rotr() throws -> Output { try visitBinary(.i32, .i32, Instruction.i32Rotr) }
    mutating func visitI64Clz() throws -> Output { try visitUnary(.i64, Instruction.i64Clz) }
    mutating func visitI64Ctz() throws -> Output { try visitUnary(.i64, Instruction.i64Ctz) }
    mutating func visitI64Popcnt() throws -> Output { try visitUnary(.i64, Instruction.i64Popcnt) }
    mutating func visitI64Add() throws -> Output { try visitBinary(.i64, .i64, Instruction.i64Add) }
    mutating func visitI64Sub() throws -> Output { try visitBinary(.i64, .i64, Instruction.i64Sub) }
    mutating func visitI64Mul() throws -> Output { try visitBinary(.i64, .i64, Instruction.i64Mul) }
    mutating func visitI64DivS() throws -> Output { try visitBinary(.i64, .i64, Instruction.i64DivS) }
    mutating func visitI64DivU() throws -> Output { try visitBinary(.i64, .i64, Instruction.i64DivU) }
    mutating func visitI64RemS() throws -> Output { try visitBinary(.i64, .i64, Instruction.i64RemS) }
    mutating func visitI64RemU() throws -> Output { try visitBinary(.i64, .i64, Instruction.i64RemU) }
    mutating func visitI64And() throws -> Output { try visitBinary(.i64, .i64, Instruction.i64And) }
    mutating func visitI64Or() throws -> Output { try visitBinary(.i64, .i64, Instruction.i64Or) }
    mutating func visitI64Xor() throws -> Output { try visitBinary(.i64, .i64, Instruction.i64Xor) }
    mutating func visitI64Shl() throws -> Output { try visitBinary(.i64, .i64, Instruction.i64Shl) }
    mutating func visitI64ShrS() throws -> Output { try visitBinary(.i64, .i64, Instruction.i64ShrS) }
    mutating func visitI64ShrU() throws -> Output { try visitBinary(.i64, .i64, Instruction.i64ShrU) }
    mutating func visitI64Rotl() throws -> Output { try visitBinary(.i64, .i64, Instruction.i64Rotl) }
    mutating func visitI64Rotr() throws -> Output { try visitBinary(.i64, .i64, Instruction.i64Rotr) }
    mutating func visitF32Abs() throws -> Output { try visitUnary(.f32, Instruction.f32Abs) }
    mutating func visitF32Neg() throws -> Output { try visitUnary(.f32, Instruction.f32Neg) }
    mutating func visitF32Ceil() throws -> Output { try visitUnary(.f32, Instruction.f32Ceil) }
    mutating func visitF32Floor() throws -> Output { try visitUnary(.f32, Instruction.f32Floor) }
    mutating func visitF32Trunc() throws -> Output { try visitUnary(.f32, Instruction.f32Trunc) }
    mutating func visitF32Nearest() throws -> Output { try visitUnary(.f32, Instruction.f32Nearest) }
    mutating func visitF32Sqrt() throws -> Output { try visitUnary(.f32, Instruction.f32Sqrt) }
    mutating func visitF32Add() throws -> Output { try visitBinary(.f32, .f32, Instruction.f32Add) }
    mutating func visitF32Sub() throws -> Output { try visitBinary(.f32, .f32, Instruction.f32Sub) }
    mutating func visitF32Mul() throws -> Output { try visitBinary(.f32, .f32, Instruction.f32Mul) }
    mutating func visitF32Div() throws -> Output { try visitBinary(.f32, .f32, Instruction.f32Div) }
    mutating func visitF32Min() throws -> Output { try visitBinary(.f32, .f32, Instruction.f32Min) }
    mutating func visitF32Max() throws -> Output { try visitBinary(.f32, .f32, Instruction.f32Max) }
    mutating func visitF32Copysign() throws -> Output { try visitBinary(.f32, .f32, Instruction.f32CopySign) }
    mutating func visitF64Abs() throws -> Output { try visitUnary(.f64, Instruction.f64Abs) }
    mutating func visitF64Neg() throws -> Output { try visitUnary(.f64, Instruction.f64Neg) }
    mutating func visitF64Ceil() throws -> Output { try visitUnary(.f64, Instruction.f64Ceil) }
    mutating func visitF64Floor() throws -> Output { try visitUnary(.f64, Instruction.f64Floor) }
    mutating func visitF64Trunc() throws -> Output { try visitUnary(.f64, Instruction.f64Trunc) }
    mutating func visitF64Nearest() throws -> Output { try visitUnary(.f64, Instruction.f64Nearest) }
    mutating func visitF64Sqrt() throws -> Output { try visitUnary(.f64, Instruction.f64Sqrt) }
    mutating func visitF64Add() throws -> Output { try visitBinary(.f64, .f64, Instruction.f64Add) }
    mutating func visitF64Sub() throws -> Output { try visitBinary(.f64, .f64, Instruction.f64Sub) }
    mutating func visitF64Mul() throws -> Output { try visitBinary(.f64, .f64, Instruction.f64Mul) }
    mutating func visitF64Div() throws -> Output { try visitBinary(.f64, .f64, Instruction.f64Div) }
    mutating func visitF64Min() throws -> Output { try visitBinary(.f64, .f64, Instruction.f64Min) }
    mutating func visitF64Max() throws -> Output { try visitBinary(.f64, .f64, Instruction.f64Max) }
    mutating func visitF64Copysign() throws -> Output { try visitBinary(.f64, .f64, Instruction.f64CopySign) }
    mutating func visitI32WrapI64() throws -> Output { try visitConversion(.i64, .i32, Instruction.i32WrapI64) }
    mutating func visitI32TruncF32S() throws -> Output { try visitConversion(.f32, .i32, Instruction.i32TruncF32S) }
    mutating func visitI32TruncF32U() throws -> Output { try visitConversion(.f32, .i32, Instruction.i32TruncF32U) }
    mutating func visitI32TruncF64S() throws -> Output { try visitConversion(.f64, .i32, Instruction.i32TruncF64S) }
    mutating func visitI32TruncF64U() throws -> Output { try visitConversion(.f64, .i32, Instruction.i32TruncF64U) }
    mutating func visitI64ExtendI32S() throws -> Output { try visitConversion(.i32, .i64, Instruction.i64ExtendI32S) }
    mutating func visitI64ExtendI32U() throws -> Output { try visitConversion(.i32, .i64, Instruction.i64ExtendI32U) }
    mutating func visitI64TruncF32S() throws -> Output { try visitConversion(.f32, .i64, Instruction.i64TruncF32S) }
    mutating func visitI64TruncF32U() throws -> Output { try visitConversion(.f32, .i64, Instruction.i64TruncF32U) }
    mutating func visitI64TruncF64S() throws -> Output { try visitConversion(.f64, .i64, Instruction.i64TruncF64S) }
    mutating func visitI64TruncF64U() throws -> Output { try visitConversion(.f64, .i64, Instruction.i64TruncF64U) }
    mutating func visitF32ConvertI32S() throws -> Output { try visitConversion(.i32, .f32, Instruction.f32ConvertI32S) }
    mutating func visitF32ConvertI32U() throws -> Output { try visitConversion(.i32, .f32, Instruction.f32ConvertI32U) }
    mutating func visitF32ConvertI64S() throws -> Output { try visitConversion(.i64, .f32, Instruction.f32ConvertI64S) }
    mutating func visitF32ConvertI64U() throws -> Output { try visitConversion(.i64, .f32, Instruction.f32ConvertI64U) }
    mutating func visitF32DemoteF64() throws -> Output { try visitConversion(.f64, .f32, Instruction.f32DemoteF64) }
    mutating func visitF64ConvertI32S() throws -> Output { try visitConversion(.i32, .f64, Instruction.f64ConvertI32S) }
    mutating func visitF64ConvertI32U() throws -> Output { try visitConversion(.i32, .f64, Instruction.f64ConvertI32U) }
    mutating func visitF64ConvertI64S() throws -> Output { try visitConversion(.i64, .f64, Instruction.f64ConvertI64S) }
    mutating func visitF64ConvertI64U() throws -> Output { try visitConversion(.i64, .f64, Instruction.f64ConvertI64U) }
    mutating func visitF64PromoteF32() throws -> Output { try visitConversion(.f32, .f64, Instruction.f64PromoteF32) }
    mutating func visitI32ReinterpretF32() throws -> Output { try visitConversion(.f32, .i32, Instruction.i32ReinterpretF32) }
    mutating func visitI64ReinterpretF64() throws -> Output { try visitConversion(.f64, .i64, Instruction.i64ReinterpretF64) }
    mutating func visitF32ReinterpretI32() throws -> Output { try visitConversion(.i32, .f32, Instruction.f32ReinterpretI32) }
    mutating func visitF64ReinterpretI64() throws -> Output { try visitConversion(.i64, .f64, Instruction.f64ReinterpretI64) }
    mutating func visitI32Extend8S() throws -> Output { try visitUnary(.i32, Instruction.i32Extend8S) }
    mutating func visitI32Extend16S() throws -> Output { try visitUnary(.i32, Instruction.i32Extend16S) }
    mutating func visitI64Extend8S() throws -> Output { try visitUnary(.i64, Instruction.i64Extend8S) }
    mutating func visitI64Extend16S() throws -> Output { try visitUnary(.i64, Instruction.i64Extend16S) }
    mutating func visitI64Extend32S() throws -> Output { try visitUnary(.i64, Instruction.i64Extend32S) }
    mutating func visitMemoryInit(dataIndex: UInt32) throws -> Output {
        try self.module.validateDataSegment(dataIndex)
        let addressType = try module.addressType(memoryIndex: 0)
        try pop3Emit((.i32, .i32, addressType)) { values, stack in
            let (size, sourceOffset, destOffset) = values
            return .memoryInit(
                Instruction.MemoryInitOperand(
                    segmentIndex: dataIndex,
                    destOffset: destOffset,
                    sourceOffset: sourceOffset,
                    size: size
                )
            )
        }
    }
    mutating func visitDataDrop(dataIndex: UInt32) throws -> Output {
        try self.module.validateDataSegment(dataIndex)
        emit(.memoryDataDrop(Instruction.MemoryDataDropOperand(segmentIndex: dataIndex)))
    }
    mutating func visitMemoryCopy(dstMem: UInt32, srcMem: UInt32) throws -> Output {
        //     C.mems[0] = it limits
        // -----------------------------
        // C ⊦ memory.fill : [it i32 it] → []
        // https://github.com/WebAssembly/memory64/blob/main/proposals/memory64/Overview.md
        let addressType = try module.addressType(memoryIndex: 0)
        try pop3Emit((addressType, addressType, addressType)) { values, stack in
            let (size, sourceOffset, destOffset) = values
            return .memoryCopy(
                Instruction.MemoryCopyOperand(
                    destOffset: destOffset,
                    sourceOffset: sourceOffset,
                    size: LVReg(size)
                )
            )
        }
    }
    mutating func visitMemoryFill(memory: UInt32) throws -> Output {
        //     C.mems[0] = it limits
        // -----------------------------
        // C ⊦ memory.fill : [it i32 it] → []
        // https://github.com/WebAssembly/memory64/blob/main/proposals/memory64/Overview.md
        let addressType = try module.addressType(memoryIndex: 0)
        try pop3Emit((addressType, .i32, addressType)) { values, stack in
            let (size, value, destOffset) = values
            return .memoryFill(
                Instruction.MemoryFillOperand(
                    destOffset: destOffset,
                    value: value,
                    size: LVReg(size)
                )
            )
        }
    }
    mutating func visitTableInit(elemIndex: UInt32, table: UInt32) throws -> Output {
        try self.module.validateElementSegment(elemIndex)
        try pop3Emit((.i32, .i32, module.addressType(tableIndex: table))) { values, stack in
            let (size, sourceOffset, destOffset) = values
            return .tableInit(
                Instruction.TableInitOperand(
                    tableIndex: table,
                    segmentIndex: elemIndex,
                    destOffset: destOffset,
                    sourceOffset: sourceOffset,
                    size: size
                )
            )
        }
    }
    mutating func visitElemDrop(elemIndex: UInt32) throws -> Output {
        try self.module.validateElementSegment(elemIndex)
        emit(.tableElementDrop(Instruction.TableElementDropOperand(index: elemIndex)))
    }
    mutating func visitTableCopy(dstTable: UInt32, srcTable: UInt32) throws -> Output {
        //   C.tables[d] = iN limits t   C.tables[s] = iM limits t    K = min {N, M}
        // -----------------------------------------------------------------------------
        // C ⊦ table.copy d s : [iN iM iK] → []
        // https://github.com/WebAssembly/memory64/blob/main/proposals/memory64/Overview.md
        let destIsMemory64 = try module.isMemory64(tableIndex: dstTable)
        let sourceIsMemory64 = try module.isMemory64(tableIndex: srcTable)
        let lengthIsMemory64 = destIsMemory64 || sourceIsMemory64
        try pop3Emit(
            (
                .address(isMemory64: lengthIsMemory64),
                .address(isMemory64: sourceIsMemory64),
                .address(isMemory64: destIsMemory64)
            )
        ) { values, stack in
            let (size, sourceOffset, destOffset) = values
            return .tableCopy(
                Instruction.TableCopyOperand(
                    sourceIndex: srcTable,
                    destIndex: dstTable,
                    destOffset: destOffset,
                    sourceOffset: sourceOffset,
                    size: size
                )
            )
        }
    }
    mutating func visitTableFill(table: UInt32) throws -> Output {
        let address = try module.addressType(tableIndex: table)
        try pop3Emit((address, .ref(module.elementType(table)), address)) { values, stack in
            let (size, value, destOffset) = values
            return .tableFill(
                Instruction.TableFillOperand(
                    tableIndex: table,
                    destOffset: destOffset,
                    value: value,
                    size: size
                )
            )
        }
    }
    mutating func visitTableGet(table: UInt32) throws -> Output {
        try popPushEmit(
            module.addressType(tableIndex: table),
            .ref(module.elementType(table))
        ) { index, result, stack in
            return .tableGet(
                Instruction.TableGetOperand(
                    index: index,
                    result: result,
                    tableIndex: table
                )
            )
        }
    }
    mutating func visitTableSet(table: UInt32) throws -> Output {
        try pop2Emit((.ref(module.elementType(table)), module.addressType(tableIndex: table))) { values, stack in
            let (value, index) = values
            return .tableSet(
                Instruction.TableSetOperand(
                    index: index,
                    value: value,
                    tableIndex: table
                )
            )
        }
    }
    mutating func visitTableGrow(table: UInt32) throws -> Output {
        let address = try module.addressType(tableIndex: table)
        try pop2PushEmit((address, .ref(module.elementType(table))), address) { values, result in
            let (delta, value) = values
            return .tableGrow(
                Instruction.TableGrowOperand(
                    tableIndex: table,
                    result: result,
                    delta: delta,
                    value: value
                )
            )
        }
    }
    mutating func visitTableSize(table: UInt32) throws -> Output {
        pushEmit(try module.addressType(tableIndex: table)) { result in
            return .tableSize(Instruction.TableSizeOperand(tableIndex: table, result: LVReg(result)))
        }
    }
    mutating func visitI32TruncSatF32S() throws -> Output { try visitConversion(.f32, .i32, Instruction.i32TruncSatF32S) }
    mutating func visitI32TruncSatF32U() throws -> Output { try visitConversion(.f32, .i32, Instruction.i32TruncSatF32U) }
    mutating func visitI32TruncSatF64S() throws -> Output { try visitConversion(.f64, .i32, Instruction.i32TruncSatF64S) }
    mutating func visitI32TruncSatF64U() throws -> Output { try visitConversion(.f64, .i32, Instruction.i32TruncSatF64U) }
    mutating func visitI64TruncSatF32S() throws -> Output { try visitConversion(.f32, .i64, Instruction.i64TruncSatF32S) }
    mutating func visitI64TruncSatF32U() throws -> Output { try visitConversion(.f32, .i64, Instruction.i64TruncSatF32U) }
    mutating func visitI64TruncSatF64S() throws -> Output { try visitConversion(.f64, .i64, Instruction.i64TruncSatF64S) }
    mutating func visitI64TruncSatF64U() throws -> Output { try visitConversion(.f64, .i64, Instruction.i64TruncSatF64U) }
}

struct TranslationError: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}

extension FunctionType {
    fileprivate init(blockType: WasmParser.BlockType, typeSection: [FunctionType]) throws {
        switch blockType {
        case .type(let valueType):
            self.init(parameters: [], results: [valueType])
        case .empty:
            self.init(parameters: [], results: [])
        case let .funcType(typeIndex):
            let typeIndex = Int(typeIndex)
            guard typeIndex < typeSection.count else {
                throw WasmParserError.invalidTypeSectionReference
            }
            let funcType = typeSection[typeIndex]
            self.init(
                parameters: funcType.parameters,
                results: funcType.results
            )
        }
    }
}

extension ValueType {
    fileprivate static func address(isMemory64: Bool) -> ValueType {
        return isMemory64 ? .i64 : .i32
    }
}

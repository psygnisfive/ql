/**
 * Provides a class for handling variables in the data flow analysis.
 */

import cpp
private import semmle.code.cpp.controlflow.SSA
private import semmle.code.cpp.dataflow.internal.SubBasicBlocks

/**
 * A conceptual variable that is assigned only once, like an SSA variable. This
 * class is used for tracking data flow through variables, where the desired
 * semantics is sometimes different from what the SSA library provides. Unlike
 * SSA, there are no _phi_ nodes; instead, each `VariableAccess` may be
 * associated with more than one `FlowVar`.
 *
 * Each instance of this class corresponds to a modification or an initial
 * value of a variable. A `FlowVar` has exactly one result for either
 * `definedByExpr` or `definedByInitialValue`. The documentation on those two
 * member predicates explains how a `FlowVar` relates to syntactic constructs of
 * the language.
 */
cached
class FlowVar extends TFlowVar {
  /**
   * Gets a `VariableAccess` that _may_ take its value from `this`. Consider
   * the following snippet.
   *
   * ```
   * int x = 0;
   * if (b) { f(x); x = 1; }
   * g(x)
   * ```
   *
   * The access to `x` in `f(x)` may take its value from the `FlowVar`
   * corresponding to `int x = 0`, while the access to `x` in `g(x)` may take
   * its value from the `FlowVar` corresponding to `int x = 0` or the `FlowVar`
   * corresponding to `x = 1`. The `x` in `x = 1` is not considered to be an
   * access.
   */
  cached
  abstract VariableAccess getAnAccess();

  /**
   * Holds if this `FlowVar` corresponds to a modification occurring when `node` is
   * evaluated, receiving a value best described by `e`. The following is an
   * exhaustive list of cases where this may happen.
   *
   * - `node` is an `Initializer` and `e` is its contained expression.
   * - `node` is an `AssignExpr`, and `e` is its right-hand side.
   * - `node` is an `AssignOperation`, and `e` is `node`.
   * - `node` is a `CrementOperation`, and `e` is `node`. The case where
   *   `node instanceof PostCrementOperation` is an exception to the rule that
   *   `this` contains the value of `e` after the evaluation of `node`.
   */
  cached
  abstract predicate definedByExpr(Expr e, ControlFlowNode node);

  /**
   * Holds if this `FlowVar` corresponds to the data written by a call that
   * passes a variable as argument `arg`.
   */
  cached
  abstract predicate definedByReference(Expr arg);

  cached
  abstract predicate definedPartiallyAt(Expr e);

  /**
   * Holds if this `FlowVar` corresponds to the initial value of `v`. The following
   * is an exhaustive list of cases where this may happen.
   *
   * - `v` is a parameter, and `this` contains the value of the parameter at
   *   the entry point of its function body.
   * - `v` is an uninitialized local variable, and `v` contains its (arbitrary)
   *   value before it is reassigned. If it can be statically determined that a
   *   local variable is always overwritten before it is used, there is no
   *   `FlowVar` instance for the uninitialized value of that variable.
   */
  cached
  abstract predicate definedByInitialValue(LocalScopeVariable v);

  /** Gets a textual representation of this element. */
  cached
  abstract string toString();

  /** Gets the location of this element. */
  cached
  abstract Location getLocation();
}

/**
 * Provides classes and predicates dealing with "partial definitions".
 *
 * In contrast to a normal "definition", which provides a new value for
 * something, a partial definition is an expression that may affect a
 * value, but does not necessarily replace it entirely. For example:
 * ```
 * x.y = 1; // a partial definition of the object `x`.
 * x.y.z = 1; // a partial definition of the objects `x` and `x.y`.
 * x.setY(1); // a partial definition of the object `x`.
 * setY(&x); // a partial definition of the object `x`.
 * ```
 */
private module PartialDefinitions {
  private newtype TPartialDefinition =
    TExplicitFieldStoreQualifier(Expr qualifier, ControlFlowNode node) {
      exists(FieldAccess fa | qualifier = fa.getQualifier() |
        isInstanceFieldWrite(fa, node)
        or
        exists(PartialDefinition pd |
          node = pd.getSubBasicBlockStart() and
          fa = pd.getDefinedExpr()
        )
      )
    } or
    TExplicitCallQualifier(Expr qualifier) {
      exists(Call call |
        qualifier = call.getQualifier() and
        not call.getTarget().hasSpecifier("const")
      )
    } or
    TReferenceArgument(Expr arg, VariableAccess va) { referenceArgument(va, arg) }

  private predicate isInstanceFieldWrite(FieldAccess fa, ControlFlowNode node) {
    not fa.getTarget().isStatic() and
    assignmentLikeOperation(node, fa.getTarget(), fa, _)
  }

  class PartialDefinition extends TPartialDefinition {
    Expr definedExpr;
    ControlFlowNode node;

    PartialDefinition() {
      this = TExplicitFieldStoreQualifier(definedExpr, node)
      or
      this = TExplicitCallQualifier(definedExpr) and node = definedExpr
      or
      this = TReferenceArgument(definedExpr, node)
    }

    predicate partiallyDefines(Variable v) { definedExpr = v.getAnAccess() }

    predicate partiallyDefinesThis(ThisExpr e) { definedExpr = e }

    /**
     * Gets the subBasicBlock where this `PartialDefinition` is defined.
     */
    ControlFlowNode getSubBasicBlockStart() { result = node }

    /**
     * Gets the expression that is being partially defined. For example in the
     * following code:
     * ```
     * x.y = 1;
     * ```
     * The expression `x` is being partially defined.
     */
    Expr getDefinedExpr() { result = definedExpr }

    Location getLocation() {
      not exists(definedExpr.getLocation()) and result = definedExpr.getParent().getLocation()
      or
      definedExpr.getLocation() instanceof UnknownLocation and
      result = definedExpr.getParent().getLocation()
      or
      result = definedExpr.getLocation() and not result instanceof UnknownLocation
    }

    string toString() { result = "partial def of " + definedExpr }
  }

  /**
   * A partial definition that's a definition by reference.
   */
  class DefinitionByReference extends PartialDefinition, TReferenceArgument {
    VariableAccess va;

    DefinitionByReference() {
      // `this` is not restricted in this charpred. That's because the full
      // extent of this class includes the charpred of the superclass, which
      // relates `this` to `definedExpr`, and `va` is functionally determined
      // by `definedExpr`.
      referenceArgument(va, definedExpr)
    }

    VariableAccess getVariableAccess() { result = va }

    override predicate partiallyDefines(Variable v) { va = v.getAnAccess() }
  }

  private predicate referenceArgument(VariableAccess va, Expr argument) {
    argument = any(Call c).getAnArgument() and
    exists(Type argumentType |
      argumentType = argument.getFullyConverted().getType().stripTopLevelSpecifiers()
    |
      argumentType instanceof ReferenceType and
      not argumentType.(ReferenceType).getBaseType().isConst() and
      va = argument
      or
      argumentType instanceof PointerType and
      not argumentType.(PointerType).getBaseType().isConst() and
      (
        // f(variable)
        va = argument
        or
        // f(&variable)
        va = argument.(AddressOfExpr).getOperand()
        or
        // f(&array[0])
        va.getType().getUnspecifiedType() instanceof ArrayType and
        va = argument.(AddressOfExpr).getOperand().(ArrayExpr).getArrayBase()
      )
    )
  }
}

import PartialDefinitions
private import FlowVar_internal

/**
 * Provides classes and predicates that ought to be private but cannot use the
 * `private` annotation because they may be referred to by unit tests.
 */
module FlowVar_internal {
  /**
   * For various reasons, not all variables handled perfectly by the SSA library.
   * Ideally, this predicate should become larger as the SSA library improves.
   * Before we can remove the `BlockVar` class completely, the SSA library needs
   * the following improvements.
   * - Considering uninitialized local variables to be definitions.
   * - Supporting fields, globals and statics like the Java SSA library does.
   * - Supporting all local variables, even if their address is taken by
   *   address-of, reference assignments, or lambdas.
   * - Understanding that assignment to a field of a local struct is a
   *   definition of the struct but not a complete overwrite. This is what the
   *   IR library uses chi nodes for.
   */
  predicate fullySupportedSsaVariable(Variable v) {
    v = any(SsaDefinition def).getAVariable() and
    // A partially-defined variable is handled using the partial definitions logic.
    not any(PartialDefinition p).partiallyDefines(v) and
    // SSA variables do not exist before their first assignment, but one
    // feature of this data flow library is to track where uninitialized data
    // ends up.
    not mayBeUsedUninitialized(v, _) and
    // If `v` may be a variable that is always overwritten in a loop that
    // always executes at least once, we give it special treatment in
    // `BlockVar`, somewhat analogous to unrolling the first iteration of the
    // loop.
    not exists(AlwaysTrueUponEntryLoop loop | loop.alwaysAssignsBeforeLeavingCondition(_, _, v)) and
    // The SSA library has a theoretically accurate treatment of reference types,
    // treating them as immutable, but for data flow it gives better results in
    // practice to make the variable synonymous with its contents.
    not v.getUnspecifiedType() instanceof ReferenceType
  }

  /**
   * Holds if `sbb` is the `SubBasicBlock` where `v` receives its initial value.
   * See the documentation for `FlowVar.definedByInitialValue`.
   */
  predicate blockVarDefinedByVariable(SubBasicBlock sbb, LocalScopeVariable v) {
    sbb = v.(Parameter).getFunction().getEntryPoint()
    or
    exists(DeclStmt declStmt |
      declStmt.getDeclaration(_) = v.(LocalVariable) and
      sbb.contains(declStmt) and
      mayBeUsedUninitialized(v, _)
    )
  }

  newtype TFlowVar =
    TSsaVar(SsaDefinition def, LocalScopeVariable v) {
      fullySupportedSsaVariable(v) and
      v = def.getAVariable()
    } or
    TBlockVar(SubBasicBlock sbb, Variable v) {
      not fullySupportedSsaVariable(v) and
      not v instanceof Field and // Fields are interprocedural data flow, not local
      reachable(sbb) and
      (
        initializer(v, sbb.getANode())
        or
        assignmentLikeOperation(sbb, v, _, _)
        or
        sbb = any(PartialDefinition p | p.partiallyDefines(v)).getSubBasicBlockStart()
        or
        blockVarDefinedByVariable(sbb, v)
      )
    }

  /**
   * A variable whose analysis is backed by the SSA library.
   */
  class SsaVar extends TSsaVar, FlowVar {
    SsaDefinition def;
    LocalScopeVariable v;

    SsaVar() { this = TSsaVar(def, v) }

    override VariableAccess getAnAccess() {
      // There is no need to know about direct accesses to phi nodes because
      // the data flow library will never see those, and the `FlowVar` library
      // is only meant to be used by the data flow library.
      this.isNonPhi() and
      (
        // This base case could be included in the transitive case by changing
        // `+` to `*`, but that's slower because it goes through the `TSsaVar`
        // indirection.
        result = def.getAUse(v)
        or
        exists(SsaDefinition descendentDef |
          getASuccessorSsaVar+() = TSsaVar(descendentDef, _) and
          result = descendentDef.getAUse(v)
        )
      )
      or
      parameterUsedInConstructorFieldInit(v, result) and
      def.definedByParameter(v)
    }

    override predicate definedByExpr(Expr e, ControlFlowNode node) {
      e = def.getDefiningValue(v) and
      (
        if def.getDefinition() = v.getInitializer().getExpr()
        then node = v.getInitializer()
        else node = def.getDefinition()
      )
    }

    override predicate definedByReference(Expr arg) {
      none() // Not supported for SSA. See `fullySupportedSsaVariable`.
    }

    override predicate definedPartiallyAt(Expr e) { none() }

    override predicate definedByInitialValue(LocalScopeVariable param) {
      def.definedByParameter(param) and
      param = v
    }

    /**
     * Holds if this `SsaVar` corresponds to a non-phi definition. Users of this
     * library will never directly use an `SsaVar` that comes from a phi node,
     * so such values are purely for implementation use.
     */
    private predicate isNonPhi() {
      // This implementation is positively phrased in terms of these two helper
      // predicates because it performs better than phrasing it negatively in
      // terms of `def.isPhiNode`.
      this.definedByExpr(_, _)
      or
      this.definedByInitialValue(_)
    }

    /**
     * Holds if `result` might have the same value as `this` because `result` is
     * a phi node with `this` as input.
     */
    private SsaVar getASuccessorSsaVar() {
      exists(SsaDefinition succDef |
        result = TSsaVar(succDef, v) and
        def = succDef.getAPhiInput(v)
      )
    }

    override string toString() { result = def.toString(v) }

    override Location getLocation() { result = def.getLocation() }
  }

  /**
   * A variable whose analysis is backed by a simple control flow analysis that
   * does not perform as well as the SSA library but gives better results for
   * data flow purposes in some cases.
   */
  class BlockVar extends TBlockVar, FlowVar {
    SubBasicBlock sbb;
    Variable v;

    BlockVar() { this = TBlockVar(sbb, v) }

    override VariableAccess getAnAccess() {
      variableAccessInSBB(v, getAReachedBlockVarSBB(this), result) and
      result != sbb
      or
      parameterUsedInConstructorFieldInit(v, result) and
      sbb = v.(Parameter).getFunction().getEntryPoint()
    }

    override predicate definedByInitialValue(LocalScopeVariable lsv) {
      blockVarDefinedByVariable(sbb, lsv) and
      lsv = v
    }

    override predicate definedByExpr(Expr e, ControlFlowNode node) {
      assignmentLikeOperation(node, v, _, e) and
      node = sbb
      or
      // We pick the defining `ControlFlowNode` of an `Initializer` to be its
      // expression rather than the `Initializer` itself. That's because the
      // `Initializer` of a `ConditionDeclExpr` is for historical reasons not
      // part of the CFG and therefore ends up in the wrong basic block.
      initializer(v, e) and
      node = e and
      node = sbb.getANode()
    }

    override predicate definedByReference(Expr arg) {
      exists(DefinitionByReference def |
        def.partiallyDefines(v) and
        sbb = def.getSubBasicBlockStart() and
        arg = def.getDefinedExpr()
      )
    }

    override predicate definedPartiallyAt(Expr e) {
      exists(PartialDefinition p |
        p.partiallyDefines(v) and
        sbb = p.getSubBasicBlockStart() and
        e = p.getDefinedExpr()
      )
    }

    override string toString() {
      exists(Expr e |
        this.definedByExpr(e, _) and
        result = "assignment to " + v
      )
      or
      this.definedByInitialValue(_) and
      result = "initial value of " + v
      or
      exists(Expr arg |
        this.definedByReference(arg) and
        result = "definition by reference of " + v
      )
      or
      exists(Expr partialDef |
        this.definedPartiallyAt(partialDef) and
        result = "partial definition at " + partialDef
      )
      or
      // impossible case
      not this.definedByExpr(_, _) and
      not this.definedByInitialValue(_) and
      not this.definedByReference(_) and
      not this.definedPartiallyAt(_) and
      result = "undefined " + v
    }

    override Location getLocation() { result = sbb.getStart().getLocation() }
  }

  /** Type-specialized version of `getEnclosingElement`. */
  private ControlFlowNode getCFNParent(ControlFlowNode node) { result = node.getEnclosingElement() }

  /**
   * A for-loop or while-loop whose condition is always true upon entry but not
   * always true after the first iteration.
   */
  class AlwaysTrueUponEntryLoop extends Stmt {
    AlwaysTrueUponEntryLoop() {
      this.(WhileStmt).conditionAlwaysTrueUponEntry() and
      not this.(WhileStmt).conditionAlwaysTrue()
      or
      this.(ForStmt).conditionAlwaysTrueUponEntry() and
      not this.(ForStmt).conditionAlwaysTrue()
    }

    /**
     * Holds if this loop always assigns to `v` before leaving through an edge
     * from `bbInside` in its condition to `bbOutside` outside the loop. Also,
     * `v` must be used outside the loop.
     */
    predicate alwaysAssignsBeforeLeavingCondition(
      BasicBlock bbInside, BasicBlock bbOutside, Variable v
    ) {
      v = this.getARelevantVariable() and
      this.bbInLoopCondition(bbInside) and
      not this.bbInLoop(bbOutside) and
      bbOutside = bbInside.getASuccessor() and
      not reachesWithoutAssignment(bbInside, v)
    }

    /**
     * Gets a variable that is assigned in this loop and read outside the loop.
     */
    private Variable getARelevantVariable() {
      result = this.getAVariableAssignedInLoop() and
      exists(VariableAccess va |
        va.getTarget() = result and
        readAccess(va) and
        bbNotInLoop(va.getBasicBlock())
      )
    }

    /** Gets a variable that is assigned in this loop. */
    pragma[noinline]
    private Variable getAVariableAssignedInLoop() {
      exists(BasicBlock bbAssign |
        assignmentLikeOperation(bbAssign.getANode(), result, _, _) and
        this.bbInLoop(bbAssign)
      )
    }

    private predicate bbInLoopCondition(BasicBlock bb) {
      getCFNParent*(bb.getANode()) = this.(Loop).getCondition()
    }

    private predicate bbInLoop(BasicBlock bb) {
      bbDominates(this.(Loop).getStmt(), bb)
      or
      bbInLoopCondition(bb)
    }

    predicate bbNotInLoop(BasicBlock bb) {
      not this.bbInLoop(bb) and
      bb.getEnclosingFunction() = this.getEnclosingFunction()
    }

    /**
     * Holds if `bb` is a basic block inside this loop where `v` has not been
     * overwritten at the end of `bb`.
     */
    private predicate reachesWithoutAssignment(BasicBlock bb, Variable v) {
      (
        // For the type of loop we are interested in, the body is always a
        // basic block.
        bb = this.(Loop).getStmt() and
        v = this.getARelevantVariable()
        or
        reachesWithoutAssignment(bb.getAPredecessor(), v) and
        this.bbInLoop(bb)
      ) and
      not assignmentLikeOperation(bb.getANode(), v, _, _)
    }
  }

  /**
   * Holds if some loop always assigns to `v` before leaving through an edge
   * from `bbInside` in its condition to `bbOutside` outside the loop, where
   * (`sbbDef`, `v`) is a `BlockVar` defined outside the loop. Also, `v` must
   * be used outside the loop.
   */
  predicate skipLoop(
    SubBasicBlock sbbInside, SubBasicBlock sbbOutside, SubBasicBlock sbbDef, Variable v
  ) {
    exists(AlwaysTrueUponEntryLoop loop, BasicBlock bbInside, BasicBlock bbOutside |
      loop.alwaysAssignsBeforeLeavingCondition(bbInside, bbOutside, v) and
      bbInside = sbbInside.getBasicBlock() and
      bbOutside = sbbOutside.getBasicBlock() and
      sbbInside.lastInBB() and
      sbbOutside.firstInBB() and
      loop.bbNotInLoop(sbbDef.getBasicBlock()) and
      exists(TBlockVar(sbbDef, v))
    )
  }

  // The noopt is needed to avoid getting `variableLiveInSBB` joined in before
  // `getASuccessor`.
  pragma[noopt]
  private SubBasicBlock getAReachedBlockVarSBB(TBlockVar start) {
    exists(Variable v |
      start = TBlockVar(result, v) and
      variableLiveInSBB(result, v) and
      not largeVariable(v, _, _)
    )
    or
    exists(SubBasicBlock mid, SubBasicBlock sbbDef, Variable v |
      mid = getAReachedBlockVarSBB(start) and
      start = TBlockVar(sbbDef, v) and
      result = mid.getASuccessor() and
      variableLiveInSBB(result, v) and
      not skipLoop(mid, result, sbbDef, v) and
      not assignmentLikeOperation(result, v, _, _)
    )
  }

  /**
   * Holds if `v` may have too many combinations of definitions and reached
   * blocks for us the feasibly compute its def-use relation.
   */
  private predicate largeVariable(Variable v, int liveBlocks, int defs) {
    liveBlocks = strictcount(SubBasicBlock sbb | variableLiveInSBB(sbb, v)) and
    defs = strictcount(SubBasicBlock sbb | exists(TBlockVar(sbb, v))) and
    liveBlocks * defs > 1000000
  }

  /**
   * Holds if a value held in `v` at the start of `sbb` (or after the first
   * assignment, if that assignment is to `v`) might later be read.
   */
  private predicate variableLiveInSBB(SubBasicBlock sbb, Variable v) {
    variableAccessInSBB(v, sbb, _)
    or
    exists(SubBasicBlock succ | succ = sbb.getASuccessor() |
      variableLiveInSBB(succ, v) and
      not variableNotLiveBefore(succ, v)
    )
  }

  /**
   * Holds if liveness of `v` should stop propagating backwards from `sbb`.
   */
  private predicate variableNotLiveBefore(SubBasicBlock sbb, Variable v) {
    assignmentLikeOperation(sbb, v, _, _)
    or
    // Liveness of `v` is killed when going backwards from a block that declares it
    exists(DeclStmt ds | ds.getADeclaration().(LocalVariable) = v and sbb.contains(ds))
  }

  /** Holds if `va` is a read access to `v` in `sbb`, where `v` is modeled by `BlockVar`. */
  pragma[noinline]
  private predicate variableAccessInSBB(Variable v, SubBasicBlock sbb, VariableAccess va) {
    exists(TBlockVar(_, v)) and
    va.getTarget() = v and
    va = sbb.getANode() and
    not overwrite(va, _)
  }

  /**
   * A local variable that is uninitialized immediately after its declaration.
   */
  class UninitializedLocalVariable extends LocalVariable {
    UninitializedLocalVariable() {
      not this.hasInitializer() and
      not this.isStatic()
    }
  }

  /** Holds if `va` may be an uninitialized access to `v`. */
  predicate mayBeUsedUninitialized(UninitializedLocalVariable v, VariableAccess va) {
    exists(BasicBlock bb, int vaIndex |
      va.getTarget() = v and
      readAccess(va) and
      va = bb.getNode(vaIndex) and
      notAccessedAtStartOfBB(v, bb) and
      (
        vaIndex < indexOfFirstOverwriteInBB(v, bb)
        or
        not exists(indexOfFirstOverwriteInBB(v, bb))
      )
    )
  }

  /**
   * Holds if `v` has not been accessed at the start of `bb`, for a variable
   * `v` where `allReadsDominatedByOverwrite(v)` does not hold.
   */
  predicate notAccessedAtStartOfBB(UninitializedLocalVariable v, BasicBlock bb) {
    // Start from a BB containing an uninitialized variable
    bb.getANode().(DeclStmt).getDeclaration(_) = v and
    // Only consider variables for which initialization before reading cannot
    // be proved by simpler means. This predicate is expensive in time and
    // space, whereas `allReadsDominatedByOverwrite` is cheap.
    not allReadsDominatedByOverwrite(v)
    or
    exists(BasicBlock pred |
      pred = bb.getAPredecessor() and
      notAccessedAtStartOfBB(v, pred) and
      // Stop searching when `v` is accessed.
      not pred.getANode() = v.getAnAccess()
    )
  }

  /**
   * Holds if all read accesses of `v` are dominated by an overwrite of `v`.
   */
  predicate allReadsDominatedByOverwrite(UninitializedLocalVariable v) {
    forall(VariableAccess va |
      va.getTarget() = v and
      readAccess(va)
    |
      dominatedByOverwrite(v, va)
    )
  }

  /** Holds if `va` accesses `v` and is dominated by an overwrite of `v`. */
  predicate dominatedByOverwrite(UninitializedLocalVariable v, VariableAccess va) {
    exists(BasicBlock bb, int vaIndex |
      va = bb.getNode(vaIndex) and
      va.getTarget() = v
    |
      vaIndex > indexOfFirstOverwriteInBB(v, bb)
      or
      bbStrictlyDominates(getAnOverwritingBB(v), bb)
    )
  }

  /** Gets a basic block in which `v` is overwritten. */
  BasicBlock getAnOverwritingBB(UninitializedLocalVariable v) {
    exists(indexOfFirstOverwriteInBB(v, result))
  }

  int indexOfFirstOverwriteInBB(LocalVariable v, BasicBlock bb) {
    result = min(int i | overwrite(v.getAnAccess(), bb.getNode(i)))
  }

  /**
   * Holds if the value of the variable accessed at `va` may affect the execution
   * of the program.
   */
  predicate readAccess(VariableAccess va) {
    reachable(va) and
    not overwrite(va, _) and
    not va = any(SizeofExprOperator so).getAChild+() and
    not va = any(AlignofExprOperator ao).getAChild+()
  }

  /**
   * Holds if the value of the variable accessed at `va` is completely
   * overwritten at `node`, where `va` is uniquely determined by `node`.
   */
  predicate overwrite(VariableAccess va, ControlFlowNode node) {
    va = node.(AssignExpr).getLValue()
  }

  /**
   * Holds if `v` is modified through `va` as a side effect of evaluating
   * `node`, receiving a value best described by `assignedExpr`.
   * Assignment-like operations are those that desugar to a non-overloaded `=`
   * assignment: `=`, `+=`, `++`, `--`, etc.
   *
   * This corresponds to `FlowVar::definedByExpr`, except that the case where
   * `node instanceof Initializer` is covered by `initializer` instead of this
   * predicate.
   */
  predicate assignmentLikeOperation(
    ControlFlowNode node, Variable v, VariableAccess va, Expr assignedExpr
  ) {
    // Together, the two following cases cover `Assignment`
    node = any(AssignExpr ae |
        va = ae.getLValue() and
        v = va.getTarget() and
        assignedExpr = ae.getRValue()
      )
    or
    node = any(AssignOperation ao |
        va = ao.getLValue() and
        v = va.getTarget() and
        // Here and in the `PrefixCrementOperation` case, we say that the assigned
        // expression is the operation itself. For example, we say that `x += 1`
        // assigns `x += 1` to `x`. The justification is that after this operation,
        // `x` will contain the same value that `x += 1` evaluated to.
        assignedExpr = ao
      )
    or
    // This case does not add further data flow paths, except if a
    // `PrefixCrementOperation` is itself a source
    node = any(CrementOperation op |
        va = op.getOperand() and
        v = va.getTarget() and
        assignedExpr = op
      )
  }

  /**
   * Holds if `v` is initialized to have value `assignedExpr`.
   */
  predicate initializer(LocalVariable v, Expr assignedExpr) {
    assignedExpr = v.getInitializer().getExpr()
  }

  /**
   * Holds if `p` is a parameter to a constructor that is used in a
   * `ConstructorFieldInit` at `va`. This ignores the corner case that `p`
   * might have been overwritten to have a different value before this happens.
   */
  predicate parameterUsedInConstructorFieldInit(Parameter p, VariableAccess va) {
    exists(Constructor constructor |
      constructor.getInitializer(_).(ConstructorFieldInit).getExpr().getAChild*() = va and
      va = p.getAnAccess()
      // We don't require that `constructor` has `p` as a parameter because
      // that follows from the two other conditions and would likely just
      // confuse the join orderer.
    )
  }

  /**
   * A point in a basic block where a non-SSA variable may have a different value
   * than it did elsewhere in the same basic block. Extending this class
   * configures the `SubBasicBlocks` library as needed for the implementation of
   * this library.
   */
  class DataFlowSubBasicBlockCutNode extends SubBasicBlockCutNode {
    DataFlowSubBasicBlockCutNode() {
      exists(Variable v | not fullySupportedSsaVariable(v) |
        assignmentLikeOperation(this, v, _, _)
        or
        this = any(PartialDefinition p | p.partiallyDefines(v)).getSubBasicBlockStart()
        // It is not necessary to cut the basic blocks at `Initializer` nodes
        // because the affected variable can have no _other_ value before its
        // initializer. It is not necessary to cut basic blocks at procedure
        // entries for the sake of `Parameter`s since we are already guaranteed
        // to have a `SubBasicBlock` starting at procedure entry.
      )
    }
  }
}
/* module FlowVar_internal */

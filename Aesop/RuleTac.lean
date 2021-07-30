/-
Copyright (c) 2021 Jannis Limperg. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Authors: Jannis Limperg
-/

import Aesop.Util
import Lean

open Lean
open Lean.Elab.Tactic
open Lean.Meta

namespace Aesop

structure RuleTacInput where
  goal : MVarId
  deriving Inhabited

-- Rule tactics must accurately report the following information, which is not
-- checked:
--
-- - `goals`: All unassigned metavariables produced by the tactic.
-- - `dependentGoals`: Those metavariables `g ∈ goals` such that some `h ∈
--   goals` depends on `g`. We say that `h` depends on `g` iff `g` appears in
--   the target type of `h` or in the type of one of the hypotheses of `h`.
--   TODO explain the purpose of these
structure RuleTacOutput where
  goals : Array MVarId
  dependentGoals : Array MVarId
  deriving Inhabited

-- When users want to register a tactic, they may not want to compute all the
-- information in `RuleTacOutput`. In this case, they can return a
-- `UserRuleTacOutput`, omitting some data, which Aesop then computes for them
-- (possibly inefficiently since Aesop does not know what the user tactic did).
structure UserRuleTacOutput where
  goals : Array MVarId
  dependentGoals : Option (Array MVarId) := none
  deriving Inhabited

@[inline]
def getHypMVars (goal : MVarId) : MetaM (Array MVarId) :=
  withMVarContext goal do
    let mut mvars := #[]
    for hyp in (← getLCtx) do
      mvars := mvars ++ (← getMVarsNoDelayed (mkFVar hyp.fvarId))
    return mvars

@[inline]
def getTargetMVars (goal : MVarId) : MetaM (Array MVarId) := do
  getMVarsNoDelayed (← getMVarType goal)

@[inline]
def getGoalMVars (goal : MVarId) : MetaM (Array MVarId) :=
  return (← getTargetMVars goal) ++ (← getHypMVars goal)

def dependentMVars (ms : Array MVarId) : MetaM (Array MVarId) := do
  let mvars ← ms.concatMapM getGoalMVars
  ms.filterM λ m => mvars.contains m

def UserRuleTacOutput.toRuleTacOutput (o : UserRuleTacOutput) : MetaM RuleTacOutput :=
  return {
    goals := o.goals
    dependentGoals := (← dependentMVars o.goals)
  }

abbrev RuleTac := RuleTacInput → MetaM RuleTacOutput

abbrev UserRuleTac := RuleTacInput → MetaM UserRuleTacOutput

-- A `RuleTacDescr` is a recipe for constructing a `RuleTac`. When we serialise
-- the rule set to an olean file, we serialise `RuleTacDescr`s because we can't
-- (currently?) serialise the actual tactics.
inductive RuleTacDescr
  | applyConst (decl : Name)
  | tacticMUnit (decl : Name)
  | ruleTac (decl : Name)
  | userRuleTac (decl : Name)
  deriving Inhabited, BEq

-- A `SerializableRuleTac` bundles a `RuleTacDescr` and the `RuleTac` that was
-- computed from the description. Local rules do not have descriptions since we
-- never serialise them.
structure SerializableRuleTac where
  tac : RuleTac
  descr : Option RuleTacDescr
  deriving Inhabited

namespace RuleTac

private def checkDeclType (expectedType : Expr) (decl : Name) : MetaM Unit := do
  let actualType ← (← getConstInfo decl).type
  unless (← isDefEq expectedType actualType) do
    throwError "aesop: {decl} was expected to have type{indentExpr expectedType}\nbut has type{indentExpr actualType}"

unsafe def ofTacticMUnitConstUnsafe (decl : Name) : MetaM RuleTac := do
  checkDeclType (← mkAppM ``TacticM #[mkConst ``Unit]) decl
  return λ input => do
    let tac ← evalConst (TacticM Unit) decl
      -- Note: it is in principle possible for the environment to change so that
      -- `decl` has a different type at the point where this tactic is called.
      -- We assume that this doesn't happen. Ideally, we would evaluate `tac`
      -- directly after `checkDeclType`, but this fails when
      -- `ofTacticMUnitConstUnsafe` is called by the `@[aesop]` attribute.
    let goals ← runTacticMAsMetaM tac input.goal
    let o : UserRuleTacOutput := { goals := goals.toArray }
    o.toRuleTacOutput

@[implementedBy ofTacticMUnitConstUnsafe]
constant ofTacticMUnitConst : Name → MetaM RuleTac

unsafe def ofRuleTacConstUnsafe (decl : Name) : MetaM RuleTac := do
  let type ← deltaExpand (mkConst ``RuleTac) λ n => n == ``RuleTac
  checkDeclType type decl
  return λ input => do (← evalConst RuleTac decl) input
    -- See note about `evalConst` in `ofTacticMUnitConstUnsafe`.

@[implementedBy ofRuleTacConstUnsafe]
constant ofRuleTacConst : Name → MetaM RuleTac

unsafe def ofUserRuleTacConstUnsafe (decl : Name) : MetaM RuleTac := do
  let type ← deltaExpand (mkConst ``UserRuleTac) λ n => n == ``UserRuleTac
  checkDeclType type decl
  return λ input => do
    let tac ← evalConst UserRuleTac decl
      -- See note about `evalConst` in `ofTacticMUnitConstUnsafe`.
    (← tac input).toRuleTacOutput

@[implementedBy ofUserRuleTacConstUnsafe]
constant ofUserRuleTacConst : Name → MetaM RuleTac

def applyConst (decl : Name) : RuleTac := λ input => do
  let goals ← apply input.goal (← mkConstWithFreshMVarLevels decl)
  UserRuleTacOutput.toRuleTacOutput { goals := goals.toArray }
  -- TODO optimise dependent goal analysis

def applyFVar (userName : Name) : RuleTac := λ input => do
  let decl ← getLocalDeclFromUserName userName
  let goals ← apply input.goal (mkFVar decl.fvarId)
  UserRuleTacOutput.toRuleTacOutput { goals := goals.toArray }
  -- TODO ditto

end RuleTac


namespace SerializableRuleTac

def ofTacticMUnit (decl : Name) : MetaM SerializableRuleTac :=
  return {
    tac := (← RuleTac.ofTacticMUnitConst decl),
    descr := RuleTacDescr.tacticMUnit decl
  }

def ofUserRuleTacConst (decl : Name) : MetaM SerializableRuleTac :=
  return {
    tac := (← RuleTac.ofUserRuleTacConst decl)
    descr := RuleTacDescr.userRuleTac decl
  }

def ofRuleTacConst (decl : Name) : MetaM SerializableRuleTac :=
  return {
    tac := (← RuleTac.ofRuleTacConst decl)
    descr := RuleTacDescr.ruleTac decl
  }

def ofTacticConst (decl : Name) : MetaM SerializableRuleTac :=
  ofTacticMUnit decl <|>
  ofUserRuleTacConst decl <|>
  ofRuleTacConst decl <|>
  do
    let type := (← getConstInfo decl).type
    throwError "aesop: {decl} was expected to be a tactic but it has type{indentExpr type}"

def applyConst (decl : Name) : MetaM SerializableRuleTac :=
  return {
    tac := RuleTac.applyConst decl
    descr := RuleTacDescr.applyConst decl
  }

def applyFVar (userName : Name) : MetaM SerializableRuleTac := do
  let _ ← getLocalDeclFromUserName userName
    -- This is just to check that the hypothesis exists.
  return {
    tac := RuleTac.applyFVar userName
    descr := none
  }

end SerializableRuleTac

namespace RuleTacDescr

def toRuleTac : RuleTacDescr → MetaM SerializableRuleTac
  | applyConst decl => SerializableRuleTac.applyConst decl
  | tacticMUnit decl => SerializableRuleTac.ofTacticMUnit decl
  | userRuleTac decl => SerializableRuleTac.ofUserRuleTacConst decl
  | ruleTac decl => SerializableRuleTac.ofRuleTacConst decl

end RuleTacDescr

end Aesop
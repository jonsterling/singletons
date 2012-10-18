{- Data/Singletons/Singletons.hs

(c) Richard Eisenberg 2012
eir@cis.upenn.edu

This file contains functions to refine constructs to work with singleton
types. It is an internal module to the singletons package.
-}

{-# OPTIONS_GHC -fwarn-incomplete-patterns #-}
{-# LANGUAGE TemplateHaskell #-}

module Data.Singletons.Singletons where

import Language.Haskell.TH
import Data.Singletons.Util
import Data.Singletons.Promote
import qualified Data.Map as Map
import Control.Monad
import Control.Monad.Writer
import Data.List

-- map to track bound variables
type ExpTable = Map.Map Name Exp

-- translating a type gives a type with a hole in it,
-- represented here as a function
type TypeFn = Type -> Type

-- a list of argument types extracted from a type application
type TypeContext = [Type]

singFamilyName, isSingletonName, forgettableName, comboClassName, witnessName,
  demoteName, singKindClassName, singInstanceMethName, singInstanceName,
  sEqClassName, sEqMethName, sconsName, snilName, smartSconsName,
  smartSnilName, sIfName, undefinedName :: Name
singFamilyName = mkName "Sing"
isSingletonName = mkName "SingI"
forgettableName = mkName "SingE"
comboClassName = mkName "SingRep"
witnessName = mkName "sing"
forgetName = mkName "fromSing"
demoteName = mkName "Demote"
singKindClassName = mkName "SingKind"
singInstanceMethName = mkName "singInstance"
singInstanceName = mkName "SingInstance"
sEqClassName = mkName "SEq"
sEqMethName = mkName "%==%"
sconsName = mkName "SCons"
snilName = mkName "SNil"
smartSconsName = mkName "sCons"
smartSnilName = mkName "sNil"
sIfName = mkName "sIf"
undefinedName = mkName "undefined"

mkTupleName :: Int -> Name
mkTupleName n = mkName $ "STuple" ++ (show n)

singFamily :: Type
singFamily = ConT singFamilyName

singKindConstraint :: Kind -> Pred
singKindConstraint k = ClassP singKindClassName [SigT anyType k]

singInstanceMeth :: Exp
singInstanceMeth = VarE singInstanceMethName

singInstanceTyCon :: Type
singInstanceTyCon = ConT singInstanceName

singInstanceDataCon :: Exp
singInstanceDataCon = ConE singInstanceName

singInstancePat :: Pat
singInstancePat = ConP singInstanceName []

demote :: Type
demote = ConT demoteName

anyType :: Type
anyType = ConT anyTypeName

singDataConName :: Name -> Name
singDataConName nm = case nameBase nm of
  "[]" -> snilName
  ":"  -> sconsName
  tuple | isTupleString tuple -> mkTupleName (tupleDegree tuple)
  _ -> prefixUCName "S" ":%" nm

singTyConName :: Name -> Name
singTyConName name | nameBase name == "[]" = mkName "SList"
                   | isTupleName name = mkTupleName (tupleDegree $ nameBase name)
                   | otherwise        = prefixUCName "S" ":%" name

singDataCon :: Name -> Exp
singDataCon = ConE . singDataConName

smartConName :: Name -> Name
smartConName = locase . singDataConName

smartCon :: Name -> Exp
smartCon = VarE . smartConName

singValName :: Name -> Name
singValName n
  | nameBase n == "undefined" = undefinedName
  | otherwise                 = (prefixLCName "s" "%") $ upcase n

singVal :: Name -> Exp
singVal = VarE . singValName

-- generate singleton definitions from an ADT
genSingletons :: [Name] -> Q [Dec]
genSingletons names = do
  checkForRep names
  infos <- mapM reifyWithWarning names
  decls <- mapM singInfo infos
  return $ concat decls

singInfo :: Info -> Q [Dec]
singInfo (ClassI dec instances) =
  fail "Singling of class info not supported"
singInfo (ClassOpI name ty className fixity) =
  fail "Singling of class members info not supported"
singInfo (TyConI dec) = singDec dec
singInfo (FamilyI dec instances) =
  fail "Singling of type family info not yet supported" -- KindFams
singInfo (PrimTyConI name numArgs unlifted) =
  fail "Singling of primitive type constructors not supported"
singInfo (DataConI name ty tyname fixity) =
  fail $ "Singling of individual constructors not supported; " ++
         "single the type instead"
singInfo (VarI name ty mdec fixity) =
  fail "Singling of value info not supported"
singInfo (TyVarI name ty) =
  fail "Singling of type variable info not supported"

-- refine a constructor. the first parameter is the type variable that
-- the singleton GADT is parameterized by
-- runs in the QWithDecs monad because auxiliary declarations are produced
singCtor :: Type -> Con -> QWithDecs Con 
singCtor a = ctorCases
  (\name types -> do
    let sName = singDataConName name
        sCon = singDataCon name
        pCon = promoteDataCon name
    indexNames <- lift $ replicateM (length types) (newName "n")
    let indices = map VarT indexNames
    kinds <- lift $ mapM promoteType types
    args <- lift $ buildArgTypes types indices
    let tvbs = zipWith KindedTV indexNames kinds
        bareKindVars = filter isVarK kinds

    -- SingI instance
    addElement $ InstanceD ((map singKindConstraint bareKindVars) ++
                            (map (ClassP comboClassName . return) indices))
                           (AppT (ConT isSingletonName)
                                 (foldType pCon (zipWith SigT indices kinds)))
                           [ValD (VarP witnessName)
                                 (NormalB $ foldExp sCon (replicate (length types)
                                                           (VarE witnessName)))
                                 []]

    -- smart constructor type signature
    smartConType <- lift $ conTypesToFunType indexNames args kinds
                                      (AppT singFamily (foldType pCon indices))
    addElement $ SigD (smartConName name) smartConType
     
    -- smart constructor
    let vars = map VarE indexNames
        smartConBody = mkSingInstances vars (foldExp (singDataCon name) vars)
    addElement $ FunD (smartConName name)
                      [Clause (map VarP indexNames)
                        (NormalB smartConBody)
                        []]

    return $ ForallC tvbs
                     ((EqualP a (foldType (promoteDataCon name) indices)) :
                       (map (ClassP comboClassName . return) indices) ++
                       (map singKindConstraint bareKindVars))
                     (NormalC sName $ map (\ty -> (NotStrict,ty)) args))
  (\tvbs cxt ctor -> case cxt of
    _:_ -> fail "Singling of constrained constructors not yet supported"
    [] -> singCtor a ctor)
  where buildArgTypes :: [Type] -> [Type] -> Q [Type]
        buildArgTypes types indices = do
          typeFns <- mapM (singType False) types
          return $ zipWith id typeFns indices

        conTypesToFunType :: [Name] -> [Type] -> [Kind] -> Type -> Q Type
        conTypesToFunType [] [] [] ret = return ret
        conTypesToFunType (nm : nmtail) (ty : tytail) (k : ktail) ret = do
          rhs <- conTypesToFunType nmtail tytail ktail ret    
          let innerty = AppT (AppT ArrowT ty) rhs
          return $ ForallT [KindedTV nm k]
                           (if isVarK k then [singKindConstraint k] else [])
                           innerty
        conTypesToFunType _ _ _ _ =
          fail "Internal error in conTypesToFunType"

        mkSingInstances :: [Exp] -> Exp -> Exp
        mkSingInstances [] exp = exp
        mkSingInstances (var:tail) exp =
          CaseE (AppE singInstanceMeth var)
                [Match singInstancePat (NormalB $ mkSingInstances tail exp) []]

-- refine the declarations given
singletons :: Q [Dec] -> Q [Dec]
singletons qdec = do
  decls <- qdec
  singDecs decls

singDecs :: [Dec] -> Q [Dec]
singDecs decls = do
  (promDecls, badNames) <- promoteDecs decls
  -- need to remove the bad names returned from promoteDecs
  newDecls <- mapM singDec
                   (filter (\dec ->
                     not $ or (map (\f -> f dec)
                              (map containsName badNames))) decls)
  return $ decls ++ promDecls ++ (concat newDecls)

singDec :: Dec -> Q [Dec]
singDec (FunD name clauses) = do
  let sName = singValName name
      vars = Map.singleton name (VarE sName)
  liftM return $ funD sName (map (singClause vars) clauses)
singDec (ValD _ (GuardedB _) _) =
  fail "Singling of definitions of values with a pattern guard not yet supported"
singDec (ValD _ _ (_:_)) =
  fail "Singling of definitions of values with a <<where>> clause not yet supported"
singDec (ValD pat (NormalB exp) []) = do
  (sPat, vartbl) <- evalForPair $ singPat TopLevel pat
  sExp <- singExp vartbl exp
  return [ValD sPat (NormalB sExp) []]
singDec (DataD (_:_) _ _ _ _) =
  fail "Singling of constrained datatypes not supported"
singDec (DataD cxt name tvbs ctors derivings) =
  singDataD False cxt name tvbs ctors derivings
singDec (NewtypeD cxt name tvbs ctor derivings) =
  singDataD False cxt name tvbs [ctor] derivings
singDec (TySynD name tvbs ty) =
  fail "Singling of type synonyms not yet supported"
singDec (ClassD cxt name tvbs fundeps decs) =
  fail "Singling of class declaration not yet supported"
singDec (InstanceD cxt ty decs) =
  fail "Singling of class instance not yet supported"
singDec (SigD name ty) = do
  tyTrans <- singType True ty
  return [SigD (singValName name) (tyTrans (promoteVal name))]
singDec (ForeignD fgn) =
  let name = extractName fgn in do
    reportWarning $ "Singling of foreign functions not supported -- " ++
                    (show name) ++ " ignored"
    return []
  where extractName :: Foreign -> Name
        extractName (ImportF _ _ _ n _) = n
        extractName (ExportF _ _ n _) = n
singDec (InfixD fixity name)
  | isUpcase name = return [InfixD fixity (singDataConName name)]
  | otherwise     = return [InfixD fixity (singValName name)]
singDec (PragmaD prag) = do
    reportWarning "Singling of pragmas not supported"
    return []
singDec (FamilyD flavour name tvbs mkind) =
  fail "Singling of type and data families not yet supported"
singDec (DataInstD cxt name tys ctors derivings) = 
  fail "Singling of data instances not yet supported"
singDec (NewtypeInstD cxt name tys ctor derivings) =
  fail "Singling of newtype instances not yet supported"
singDec (TySynInstD name tys ty) =
  fail "Singling of type family instances not yet supported"

-- the first parameter is True when we're refining the special case "Rep"
-- and false otherwise. We wish to consider the promotion of "Rep" to be *
-- not a promoted data constructor.
singDataD :: Bool -> Cxt -> Name -> [TyVarBndr] -> [Con] -> [Name] -> Q [Dec]
singDataD rep cxt name tvbs ctors derivings = do
  aName <- newName "a"
  let a = VarT aName
  let tvbNames = map extractTvbName tvbs
  k <- promoteType (foldType (ConT name) (map VarT tvbNames))
  (ctors', ctorInstDecls) <- evalForPair $ mapM (singCtor a) ctors
  
  -- instance for SingKind
  let singKindInst =
        InstanceD []
                  (AppT (ConT singKindClassName)
                        (SigT anyType k))
                  [FunD singInstanceMethName
                        (map mkSingInstanceClause ctors')]
  
  -- SEq instance
  let ctorPairs = [ (c1, c2) | c1 <- ctors', c2 <- ctors' ]
  sEqMethClauses <- mapM mkEqMethClause ctorPairs
  let sEqInst =
        InstanceD (map (\k -> ClassP sEqClassName [SigT anyType k])
                       (getBareKinds ctors'))
                  (AppT (ConT sEqClassName)
                        (SigT anyType k))
                  [FunD sEqMethName sEqMethClauses]
  
  -- e.g. type SNat (a :: Nat) = Sing a
  let kindedSynInst =
        TySynD (singTyConName name)
               [KindedTV aName k]
               (AppT singFamily a)

  -- SingE instance
  forgetClauses <- mapM mkForgetClause ctors
  let singEInst =
        InstanceD []
                  (AppT (ConT forgettableName) (SigT a k))
                  [TySynInstD demoteName [a]
                     (foldType (ConT name)
                        (map (\kv -> AppT demote (SigT anyType (VarT kv)))
                             tvbNames)),
                   FunD forgetName
                        forgetClauses]

  return $ (if (any (\n -> (nameBase n) == "Eq") derivings)
            then (sEqInst :)
            else id) $
             (DataInstD [] singFamilyName [SigT a k] ctors' []) :
             singEInst :
             kindedSynInst :
             singKindInst :
             ctorInstDecls
  where mkSingInstanceClause :: Con -> Clause
        mkSingInstanceClause = ctor1Case
          (\nm tys ->
            Clause [ConP nm (replicate (length tys) WildP)]
                   (NormalB singInstanceDataCon) [])

        mkEqMethClause :: (Con, Con) -> Q Clause
        mkEqMethClause (c1, c2) =
          if c1 == c2
          then do
            let (name, numArgs) = extractNameArgs c1
            lnames <- replicateM numArgs (newName "a")
            rnames <- replicateM numArgs (newName "b")
            let lpats = map VarP lnames
                rpats = map VarP rnames
                lvars = map VarE lnames
                rvars = map VarE rnames
            return $ Clause
              [ConP name lpats, ConP name rpats]
              (NormalB $
                allExp (zipWith (\l r -> foldExp (VarE sEqMethName) [l, r])
                                lvars rvars))
              []
          else do
            let (lname, lNumArgs) = extractNameArgs c1
                (rname, rNumArgs) = extractNameArgs c2
            return $ Clause
              [ConP lname (replicate lNumArgs WildP),
               ConP rname (replicate rNumArgs WildP)]
              (NormalB (singDataCon falseName))
              []

        mkForgetClause :: Con -> Q Clause
        mkForgetClause c = do
          let (name, numArgs) = extractNameArgs c
          varNames <- replicateM numArgs (newName "a")
          return $ Clause [ConP (singDataConName name) (map VarP varNames)]
                          (NormalB $ foldExp
                             (ConE $ (if rep then reinterpret else id) name)
                             (map (AppE (VarE forgetName) . VarE) varNames))
                          []

        getBareKinds :: [Con] -> [Kind]
        getBareKinds = foldl (\res -> ctorCases
          (\_ _ -> res) -- must be a constant constructor
          (\tvbs _ _ -> union res (filter isVarK $ map extractTvbKind tvbs)))
          []

        allExp :: [Exp] -> Exp
        allExp [] = singDataCon trueName
        allExp [one] = one
        allExp (h:t) = AppE (AppE (singVal andName) h) (allExp t)

singKind :: Kind -> Q (Kind -> Kind)
singKind (ForallT _ _ _) =
  fail "Singling of explicitly quantified kinds not yet supported"
singKind (VarT _) = fail "Singling of kind variables not yet supported"
singKind (ConT _) = fail "Singling of named kinds not yet supported"
singKind (TupleT _) = fail "Singling of tuple kinds not yet supported"
singKind (UnboxedTupleT _) = fail "Unboxed tuple used as kind"
singKind ArrowT = fail "Singling of unsaturated arrow kinds not yet supported"
singKind ListT = fail "Singling of list kinds not yet supported"
singKind (AppT (AppT ArrowT k1) k2) = do
  k1fn <- singKind k1
  k2fn <- singKind k2
  k <- newName "k"
  return $ \f -> AppT (AppT ArrowT (k1fn (VarT k))) (k2fn (AppT f (VarT k)))
singKind (AppT _ _) = fail "Singling of kind applications not yet supported"
singKind (SigT _ _) =
  fail "Singling of explicitly annotated kinds not yet supported"
singKind (LitT _) = fail "Type literal used as kind"
singKind (PromotedT _) = fail "Promoted data constructor used as kind"
singKind (PromotedTupleT _) = fail "Promoted tuple used as kind"
singKind PromotedNilT = fail "Promoted nil used as kind"
singKind PromotedConsT = fail "Promoted cons used as kind"
singKind StarT = return $ \k -> AppT (AppT ArrowT k) StarT
singKind ConstraintT = fail "Singling of constraint kinds not yet supported"

-- the first parameter is whether or not this type occurs in a positive position
singType :: Bool -> Type -> Q TypeFn
singType = singTypeRec []

-- the first parameter is the list of types the current type is applied to
-- the second parameter is whether or not this type occurs in a positive position
singTypeRec :: TypeContext -> Bool -> Type -> Q TypeFn
singTypeRec ctx pos (ForallT tvbs (_:_) ty) =
  fail "Singling of constrained functions not yet supported"
singTypeRec (_:_) pos (ForallT _ _ _) =
  fail "I thought this was impossible in Haskell. Email me at eir@cis.upenn.edu with your code if you see this message."
singTypeRec [] pos (ForallT _ [] ty) = -- Sing makes handling foralls automatic
  singTypeRec [] pos ty
singTypeRec (_:_) pos (VarT _) =
  fail "Singling of type variables of arrow kinds not yet supported"
singTypeRec [] pos (VarT name) = 
  return $ \ty -> AppT singFamily ty
singTypeRec ctx pos (ConT name) = -- we don't need to process the context with Sing
  return $ \ty -> AppT singFamily ty
singTypeRec ctx pos (TupleT n) = -- just like ConT
  return $ \ty -> AppT singFamily ty
singTypeRec ctx pos (UnboxedTupleT n) =
  fail "Singling of unboxed tuple types not yet supported"
singTypeRec ctx pos ArrowT = case ctx of
  [ty1, ty2] -> do
    t <- newName "t"
    sty1 <- singTypeRec [] (not pos) ty1
    sty2 <- singTypeRec [] pos ty2
    k1 <- promoteType ty1
    -- need a SingKind constraint on all kind variables that appear
    -- outside of any kind constructor in a negative position (to the
    -- left of an odd number of arrows)
    let polykinds = extractPolyKinds (not pos) k1
    return (\f -> ForallT [KindedTV t k1]
                          (map (\k -> ClassP singKindClassName [SigT anyType k]) polykinds)
                          (AppT (AppT ArrowT (sty1 (VarT t)))
                                (sty2 (AppT f (VarT t)))))
    where extractPolyKinds :: Bool -> Kind -> [Kind]
          extractPolyKinds pos (AppT (AppT ArrowT k1) k2) =
            (extractPolyKinds (not pos) k1) ++ (extractPolyKinds pos k2)
          extractPolyKinds False (VarT k) = [VarT k]
          extractPolyKinds _ _ = []
  _ -> fail "Internal error in Sing: converting ArrowT with improper context"
singTypeRec ctx pos ListT =
  return $ \ty -> AppT singFamily ty
singTypeRec ctx pos (AppT ty1 ty2) =
  singTypeRec (ty2 : ctx) pos ty1 -- recur with the ty2 in the applied context
singTypeRec ctx pos (SigT ty knd) =
  fail "Singling of types with explicit kinds not yet supported"
singTypeRec ctx pos (LitT t) = return $ \ty -> AppT singFamily ty
singTypeRec ctx pos (PromotedT _) =
  fail "Singling of promoted data constructors not yet supported"
singTypeRec ctx pos (PromotedTupleT _) =
  fail "Singling of type-level tuples not yet supported"
singTypeRec ctx pos PromotedNilT = fail "Singling of promoted nil not yet supported"
singTypeRec ctx pos PromotedConsT = fail "Singling of type-level cons not yet supported"
singTypeRec ctx pos StarT = fail "* used as type"
singTypeRec ctx pos ConstraintT = fail "Constraint used as type"

singClause :: ExpTable -> Clause -> Q Clause
singClause vars (Clause pats (NormalB exp) []) = do
  (sPats, vartbl) <- evalForPair $ mapM (singPat Parameter) pats
  let vars' = Map.union vartbl vars
  sBody <- normalB $ singExp vars' exp
  return $ Clause sPats sBody []
singClause _ (Clause _ (GuardedB _) _) =
  fail "Singling of guarded patterns not yet supported"
singClause _ (Clause _ _ (_:_)) =
  fail "Singling of <<where>> declarations not yet supported"

type ExpsQ = QWithAux ExpTable

-- we need to know where a pattern is to anticipate when
-- GHC's brain might explode
data PatternContext = LetBinding
                    | CaseStatement
                    | TopLevel
                    | Parameter
                    | Statement
                    deriving Eq

checkIfBrainWillExplode :: PatternContext -> ExpsQ ()
checkIfBrainWillExplode CaseStatement = return ()
checkIfBrainWillExplode Statement = return ()
checkIfBrainWillExplode Parameter = return ()
checkIfBrainWillExplode _ =
  fail $ "Can't use a singleton pattern outside of a case-statement or\n" ++
         "do expression: GHC's brain will explode if you try. (Do try it!)"

-- convert a pattern, building up the lexical scope as we go
singPat :: PatternContext -> Pat -> ExpsQ Pat
singPat patCxt (LitP lit) =
  fail "Singling of literal patterns not yet supported"
singPat patCxt (VarP name) =
  let newName = if patCxt == TopLevel then singValName name else name in do
    addBinding name (VarE newName)
    return $ VarP newName
singPat patCxt (TupP pats) =
  singPat patCxt (ConP (tupleDataName (length pats)) pats)
singPat patCxt (UnboxedTupP pats) =
  fail "Singling of unboxed tuples not supported"
singPat patCxt (ConP name pats) = do
  checkIfBrainWillExplode patCxt
  pats' <- mapM (singPat patCxt) pats
  return $ ConP (singDataConName name) pats'
singPat patCxt (InfixP pat1 name pat2) = singPat patCxt (ConP name [pat1, pat2])
singPat patCxt (UInfixP _ _ _) =
  fail "Singling of unresolved infix patterns not supported"
singPat patCxt (ParensP _) =
  fail "Singling of unresolved paren patterns not supported"
singPat patCxt (TildeP pat) = do
  pat' <- singPat patCxt pat
  return $ TildeP pat'
singPat patCxt (BangP pat) = do
  pat' <- singPat patCxt pat
  return $ BangP pat'
singPat patCxt (AsP name pat) = do
  let newName = if patCxt == TopLevel then singValName name else name in do
    pat' <- singPat patCxt pat
    addBinding name (VarE newName)
    return $ AsP name pat'
singPat patCxt WildP = return WildP
singPat patCxt (RecP name fields) =
  fail "Singling of record patterns not yet supported"
singPat patCxt (ListP pats) = do
  checkIfBrainWillExplode patCxt
  sPats <- mapM (singPat patCxt) pats
  return $ foldr (\elt lst -> ConP sconsName [elt, lst]) (ConP snilName []) sPats
singPat patCxt (SigP pat ty) =
  fail "Singling of annotated patterns not yet supported"
singPat patCxt (ViewP exp pat) =
  fail "Singling of view patterns not yet supported"

singExp :: ExpTable -> Exp -> Q Exp
singExp vars (VarE name) = case Map.lookup name vars of
  Just exp -> return exp
  Nothing -> return (singVal name)
singExp vars (ConE name) = return $ smartCon name
singExp vars (LitE lit) = case lit of
  StringL str -> sigE (dyn "sing") (appT (conT (mkName "Sing")) (litT (strTyLit str)))
  IntegerL str -> sigE (dyn "sing") (appT (conT (mkName "Sing")) (litT (numTyLit str)))
  _ -> fail "Singling of literal expressions not entirely supported"

singExp vars (AppE exp1 exp2) = do
  exp1' <- singExp vars exp1
  exp2' <- singExp vars exp2
  return $ AppE exp1' exp2'
singExp vars (InfixE mexp1 exp mexp2) =
  case (mexp1, mexp2) of
    (Nothing, Nothing) -> singExp vars exp
    (Just exp1, Nothing) -> singExp vars (AppE exp exp1)
    (Nothing, Just exp2) ->
      fail "Singling of right-only sections not yet supported"
    (Just exp1, Just exp2) -> singExp vars (AppE (AppE exp exp1) exp2)
singExp vars (UInfixE _ _ _) =
  fail "Singling of unresolved infix expressions not supported"
singExp vars (ParensE _) =
  fail "Singling of unresolved paren expressions not supported"
singExp vars (LamE pats exp) = do
  (pats', vartbl) <- evalForPair $ mapM (singPat Parameter) pats
  let vars' = Map.union vartbl vars -- order matters; union is left-biased
  singExp vars' exp
singExp vars (LamCaseE matches) = 
  fail "Singling of case expressions not yet supported"
singExp vars (TupE exps) = do
  sExps <- mapM (singExp vars) exps
  sTuple <- singExp vars (ConE (tupleDataName (length exps)))
  return $ foldExp sTuple sExps
singExp vars (UnboxedTupE exps) =
  fail "Singling of unboxed tuple not supported"
singExp vars (CondE bexp texp fexp) = do
  exps <- mapM (singExp vars) [bexp, texp, fexp]
  return $ foldExp (VarE sIfName) exps
singExp vars (MultiIfE alts) =
  fail "Singling of multi-way if statements not yet supported"
singExp vars (LetE decs exp) =
  fail "Singling of let expressions not yet supported"
singExp vars (CaseE exp matches) =
  fail "Singling of case expressions not yet supported"
singExp vars (DoE stmts) =
  fail "Singling of do expressions not yet supported"
singExp vars (CompE stmts) =
  fail "Singling of list comprehensions not yet supported"
singExp vars (ArithSeqE range) =
  fail "Singling of ranges not yet supported"
singExp vars (ListE exps) = do
  sExps <- mapM (singExp vars) exps
  return $ foldr (\x -> (AppE (AppE (VarE smartSconsName) x)))
                 (VarE smartSnilName) sExps
singExp vars (SigE exp ty) =
  fail "Singling of annotated expressions not yet supported"
singExp vars (RecConE name fields) =
  fail "Singling of record construction not yet supported"
singExp vars (RecUpdE exp fields) =
  fail "Singling of record updates not yet supported"

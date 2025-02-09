{-# LANGUAGE CPP #-}
{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE UndecidableInstances #-}

module Agda.Interaction.BasicOps where

import Control.Arrow ((***), first, second)
import Control.Applicative
import Control.Monad.Error
import Control.Monad.Reader
import Control.Monad.State
import Control.Monad.Identity
import qualified Data.Map as Map
import Data.List
import Data.Maybe
import Data.Traversable hiding (mapM, forM)

import qualified Agda.Syntax.Concrete as C -- ToDo: Remove with instance of ToConcrete
import Agda.Syntax.Position
import Agda.Syntax.Abstract as A hiding (Open, Apply)
import Agda.Syntax.Abstract.Views as A
import Agda.Syntax.Common
import Agda.Syntax.Info (ExprInfo(..),MetaInfo(..),emptyMetaInfo)
import qualified Agda.Syntax.Info as Info
import Agda.Syntax.Internal as I
import Agda.Syntax.Translation.InternalToAbstract
import Agda.Syntax.Translation.AbstractToConcrete
import Agda.Syntax.Translation.ConcreteToAbstract
import Agda.Syntax.Scope.Base
import Agda.Syntax.Scope.Monad
import Agda.Syntax.Fixity(Precedence(..))
import Agda.Syntax.Parser

import Agda.TypeChecker
import Agda.TypeChecking.Conversion
import Agda.TypeChecking.Monad as M hiding (MetaInfo)
import Agda.TypeChecking.MetaVars
import Agda.TypeChecking.Reduce
import Agda.TypeChecking.Substitute
import Agda.TypeChecking.Telescope
import Agda.TypeChecking.With
import Agda.TypeChecking.Coverage
import Agda.TypeChecking.Records
import Agda.TypeChecking.Irrelevance (wakeIrrelevantVars)
import Agda.TypeChecking.Pretty (prettyTCM)
import Agda.TypeChecking.Free (freeIn)
import qualified Agda.TypeChecking.Pretty as TP

import Agda.Utils.List
import Agda.Utils.Maybe
import Agda.Utils.Monad
import Agda.Utils.Pretty
import Agda.Utils.Permutation
import Agda.Utils.Size

#include "../undefined.h"
import Agda.Utils.Impossible

-- | Parses an expression.

parseExpr :: Range -> String -> TCM C.Expr
parseExpr rng s = liftIO $ parsePosString exprParser pos s
  where pos = fromMaybe (startPos Nothing) $ rStart rng

parseExprIn :: InteractionId -> Range -> String -> TCM Expr
parseExprIn ii rng s = do
    mId <- lookupInteractionId ii
    updateMetaVarRange mId rng
    mi  <- getMetaInfo <$> lookupMeta mId
    e   <- parseExpr rng s
    concreteToAbstract (clScope mi) e

giveExpr :: MetaId -> Expr -> TCM Expr
-- When translator from internal to abstract is given, this function might return
-- the expression returned by the type checker.
giveExpr mi e = do
    mv <- lookupMeta mi
    -- In the context (incl. signature) of the meta variable,
    -- type check expression and assign meta
    withMetaInfo (getMetaInfo mv) $ do
      metaTypeCheck mv (mvJudgement mv)
  where
    metaTypeCheck mv IsSort{}      = __IMPOSSIBLE__
    metaTypeCheck mv (HasType _ t) = do
      reportSDoc "interaction.give" 20 $
        TP.text "give: meta type =" TP.<+> prettyTCM t
      -- Here, we must be in the same context where the meta was created.
      -- Thus, we can safely apply its type to the context variables.
      ctx <- getContextArgs
      let t' = t `piApply` permute (takeP (length ctx) $ mvPermutation mv) ctx
      reportSDoc "interaction.give" 20 $
        TP.text "give: instantiated meta type =" TP.<+> prettyTCM t'
      v	<- checkExpr e t'
      case mvInstantiation mv of
          InstV v' -> unlessM ((Irrelevant ==) <$> asks envRelevance) $
                        equalTerm t' v (v' `apply` ctx)
          _	   -> updateMeta mi v
      reify v

-- | Try to fill hole by expression.
--
--   Returns the given expression unchanged
--   (for convenient generalization to @'refine'@).
give
  :: InteractionId  -- ^ Hole.
  -> Maybe Range
  -> Expr           -- ^ The expression to give.
  -> TCM Expr       -- ^ If successful, the very expression is returned unchanged.
give ii mr e = liftTCM $ do
  -- if Range is given, update the range of the interaction meta
  mi  <- lookupInteractionId ii
  whenJust mr $ updateMetaVarRange mi
  reportSDoc "interaction.give" 10 $ TP.text "giving expression" TP.<+> prettyTCM e
  reportSDoc "interaction.give" 50 $ TP.text $ show $ deepUnScope e
  -- Try to give mi := e
  giveExpr mi e `catchError` \ err -> case err of
    -- Turn PatternErr into proper error:
    PatternErr _ -> do
      err <- withInteractionId ii $ TP.text "Failed to give" TP.<+> prettyTCM e
      typeError $ GenericError $ show err
    _ -> throwError err
  removeInteractionPoint ii
  return e


-- | Try to refine hole by expression @e@.
--
--   This amounts to successively try to give @e@, @e ?@, @e ? ?@, ...
--   Returns the successfully given expression.
refine
  :: InteractionId  -- ^ Hole.
  -> Maybe Range
  -> Expr           -- ^ The expression to refine the hole with.
  -> TCM Expr       -- ^ The successfully given expression.
refine ii mr e = do
  mi <- lookupInteractionId ii
  mv <- lookupMeta mi
  let range = fromMaybe (getRange mv) mr
      scope = M.getMetaScope mv
  reportSDoc "interaction.refine" 10 $
    TP.text "refining with expression" TP.<+> prettyTCM e
  reportSDoc "interaction.refine" 50 $
    TP.text $ show $ deepUnScope e
  -- We try to append up to 10 meta variables
  tryRefine 10 range scope e
  where
    tryRefine :: Int -> Range -> ScopeInfo -> Expr -> TCM Expr
    tryRefine nrOfMetas r scope e = try nrOfMetas e
      where
        try :: Int -> Expr -> TCM Expr
        try 0 e = throwError (strMsg "Can not refine")
        try n e = give ii (Just r) e `catchError` (\_ -> try (n-1) =<< appMeta e)

        -- Apply A.Expr to a new meta
        appMeta :: Expr -> TCM Expr
        appMeta e = do
          let rng = rightMargin r -- Andreas, 2013-05-01 conflate range to its right margin to ensure that appended metas are last in numbering.  This fixes issue 841.
          -- Make new interaction point
          ii <- registerInteractionPoint rng Nothing
          let info = Info.MetaInfo
                { Info.metaRange = rng
                , Info.metaScope = scope { scopePrecedence = ArgumentCtx }
                , metaNumber = Nothing -- in order to print just as ?, not ?n
                , metaNameSuggestion = ""
                }
              metaVar = QuestionMark info ii
          return $ App (ExprRange r) e $ defaultNamedArg metaVar
          --ToDo: The position of metaVar is not correct
          --ToDo: The fixity of metavars is not correct -- fixed? MT

{-| Evaluate the given expression in the current environment -}
evalInCurrent :: Expr -> TCM Expr
evalInCurrent e =
    do  (v, t) <- inferExpr e
	v' <- {- etaContract =<< -} normalise v
	reify v'


evalInMeta :: InteractionId -> Expr -> TCM Expr
evalInMeta ii e =
   do 	m <- lookupInteractionId ii
	mi <- getMetaInfo <$> lookupMeta m
	withMetaInfo mi $
	    evalInCurrent e


data Rewrite =  AsIs | Instantiated | HeadNormal | Simplified | Normalised
    deriving (Read)

--normalForm :: Rewrite -> Term -> TCM Term
normalForm AsIs	     t = return t
normalForm Instantiated t = return t   -- reify does instantiation
normalForm HeadNormal   t = {- etaContract =<< -} reduce t
normalForm Simplified   t = {- etaContract =<< -} simplify t
normalForm Normalised   t = {- etaContract =<< -} normalise t


data OutputForm a b = OutputForm Range ProblemId (OutputConstraint a b)
  deriving (Functor)

data OutputConstraint a b
      = OfType b a | CmpInType Comparison a b b
                   | CmpElim [Polarity] a [b] [b]
      | JustType b | CmpTypes Comparison b b
                   | CmpLevels Comparison b b
                   | CmpTeles Comparison b b
      | JustSort b | CmpSorts Comparison b b
      | Guard (OutputConstraint a b) ProblemId
      | Assign b a | TypedAssign b a a | PostponedCheckArgs b [a] a a
      | IsEmptyType a | FindInScopeOF b a [(a,a)]
  deriving (Functor)

-- | A subset of 'OutputConstraint'.

data OutputConstraint' a b = OfType' { ofName :: b
                                     , ofExpr :: a
                                     }

outputFormId :: OutputForm a b -> b
outputFormId (OutputForm _ _ o) = out o
  where
    out o = case o of
      OfType i _                 -> i
      CmpInType _ _ i _          -> i
      CmpElim _ _ (i:_) _        -> i
      CmpElim _ _ [] _           -> __IMPOSSIBLE__
      JustType i                 -> i
      CmpLevels _ i _            -> i
      CmpTypes _ i _             -> i
      CmpTeles _ i _             -> i
      JustSort i                 -> i
      CmpSorts _ i _             -> i
      Guard o _                  -> out o
      Assign i _                 -> i
      TypedAssign i _ _          -> i
      PostponedCheckArgs i _ _ _ -> i
      IsEmptyType _              -> __IMPOSSIBLE__   -- Should never be used on IsEmpty constraints
      FindInScopeOF _ _ _        -> __IMPOSSIBLE__

instance Reify ProblemConstraint (Closure (OutputForm Expr Expr)) where
  reify (PConstr pid cl) = enterClosure cl $ \c -> buildClosure =<< (OutputForm (getRange c) pid <$> reify c)

instance Reify Constraint (OutputConstraint Expr Expr) where
    reify (ValueCmp cmp t u v)   = CmpInType cmp <$> reify t <*> reify u <*> reify v
    reify (ElimCmp cmp t v es1 es2) =
      CmpElim cmp <$> reify t <*> reify es1
                              <*> reify es2
    reify (LevelCmp cmp t t')    = CmpLevels cmp <$> reify t <*> reify t'
    reify (TypeCmp cmp t t')     = CmpTypes cmp <$> reify t <*> reify t'
    reify (TelCmp a b cmp t t')  = CmpTeles cmp <$> (ETel <$> reify t) <*> (ETel <$> reify t')
    reify (SortCmp cmp s s')     = CmpSorts cmp <$> reify s <*> reify s'
    reify (Guarded c pid) = do
	o  <- reify c
	return $ Guard o pid
    reify (UnBlock m) = do
        mi <- mvInstantiation <$> lookupMeta m
        case mi of
          BlockedConst t -> do
            e  <- reify t
            m' <- reify (MetaV m [])
            return $ Assign m' e
          PostponedTypeCheckingProblem cl _ -> enterClosure cl $ \p -> case p of
            CheckExpr e a -> do
                a  <- reify a
                m' <- reify (MetaV m [])
                return $ TypedAssign m' e a
            CheckArgs _ _ _ args t0 t1 _ -> do
              t0 <- reify t0
              t1 <- reify t1
              m  <- reify (MetaV m [])
              return $ PostponedCheckArgs m (map (namedThing . unArg) args) t0 t1
          Open{}  -> __IMPOSSIBLE__
          OpenIFS{}  -> __IMPOSSIBLE__
          InstS{} -> __IMPOSSIBLE__
          InstV{} -> __IMPOSSIBLE__
    reify (FindInScope m cands) = do
      m' <- reify (MetaV m [])
      ctxArgs <- getContextArgs
      t <- getMetaType m
      t' <- reify t
      cands' <- mapM (\(tm,ty) -> (,) <$> reify tm <*> reify ty) cands
      return $ FindInScopeOF m' t' cands' -- IFSTODO
    reify (IsEmpty r a) = IsEmptyType <$> reify a

showComparison :: Comparison -> String
showComparison CmpEq  = " = "
showComparison CmpLeq = " =< "

instance (Show a,Show b) => Show (OutputForm a b) where
  show o =
    case o of
      OutputForm r 0   c -> show c ++ range r
      OutputForm r pid c -> "[" ++ show pid ++ "] " ++ show c ++ range r
    where
      range r | null s    = ""
              | otherwise = " [ at " ++ s ++ " ]"
        where s = show r

instance (Show a,Show b) => Show (OutputConstraint a b) where
    show (OfType e t)           = show e ++ " : " ++ show t
    show (JustType e)           = "Type " ++ show e
    show (JustSort e)           = "Sort " ++ show e
    show (CmpInType cmp t e e') = show e ++ showComparison cmp ++ show e' ++ " : " ++ show t
    show (CmpElim cmp t e e')   = show e ++ " == " ++ show e' ++ " : " ++ show t
    show (CmpTypes  cmp t t')   = show t ++ showComparison cmp ++ show t'
    show (CmpLevels cmp t t')   = show t ++ showComparison cmp ++ show t'
    show (CmpTeles  cmp t t')   = show t ++ showComparison cmp ++ show t'
    show (CmpSorts cmp s s')    = show s ++ showComparison cmp ++ show s'
    show (Guard o pid)          = show o ++ " [blocked by problem " ++ show pid ++ "]"
    show (Assign m e)           = show m ++ " := " ++ show e
    show (TypedAssign m e a)    = show m ++ " := " ++ show e ++ " :? " ++ show a
    show (PostponedCheckArgs m es t0 t1) = show m ++ " := (_ : " ++ show t0 ++ ") " ++ unwords (map (paren . show) es)
                                                  ++ " : " ++ show t1
      where paren s | elem ' ' s = "(" ++ s ++ ")"
                    | otherwise  = s
    show (IsEmptyType a)        = "Is empty: " ++ show a
    show (FindInScopeOF s t cs) = "Resolve instance argument " ++ showCand (s,t) ++ ". Candidates: [" ++
                                    intercalate ", " (map showCand cs) ++ "]"
      where showCand (tm,ty) = show tm ++ " : " ++ show ty

instance (ToConcrete a c, ToConcrete b d) =>
         ToConcrete (OutputForm a b) (OutputForm c d) where
    toConcrete (OutputForm r pid c) = OutputForm r pid <$> toConcrete c

instance (ToConcrete a c, ToConcrete b d) =>
         ToConcrete (OutputConstraint a b) (OutputConstraint c d) where
    toConcrete (OfType e t) = OfType <$> toConcrete e <*> toConcreteCtx TopCtx t
    toConcrete (JustType e) = JustType <$> toConcrete e
    toConcrete (JustSort e) = JustSort <$> toConcrete e
    toConcrete (CmpInType cmp t e e') =
      CmpInType cmp <$> toConcreteCtx TopCtx t <*> toConcreteCtx ArgumentCtx e
                                               <*> toConcreteCtx ArgumentCtx e'
    toConcrete (CmpElim cmp t e e') =
      CmpElim cmp <$> toConcreteCtx TopCtx t <*> toConcreteCtx TopCtx e <*> toConcreteCtx TopCtx e'
    toConcrete (CmpTypes cmp e e') = CmpTypes cmp <$> toConcreteCtx ArgumentCtx e
                                                  <*> toConcreteCtx ArgumentCtx e'
    toConcrete (CmpLevels cmp e e') = CmpLevels cmp <$> toConcreteCtx ArgumentCtx e
                                                    <*> toConcreteCtx ArgumentCtx e'
    toConcrete (CmpTeles cmp e e') = CmpTeles cmp <$> toConcrete e <*> toConcrete e'
    toConcrete (CmpSorts cmp e e') = CmpSorts cmp <$> toConcreteCtx ArgumentCtx e
                                                  <*> toConcreteCtx ArgumentCtx e'
    toConcrete (Guard o pid) = Guard <$> toConcrete o <*> pure pid
    toConcrete (Assign m e) = noTakenNames $ Assign <$> toConcrete m <*> toConcreteCtx TopCtx e
    toConcrete (TypedAssign m e a) = TypedAssign <$> toConcrete m <*> toConcreteCtx TopCtx e
                                                                  <*> toConcreteCtx TopCtx a
    toConcrete (PostponedCheckArgs m args t0 t1) =
      PostponedCheckArgs <$> toConcrete m <*> toConcrete args <*> toConcrete t0 <*> toConcrete t1
    toConcrete (IsEmptyType a) = IsEmptyType <$> toConcreteCtx TopCtx a
    toConcrete (FindInScopeOF s t cs) =
      FindInScopeOF <$> toConcrete s <*> toConcrete t
                    <*> mapM (\(tm,ty) -> (,) <$> toConcrete tm <*> toConcrete ty) cs

instance (Pretty a, Pretty b) => Pretty (OutputConstraint' a b) where
  pretty (OfType' e t) = pretty e <+> text ":" <+> pretty t

instance (ToConcrete a c, ToConcrete b d) =>
            ToConcrete (OutputConstraint' a b) (OutputConstraint' c d) where
  toConcrete (OfType' e t) = OfType' <$> toConcrete e <*> toConcreteCtx TopCtx t

--ToDo: Move somewhere else
instance ToConcrete InteractionId C.Expr where
    toConcrete (InteractionId i) = return $ C.QuestionMark noRange (Just i)
{- UNUSED
instance ToConcrete MetaId C.Expr where
    toConcrete x@(MetaId i) = do
      return $ C.Underscore noRange (Just $ "_" ++ show i)
-}
instance ToConcrete NamedMeta C.Expr where
    toConcrete i = do
      return $ C.Underscore noRange (Just $ show i)

judgToOutputForm :: Judgement a c -> OutputConstraint a c
judgToOutputForm (HasType e t) = OfType e t
judgToOutputForm (IsSort  s t) = JustSort s

getConstraints :: TCM [OutputForm C.Expr C.Expr]
getConstraints = liftTCM $ do
    cs <- M.getAllConstraints
    cs <- forM cs $ \c -> do
            cl <- reify c
            enterClosure cl abstractToConcrete_
    ss <- mapM toOutputForm =<< getSolvedInteractionPoints True -- get all
    return $ ss ++ cs
  where
    toOutputForm (ii, mi, e) = do
      mv <- getMetaInfo <$> lookupMeta mi
      withMetaInfo mv $ do
        let m = QuestionMark emptyMetaInfo{ metaNumber = Just $ fromIntegral ii } ii
        abstractToConcrete_ $ OutputForm noRange 0 $ Assign m e

-- | @getSolvedInteractionPoints True@ returns all solutions,
--   even if just solved by another, non-interaction meta.
--
--   @getSolvedInteractionPoints False@ only returns metas that
--   are solved by a non-meta.

getSolvedInteractionPoints :: Bool -> TCM [(InteractionId, MetaId, Expr)]
getSolvedInteractionPoints all = concat <$> do
  mapM solution =<< getInteractionIdsAndMetas
  where
    solution (i, m) = do
      mv <- lookupMeta m
      withMetaInfo (getMetaInfo mv) $ do
        args  <- getContextArgs
        scope <- getScope
        let sol v = do
              -- Andreas, 2014-02-17 exclude metas solved by metas
              v <- ignoreSharing <$> instantiate v
              let isMeta = case v of MetaV{} -> True; _ -> False
              if isMeta && not all then return [] else do
                e <- reify v
                return [(i, m, ScopedExpr scope e)]
            unsol = return []
        case mvInstantiation mv of
          InstV{}                        -> sol (MetaV m $ map Apply args)
          InstS{}                        -> sol (Level $ Max [Plus 0 $ MetaLevel m $ map Apply args])
          Open{}                         -> unsol
          OpenIFS{}                      -> unsol
          BlockedConst{}                 -> unsol
          PostponedTypeCheckingProblem{} -> unsol

typeOfMetaMI :: Rewrite -> MetaId -> TCM (OutputConstraint Expr NamedMeta)
typeOfMetaMI norm mi =
     do mv <- lookupMeta mi
	withMetaInfo (getMetaInfo mv) $
	  rewriteJudg mv (mvJudgement mv)
   where
    rewriteJudg mv (HasType i t) = do
      ms <- getMetaNameSuggestion i
      t <- normalForm norm t
      vs <- getContextArgs
      let x = NamedMeta ms i
      reportSDoc "interactive.meta" 10 $ TP.vcat
        [ TP.text $ unwords ["permuting", show i, "with", show $ mvPermutation mv]
        , TP.nest 2 $ TP.vcat
          [ TP.text "len  =" TP.<+> TP.text (show $ length vs)
          , TP.text "args =" TP.<+> prettyTCM vs
          , TP.text "t    =" TP.<+> prettyTCM t
          , TP.text "x    =" TP.<+> TP.text (show x)
          ]
        ]
      OfType x <$> reify (t `piApply` permute (takeP (size vs) $ mvPermutation mv) vs)
    rewriteJudg mv (IsSort i t) = do
      ms <- getMetaNameSuggestion i
      return $ JustSort $ NamedMeta ms i


typeOfMeta :: Rewrite -> InteractionId -> TCM (OutputConstraint Expr InteractionId)
typeOfMeta norm ii = typeOfMeta' norm . (ii,) =<< lookupInteractionId ii

typeOfMeta' :: Rewrite -> (InteractionId, MetaId) -> TCM (OutputConstraint Expr InteractionId)
typeOfMeta' norm (ii, mi) = fmap (\_ -> ii) <$> typeOfMetaMI norm mi

typesOfVisibleMetas :: Rewrite -> TCM [OutputConstraint Expr InteractionId]
typesOfVisibleMetas norm =
  liftTCM $ mapM (typeOfMeta' norm) =<< getInteractionIdsAndMetas

typesOfHiddenMetas :: Rewrite -> TCM [OutputConstraint Expr NamedMeta]
typesOfHiddenMetas norm = liftTCM $ do
  is    <- getInteractionMetas
  store <- Map.filterWithKey (openAndImplicit is) <$> getMetaStore
  mapM (typeOfMetaMI norm) $ Map.keys store
  where
  openAndImplicit is x (MetaVar{mvInstantiation = M.Open}) = x `notElem` is
  openAndImplicit is x (MetaVar{mvInstantiation = M.BlockedConst _}) = True
  openAndImplicit _  _ _                                    = False

metaHelperType :: Rewrite -> InteractionId -> Range -> String -> TCM (OutputConstraint' Expr Expr)
metaHelperType norm ii rng s = case words s of
  []    -> fail "C-c C-h expects an argument of the form f e1 e2 .. en"
  f : _ -> do
    A.Application h args <- A.appView . getBody . deepUnScope <$> parseExprIn ii rng ("let " ++ f ++ " = _ in " ++ s)
    withInteractionId ii $ do
      cxtArgs  <- getContextArgs
      -- cleanupType relies on with arguments being named 'w',
      -- so we'd better rename any actual 'w's to avoid confusion.
      tel      <- runIdentity . onNamesTel unW <$> getContextTelescope
      a        <- runIdentity . onNames unW . (`piApply` cxtArgs) <$> (getMetaType =<< lookupInteractionId ii)
      (vs, as) <- unzip <$> mapM (inferExpr . namedThing . unArg) args
      -- Remember the arity of a
      TelV atel _ <- telView a
      let arity = size atel
      a        <- local (\e -> e { envPrintDomainFreePi = True }) $ do
        reify =<< cleanupType arity args =<< normalForm norm =<< withFunctionType tel vs as EmptyTel a
      return (OfType' h a)
  where
    cleanupType arity args t = do
      -- Get the arity of t
      TelV ttel _ <- telView t
      -- Compute the number or pi-types subject to stripping.
      let n = size ttel - arity
      -- It cannot be negative, otherwise we would have performed a
      -- negative number of with-abstractions.
      unless (n >= 0) __IMPOSSIBLE__
      return $ evalState (renameVars $ hiding args $ stripUnused n t) args

    getBody (A.Let _ _ e)      = e
    getBody _                  = __IMPOSSIBLE__

    -- Strip the non-dependent abstractions from the first n abstractions.
    stripUnused n (El s v) = El s $ strip n v
    strip 0 v = v
    strip n v = case v of
      I.Pi a b -> case stripUnused (n-1) <$> b of
        b | absName b == "w"   -> I.Pi a b
        NoAbs _ b              -> unEl b
        Abs s b | 0 `freeIn` b -> I.Pi (hide a) (Abs s b)
                | otherwise    -> subst __IMPOSSIBLE__ (unEl b)
      _ -> v  -- todo: handle if goal type is a Pi

    renameVars = onNames renameVar

    hiding args (El s v) = El s $ hidingTm args v
    hidingTm (arg:args) (I.Pi a b) | absName b == "w" =
      I.Pi (setHiding (getHiding arg) a) (hiding args <$> b)
    hidingTm args (I.Pi a b) = I.Pi a (hiding args <$> b)
    hidingTm _ a = a

    onNames :: Applicative m => (String -> m String) -> Type -> m Type
    onNames f (El s v) = El s <$> onNamesTm f v

    onNamesTel :: Applicative f => (String -> f String) -> I.Telescope -> f I.Telescope
    onNamesTel f I.EmptyTel = pure I.EmptyTel
    onNamesTel f (I.ExtendTel a b) = I.ExtendTel <$> traverse (onNames f) a <*> onNamesAbs f onNamesTel b

    onNamesTm f v = case v of
      I.Var x es   -> I.Var x <$> onNamesElims f es
      I.Def q es   -> I.Def q <$> onNamesElims f es
      I.Con c args -> I.Con c <$> onNamesArgs f args
      I.Lam i b    -> I.Lam i <$> onNamesAbs f onNamesTm b
      I.Pi a b     -> I.Pi <$> traverse (onNames f) a <*> onNamesAbs f onNames b
      I.DontCare v -> I.DontCare <$> onNamesTm f v
      I.Lit{}      -> pure v
      I.Sort{}     -> pure v
      I.Level{}    -> pure v
      I.MetaV{}    -> pure v
      I.Shared{}   -> pure v
    onNamesElims f = traverse $ traverse $ onNamesTm f
    onNamesArgs f  = traverse $ traverse $ onNamesTm f
    onNamesAbs f nd (Abs   s x) = Abs   <$> f s <*> nd f x
    onNamesAbs f nd (NoAbs s x) = NoAbs <$> f s <*> nd f x

    unW "w" = return ".w"
    unW s   = return s

    renameVar ('.':s) = pure s
    renameVar "w"     = betterName
    renameVar s       = pure s

    betterName = do
      arg : args <- get
      put args
      return $ case arg of
        Arg _ (Named _ (A.Var x)) -> show x
        Arg _ (Named (Just x) _)  -> rangedThing x
        _                         -> "w"


-- Gives a list of names and corresponding types.

contextOfMeta :: InteractionId -> Rewrite -> TCM [OutputConstraint' Expr Name]
contextOfMeta ii norm = do
  info <- getMetaInfo <$> (lookupMeta =<< lookupInteractionId ii)
  let localVars = map ctxEntry . envContext . clEnv $ info
      letVars = map (\(n, OpenThing _ (tm, (Dom c ty))) -> Dom c (n, ty))
                    $ Map.toDescList . envLetBindings . clEnv $ info
  withMetaInfo info $ gfilter visible <$> reifyContext (length letVars)
                                                       (letVars ++ localVars)
  where gfilter p = catMaybes . map p
        visible (OfType x y) | show x /= "_" = Just (OfType' x y)
                             | otherwise     = Nothing
	visible _	     = __IMPOSSIBLE__
        reifyContext skip xs =
          reverse <$> zipWithM out
                               -- don't escape context for letvars
                               (replicate skip 0 ++ [1..])
                               xs

        out i (Dom _ (x, t)) = escapeContext i $ do
          t' <- reify =<< normalForm norm t
          return $ OfType x t'


-- | Returns the type of the expression in the current environment
--   We wake up irrelevant variables just in case the user want to
--   invoke that command in an irrelevant context.
typeInCurrent :: Rewrite -> Expr -> TCM Expr
typeInCurrent norm e =
    do 	(_,t) <- wakeIrrelevantVars $ inferExpr e
        v <- normalForm norm t
        reify v



typeInMeta :: InteractionId -> Rewrite -> Expr -> TCM Expr
typeInMeta ii norm e =
   do 	m <- lookupInteractionId ii
	mi <- getMetaInfo <$> lookupMeta m
	withMetaInfo mi $
	    typeInCurrent norm e

withInteractionId :: InteractionId -> TCM a -> TCM a
withInteractionId i ret = do
  m <- lookupInteractionId i
  withMetaId m ret

withMetaId :: MetaId -> TCM a -> TCM a
withMetaId m ret = do
  mv <- lookupMeta m
  withMetaInfo' mv ret

-- The intro tactic

-- Returns the terms (as strings) that can be
-- used to refine the goal. Uses the coverage checker
-- to find out which constructors are possible.
introTactic :: Bool -> InteractionId -> TCM [String]
introTactic pmLambda ii = do
  mi <- lookupInteractionId ii
  mv <- lookupMeta mi
  withMetaInfo (getMetaInfo mv) $ case mvJudgement mv of
    HasType _ t -> do
        t <- reduce =<< piApply t <$> getContextArgs
        -- Andreas, 2013-03-05 Issue 810: skip hidden domains in introduction
        -- of constructor.
        TelV tel' t <- telViewUpTo' (-1) notVisible t
        -- if we cannot introduce a constructor, we try a lambda
        let fallback = do
              TelV tel _ <- telView t
              reportSDoc "interaction.intro" 20 $ TP.sep
                [ TP.text "introTactic/fallback"
                , TP.text "tel' = " TP.<+> prettyTCM tel'
                , TP.text "tel  = " TP.<+> prettyTCM tel
                ]
              case (tel', tel) of
                (EmptyTel, EmptyTel) -> return []
                _ -> introFun (telToList tel' ++ telToList tel)

        case ignoreSharing $ unEl t of
          I.Def d _ -> do
            def <- getConstInfo d
            case theDef def of
              Datatype{}    -> addCtxTel tel' $ introData t
              Record{ recNamedCon = name }
                | name      -> addCtxTel tel' $ introData t
                | otherwise -> addCtxTel tel' $ introRec d
              _ -> fallback
          _ -> fallback
     `catchError` \_ -> return []
    _ -> __IMPOSSIBLE__
  where
    conName [p] = [ c | I.ConP c _ _ <- [namedArg p] ]
    conName _   = __IMPOSSIBLE__

    showTCM v = show <$> prettyTCM v

    introFun tel = addCtxTel tel' $ do
        reportSDoc "interaction.intro" 10 $ do TP.text "introFun" TP.<+> prettyTCM (telFromList tel)
        imp <- showImplicitArguments
        let okHiding0 h = imp || h == NotHidden
            -- if none of the vars were displayed, we would get a parse error
            -- thus, we switch to displaying all
            allHidden   = null (filter okHiding0 hs)
            okHiding    = if allHidden then const True else okHiding0
        vars <- -- setShowImplicitArguments (imp || allHidden) $
                (if allHidden then withShowAllArguments else id) $
                  mapM showTCM [ setHiding h $ defaultArg $ var i :: I.Arg Term
                               | (h, i) <- zip hs $ downFrom n
                               , okHiding h
                               ]
        if pmLambda
           then return [ unwords $ ["λ", "{"] ++ vars ++ ["→", "?", "}"] ]
           else return [ unwords $ ["λ"]      ++ vars ++ ["→", "?"] ]
      where
        n = size tel
        hs   = map getHiding tel
        tel' = telFromList [ fmap makeName b | b <- tel ]
        makeName ("_", t) = ("x", t)
        makeName (x, t)   = (x, t)

    introData t = do
      let tel  = telFromList [domFromArg $ defaultArg ("_", t)]
          pat  = [defaultArg $ unnamed $ I.VarP "c"]
      r <- splitLast CoInductive tel pat
      case r of
        Left err -> return []
        Right cov -> mapM showTCM $ concatMap (conName . scPats) $ splitClauses cov

    introRec d = do
      hfs <- getRecordFieldNames d
      fs <- ifM showImplicitArguments
            (return $ map unArg hfs)
            (return [ unArg a | a <- hfs, getHiding a == NotHidden ])
      return
        [ concat $
            "record {" :
            intersperse ";" (map (\ f -> show f ++ " = ?") fs) ++
            ["}"]
        ]

-- | Runs the given computation as if in an anonymous goal at the end
--   of the top-level module.
--
--   Sets up current module, scope, and context.
atTopLevel :: TCM a -> TCM a
atTopLevel m = inConcreteMode $ do
  let err = typeError $ GenericError "The file has not been loaded yet."
  caseMaybeM (gets stCurrentModule) err $ \ current -> do
    caseMaybeM (getVisitedModule $ toTopLevelModuleName current) __IMPOSSIBLE__ $ \ mi -> do
      let scope = iInsideScope $ miInterface mi
      tel <- lookupSection current
      -- Get the names of the local variables from @scope@
      -- and put them into the context.
      let names :: [A.Name]
          names = reverse $ map snd $ scopeLocals scope
          types :: [I.Dom I.Type]
          types = map (snd <$>) $ telToList tel
          gamma :: ListTel' A.Name
          gamma = zipWith' (\ x dom -> (x,) <$> dom) names types
      M.withCurrentModule current $
        withScope_ scope $
          addContext gamma $
            m

-- | Parse a name.
parseName :: Range -> String -> TCM C.QName
parseName r s = do
  m <- parseExpr r s
  case m of
    C.Ident m              -> return m
    C.RawApp _ [C.Ident m] -> return m
    _                      -> typeError $
      GenericError $ "Not an identifier: " ++ show m ++ "."

-- | Returns the contents of the given module.

moduleContents :: Rewrite
                  -- ^ How should the types be presented
               -> Range
                  -- ^ The range of the next argument.
               -> String
                  -- ^ The module name.
               -> TCM ([C.Name], [(C.Name, Type)])
                  -- ^ Module names, names paired up with
                  -- corresponding types.
moduleContents norm rng s = do
  m <- parseName rng s
  modScope <- getNamedScope . amodName =<< resolveModule m
  let modules :: ThingsInScope AbstractModule
      modules = exportedNamesInScope modScope
      names :: ThingsInScope AbstractName
      names = exportedNamesInScope modScope
  types <- mapM (\(x, n) -> do
                   d <- getConstInfo $ anameName n
                   t <- normalForm norm =<< (defType <$> instantiateDef d)
                   return (x, t))
                (concatMap (\(x, ns) -> map ((,) x) ns) $
                           Map.toList names)
  return (Map.keys modules, types)

whyInScope :: String -> TCM (Maybe A.Name, [AbstractName], [AbstractModule])
whyInScope s = do
  x     <- parseName noRange s
  scope <- getScope
  return ( lookup x $ map (first C.QName) $ scopeLocals scope
         , scopeLookup x scope
         , scopeLookup x scope )


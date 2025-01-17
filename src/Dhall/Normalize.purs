module Dhall.Normalize where

import Prelude

import Control.Apply (lift2)
import Control.Comonad (class Comonad, class Extend, extend, extract)
import Control.Plus (empty)
import Data.Array (foldr)
import Data.Array as Array
import Data.Array.NonEmpty as NEA
import Data.Const (Const)
import Data.Either (Either(..))
import Data.Enum (toEnum)
import Data.Foldable as Foldable
import Data.Function (on)
import Data.Functor.App as AppF
import Data.Functor.Product (Product(..), product)
import Data.Functor.Variant (VariantF)
import Data.Functor.Variant as VariantF
import Data.FunctorWithIndex (mapWithIndex)
import Data.Identity (Identity(..))
import Data.Int as Int
import Data.Lazy (Lazy, defer)
import Data.Lens as Lens
import Data.Map (Map)
import Data.Maybe (Maybe(..), isJust)
import Data.Maybe.First (First)
import Data.Monoid.Conj (Conj(..))
import Data.Newtype (class Newtype, unwrap, wrap)
import Data.String as String
import Data.Symbol (class IsSymbol)
import Data.These (These(..))
import Data.Traversable (class Traversable, sequence, traverse)
import Data.Tuple (Tuple(..), uncurry)
import Data.Variant (Variant)
import Data.Variant as Variant
import Dhall.Lib.Numbers (Double, Natural, Integer, (+-))
import Dhall.Lib.Numbers as Num
import Dhall.Core.AST (CONST, Expr, TextLitF(..), UNIT, ExprLayerRow)
import Dhall.Core.AST as AST
import Dhall.Core.AST.Operations.Transformations (ConsNodeOps, ConsNodeOpsM, OverCasesM(..), runAlgebraExprM)
import Dhall.Core.AST.Types.Basics (S_, _S)
import Dhall.Map (class MapLike)
import Dhall.Map as Dhall.Map
import Dhall.Normalize.Apps (AppsF(..), appsG, noappG, noapplitG, noapplitG', (~))
import Dhall.Variables (ShiftSubstAlg, shiftSubstAlgGM)
import Dhall.Variables as Variables
import Prim.Row as Row
import Type.Proxy (Proxy)

-- | Reduce an expression to its normal form, performing beta reduction
-- | `normalize` does not type-check the expression.  You may want to type-check
-- | expressions before normalizing them since normalization can convert an
-- | ill-typed expression into a well-typed expression.
-- | However, `normalize` will not fail if the expression is ill-typed and will
-- | leave ill-typed sub-expressions unevaluated.
normalize :: forall m a. MapLike String m => Eq a => Expr m a -> Expr m a
normalize = normalizeWith mempty

-- | This function is used to determine whether folds like `Natural/fold` or
-- | `List/fold` should be lazy or strict in their accumulator based on the type
-- | of the accumulator
-- |
-- | If this function returns `True`, then they will be strict in their
-- | accumulator since we can guarantee an upper bound on the amount of work to
-- | normalize the accumulator on each step of the loop.  If this function
-- | returns `False` then they will be lazy in their accumulator and only
-- | normalize the final result at the end of the fold
boundedTypeG :: forall node all ops.
  { unlayer :: node -> VariantF all node
  | ops
  } -> node -> Boolean
boundedTypeG _ _ = false

newtype GNormalizerF i a = GNormalizer
  (i -> AppsF a -> Maybe (Unit -> a))
derive instance newtypeNormalizer :: Newtype (GNormalizerF i a) _
-- not Alt, because it is not a covariant functor
instance semigroupNormalizer :: Semigroup (GNormalizerF i a) where
  append (GNormalizer n) (GNormalizer m) = GNormalizer \ops as ->
    case n ops as of
      Just r -> Just r
      Nothing -> m ops as
instance monoidNormalizer :: Monoid (GNormalizerF i a) where
  mempty = GNormalizer \_ _ -> Nothing

type GNormalizer all i node ops =
  GNormalizerF (Record (ConsNodeOps all i node ops)) node
type Normalizer m a = GNormalizerF Unit (Expr m a)

type Preview' a b = Lens.Fold (First b) a a b b

{-| Reduce an expression to its normal form, performing beta reduction and applying
    any custom definitions.
    `normalizeWith` is designed to be used with function `typeWith`. The `typeWith`
    function allows typing of Dhall functions in a custom typing context whereas
    `normalizeWith` allows evaluating Dhall expressions in a custom context.
    To be more precise `normalizeWith` applies the given normalizer when it finds an
    application term that it cannot reduce by other means.
    Note that the context used in normalization will determine the properties of normalization.
    That is, if the functions in custom context are not total then the Dhall language, evaluated
    with those functions is not total either.
-}
normalizeWith :: forall m a. MapLike String m => Eq a => Normalizer m a -> Expr m a -> Expr m a
normalizeWith ctx = extract <<< extract <<< unwrap <<< normalizeWithW ctx

newtype W a = W (Tuple (Conj Boolean) (Lazy a))
derive instance newtypeW :: Newtype (W a) _
derive instance functorW :: Functor W
instance applyW :: Apply W where
  apply (W (Tuple l fab)) (W (Tuple r fb)) = W (Tuple (l<>r) (fab <*> fb))
instance applicativeW :: Applicative W where
  pure = W <<< pure <<< pure
instance bindW :: Bind W where
  bind (W (Tuple (Conj false) l)) f =
    W (Tuple (Conj false) (l >>= f >>> unwrap >>> extract))
  bind (W (Tuple (Conj true) l)) f = f $ extract l
instance extendW :: Extend W where
  extend f w@(W (Tuple c _)) = W $ Tuple c $ extend (extract >>> f) (pure w)
instance comonadW :: Comonad W where
  extract (W (Tuple _ l)) = extract l

type NormalizeAlg node v = ShiftSubstAlg node
  ( normalize :: {} | v )

lowerOps :: forall all i node.
  Record (ConsNodeOpsM W all i node ()) ->
  Record (ConsNodeOps all i node ())
lowerOps node =
  { layer: node.layer
  , unlayer: node.unlayer
  , overlayer: OverCasesM \f -> Identity <<< case node.overlayer of
      OverCasesM g -> g (pure <<< extract <<< f) >>> extract
  , recurse: \i -> node.recurse i >>> Identity <<< extract
  }

normalizeWithAlgGW :: forall m a v node. MapLike String m => Eq a =>
  GNormalizer (AST.ExprLayerRow m a) (Variant (NormalizeAlg node v)) node () ->
  (Variant v -> Record (ConsNodeOpsM W (AST.ExprLayerRow m a) (Variant (NormalizeAlg node v)) node ()) -> node -> W node) ->
  (Variant (NormalizeAlg node v) -> Record (ConsNodeOpsM W (AST.ExprLayerRow m a) (Variant (NormalizeAlg node v)) node ()) -> node -> W node)
normalizeWithAlgGW normApp finally i node = i # flip (Variant.on (_S::S_ "normalize")) rest handleLayer where
  rest = shiftSubstAlgGM finally <@> node

  unchanged :: forall x. W x -> Boolean
  unchanged (W (Tuple (Conj c) _)) = c

  -- Normalize one layer of content
  handleLayer (_ :: {}) orig = case rules catchall orig of
    -- Hack: return the original node of the algorithm says it was unchanged
    modified ->
      if unchanged modified
        then pure orig
        else modified

  -- Recurse as necessary
  go = node.recurse $ Variant.inj (_S::S_ "normalize") mempty

  -- Default behavior is to traverse the children, gather the new results
  -- and detect if any of them changed
  catchall :: node -> W node
  catchall = case node.overlayer of
    OverCasesM overCases -> overCases (traverse go)

  expose ::
    forall sym f rest r.
      Functor f =>
      Row.Cons sym f rest (AST.ExprLayerRow m a) =>
      IsSymbol sym =>
    Proxy sym ->
    (f (W node) -> r) -> (node -> r) -> node -> r
  expose sym here other e =
    VariantF.on sym (here <<< map go) (\_ -> other e) (node.unlayer e)

  exposeW ::
    forall sym f rest r.
      Functor f =>
      Row.Cons sym f rest (AST.ExprLayerRow m a) =>
      IsSymbol sym =>
    Proxy sym ->
    (f (W node) -> r) -> (W node -> r) -> W node -> r
  exposeW sym here other e =
    VariantF.on sym (here <<< map pure) (\_ -> other e) (node.unlayer (extractW e))

  previewF ::
    forall sym f rest.
      Functor f =>
      Row.Cons sym f rest (AST.ExprLayerRow m a) =>
      IsSymbol sym =>
    Proxy sym ->
    node -> Maybe (f (W node))
  previewF sym = expose sym Just (const Nothing)

  previewLit ::
    forall sym lit rest.
      Row.Cons sym (Const lit) rest (AST.ExprLayerRow m a) =>
      IsSymbol sym =>
    Proxy sym ->
    node -> Maybe lit
  previewLit sym = previewF sym >>> map unwrap

  binOpWith :: forall i r.
    (node -> i) ->
    (W node -> W node -> i -> i -> r) ->
    (AST.Pair (W node) -> r)
  binOpWith praevise here (AST.Pair l r) = here l r
      do l # extractW # praevise
      do r # extractW # praevise

  anew ::
    forall sym f rest.
      Functor f =>
      Row.Cons sym f rest (AST.ExprLayerRow m a) =>
      IsSymbol sym =>
    Proxy sym ->
    f (W node) -> W node
  anew sym children = instead \_ ->
    node.layer $ VariantF.inj sym $ children <#> extractW

  anewAnd ::
    forall sym f rest.
      Functor f =>
      Row.Cons sym f rest (AST.ExprLayerRow m a) =>
      IsSymbol sym =>
    Proxy sym ->
    f (W node) -> W node
  anewAnd sym children = instead \_ -> extractW $ go $
    node.layer $ VariantF.inj sym $ children <#> extractW

  reconstruct ::
    forall sym f rest.
      Traversable f =>
      Row.Cons sym f rest (AST.ExprLayerRow m a) =>
      IsSymbol sym =>
    Proxy sym ->
    f (W node) -> W node
  reconstruct sym = sequence >>> map \children ->
    node.layer $ VariantF.inj sym $ children

  -- The companion to judgmentallyEqual for terms that are already
  -- normalized recursively from this
  judgEq :: W node -> W node -> Boolean
  judgEq = on (eq :: Expr (Map String) a -> Expr (Map String) a -> Boolean) $
    extractW >>> unlayers >>> AST.unordered >>> Variables.alphaNormalize

  judgEqW :: node -> node -> Boolean
  judgEqW = on (eq :: Expr (Map String) a -> Expr (Map String) a -> Boolean) $
    unlayers >>> AST.unordered >>> Variables.alphaNormalize

  unlayers :: node -> Expr m a
  unlayers e = AST.embedW (node.unlayer e <#> unlayers)

  relayers :: Expr m a -> node
  relayers e = AST.projectW e # map relayers # node.layer

  extractW :: forall x. W x -> x
  extractW = extract

  deferred :: forall x. (Unit -> x) -> W x
  deferred x = W $ pure (defer x)

  simpler :: forall x. W x -> W x
  simpler (W (Tuple _ x)) = W $ Tuple (Conj false) x

  instead :: forall x. (Unit -> x) -> W x
  instead x = simpler (deferred x)

  insteadExpr :: (Unit -> Expr m a) -> W node
  insteadExpr x = instead \_ -> relayers (x unit)

  shiftSubstShift0 :: String -> node -> node -> node
  shiftSubstShift0 var substitution =
    let variable = AST.V var 0 in
    extractW <<< node.recurse (Variant.inj (_S::S_ "shift") { variable, delta: (-1) }) <<<
    extractW <<< node.recurse (Variant.inj (_S::S_ "subst") { variable, substitution:
      substitution # extractW <<< node.recurse (Variant.inj (_S::S_ "shift") { variable, delta: 1 })
    })

  rules :: (node -> W node) -> node -> W node
  rules = identity
    >>> expose (_S::S_ "Annot")
    do \(AST.Pair e _) -> simpler e
    >>> expose (_S::S_ "Let")
    do \(AST.LetF var _ value body) ->
        instead \_ -> extractW $ go $
          shiftSubstShift0 var (extractW value) (extractW body)
    >>> expose (_S::S_ "BoolAnd")
    do binOpWith (previewLit (_S::S_ "BoolLit")) \l r -> case _, _ of
        Just true, _ -> simpler r -- (l = True) && r -> r
        Just false, _ -> simpler l -- (l = False) && r -> (l = False)
        _, Just false -> simpler r -- l && (r = False) -> (r = False)
        _, Just true -> simpler l -- l && (r = True) -> l
        _, _ ->
          if judgEq l r
          then simpler l
          else reconstruct (_S::S_ "BoolAnd") (AST.Pair l r)
    >>> expose (_S::S_ "BoolOr")
    do binOpWith (previewLit (_S::S_ "BoolLit")) \l r -> case _, _ of
        Just true, _ -> simpler l -- (l = True) || r -> (l = True)
        Just false, _ -> simpler r -- (l = False) || r -> r
        _, Just false -> simpler l -- l || (r = False) -> l
        _, Just true -> simpler r -- l || (r = True) -> (r = True)
        _, _ ->
          if judgEq l r
          then simpler l
          else reconstruct (_S::S_ "BoolOr") (AST.Pair l r)
    >>> expose (_S::S_ "BoolEQ")
    do binOpWith (previewLit (_S::S_ "BoolLit")) \l r -> case _, _ of
        Just a, Just b -> insteadExpr \_ -> AST.mkBoolLit (a == b)
        Just true, _ -> simpler r
        _, Just true -> simpler l
        _, _ ->
          if judgEq l r
          then insteadExpr \_ -> AST.mkBoolLit true
          else reconstruct (_S::S_ "BoolEQ") (AST.Pair l r)
    >>> expose (_S::S_ "BoolNE")
    do binOpWith (previewLit (_S::S_ "BoolLit")) \l r -> case _, _ of
        Just a, Just b -> insteadExpr \_ -> AST.mkBoolLit (a /= b)
        Just false, _ -> simpler r
        _, Just false -> simpler l
        _, _ ->
          if judgEq l r
          then insteadExpr \_ -> AST.mkBoolLit false
          else reconstruct (_S::S_ "BoolNE") (AST.Pair l r)
    >>> expose (_S::S_ "BoolIf")
    do \(AST.Triplet b t f) ->
        case previewLit (_S::S_ "BoolLit") (extractW b) of
          Just true -> simpler t
          Just false -> simpler f
          Nothing ->
            case previewLit (_S::S_ "BoolLit") (extractW t), previewLit (_S::S_ "BoolLit") (extractW f) of
              Just true, Just false -> simpler b
              _, _ ->
                if judgEq t f
                  then simpler t
                  else reconstruct (_S::S_ "BoolIf") (AST.Triplet b t f)
    >>> expose (_S::S_ "NaturalPlus")
    do binOpWith (previewLit (_S::S_ "NaturalLit")) \l r -> case _, _ of
        Just a, Just b -> insteadExpr \_ -> AST.mkNaturalLit (a + b)
        Just a, _ | a == zero -> simpler r
        _, Just b | b == zero -> simpler l
        _, _ -> reconstruct (_S::S_ "NaturalPlus") (AST.Pair l r)
    >>> expose (_S::S_ "NaturalTimes")
    do binOpWith (previewLit (_S::S_ "NaturalLit")) \l r -> case _, _ of
        Just a, Just b -> insteadExpr \_ -> AST.mkNaturalLit (a * b)
        Just a, _ | a == zero -> simpler l
        _, Just b | b == zero -> simpler r
        Just a, _ | a == one -> simpler r
        _, Just b | b == one -> simpler l
        _, _ -> reconstruct (_S::S_ "NaturalTimes") (AST.Pair l r)
    >>> expose (_S::S_ "TextLit")
    do
      let
        trav :: AST.TextLitF (W node) -> W (AST.TextLitF (W node))
        trav (AST.TextLit s) = pure (AST.TextLit s)
        trav (AST.TextInterp s v tl) =
          (v # exposeW (_S::S_ "TextLit")
            do \tl2 -> instead \_ -> (AST.TextLit s <> tl2) <> (extractW (trav tl))
            do \_ -> lift2 (AST.TextInterp s) (v <$ v) (trav tl)
          )
        finalize tl =
          let tl' = trav tl in
          case extractW tl' of
            AST.TextInterp "" v' (AST.TextLit "") -> simpler v'
            _ -> reconstruct (_S::S_ "TextLit") =<< tl'
      finalize
    >>> expose (_S::S_ "TextAppend")
    do binOpWith (previewF (_S::S_ "TextLit")) \l r -> case _, _ of
        Just a, Just b -> anew (_S::S_ "TextLit") (a <> b)
        Just (AST.TextLit ""), _ -> simpler r
        _, Just (AST.TextLit "") -> simpler l
        _, _ -> anewAnd (_S::S_ "TextLit") (TextInterp "" l (TextInterp "" r (TextLit "")))
    >>> expose (_S::S_ "ListLit")
    do \(Product (Tuple mty vs)) ->
        -- Remove annotation on non-empty lists
        if not Array.null vs && isJust mty
          then anew (_S::S_ "ListLit") (Product (Tuple Nothing vs))
          else reconstruct (_S::S_ "ListLit") (Product (Tuple mty vs))
    >>> expose (_S::S_ "ListAppend")
    do binOpWith (previewF (_S::S_ "ListLit")) \l r -> case _, _ of
        Just (Product (Tuple mty as)), Just (Product (Tuple _ bs)) ->
          let rs = as <> bs
              mty' = if Array.null rs then mty else Nothing
          in
          anew (_S::S_ "ListLit") (Product (Tuple mty' rs))
        Just (Product (Tuple _ [])), _ -> simpler r
        _, Just (Product (Tuple _ [])) -> simpler l
        _, _ -> reconstruct (_S::S_ "ListAppend") (AST.Pair l r)
    >>> expose (_S::S_ "RecordCompletion")
    do \(AST.Pair t r) -> anewAnd (_S::S_ "Prefer") $ AST.Pair
        (anew (_S::S_ "Field") (Tuple "default" t))
        r
    >>> expose (_S::S_ "Combine")
    do
      let
        decideThese = case _ of
          This a -> a
          That b -> b
          Both a b -> decide (AST.Pair a b)
        decide = binOpWith (previewF (_S::S_ "RecordLit")) \l r -> case _, _ of
          Just a, Just b -> anew (_S::S_ "RecordLit") $
              Dhall.Map.unionWith (pure $ pure <<< decideThese) a b
          Just a, _ | Dhall.Map.isEmpty a -> simpler r
          _, Just b | Dhall.Map.isEmpty b -> simpler l
          _, _ | judgEq l r -> simpler r
          _, _ -> reconstruct (_S::S_ "Combine") (AST.Pair l r)
      decide
    >>> expose (_S::S_ "CombineTypes")
    do
      let
        decideThese = case _ of
          This a -> a
          That b -> b
          Both a b -> decide (AST.Pair a b)
        decide = binOpWith (previewF (_S::S_ "Record")) \l r -> case _, _ of
          Just a, Just b -> anew (_S::S_ "Record") $
              Dhall.Map.unionWith (pure $ pure <<< decideThese) a b
          Just a, _ | Dhall.Map.isEmpty a -> simpler r
          _, Just b | Dhall.Map.isEmpty b -> simpler l
          _, _ | judgEq l r -> simpler r
          _, _ -> reconstruct (_S::S_ "CombineTypes") (AST.Pair l r)
      decide
    >>> expose (_S::S_ "Prefer")
    do
      let
        preference = case _ of
          This a -> a
          That b -> b
          Both _ a -> a -- Prefer the right operand!
        decide = binOpWith (previewF (_S::S_ "RecordLit")) \l r -> case _, _ of
          Just a, Just b -> anew (_S::S_ "RecordLit") $
              Dhall.Map.unionWith (pure $ pure <<< preference) a b
          Just a, _ | Dhall.Map.isEmpty a -> simpler r
          _, Just b | Dhall.Map.isEmpty b -> simpler l
          _, _ | judgEq l r -> simpler r
          _, _ -> reconstruct (_S::S_ "Prefer") (AST.Pair l r)
      decide
    >>> expose (_S::S_ "Merge")
    do \(AST.MergeF x y mty) ->
          let
            default _ = reconstruct (_S::S_ "Merge") (AST.MergeF x y mty)
          in x # exposeW (_S::S_ "RecordLit")
            do \kvsX ->
                -- TODO: union field
                y # exposeW (_S::S_ "App")
                  do \(AST.Pair field vY) ->
                      field # exposeW (_S::S_ "Field")
                        do \(Tuple kY _) ->
                            case Dhall.Map.get kY kvsX of
                              Just vX -> anewAnd (_S::S_ "App") (AST.Pair vX vY)
                              _ -> default unit
                        do \_ -> field # exposeW (_S::S_ "None")
                            do \_ ->
                                case Dhall.Map.get "None" kvsX of
                                  Just vX -> simpler vX
                                  _ -> default unit
                            do \_ -> default unit
                  do \_ ->
                      y # exposeW (_S::S_ "Field")
                        do \(Tuple kY _) ->
                            case Dhall.Map.get kY kvsX of
                              Just vX -> simpler vX
                              _ -> default unit
                        do \_ -> y # exposeW (_S::S_ "Some")
                            do \(Identity vY) ->
                                case Dhall.Map.get "Some" kvsX of
                                  Just vX -> anewAnd (_S::S_ "App") (AST.Pair vX vY)
                                  _ -> default unit
                            do \_ -> default unit
            do \_ -> default unit
    >>> expose (_S::S_ "ToMap")
    do \(Product (Tuple (Identity x) mty)) ->
          let
            default _ = reconstruct (_S::S_ "ToMap") (Product (Tuple (Identity x) mty))
          in x # exposeW (_S::S_ "RecordLit")
            do \kvs ->
                anew (_S::S_ "ListLit") $ Product $
                  Tuple (if Dhall.Map.isEmpty kvs then mty else Nothing) $
                    Dhall.Map.toUnfoldableSorted kvs <#> \(Tuple k v) ->
                      anew (_S::S_ "RecordLit") $ Dhall.Map.fromFoldable
                        [ Tuple "mapKey" (anew (_S::S_ "TextLit") (TextLit k))
                        , Tuple "mapValue" v
                        ]
            do \_ -> default unit
    >>> expose (_S::S_ "Field")
    do \(Tuple k r) ->
        let
          default _ = reconstruct (_S::S_ "Field") (Tuple k r)
        in r # exposeW (_S::S_ "RecordLit")
          do
            \kvs ->
              case Dhall.Map.get k kvs of
                Just v -> simpler v
                _ -> default unit
          do \_ -> r # exposeW (_S::S_ "Project")
              do \(Product (Tuple (Identity r') _)) ->
                  anewAnd (_S::S_ "Field") (Tuple k r')
              do \_ -> r # exposeW (_S::S_ "Prefer")
                  do \(AST.Pair r1 r2) ->
                      r1 # exposeW (_S::S_ "RecordLit")
                        do \kvs ->
                            case Dhall.Map.get k kvs of
                              -- Ensure this is strictly better
                              Just _v | Dhall.Map.size kvs == 1 ->
                                default unit
                              Just v ->
                                let single = Dhall.Map.singleton k v in
                                anewAnd (_S::S_ "Field") $ Tuple k $
                                anewAnd (_S::S_ "Prefer")
                                  (AST.Pair (anew (_S::S_ "RecordLit") single) r2)
                              Nothing ->
                                anewAnd (_S::S_ "Field") $ Tuple k r2
                        do \_ -> r2 # exposeW (_S::S_ "RecordLit")
                            do \kvs ->
                                case Dhall.Map.get k kvs of
                                  Just v ->
                                    simpler v
                                  Nothing ->
                                    anewAnd (_S::S_ "Field") $ Tuple k r1
                            do \_ -> default unit
                  do \_ -> r # exposeW (_S::S_ "Combine")
                      do \(AST.Pair r1 r2) ->
                          r1 # exposeW (_S::S_ "RecordLit")
                            do \kvs ->
                                case Dhall.Map.get k kvs of
                                  -- Ensure this is strictly better
                                  Just _v | Dhall.Map.size kvs == 1 ->
                                    default unit
                                  Just v ->
                                    let single = Dhall.Map.singleton k v in
                                    anewAnd (_S::S_ "Field") $ Tuple k $
                                    anewAnd (_S::S_ "Combine")
                                      (AST.Pair (anew (_S::S_ "RecordLit") single) r2)
                                  Nothing ->
                                    anewAnd (_S::S_ "Field") $ Tuple k r2
                            do \_ -> r2 # exposeW (_S::S_ "RecordLit")
                                do \kvs ->
                                    case Dhall.Map.get k kvs of
                                      -- Ensure this is strictly better
                                      Just _v | Dhall.Map.size kvs == 1 ->
                                        default unit
                                      Just v ->
                                        let single = Dhall.Map.singleton k v in
                                        anewAnd (_S::S_ "Field") $ Tuple k $
                                        anewAnd (_S::S_ "Combine")
                                          (AST.Pair r1 (anew (_S::S_ "RecordLit") single))
                                      Nothing ->
                                        anewAnd (_S::S_ "Field") $ Tuple k r1
                                do \_ -> default unit
                      do \_ -> default unit
    >>> expose (_S::S_ "Project")
    do \(Product (Tuple (Identity r) proj)) ->
        let
          default _ = reconstruct (_S::S_ "Project") (Product (Tuple (Identity r) proj))
          default1 ks _ =
            case proj of
              Right _ -> anew (_S::S_ "Project")
                (Product (Tuple (Identity r) (Left (AppF.App ks))))
              Left _ -> default unit
          default2 ks _ =
            r # exposeW (_S::S_ "Project")
              do \(Product (Tuple (Identity rr) _)) ->
                  anewAnd (_S::S_ "Project") (Product (Tuple (Identity rr) proj))
              do default1 ks
          mks = case proj of
            Left (AppF.App ks) -> Just ks
            Right t -> t # exposeW (_S::S_ "Record") (Just <<< (unit <$ _)) \_ -> Nothing
        in case mks of
          Nothing -> default unit
          Just ks
            | Dhall.Map.isEmpty ks -> anew (_S::S_ "RecordLit") Dhall.Map.empty
            | otherwise -> r # exposeW (_S::S_ "RecordLit")
                do
                  \kvs ->
                    let
                      adapt = case _ of
                        Both (_ :: Unit) v -> Just v
                        _ -> Nothing
                    in
                      anewAnd (_S::S_ "RecordLit") $
                        Dhall.Map.unionWith (pure adapt) ks kvs
                do \_ -> r # exposeW (_S::S_ "Prefer")
                    do \(AST.Pair r1 r2) ->
                        r2 # exposeW (_S::S_ "RecordLit")
                          do \kvs ->
                              let
                                -- kvs restricted to the keys in kvs
                                taken = Dhall.Map.unionWith take ks kvs
                                take _ = case _ of
                                  Both _ v -> Just v
                                  _ -> Nothing
                                -- ks minus the items from kvs
                                left = Dhall.Map.unionWith leave ks kvs
                                leave _ = case _ of
                                  This u -> Just u
                                  _ -> Nothing
                              in anewAnd (_S::S_ "Prefer") $ AST.Pair
                                (anew (_S::S_ "Project") (Product (Tuple (Identity r1) (Left (AppF.App left)))))
                                (anew (_S::S_ "RecordLit") taken)
                          do default2 ks
                    do default2 ks
    >>> expose (_S::S_ "With")
    do \(Product (Tuple (Identity e) (Tuple ks v))) ->
        let
          default _ =
            reconstruct (_S::S_ "With") (Product (Tuple (Identity e) (Tuple ks v)))
          k0 = NEA.head ks
          alterer = case NEA.fromArray (NEA.tail ks) of
            Nothing -> \_ -> v
            Just ks' -> case _ of
              Nothing ->
                Foldable.foldr (\k v' -> anew (_S::S_ "RecordLit") (Dhall.Map.singleton k v')) v ks'
              Just v0 ->
                anew (_S::S_ "With") (Product (Tuple (Identity v0) (Tuple ks' v)))
        in e # exposeW (_S::S_ "RecordLit")
          do \kvs -> anewAnd (_S::S_ "RecordLit") $
              Dhall.Map.alter k0 (Just <<< alterer) kvs
          do default
    -- NOTE: eta-normalization, added
    {-
    >>> expose (_S::S_ "Lam")
    do \(AST.BindingBody var ty body) ->
        body #
        let
          default :: Unit -> W node
          default _ = reconstruct (_S::S_ "Lam") (AST.BindingBody var ty body)
        in (\_ -> default unit)
        # exposeW (_S::S_ "App")
          \(AST.Pair fn arg) ->
            let var0 = AST.V var 0 in
            if unlayers (extractW arg) == AST.mkVar var0 && not (un Disj (freeIn var0 (extractW fn)))
              then instead \_ ->
                extractW $
                  node.recurse (Variant.inj (_S::S_ "shift") { variable: var0, delta: (-1) }) $
                    extractW fn
              else default unit
    -}
    -- composing with <<< gives this case priority
    >>> identity <<< expose (_S::S_ "App") \(AST.Pair fn arg) ->
      fn # exposeW (_S::S_ "Lam")
        do \(AST.BindingBody var _ body) -> instead \_ -> extractW $ go $
            shiftSubstShift0 var (extractW arg) (extractW body)
        do \_ ->
            let
              -- TODO: add builtins
              again = go >>> extractW
              appNormed = unwrap (builtinsG judgEqW again <> normApp) (lowerOps node) $ on (~)
                (extractW >>> Lens.view (appsG node)) fn arg
            in case appNormed of
              Just ret -> instead ret
              _ -> reconstruct (_S::S_ "App") (AST.Pair fn arg)

normalizeWithW :: forall m a. MapLike String m => Eq a =>
  Normalizer m a -> Expr m a ->
  W (Expr m a)
normalizeWithW (GNormalizer normApp) =
  Variant.inj (_S::S_ "normalize") mempty # runAlgebraExprM
    (Variant.case_ # normalizeWithAlgGW (GNormalizer \_ -> normApp unit))

builtinsG :: forall node ops v m a. MapLike String m =>
  (node -> node -> Boolean) ->
  (node -> node) ->
  GNormalizer (AST.ExprLayerRow m a)
    (Variant (ShiftSubstAlg node v)) node ops
builtinsG = conversionsG <> naturalfnsG <> listfnsG

mk ::
  forall sym f rest all node ops.
    Functor f =>
    Row.Cons sym f rest all =>
    IsSymbol sym =>
  { layer :: VariantF all node -> node
  | ops
  } ->
  Proxy sym ->
  f node -> node
mk node sym children = node.layer $ VariantF.inj sym $ children

mkAppsF ::
  forall sym f rest all node ops.
    Functor f =>
    Row.Cons sym f rest all =>
    IsSymbol sym =>
  { layer :: VariantF all node -> node
  | ops
  } ->
  Proxy sym ->
  f node -> AppsF node
mkAppsF node sym children = NoApp $ mk node sym children

fusionsG :: forall all' i node ops.
  (node -> node -> Boolean) ->
  (node -> node) ->
  GNormalizer
    ( "App" :: AST.Pair
    , "ListBuild" :: UNIT
    , "ListFold" :: UNIT
    , "NaturalBuild" :: UNIT
    , "NaturalFold" :: UNIT
    | all'
    )
    i node ops
fusionsG _judgEq _again = GNormalizer \node -> case _ of
  -- build/fold fusion for `List`
  -- App (App ListBuild _) (App (App ListFold _) e') -> loop e'
  listbuild~_~(listfold~_~e')
    | noappG node (_S::S_ "ListBuild") listbuild
    , noappG node (_S::S_ "ListFold") listfold ->
      pure \_ -> Lens.review (appsG node) e'
  -- build/fold fusion for `Natural`
  -- App NaturalBuild (App NaturalFold e') -> loop e'
  naturalbuild~(naturalfold~e')
    | noappG node (_S::S_ "NaturalBuild") naturalbuild
    , noappG node (_S::S_ "NaturalFold") naturalfold ->
      pure \_ -> Lens.review (appsG node) e'
  _ -> empty

conversionsG :: forall all' node v ops.
  (node -> node -> Boolean) ->
  (node -> node) ->
  GNormalizer
    ( "App" :: AST.Pair
    , "NaturalToInteger" :: UNIT
    , "NaturalShow" :: UNIT
    , "IntegerShow" :: UNIT
    , "IntegerToDouble" :: UNIT
    , "IntegerNegate" :: UNIT
    , "IntegerClamp" :: UNIT
    , "DoubleShow" :: UNIT
    , "NaturalLit" :: CONST Natural
    , "IntegerLit" :: CONST Integer
    , "TextLit" :: AST.TextLitF
    , "DoubleLit" :: CONST Double
    , "TextShow" :: UNIT
    , "TextReplace" :: UNIT
    | all'
    )
    (Variant (ShiftSubstAlg node v)) node ops
conversionsG _judgEq again = GNormalizer \node -> case _ of
  naturaltointeger~naturallit
    | noappG node (_S::S_ "NaturalToInteger") naturaltointeger
    , Just n <- noapplitG node (_S::S_ "NaturalLit") naturallit ->
      pure \_ -> mk node (_S::S_ "IntegerLit") $ wrap $ Num.naturalToInteger n
  naturalshow~naturallit
    | noappG node (_S::S_ "NaturalShow") naturalshow
    , Just n <- noapplitG node (_S::S_ "NaturalLit") naturallit ->
      pure \_ -> mk node (_S::S_ "TextLit") $ AST.TextLit $ show n
  integershow~integerlit
    | noappG node (_S::S_ "IntegerShow") integershow
    , Just n <- noapplitG node (_S::S_ "IntegerLit") integerlit ->
      pure \_ -> mk node (_S::S_ "TextLit") $ AST.TextLit $ show n
  integertodouble~integerlit
    | noappG node (_S::S_ "IntegerToDouble") integertodouble
    , Just n <- noapplitG node (_S::S_ "IntegerLit") integerlit ->
      pure \_ -> mk node (_S::S_ "DoubleLit") $ wrap $ wrap $ Num.integerToNumber n
  integernegate~integerlit
    | noappG node (_S::S_ "IntegerNegate") integernegate
    , Just n <- noapplitG node (_S::S_ "IntegerLit") integerlit ->
      pure \_ -> mk node (_S::S_ "IntegerLit") $ wrap $ negate n
  integerclamp~integerlit
    | noappG node (_S::S_ "IntegerClamp") integerclamp
    , Just n <- noapplitG node (_S::S_ "IntegerLit") integerlit ->
      pure \_ -> mk node (_S::S_ "NaturalLit") $ wrap $ Num.naturalFromInteger n
  doubleshow~doublelit
    | noappG node (_S::S_ "DoubleShow") doubleshow
    , Just n <- noapplitG node (_S::S_ "DoubleLit") doublelit ->
      pure \_ -> mk node (_S::S_ "TextLit") $ AST.TextLit $ show n
  textshow~textlit
    | noappG node (_S::S_ "TextShow") textshow
    , Just (TextLit n) <- noapplitG' node (_S::S_ "TextLit") textlit ->
      pure \_ -> mk node (_S::S_ "TextLit") $ AST.TextLit $ textShow n
  textreplace~needle~_replacement~haystack
    | noappG node (_S::S_ "TextReplace") textreplace
    , Just (TextLit "") <- noapplitG' node (_S::S_ "TextLit") needle ->
      pure \_ -> Lens.review (appsG node) haystack
  textreplace~needle~replacement~haystack
    | noappG node (_S::S_ "TextReplace") textreplace
    , Just (TextLit n) <- noapplitG' node (_S::S_ "TextLit") needle
    , Just (TextLit h) <- noapplitG' node (_S::S_ "TextLit") haystack ->
      case noapplitG' node (_S::S_ "TextLit") replacement of
        Just (TextLit r) -> pure \_ ->
          mk node (_S::S_ "TextLit") $ AST.TextLit $
            String.replaceAll (String.Pattern n) (String.Replacement r) h
        _ -> pure \_ ->
          let r = Lens.review (appsG node) replacement in
          case Array.unsnoc (String.split (String.Pattern n) h) of
            Nothing -> mk node (_S::S_ "TextLit") $ AST.TextLit ""
            Just { init, last } ->
              again $ mk node (_S::S_ "TextLit") $
                Array.foldr (AST.TextInterp <@> r) (AST.TextLit last) init
  _ -> Nothing

textShow :: String -> String
textShow s = "\"" <> replaced <> "\"" where
  replaced = Array.foldl (flip (uncurry String.replaceAll)) s replacements
  replacements =
    [ Tuple (String.Pattern "\\") (String.Replacement "\\\\")
    , Tuple (String.Pattern "\"") (String.Replacement "\\\"")
    , Tuple (String.Pattern "\x08") (String.Replacement "\\b")
    , Tuple (String.Pattern "\x0c") (String.Replacement "\\f")
    , Tuple (String.Pattern "\n") (String.Replacement "\\n")
    , Tuple (String.Pattern "\r") (String.Replacement "\\r")
    , Tuple (String.Pattern "\t") (String.Replacement "\\t")
    , Tuple (String.Pattern "$") (String.Replacement "\\u0024")
    ] <> nonprintable
  nonprintable = Array.range 0x00 0x1F # Array.mapMaybe \c ->
    toEnum c <#> \lit ->
    Tuple (String.Pattern (String.fromCodePointArray [lit]))
      (String.Replacement ("\\u00" <> (if c < 0x10 then "0" else "") <> Int.toStringAs Int.hexadecimal c))

unlayersG :: forall node m a all unused r.
  Row.Union all unused (ExprLayerRow m a) =>
  { unlayer :: node -> VariantF all node | r } ->
  node -> Expr m a
unlayersG node e = AST.embedW (VariantF.expand (node.unlayer e <#> unlayersG node))

naturalfnsG :: forall all' node v ops.
  (node -> node -> Boolean) ->
  (node -> node) ->
  GNormalizer
    ( "App" :: AST.Pair
    , "Natural" :: UNIT
    , "NaturalFold" :: UNIT
    , "NaturalBuild" :: UNIT
    , "NaturalIsZero" :: UNIT
    , "NaturalEven" :: UNIT
    , "NaturalOdd" :: UNIT
    , "NaturalLit" :: CONST Natural
    , "NaturalSubtract" :: UNIT
    , "BoolLit" :: CONST Boolean
    , "Var" :: CONST AST.Var
    , "Lam" :: AST.BindingBody
    , "NaturalPlus" :: AST.Pair
    | all'
    )
    (Variant (ShiftSubstAlg node v)) node ops
naturalfnsG judgEq again = GNormalizer \node -> case _ of
  -- App (App (App (App NaturalFold (NaturalLit n0)) t) succ') zero
  naturalfold~naturallit~t~succ'~zero'
    | noappG node (_S::S_ "NaturalFold") naturalfold
    , Just n0 <- noapplitG node (_S::S_ "NaturalLit") naturallit -> pure \_ ->
      let
        t' = again (Lens.review (appsG node) t)
        succE = Lens.review (appsG node) succ'
        zeroE = Lens.review (appsG node) zero'
      in if boundedTypeG node t'
        then
          let
            strictLoop n =
              if n > zero then
                again (mk node (_S::S_ "App") $ AST.Pair succE (strictLoop (n +- one)))
              else again zeroE
          in strictLoop n0
        else
          let
            lazyLoop n =
              if n > zero then
                mk node (_S::S_ "App") $ AST.Pair succE (lazyLoop (n +- one))
              else zeroE
          in again (lazyLoop n0)
  naturalbuild~g
    | noappG node (_S::S_ "NaturalBuild") naturalbuild -> pure \_ ->
      let
        zero_ = NoApp $ mk node (_S::S_ "NaturalLit") zero
        succ_ = NoApp $ mk node (_S::S_ "Lam") $ AST.BindingBody "x" (mk node (_S::S_ "Natural") mempty) $
          mk node (_S::S_ "NaturalPlus") $ AST.Pair
            do mk node (_S::S_ "Var") $ wrap (AST.V "x" 0)
            do mk node (_S::S_ "NaturalLit") one
      in again $ Lens.review (appsG node) (g~(mkAppsF node (_S::S_ "Natural") mempty)~succ_~zero_)
  naturaliszero~naturallit
    | noappG node (_S::S_ "NaturalIsZero") naturaliszero
    , Just n <- noapplitG node (_S::S_ "NaturalLit") naturallit ->
      pure \_ -> mk node (_S::S_ "BoolLit") $ wrap $ n == zero
  naturaleven~naturallit
    | noappG node (_S::S_ "NaturalEven") naturaleven
    , Just n <- noapplitG node (_S::S_ "NaturalLit") naturallit ->
      pure \_ -> mk node (_S::S_ "BoolLit") $ wrap $ Num.even $ Num.naturalToInteger n
  naturalodd~naturallit
    | noappG node (_S::S_ "NaturalOdd") naturalodd
    , Just n <- noapplitG node (_S::S_ "NaturalLit") naturallit ->
      pure \_ -> mk node (_S::S_ "BoolLit") $ wrap $ not Num.even $ Num.naturalToInteger n
  naturalsubtract~naturallit0~naturallit1
    | noappG node (_S::S_ "NaturalSubtract") naturalsubtract
    , a <- noapplitG node (_S::S_ "NaturalLit") naturallit0
    , b <- noapplitG node (_S::S_ "NaturalLit") naturallit1 ->
      case a, b of
        Just n, Just m ->
          pure \_ -> mk node (_S::S_ "NaturalLit") $ wrap $ m +- n
        Just n, _ | n == zero ->
          pure \_ -> Lens.review (appsG node) naturallit1
        _, Just m | m == zero ->
          pure \_ -> Lens.review (appsG node) naturallit1
        _, _ | (Lens.review (appsG node) naturallit0) `judgEq` (Lens.review (appsG node) naturallit1) ->
          pure \_ -> mk node (_S::S_ "NaturalLit") (wrap zero)
        _, _ -> Nothing
  _ -> Nothing

listfnsG :: forall all' node v ops m. MapLike String m =>
  (node -> node -> Boolean) ->
  (node -> node) ->
  GNormalizer
    ( "App" :: AST.Pair
    , "List" :: UNIT
    , "ListBuild" :: UNIT
    , "ListFold" :: UNIT
    , "ListLength" :: UNIT
    , "ListHead" :: UNIT
    , "ListLast" :: UNIT
    , "ListIndexed" :: UNIT
    , "ListReverse" :: UNIT
    , "ListLit" :: Product Maybe Array
    , "Lam" :: AST.BindingBody
    , "ListAppend" :: AST.Pair
    , "Var" :: CONST AST.Var
    , "NaturalLit" :: CONST Natural
    , "Some" :: Identity
    , "None" :: UNIT
    , "Record" :: m
    , "Natural" :: UNIT
    , "RecordLit" :: m
    | all'
    )
    (Variant (ShiftSubstAlg node v)) node ops
listfnsG _judgEq again = GNormalizer \node -> case _ of
  listbuild~t~g
    | noappG node (_S::S_ "ListBuild") listbuild -> pure \_ ->
      let
        ty = Lens.review (appsG node) t
        ty' = extract $ node.recurse (Variant.inj (_S::S_ "shift") { variable: AST.V "a" 0, delta: 1 }) ty
        list = mkAppsF node (_S::S_ "List") mempty ~ NoApp ty'
        cons = NoApp $ mk node (_S::S_ "Lam") $ AST.BindingBody "a" ty $
          mk node (_S::S_ "Lam") $ AST.BindingBody "as" (mk node (_S::S_ "App") $ AST.Pair (mk node (_S::S_ "List") mempty) ty') $
            mk node (_S::S_ "ListAppend") $ AST.Pair
              (mk node (_S::S_ "ListLit") (product Nothing (pure (mk node (_S::S_ "Var") (wrap $ AST.V "a" 0)))))
              (mk node (_S::S_ "Var") (wrap $ AST.V "as" 0))
        nil = NoApp $ mk node (_S::S_ "ListLit") (product (Just (mk node (_S::S_ "App") $ AST.Pair (mk node (_S::S_ "List") mempty) ty)) empty)
      in again $ Lens.review (appsG node) $
        (g~list~cons~nil)
  listfold~_~listlit~t~cons~nil
    | noappG node (_S::S_ "ListFold") listfold
    , Just (Product (Tuple _ xs)) <- noapplitG' node (_S::S_ "ListLit") listlit ->
      pure \_ ->
      let
        t' = again (Lens.review (appsG node) t)
        consE = Lens.review (appsG node) cons
        nilE = Lens.review (appsG node) nil
      in if boundedTypeG node t'
        then
          let
            strictNil = again nilE
            strictCons y ys = again
              (mk node (_S::S_ "App") $ AST.Pair (mk node (_S::S_ "App") $ AST.Pair consE y) ys)
          in foldr strictCons strictNil xs
        else
          let
            lazyNil = nilE
            lazyCons y ys = mk node (_S::S_ "App") $ AST.Pair (mk node (_S::S_ "App") $ AST.Pair consE y) ys
          in again (foldr lazyCons lazyNil xs)
  listlength~_~listlit
    | noappG node (_S::S_ "ListLength") listlength
    , Just (Product (Tuple _ xs)) <- noapplitG' node (_S::S_ "ListLit") listlit ->
      pure \_ ->
        mk node (_S::S_ "NaturalLit") $ wrap $ Num.naturalFromInt $ Array.length xs
  listhead~t~listlit
    | noappG node (_S::S_ "ListHead") listhead
    , Just (Product (Tuple _ xs)) <- noapplitG' node (_S::S_ "ListLit") listlit ->
      pure \_ -> again $
      case Array.head xs of
        Just x -> mk node (_S::S_ "Some") $ Identity x
        Nothing -> mk node (_S::S_ "App") $ AST.Pair (mk node (_S::S_ "None") mempty) (Lens.review (appsG node) t)
  listlast~t~listlit
    | noappG node (_S::S_ "ListLast") listlast
    , Just (Product (Tuple _ xs)) <- noapplitG' node (_S::S_ "ListLit") listlit ->
      pure \_ -> again $
      case Array.last xs of
        Just x -> mk node (_S::S_ "Some") $ Identity x
        Nothing -> mk node (_S::S_ "App") $ AST.Pair (mk node (_S::S_ "None") mempty) (Lens.review (appsG node) t)
  listindexed~t~listlit
    | noappG node (_S::S_ "ListIndexed") listindexed
    , Just (Product (Tuple _ xs)) <- noapplitG' node (_S::S_ "ListLit") listlit ->
      pure \_ -> again $
        let
          mty' = if not Array.null xs then Nothing else
            Just $ mk node (_S::S_ "App") $ AST.Pair (mk node (_S::S_ "List") mempty) $
              mk node (_S::S_ "Record") $ Dhall.Map.fromFoldable
                [ Tuple "index" $ mk node (_S::S_ "Natural") mempty
                , Tuple "value" (Lens.review (appsG node) t)
                ]
          adapt i x = mk node (_S::S_ "RecordLit") $ Dhall.Map.fromFoldable
            [ Tuple "index" $ mk node (_S::S_ "NaturalLit") $ wrap $ Num.naturalFromInt i
            , Tuple "value" x
            ]
        in mk node (_S::S_ "ListLit") $ product mty' (mapWithIndex adapt xs)
  listreverse~_~listlit
    | noappG node (_S::S_ "ListReverse") listreverse
    , Just (Product (Tuple mty xs)) <- noapplitG' node (_S::S_ "ListLit") listlit ->
      pure \_ -> again $
        mk node (_S::S_ "ListLit") $ product mty (Array.reverse xs)
  _ -> Nothing

-- | Returns `true` if two expressions are α-equivalent and β-equivalent and
-- | `false` otherwise
judgmentallyEqual' :: forall m a. MapLike String m => Eq a => Expr m a -> Expr m a -> Boolean
judgmentallyEqual' eL0 eR0 = alphaBetaNormalize eL0 == alphaBetaNormalize eR0
  where
    alphaBetaNormalize :: Expr m a -> Expr m a
    alphaBetaNormalize = Variables.alphaNormalize <<< normalize

-- | Additionally normalizes the order of fields
judgmentallyEqual :: forall m a. MapLike String m => Eq a => Expr m a -> Expr m a -> Boolean
judgmentallyEqual = judgmentallyEqual' `on` AST.unordered

-- | Check if an expression is in a normal form given a context of evaluation.
isNormalized :: forall m a. MapLike String m => Eq a => Expr m a -> Boolean
isNormalized = isNormalizedWith mempty

-- | Quickly check if an expression is in normal form
isNormalizedWith :: forall m a. MapLike String m => Eq a => Normalizer m a -> Expr m a -> Boolean
isNormalizedWith ctx e0 = case normalizeWithW ctx e0 of
  W (Tuple (Conj wasNormalized) _) -> wasNormalized

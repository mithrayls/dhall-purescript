module Dhall.Core.AST.Operations where

import Prelude

import Control.Monad.Free (hoistFree)
import Data.Bifunctor (lmap)
import Data.Functor.App (App(..))
import Data.Functor.Compose (Compose(..))
import Data.Functor.Product (bihoistProduct)
import Data.Functor.Variant (VariantF)
import Data.Functor.Variant as VariantF
import Data.Map (Map)
import Data.Newtype (over, unwrap)
import Data.Traversable (class Traversable, sequence, traverse)
import Dhall.Core.AST.Types (Expr(..), ExprLayerRow, SimpleExpr, embedW, projectW)
import Dhall.Map (class MapLike)
import Dhall.Map as Dhall.Map
import Prim.Row as Row
import Type.Proxy (Proxy)

-- Some general operations for the Expr AST
hoistExpr :: forall m m'. Functor m' => (m ~> m') -> Expr m ~> Expr m'
hoistExpr nat = over Expr $ hoistFree \a ->
  VariantF.over
    { "Project": (bihoistProduct identity (lmap (over App nat)) $ _)
    , "Record": ($) nat
    , "RecordLit": ($) nat
    , "Union": ($) over Compose nat
    } identity a

conv :: forall m m'. MapLike String m => MapLike String m' => Expr m ~> Expr m'
conv = hoistExpr Dhall.Map.conv

convTo :: forall m m'. MapLike String m => MapLike String m' => Proxy m' -> Expr m ~> Expr m'
convTo = hoistExpr <<< Dhall.Map.convTo

unordered :: forall m. MapLike String m => Expr m ~> Expr (Map String)
unordered = hoistExpr Dhall.Map.unordered

-- | Just a helper to handle recursive rewrites: top-down, requires explicit
-- | recursion for the cases that are handled by the rewrite.
rewriteTopDown :: forall r r' m a b.
  Row.Union r r' (ExprLayerRow m b) =>
  (
    (VariantF r (Expr m a) -> Expr m b) ->
    VariantF (ExprLayerRow m a) (Expr m a) ->
    Expr m b
  ) ->
  Expr m a -> Expr m b
rewriteTopDown rw1 = go where
  go expr = rw1 (map go >>> VariantF.expand >>> embedW) $ projectW expr

-- | Another recursion helper: bottom-up, recursion already happens before
-- | the rewrite gets ahold of it. Just follow the types.
rewriteBottomUp :: forall r r' m a b.
  Row.Union r r' (ExprLayerRow m b) =>
  (
    (VariantF r (Expr m b) -> Expr m b) ->
    VariantF (ExprLayerRow m a) (Expr m b) ->
    Expr m b
  ) ->
  Expr m a -> Expr m b
rewriteBottomUp rw1 = go where
  go expr = rw1 (VariantF.expand >>> embedW) $ go <$> projectW expr

rewriteTopDownA :: forall r r' m a b f. Applicative f =>
  Traversable (VariantF r) =>
  Row.Union r r' (ExprLayerRow m b) =>
  (
    (VariantF r (Expr m a) -> f (Expr m b)) ->
    VariantF (ExprLayerRow m a) (Expr m a) ->
    f (Expr m b)
  ) ->
  Expr m a -> f (Expr m b)
rewriteTopDownA rw1 = go where
  trav = traverse :: forall x y. (x -> f y) -> VariantF r x -> f (VariantF r y)
  go expr = rw1 (trav go >>> map (VariantF.expand >>> embedW)) $ projectW expr

rewriteBottomUpM :: forall r r' m a b f. Monad f => Traversable m =>
  Row.Union r r' (ExprLayerRow m b) =>
  (
    (VariantF r (Expr m b) -> (Expr m b)) ->
    VariantF (ExprLayerRow m a) (Expr m b) ->
    f (Expr m b)
  ) ->
  Expr m a -> f (Expr m b)
rewriteBottomUpM rw1 = go where
  go expr = rw1 (VariantF.expand >>> embedW) =<< traverse go (projectW expr)

rewriteBottomUpA :: forall r r' m a b f. Applicative f => Traversable m =>
  Row.Union r r' (ExprLayerRow m b) =>
  (
    (VariantF r (Expr m b) -> (Expr m b)) ->
    VariantF (ExprLayerRow m a) (f (Expr m b)) ->
    f (Expr m b)
  ) ->
  Expr m a -> f (Expr m b)
rewriteBottomUpA rw1 = go where
  go expr = rw1 (VariantF.expand >>> embedW) $ go <$> (projectW expr)

rewriteBottomUpA' :: forall r r' m a b f. Applicative f => Traversable m =>
  Traversable (VariantF r) =>
  Row.Union r r' (ExprLayerRow m b) =>
  (
    (VariantF r (f (Expr m b)) -> f (Expr m b)) ->
    VariantF (ExprLayerRow m a) (f (Expr m b)) ->
    f (Expr m b)
  ) ->
  Expr m a -> f (Expr m b)
rewriteBottomUpA' rw1 = go where
  go expr = rw1 (sequence >>> map (VariantF.expand >>> embedW)) $ go <$> (projectW expr)

rehydrate :: forall m a. Functor m => SimpleExpr -> Expr m a
rehydrate = map absurd <<< hoistExpr (absurd <<< unwrap <<< unwrap)

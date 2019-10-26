{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE FlexibleInstances #-}

module AST.Variable where

import AST.V0_16
import Data.Map.Strict
import ElmFormat.Mapping


data Ref ns
    = VarRef ns LowercaseIdentifier
    | TagRef ns UppercaseIdentifier
    | OpRef SymbolIdentifier
    deriving (Eq, Ord, Show, Functor)


instance MapNamespace a b (Ref a) (Ref b) where
    mapNamespace = fmap


instance MapReferences a b (Ref a) (Ref b) where
    mapReferences fu fl = \case
        VarRef ns l -> uncurry VarRef $ fl (ns, l)
        TagRef ns u -> uncurry TagRef $ fu (ns, u)
        OpRef o -> OpRef o



-- LISTINGS

-- | A listing of values. Something like (a,b,c) or (..) or (a,b,..)
data BeforeDots; data AfterDots
data Listing a
    = ExplicitListing a Bool
    | OpenListing (C2 BeforeDots AfterDots ())
    | ClosedListing
    deriving (Eq, Ord, Show) -- TODO: is Ord needed?


data AfterValue
type CommentedMap k v =
    Map k (C2 BeforeValue AfterValue v)


-- | A value that can be imported or exported
data Value
    = Value !LowercaseIdentifier
    | OpValue SymbolIdentifier
    | Union (C1 After UppercaseIdentifier) (Listing (CommentedMap UppercaseIdentifier ()))
    deriving (Eq, Ord, Show) -- TODO: is Ord needed?
